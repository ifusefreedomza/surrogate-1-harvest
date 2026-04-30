#!/usr/bin/env bash
# Surrogate-1 v2 — Anchor cron loop (runs on OCI A1.Flex 4 OCPU / 24 GB ARM).
#
# Synced from HF Space repo via state-sync-from-hf.sh — DON'T edit on the
# anchor directly. Push changes to axentx/surrogate-1 git, next sync (15
# min) propagates here.
#
# Anchor has WAY more headroom than HF Space cpu-basic:
#   • 4 OCPU + 24 GB RAM (vs cpu-basic 16 GB)
#   • Persistent /data (no factory_reboot wipes)
#   • Local Ollama with qwen2.5-coder:7b (free local inference)
#   • ARM linux — torch/transformers work, vLLM via wheels
#
# So anchor runs HEAVY workers + uses LOCAL LLM for enrich. HF Space stays
# light (orchestration + 3 workers + cron). Both share the same coordinator
# claim queue via HTTP API on coordinator E2 instance.
set -uo pipefail
[[ -f /home/surrogate/surrogate/.env ]] && { set -a; source /home/surrogate/surrogate/.env 2>/dev/null; set +a; }

REPO=/home/surrogate/surrogate
DATA=/data
LOG=/data/logs/anchor-cron.log
mkdir -p /data/logs /data/v2 /data/bulk-mirror /data/state

# Anchor-specific config (ARM, 24 GB)
export LOW_MEM="${LOW_MEM:-0}"             # ARM has plenty
export BULK_WORKERS="${BULK_WORKERS:-2}"
export STREAM_WORKERS="${STREAM_WORKERS:-4}"
export OLLAMA_HOST="${OLLAMA_HOST:-127.0.0.1:11434}"
export SURROGATE_LADDER="${SURROGATE_LADDER:-ollama,zero-gpu,cerebras,groq,hf-inference,gemini}"  # local first
export DISCORD_WEBHOOK="${DISCORD_WEBHOOK:-}"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] anchor-cron-loop start (LOW_MEM=$LOW_MEM, $BULK_WORKERS bulk + $STREAM_WORKERS stream)" >> "$LOG"

notify() {
    [[ -z "$DISCORD_WEBHOOK" ]] && return
    curl -s -X POST -H "Content-Type: application/json" \
        -d "{\"content\":\"⚓ anchor: $1\"}" "$DISCORD_WEBHOOK" >/dev/null 2>&1 || true
}

# ── Boot-time worker fleet ─────────────────────────────────────────────
# Spawn workers as background processes; they pull from coordinator HTTP API.
# (Coordinator hostname = coordinator E2 instance — DNS via /etc/hosts or env.)
COORDINATOR_URL="${COORDINATOR_URL:-http://10.0.1.10:8001}"

start_workers_once() {
    local kind=$1 n=$2
    for i in $(seq 1 "$n"); do
        wid="anchor-${kind}-w$i"
        if ! pgrep -f "${kind}-mirror-worker.sh ${wid}" >/dev/null; then
            nohup bash "${REPO}/bin/v2/${kind}-mirror-worker.sh" "$wid" \
                > "/data/logs/${kind}-worker-${i}.log" 2>&1 &
        fi
    done
}

start_workers_once bulk "$BULK_WORKERS"
start_workers_once streaming "$STREAM_WORKERS"
echo "[$(date '+%H:%M:%S')] worker fleet up: $BULK_WORKERS bulk + $STREAM_WORKERS streaming" >> "$LOG"

# ── Cron loop ──────────────────────────────────────────────────────────
while true; do
    M=$(($(date +%s) / 60))

    # ── Round 5 (sustainability loops) ─────────────────────────────────
    [[ $((M % 360)) -eq 90 ]]   && bash "${REPO}/bin/v2/self-improve-loop.sh"     >>"$LOG" 2>&1 &
    [[ $((M % 30))  -eq 22 ]]   && python3 "${REPO}/bin/v2/tool-trace-collector.py" >>"$LOG" 2>&1 &
    [[ $((M % 60))  -eq 17 ]]   && python3 "${REPO}/bin/v2/voyager-skills.py" export >>"$LOG" 2>&1 &
    [[ $((M % 1440)) -eq 420 ]] && {
        POOL=$(ls -t /data/bulk-mirror/*.jsonl 2>/dev/null | head -1)
        [[ -n "$POOL" ]] && python3 "${REPO}/bin/v2/active-learning.py" \
            --pool "$POOL" --n 200 --scan 1500 >>"$LOG" 2>&1 &
    }
    [[ $((M % 1440)) -eq 480 ]] && {
        WIN=$(ls -t /data/v2/self-improve/winners-*.jsonl 2>/dev/null | head -1)
        [[ -n "$WIN" ]] && python3 "${REPO}/bin/v2/constitutional-loop.py" \
            --input "$WIN" --n 200 >>"$LOG" 2>&1 &
    }

    # ── Round 7 (frontier 2026 + harvester + enrich) ───────────────────
    [[ $((M % 30)) -eq 9 ]]    && bash "${REPO}/bin/v2/aggressive-harvester.sh" >>"$LOG" 2>&1 &
    [[ $((M % 60)) -eq 35 ]]   && bash "${REPO}/bin/v2/enrich-pipeline.sh"      >>"$LOG" 2>&1 &
    [[ $((M % 1440)) -eq 540 ]] && {
        LATEST=$(ls -t /data/v2/enriched/*.jsonl 2>/dev/null | head -1)
        [[ -n "$LATEST" ]] && python3 "${REPO}/bin/v2/teachable-prompt-filter.py" \
            --input "$LATEST" --out "/data/v2/teachable-$(date +%Y%m%d).jsonl" \
            --n 1000 --keep-target 200 >>"$LOG" 2>&1 &
    }
    [[ $((M % 10080)) -eq 600 ]] && {
        for f in /data/v2/verify-traces.jsonl /data/v2/self-improve/winners-*.jsonl; do
            [[ -f "$f" ]] || continue
            python3 "${REPO}/bin/v2/abstract-cot-compressor.py" \
                --input "$f" --out "${f%.jsonl}-compressed.jsonl" >>"$LOG" 2>&1
        done
    }

    # ── Round 8 (worker keep-alive — anchor is durable, but defensive) ─
    [[ $((M % 30)) -eq 25 ]] && {
        # If any worker died, respawn (idempotent — checks pgrep first)
        for kind in bulk streaming; do
            n_var="$([ "$kind" = "bulk" ] && echo "$BULK_WORKERS" || echo "$STREAM_WORKERS")"
            for i in $(seq 1 "$n_var"); do
                wid="anchor-${kind}-w$i"
                if ! pgrep -f "${kind}-mirror-worker.sh ${wid}" >/dev/null; then
                    nohup bash "${REPO}/bin/v2/${kind}-mirror-worker.sh" "$wid" \
                        > "/data/logs/${kind}-worker-${i}.log" 2>&1 &
                    echo "[$(date '+%H:%M:%S')] respawned $wid" >>"$LOG"
                fi
            done
        done
    }

    # ── Anchor-only: push enriched data to HF Hub every 30 min ─────────
    [[ $((M % 30)) -eq 4 ]] && {
        # Push enriched files (anchor has bandwidth + persistent state)
        if [[ -d /data/v2/enriched ]] && command -v python3 >/dev/null; then
            python3 "${REPO}/bin/v2/push-to-hub.py" \
                --src /data/v2/enriched \
                --repo "axentx/surrogate-1-training-pairs" \
                >>"$LOG" 2>&1 &
        fi
    }

    # ── Heartbeat every 30 min ─────────────────────────────────────────
    [[ $((M % 30)) -eq 0 ]] && {
        N_BULK=$(pgrep -cf bulk-mirror-worker.sh)
        N_STR=$(pgrep -cf streaming-mirror-worker.sh)
        N_DATA=$(find /data/bulk-mirror -name "*.jsonl" 2>/dev/null | wc -l | tr -d ' ')
        echo "[$(date '+%H:%M:%S')] heartbeat: bulk=$N_BULK stream=$N_STR mirror_files=$N_DATA" >>"$LOG"
    }

    sleep 60
done
