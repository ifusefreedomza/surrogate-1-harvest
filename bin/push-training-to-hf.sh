#!/usr/bin/env bash
# Push accumulated training pairs from local jsonl → axentx/surrogate-1-training-pairs (HF dataset).
# Idempotent: tracks last-pushed line offset so duplicates are skipped.
set -uo pipefail
set -a; source "$HOME/.hermes/.env" 2>/dev/null; set +a

SRC="$HOME/.surrogate/training-pairs.jsonl"
OFFSET_FILE="$HOME/.surrogate/.training-push-offset"
LOG="$HOME/.claude/logs/training-push.log"
mkdir -p "$(dirname "$LOG")"

[[ ! -f "$SRC" ]] && { echo "[$(date +%H:%M:%S)] no source $SRC" | tee -a "$LOG"; exit 0; }

CUR_LINES=$(wc -l < "$SRC" | tr -d ' ')
PREV_OFFSET=$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)
NEW_LINES=$(( CUR_LINES - PREV_OFFSET ))

echo "[$(date +%H:%M:%S)] training push: $NEW_LINES new pairs (offset=$PREV_OFFSET, total=$CUR_LINES)" | tee -a "$LOG"
[[ $NEW_LINES -le 0 ]] && exit 0

# Slice new pairs to a daily file for upload
DATE_TAG=$(date +%Y-%m-%d)
SLICE="$HOME/.surrogate/.push-slice-${DATE_TAG}.jsonl"
tail -n "$NEW_LINES" "$SRC" >> "$SLICE"

# Try huggingface-cli first; fall back to python HfApi
if command -v huggingface-cli >/dev/null 2>&1 && [[ -n "${HF_TOKEN:-}" ]]; then
    huggingface-cli upload axentx/surrogate-1-training-pairs \
        "$SLICE" "auto-orchestrate-${DATE_TAG}.jsonl" \
        --repo-type dataset \
        --commit-message "auto-orchestrate: +${NEW_LINES} pairs ($(date +%H:%M))" \
        --token "$HF_TOKEN" 2>&1 | tee -a "$LOG"
else
    /usr/bin/python3 - "$SLICE" "$NEW_LINES" "$DATE_TAG" <<'PYEOF' 2>&1 | tee -a "$LOG"
import sys, os
slice_path, n_pairs, date_tag = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    from huggingface_hub import HfApi
except ImportError:
    print("huggingface_hub not installed — install via: pip install huggingface_hub")
    sys.exit(1)
api = HfApi()
api.upload_file(
    path_or_fileobj=slice_path,
    path_in_repo=f"auto-orchestrate-{date_tag}.jsonl",
    repo_id="axentx/surrogate-1-training-pairs",
    repo_type="dataset",
    commit_message=f"auto-orchestrate: +{n_pairs} pairs",
)
print(f"  ✅ uploaded {n_pairs} pairs to axentx/surrogate-1-training-pairs/auto-orchestrate-{date_tag}.jsonl")
PYEOF
fi

# Update offset on success
echo "$CUR_LINES" > "$OFFSET_FILE"
echo "[$(date +%H:%M:%S)] push complete · offset → $CUR_LINES" | tee -a "$LOG"
