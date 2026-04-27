#!/usr/bin/env bash
# Continuous qwen-coder worker — local = unlimited, free, always-on.
# Picks one 'ready' code priority every 5 min → generates implementation
# in ~/.hermes/workspace/qwen-coder/ → reviewer (Sonnet) inspects every 15 min.
#
# Scope: code generation only (implementation plan + actual code).
# Philosophy: cheap + fast iteration — reviewer catches bad outputs.
set -u

LOG="$HOME/.surrogate/logs/qwen-coder-worker.log"
OUT_DIR="$HOME/.hermes/workspace/qwen-coder"
SHARED="$HOME/.hermes/workspace/swarm-shared"
mkdir -p "$(dirname "$LOG")" "$OUT_DIR"

# Pick priority: honor HERMES_PRIO_ID pin from daemon, else top 'ready'.
PRIORITY=$(python3 -c "
import json, os, sys
PINNED = os.environ.get('HERMES_PRIO_ID', '').strip()
try:
    with open('$SHARED/priority.json') as f: d = json.load(f)
    if PINNED:
        for p in d.get('priorities', []):
            if p.get('id') == PINNED and p.get('status') == 'ready':
                print(json.dumps(p)); sys.exit(0)
    for p in d.get('priorities', []):
        if p.get('status') == 'ready':
            print(json.dumps(p)); sys.exit(0)
except Exception as e:
    print('', file=sys.stderr)
" 2>>"$LOG")

if [[ -z "$PRIORITY" ]]; then
    echo "[$(date '+%H:%M:%S')] no 'ready' priority — skipping" >> "$LOG"
    exit 0
fi

PRIO_ID=$(echo "$PRIORITY" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['id'])")
PRIO_TITLE=$(echo "$PRIORITY" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['title'])")
PRIO_PROJECT=$(echo "$PRIORITY" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('project','?'))")

# Skip if we just worked on it (rate-limit per-priority to 30 min)
LAST="$OUT_DIR/.last_$PRIO_ID"
if [[ -f "$LAST" ]] && [[ $(($(date +%s) - $(cat "$LAST" 2>/dev/null || echo 0))) -lt 1800 ]]; then
    echo "[$(date '+%H:%M:%S')] $PRIO_ID just worked, skipping" >> "$LOG"
    exit 0
fi

DATE=$(date +%Y-%m-%d_%H-%M)
OUT="$OUT_DIR/${PRIO_ID}_${DATE}.md"
START=$(date +%s)
echo "[$(date '+%H:%M:%S')] $PRIO_ID start ($PRIO_PROJECT: $PRIO_TITLE)" >> "$LOG"

# -------- Context: repo map + RAG-grounded code examples (anti-hallucination) --------
REPO_MAP=""
MAP_FILE="$SHARED/repo-maps/${PRIO_PROJECT}.md"
[[ -f "$MAP_FILE" ]] && REPO_MAP=$(head -c 3000 "$MAP_FILE")

# RAG: fetch real code examples from THIS project's actual codebase via FTS
# Grounds the model in real APIs/imports/patterns instead of hallucinating
RAG_EXAMPLES=""
if [[ -x "$HOME/.surrogate/bin/ask-sqlite.py" ]]; then
    RAG_EXAMPLES=$(python3 "$HOME/.surrogate/bin/ask-sqlite.py" \
        "$PRIO_PROJECT $PRIO_TITLE" 2>/dev/null | head -c 2500)
fi

# Few-shot: 1 recent ACCEPTED output (quality >=7) as anti-hallucination anchor
FEWSHOT=""
for review in $(ls -t "$HOME/.hermes/workspace/qwen-coder-reviews/"*.json 2>/dev/null | head -20); do
    if grep -l '"quality_score": *[789]' "$review" > /dev/null 2>&1 || \
       grep -l '"quality_score": *10' "$review" > /dev/null 2>&1; then
        OUT_FILE=$(basename "$review" .review.json)
        OUT_PATH="$HOME/.hermes/workspace/qwen-coder/${OUT_FILE}.md"
        if [[ -f "$OUT_PATH" ]]; then
            FEWSHOT=$(head -c 1500 "$OUT_PATH")
            break
        fi
    fi
done

# Inject recent REJECTIONS as anti-patterns (what NOT to do) — last 3 rejected reasons
ANTI_PATTERNS=""
for review in $(ls -t "$HOME/.hermes/workspace/qwen-coder-reviews/"*.json 2>/dev/null | head -10); do
    bugs=$(python3 -c "
import json, sys, re
try:
    txt = open('$review').read()
    m = re.search(r'\{.*\}', txt, re.DOTALL)
    if not m: sys.exit()
    d = json.loads(m.group(0))
    if d.get('verdict') in ('reject', 'rework') and d.get('bugs'):
        for b in d['bugs'][:2]:
            print(f'- {b[:120]}')
except: pass
" 2>/dev/null)
    [[ -n "$bugs" ]] && ANTI_PATTERNS="$ANTI_PATTERNS$bugs"$'\n'
done
ANTI_PATTERNS=$(echo "$ANTI_PATTERNS" | head -8)

PROMPT=$(cat <<EOF
You are qwen-coder (local, always-on). Implement this priority.

⚠️ ANTI-HALLUCINATION RULES — VIOLATE ANY = REWRITE:
1. Only use imports that appear in the RAG examples below OR that are in Python stdlib / well-known packages
2. Every function you call must either: be defined in your output, be in stdlib, or appear in the RAG examples
3. If unsure an API exists, DO NOT guess — say "TBD: verify <api-name> exists" instead
4. All code must run end-to-end without ImportError / NameError / AttributeError
5. Tests must import the same module they test (no hallucinated test utilities)

PROJECT: $PRIO_PROJECT
PRIORITY_ID: $PRIO_ID
TITLE: $PRIO_TITLE

=== REPO MAP (real files + symbols in this project) ===
$REPO_MAP

=== RAG: actual code patterns from this project (MATCH this style) ===
$RAG_EXAMPLES

$(if [[ -n "$FEWSHOT" ]]; then echo "=== FEW-SHOT: example of an ACCEPTED qwen-coder output (quality ≥ 7) ==="; echo "$FEWSHOT"; fi)

$(if [[ -n "$ANTI_PATTERNS" ]]; then echo "=== ANTI-PATTERNS: previously rejected — DO NOT repeat these bugs ==="; echo "$ANTI_PATTERNS"; fi)

=== YOUR TASK ===

STEP 1 — DRAFT (think first, show work):
Write a 3-line "plan" then write the code. No explanation paragraphs.

STEP 2 — SELF-CRITIQUE (mandatory, do before final):
Before your final answer, list 3 things that could go wrong with your draft:
- Import X might not exist → verify
- Edge case Y might break → handle
- Test Z might fail type check → fix

STEP 3 — FINAL OUTPUT:
Then produce ONLY this structure (no extra prose):

## Implementation Plan
- 3-5 bullets: files to create/modify, dependency order

## Code
\`\`\`<language>
// complete, runnable, all imports verified
\`\`\`

## Tests
\`\`\`<language>
// 2-3 cases: happy path + 1 edge case + 1 error case
\`\`\`

## Acceptance Criteria
- 3 bullets: how to verify it works (exact commands/assertions)

Total under 2000 tokens. No "// TODO" stubs.
EOF
)

# Call qwen-coder direct (keep_alive=-1 pins it in memory).
# Build JSON body via Python-heredoc + env var → avoids bash brace-expansion bug on '{...}'.
BODY=$(PROMPT_VAR="$PROMPT" python3 <<'PYEOF'
import json, os
body = {
    "model": "qwen2.5-coder:7b",
    "messages": [{"role": "user", "content": os.environ["PROMPT_VAR"]}],
    "max_tokens": 3000,
    "temperature": 0.1,
    "top_p": 0.9,
    "keep_alive": -1,
}
print(json.dumps(body))
PYEOF
)
RESP=$(curl -sS --max-time 180 \
    http://localhost:11434/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d "$BODY" 2>>"$LOG")

RESULT=$(echo "$RESP" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d['choices'][0]['message']['content'])
except Exception as e:
    print(f'[parse-fail] {e}', file=sys.stderr)
    sys.exit(1)
" 2>>"$LOG")

DUR=$(( $(date +%s) - START ))
if [[ -z "$RESULT" ]]; then
    echo "[$(date '+%H:%M:%S')] $PRIO_ID FAILED after ${DUR}s" >> "$LOG"
    exit 1
fi

# Write output with frontmatter
cat > "$OUT" <<EOF
---
priority_id: $PRIO_ID
project: $PRIO_PROJECT
title: $PRIO_TITLE
model: qwen2.5-coder:7b (local)
ran_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
duration_s: $DUR
reviewed: false
---

$RESULT
EOF

date +%s > "$LAST"
echo "[$(date '+%H:%M:%S')] $PRIO_ID OK → $OUT (${DUR}s, $(wc -c < "$OUT") bytes)" >> "$LOG"
