#!/usr/bin/env python3
"""axentx dataset-mirror — pull ON-TOPIC public datasets into our training corpus.

User directive (2026-05-02):
  > 'ไปหา data มาเทรนให้ได้มากที่สุด แต่ต้องเป็น เรื่องที่เกี่ยวกัน
  >  รู้อยู่แล้วนี้ต้องใช้ข้อมูลด้านไหนบ้าง'

Pulls samples from curated public HF datasets (code/devops/SRE/security/
agent/reasoning) and converts to our pairs format, appending to
state/training-pairs.jsonl. The existing push-training-to-hf cron then
ships them to axentx/surrogate-1-pairs-C.

Sources are TIGHTLY scoped to what Surrogate-1 actually needs:
  - Code: Python/TypeScript/Rust/Go (matches our axentx project stack)
  - DevOps: Terraform/K8s/AWS/GCP (matches our infra)
  - SRE: incident response, runbooks
  - Security: IAM, CVE, hardening
  - Agent: SWE-Bench, multi-step tool use
  - Reasoning: math/code reasoning
  - Dialog: instruction following

State: state/.dataset-mirror-cursor.json tracks per-source byte offset so
we never re-pull what we already mirrored (cross-VM via D1 too — only
ONE VM should run this daemon, default GCP).
"""
from __future__ import annotations

import datetime
import hashlib
import json
import os
import sys
import urllib.request
from pathlib import Path

REPO_ROOT = Path(os.environ.get("REPO_ROOT", "/opt/surrogate-1-harvest"))
sys.path.insert(0, str(REPO_ROOT / "bin"))
from axentx_pipeline import log, daemon_loop  # noqa: E402

POLL_SEC = int(os.environ.get("MIRROR_POLL_SEC", "3600"))   # 1h
PER_SOURCE_BUDGET = int(os.environ.get("MIRROR_PER_SOURCE", "500"))  # rows/cycle
PAIRS_FILE = REPO_ROOT / "state" / "training-pairs.jsonl"
HOME_PAIRS = Path.home() / ".surrogate" / "training-pairs.jsonl"
CURSOR_FILE = REPO_ROOT / "state" / ".dataset-mirror-cursor.json"

HF_TOKEN = os.environ.get("HF_TOKEN", "")
UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")


# Curated source list — each entry: (dataset_id, config, split, mapper).
# mapper(row) returns {prompt, response} or None to skip.
def _map_codealpaca(r):
    inst = r.get("instruction") or ""
    inp = r.get("input") or ""
    out = r.get("output") or ""
    if not (inst and out): return None
    prompt = inst + (f"\n\nInput:\n{inp}" if inp else "")
    return {"prompt": prompt, "response": out}


def _map_evolinst(r):
    inst = r.get("instruction") or ""
    out = r.get("output") or ""
    if not (inst and out): return None
    return {"prompt": inst, "response": out}


def _map_oasst(r):
    role = r.get("role")
    if role != "assistant": return None
    parent_text = r.get("parent_text") or r.get("user_text") or ""
    text = r.get("text") or ""
    if not (parent_text and text): return None
    return {"prompt": parent_text, "response": text}


def _map_swe_bench(r):
    repo = r.get("repo", "")
    inst = r.get("problem_statement") or ""
    patch = r.get("patch") or ""
    if not (inst and patch): return None
    return {
        "prompt": f"Repo: {repo}\n\nIssue:\n{inst}\n\nProduce a patch.",
        "response": patch,
    }


def _map_open_orca(r):
    sys_msg = r.get("system_prompt") or ""
    q = r.get("question") or ""
    a = r.get("response") or ""
    if not (q and a): return None
    return {"prompt": (sys_msg + "\n\n" + q).strip(), "response": a}


SOURCES = [
    # (id, config, split, kind, mapper)
    ("sahil2801/CodeAlpaca-20k",        None, "train", "code-alpaca",  _map_codealpaca),
    ("nickrosh/Evol-Instruct-Code-80k-v1", None, "train", "code-evol", _map_evolinst),
    ("ise-uiuc/Magicoder-OSS-Instruct-75K", None, "train", "code-magicoder", _map_evolinst),
    ("OpenAssistant/oasst2",            None, "train", "dialog-oasst", _map_oasst),
    ("Open-Orca/OpenOrca",              None, "train", "reasoning-orca", _map_open_orca),
    ("princeton-nlp/SWE-bench_Lite",    None, "test",  "agent-swebench", _map_swe_bench),
]


def load_cursor() -> dict:
    if CURSOR_FILE.exists():
        try: return json.loads(CURSOR_FILE.read_text())
        except: pass
    return {"offsets": {}}


def save_cursor(c: dict) -> None:
    CURSOR_FILE.parent.mkdir(parents=True, exist_ok=True)
    CURSOR_FILE.write_text(json.dumps(c, indent=2))


def fetch_dataset_rows(repo_id: str, config: str | None, split: str,
                       offset: int, limit: int) -> list[dict]:
    """Pull rows via HF datasets-server. Page in 100-row chunks (datasets-
    server caps per-request at 100; a single 'length=500' returns 422)."""
    cfg = config or "default"
    headers = {"User-Agent": UA}
    if HF_TOKEN:
        headers["Authorization"] = f"Bearer {HF_TOKEN}"
    rows: list[dict] = []
    page = 100
    fetched = 0
    while fetched < limit:
        chunk = min(page, limit - fetched)
        url = (f"https://datasets-server.huggingface.co/rows"
               f"?dataset={urllib.parse.quote(repo_id)}"
               f"&config={cfg}&split={split}"
               f"&offset={offset + fetched}&length={chunk}")
        req = urllib.request.Request(url, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                d = json.loads(r.read())
        except Exception as e:
            log("ds-mirror", f"  ✗ fetch fail {repo_id} @{offset+fetched}: "
                            f"{type(e).__name__}: {str(e)[:100]}")
            break
        page_rows = [row.get("row") or {} for row in (d.get("rows") or [])]
        if not page_rows:
            break
        rows.extend(page_rows)
        fetched += len(page_rows)
        if len(page_rows) < chunk:
            break  # end of split
    return rows


def append_pair(rec: dict) -> None:
    line = json.dumps(rec, ensure_ascii=False) + "\n"
    PAIRS_FILE.parent.mkdir(parents=True, exist_ok=True)
    with PAIRS_FILE.open("a") as f:
        f.write(line)
    try:
        HOME_PAIRS.parent.mkdir(parents=True, exist_ok=True)
        with HOME_PAIRS.open("a") as f:
            f.write(line)
    except (PermissionError, OSError):
        pass


def fingerprint(prompt: str, response: str) -> str:
    return hashlib.sha256((prompt[:500] + "|" + response[:500]).encode()).hexdigest()[:16]


# Avoid importing urllib.parse at top — use it lazily here
import urllib.parse  # noqa: E402


def do_one_cycle() -> bool:
    cur = load_cursor()
    offsets = cur.setdefault("offsets", {})
    n_total = 0
    for repo_id, config, split, kind, mapper in SOURCES:
        key = f"{repo_id}|{config or 'default'}|{split}"
        offset = offsets.get(key, 0)
        log("ds-mirror", f"▸ {repo_id} (offset={offset}, +{PER_SOURCE_BUDGET})")
        rows = fetch_dataset_rows(repo_id, config, split, offset, PER_SOURCE_BUDGET)
        if not rows:
            log("ds-mirror", f"  (no rows — possibly end of split)")
            continue
        n_kept = 0
        for r in rows:
            try:
                pair = mapper(r)
            except Exception:
                pair = None
            if not pair:
                continue
            rec = {
                "flavor": f"sft-public-{kind}",
                "id": f"public-{kind}-{fingerprint(pair['prompt'], pair['response'])}",
                "prompt": pair["prompt"][:6000],
                "response": pair["response"][:6000],
                "source": f"public:{repo_id}",
                "captured_at": datetime.datetime.utcnow().isoformat() + "Z",
            }
            append_pair(rec)
            n_kept += 1
        offsets[key] = offset + len(rows)
        n_total += n_kept
        log("ds-mirror", f"  ✓ {n_kept}/{len(rows)} kept (cumulative offset={offsets[key]})")
    cur["offsets"] = offsets
    save_cursor(cur)
    log("ds-mirror", f"cycle done — {n_total} new pairs appended")
    return n_total > 0


if __name__ == "__main__":
    daemon_loop("ds-mirror", POLL_SEC, do_one_cycle)
