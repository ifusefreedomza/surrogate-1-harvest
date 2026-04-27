#!/usr/bin/env bash
# Continuous domain-scrape loop — runs until taxonomy exhausted or duration hit
# Uses rotating tokens from pool. Respects 60 search/min combined (1 call/2s avg).
#
# Usage:
#   domain-scrape-loop.sh              # default 15 min
#   domain-scrape-loop.sh 1800         # 30 min
set -u
DUR="${1:-900}"
PARALLEL="${2:-3}"
LOG="$HOME/.surrogate/logs/domain-scrape-loop.log"
START=$(date +%s)
BEFORE_PAIRS=$(wc -l ~/axentx/surrogate/data/training-jsonl/*.jsonl 2>/dev/null | tail -1 | awk '{print $1}')
BEFORE_LEDGER=$(sqlite3 ~/.surrogate/state/scrape-ledger.db "SELECT COUNT(*) FROM scraped" 2>/dev/null)

echo "═══ LOOP START $(date +%H:%M:%S) duration=${DUR}s parallel=$PARALLEL" | tee -a "$LOG"
echo "   before: pairs=$BEFORE_PAIRS ledger_repos=$BEFORE_LEDGER" | tee -a "$LOG"

ITER=0
while true; do
    NOW=$(date +%s)
    [[ $((NOW - START)) -gt $DUR ]] && break
    ITER=$((ITER + 1))

    # Health check — break if load > 10
    LOAD=$(uptime | awk -F'load averages:' '{print $2}' | awk '{print int($1)}')
    if [[ $LOAD -gt 10 ]]; then
        echo "  [iter=$ITER] load=$LOAD pause 30s" | tee -a "$LOG"
        sleep 30
        continue
    fi

    # Fire N parallel instances, each picks different domain via ledger
    for i in $(seq 1 $PARALLEL); do
        (
            ~/.surrogate/bin/github-domain-scrape.sh >> "$LOG" 2>&1
        ) &
    done
    wait  # wait all parallel to finish (30-60s typical)

    # Pause 10s to let rate limit breathe
    sleep 10

    # Progress every 5 iters
    if (( ITER % 5 == 0 )); then
        PAIRS=$(wc -l ~/axentx/surrogate/data/training-jsonl/*.jsonl 2>/dev/null | tail -1 | awk '{print $1}')
        LEDGER=$(sqlite3 ~/.surrogate/state/scrape-ledger.db "SELECT COUNT(*) FROM scraped" 2>/dev/null)
        echo "  [iter=$ITER $((NOW - START))s] pairs=$PAIRS (+$((PAIRS - BEFORE_PAIRS))) ledger=$LEDGER (+$((LEDGER - BEFORE_LEDGER)))" | tee -a "$LOG"
    fi
done

AFTER_PAIRS=$(wc -l ~/axentx/surrogate/data/training-jsonl/*.jsonl 2>/dev/null | tail -1 | awk '{print $1}')
AFTER_LEDGER=$(sqlite3 ~/.surrogate/state/scrape-ledger.db "SELECT COUNT(*) FROM scraped" 2>/dev/null)
echo "═══ LOOP DONE $(date +%H:%M:%S)" | tee -a "$LOG"
echo "   iters: $ITER" | tee -a "$LOG"
echo "   pairs added:  $((AFTER_PAIRS - BEFORE_PAIRS))" | tee -a "$LOG"
echo "   ledger added: $((AFTER_LEDGER - BEFORE_LEDGER)) repos" | tee -a "$LOG"
