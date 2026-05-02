#!/usr/bin/env python3
"""Convert agent pipeline decisions into training data.

Walks swarm-shared/{done,dev-queue,review-queue,qa-queue,commit-queue} and
extracts THREE flavors of training signal from every completed (or in-flight)
agent task:

  1. SFT pairs   — (prompt, final_approved_output) for every cycle that
                   reached qa or commit. Standard supervised fine-tuning data.

  2. DPO pairs   — (prompt, chosen=refined_output, rejected=initial_output)
                   for every cycle where reviewer rejected attempt 1 and dev
                   refined to attempt 2+ that eventually got approved.
                   This is the "self-improve from your own rejections" signal.

  3. Verdict triples — (proposal, reject_reason, refined_proposal).
                   Trains the model to read reviewer feedback and address
                   the SPECIFIC blockers cited rather than rewriting blindly.

Output: NDJSON appended to state/training-pairs.jsonl + per-flavor shards
written to state/training-shards/. push-training-to-hf.sh picks them up
and pushes to axentx/surrogate-1-self-improve on the next cron tick.

Idempotent: tracks last-processed item ID in state/.decisions-cursor so
we never double-emit. Safe to run on a tight cron.

Why this exists:
  Audit 2026-05-02 found that agent decisions were piling up in done/
  with no path back to training. ~100+ rejection cycles burned LLM tokens
  without any of that signal being captured. This closes the loop.
"""
from __future__ import annotations

import datetime
import hashlib
import json
import os
import sys
from pathlib import Path

# bin/lib is a sibling — make it importable regardless of CWD
sys.path.insert(0, str(Path(__file__).parent))
from lib.pii_scrub import scrub_record  # noqa: E402

REPO_ROOT = Path(os.environ.get("REPO_ROOT", "/opt/surrogate-1-harvest"))
SHARED = REPO_ROOT / "state" / "swarm-shared"
# Local-to-repo file (audit trail + retry safety)
PAIRS_FILE = REPO_ROOT / "state" / "training-pairs.jsonl"
# Canonical training-pairs feed the existing push-training-to-hf.sh cron
# already drains incrementally to axentx/surrogate-1-training-pairs.
# Mirror to BOTH so the push script picks our agent records up automatically.
HOME_PAIRS_FILE = Path(
    os.environ.get("HOME_PAIRS_FILE",
                   str(Path.home() / ".surrogate" / "training-pairs.jsonl"))
)
SHARDS_DIR = REPO_ROOT / "state" / "training-shards"
CURSOR_FILE = REPO_ROOT / "state" / ".decisions-cursor.json"
LOG_FILE = REPO_ROOT / "logs" / "agent-decisions-to-pairs.log"

PAIRS_FILE.parent.mkdir(parents=True, exist_ok=True)
SHARDS_DIR.mkdir(parents=True, exist_ok=True)
LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
try:
    HOME_PAIRS_FILE.parent.mkdir(parents=True, exist_ok=True)
except (PermissionError, OSError):
    HOME_PAIRS_FILE = None  # daemon user can't write home — silent skip


def log(msg: str) -> None:
    line = f"[{datetime.datetime.utcnow().isoformat()}Z] {msg}"
    print(line, flush=True)
    with LOG_FILE.open("a") as f:
        f.write(line + "\n")


def load_cursor() -> set[str]:
    if not CURSOR_FILE.exists():
        return set()
    try:
        return set(json.loads(CURSOR_FILE.read_text()).get("seen_ids", []))
    except Exception:
        return set()


def save_cursor(seen: set[str]) -> None:
    CURSOR_FILE.write_text(json.dumps({"seen_ids": sorted(seen)}, indent=2))


def append_jsonl(path: Path, rec: dict) -> None:
    with path.open("a") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")


def make_prompt(item: dict) -> str:
    """Reconstruct the original task prompt from item metadata."""
    return (
        f"Project: {item.get('project','?')}\n"
        f"Focus: {item.get('focus','?')}\n\n"
        f"Task: produce the highest-value incremental improvement under the "
        f"{item.get('focus','?')} focus. Output sections: Diagnosis, Proposed "
        f"change, Implementation (concrete code/diff), Verification."
    )


def extract_pairs(item: dict) -> list[dict]:
    """Mine (prompt, output) examples from a single completed agent item.

    Returns multiple records — one per training flavor:
      - flavor=sft: prompt + final approved/forced-approved output
      - flavor=dpo: prompt + chosen (refined) + rejected (initial)
      - flavor=verdict: proposal + reject_reason + refined_proposal
    """
    out: list[dict] = []
    history = item.get("history", []) or []
    if not history:
        return out

    prompt = make_prompt(item)
    item_id = item.get("id", "")
    project = item.get("project", "?")
    focus = item.get("focus", "?")

    # Walk history and split into stages
    dev_attempts = [h for h in history if h.get("stage") == "dev"]
    review_outputs = [h for h in history if h.get("stage") == "review"]
    qa_outputs = [h for h in history if h.get("stage") == "qa"]
    commit_outputs = [h for h in history if h.get("stage") == "commit"]

    # ── Flavor 1: SFT ────────────────────────────────────────────────────
    # Final approved output is the LAST dev attempt that made it past review.
    # If item.needs_iteration=True (escape hatch) we still emit the SFT
    # record but tag it so trainer can downweight if desired.
    if commit_outputs or qa_outputs:
        final_dev = dev_attempts[-1]["output"] if dev_attempts else ""
        if final_dev:
            out.append({
                "flavor": "sft",
                "id": f"{item_id}-sft",
                "prompt": prompt,
                "response": final_dev,
                "project": project,
                "focus": focus,
                "needs_iteration": bool(item.get("needs_iteration")),
                "n_attempts": len(dev_attempts),
                "source": "axentx-agent-pipeline",
            })

    # ── Flavor 2: DPO preference pair ────────────────────────────────────
    # Whenever there are 2+ dev attempts, the LAST is "chosen" (passed
    # review eventually) and the FIRST is "rejected" (the one reviewer
    # blocked). This is the self-improvement signal.
    if len(dev_attempts) >= 2:
        out.append({
            "flavor": "dpo",
            "id": f"{item_id}-dpo",
            "prompt": prompt,
            "chosen": dev_attempts[-1]["output"],
            "rejected": dev_attempts[0]["output"],
            "project": project,
            "focus": focus,
            "n_attempts": len(dev_attempts),
            "source": "axentx-agent-pipeline-rework",
        })

    # ── Flavor 3: Verdict-triple (read-and-address-feedback) ─────────────
    # For each (rejected_dev, review_reject, refined_dev) triple, emit a
    # training example that teaches the model "given THIS proposal and
    # THIS reviewer feedback, produce the refined version".
    for i in range(min(len(dev_attempts) - 1, len(review_outputs))):
        rejected_dev = dev_attempts[i].get("output", "")
        review = review_outputs[i].get("output", "")
        refined_dev = dev_attempts[i + 1].get("output", "")
        if not (rejected_dev and review and refined_dev):
            continue
        out.append({
            "flavor": "verdict",
            "id": f"{item_id}-v{i}",
            "prompt": (
                f"You proposed this change:\n\n{rejected_dev[:3000]}\n\n"
                f"The reviewer rejected with this feedback:\n\n{review[:2000]}\n\n"
                f"Produce a refined version that addresses each cited blocker."
            ),
            "response": refined_dev,
            "project": project,
            "focus": focus,
            "source": "axentx-agent-pipeline-verdict",
        })

    return out


def fingerprint(rec: dict) -> str:
    """Stable hash so duplicate records (re-runs) get deduped downstream."""
    body = json.dumps(
        {k: rec.get(k) for k in ("flavor", "prompt", "response", "chosen", "rejected")},
        sort_keys=True,
    )
    return hashlib.sha256(body.encode()).hexdigest()[:16]


def main() -> int:
    seen = load_cursor()
    n_new_items = 0
    n_records = {"sft": 0, "dpo": 0, "verdict": 0}
    n_skipped_seen = 0

    # Walk every queue subdir — items in done/ are complete; items elsewhere
    # might be in-flight but still produce useful partial signal (especially
    # DPO + verdict, which only need 2 dev attempts to be valid).
    for q in ("done", "dev-queue", "review-queue", "qa-queue", "commit-queue"):
        qdir = SHARED / q
        if not qdir.exists():
            continue
        for path in sorted(qdir.glob("*.json")):
            try:
                item = json.loads(path.read_text())
            except Exception as e:
                log(f"  skip unreadable {path.name}: {e}")
                continue
            item_id = item.get("id", "")
            if not item_id or item_id in seen:
                n_skipped_seen += 1
                continue
            recs = extract_pairs(item)
            if not recs:
                # Don't mark as seen yet — incomplete items may produce records later
                continue
            for rec in recs:
                # PII scrub before fingerprint so deduping reflects the
                # cleaned content (matches what we actually publish).
                rec = scrub_record(rec)
                rec["fp"] = fingerprint(rec)
                rec["captured_at"] = datetime.datetime.utcnow().isoformat() + "Z"
                append_jsonl(PAIRS_FILE, rec)
                # Mirror into the canonical home pairs file so the existing
                # push-training-to-hf.sh cron picks up agent records on its
                # next tick and ships them to axentx/surrogate-1-training-pairs.
                if HOME_PAIRS_FILE:
                    try:
                        append_jsonl(HOME_PAIRS_FILE, rec)
                    except Exception:
                        pass
                # Per-flavor shard for downstream consumers (trainer, push-to-hf)
                shard = SHARDS_DIR / f"{rec['flavor']}.jsonl"
                append_jsonl(shard, rec)
                n_records[rec["flavor"]] += 1
            seen.add(item_id)
            n_new_items += 1

    save_cursor(seen)

    total_new = sum(n_records.values())
    log(
        f"processed: {n_new_items} new items → "
        f"sft={n_records['sft']} dpo={n_records['dpo']} verdict={n_records['verdict']} "
        f"(total records appended: {total_new}; skipped already-seen: {n_skipped_seen})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
