#!/usr/bin/env bash
# Hermes start orchestrator for HF Space.
# Boots: Redis → Ollama → pull model → all Hermes daemons → keep-alive HTTP server
set -uo pipefail

LOG_DIR="${HOME}/.claude/logs"
mkdir -p "$LOG_DIR"

echo "[$(date +%H:%M:%S)] hermes-hf-space boot start" | tee "$LOG_DIR/boot.log"

# ── 1. Bind secrets from HF Space env to ~/.hermes/.env ─────────────────────
mkdir -p ~/.hermes
{
    echo "# Auto-generated from HF Space secrets at boot"
    [[ -n "${OPENROUTER_API_KEY:-}" ]]   && echo "OPENROUTER_API_KEY=$OPENROUTER_API_KEY"
    [[ -n "${GEMINI_API_KEY:-}" ]]       && echo "GEMINI_API_KEY=$GEMINI_API_KEY"
    [[ -n "${GEMINI_API_KEY_2:-}" ]]     && echo "GEMINI_API_KEY_2=$GEMINI_API_KEY_2"
    [[ -n "${GITHUB_TOKEN:-}" ]]         && echo "GITHUB_TOKEN=$GITHUB_TOKEN"
    [[ -n "${GITHUB_TOKEN_POOL:-}" ]]    && echo "GITHUB_TOKEN_POOL=$GITHUB_TOKEN_POOL"
    [[ -n "${DISCORD_BOT_TOKEN:-}" ]]    && echo "DISCORD_BOT_TOKEN=$DISCORD_BOT_TOKEN"
    [[ -n "${DISCORD_WEBHOOK:-}" ]]      && echo "DISCORD_WEBHOOK=$DISCORD_WEBHOOK"
} > ~/.hermes/.env
chmod 600 ~/.hermes/.env

# ── 2. Redis (TCP only, default 6379) ────────────────────────────────────────
redis-server --daemonize yes --port 6379 --bind 127.0.0.1 --maxmemory 1gb --maxmemory-policy allkeys-lru
sleep 1
redis-cli -h 127.0.0.1 -p 6379 ping >> "$LOG_DIR/redis.log"

# ── 3. Ollama (background, CPU mode) ────────────────────────────────────────
OLLAMA_HOST=127.0.0.1:11434 nohup ollama serve > "$LOG_DIR/ollama.log" 2>&1 &
sleep 6

# Pull model on first boot only — gemma4:e4b ~9.6 GB
if ! ollama list 2>/dev/null | grep -q "gemma4:e4b"; then
    echo "[$(date +%H:%M:%S)] pulling gemma4:e4b (first boot, ~5-10 min)" >> "$LOG_DIR/boot.log"
    ollama pull gemma4:e4b >> "$LOG_DIR/ollama.log" 2>&1 &
fi

# ── 4. Discord bot ───────────────────────────────────────────────────────────
if [[ -n "${DISCORD_BOT_TOKEN:-}" ]]; then
    set -a; source ~/.hermes/.env; set +a
    nohup python ~/.claude/bin/hermes-discord-bot.py >> "$LOG_DIR/discord-bot.log" 2>&1 &
    echo "[$(date +%H:%M:%S)] discord bot started" >> "$LOG_DIR/boot.log"
fi

# ── 5. Periodic loops via inline cron (no systemd/launchd on HF) ────────────
cat > /tmp/hermes-cron.sh <<'CRONSH'
#!/bin/bash
set -a; source ~/.hermes/.env 2>/dev/null; set +a
while true; do
    NOW=$(date +%s)
    M=$((NOW / 60))
    # Every 90s: surrogate-dev-loop
    [[ $((M % 2)) -eq 0 ]] && bash ~/.claude/bin/surrogate-dev-loop.sh 1 &
    # Every 30 min: scrape loop
    [[ $((M % 30)) -eq 0 ]] && bash ~/.claude/bin/domain-scrape-loop.sh 1700 4 &
    # Every 60 min: keyword tuner
    [[ $((M % 60)) -eq 0 ]] && bash ~/.claude/bin/scrape-keyword-tuner.sh &
    # Every 20 min: auto-orchestrate
    [[ $((M % 20)) -eq 0 ]] && bash ~/.claude/bin/auto-orchestrate-loop.sh &
    # Every 5 min: producer
    [[ $((M % 5)) -eq 0 ]] && bash ~/.claude/bin/work-queue-producer.sh &
    sleep 60
done
CRONSH
chmod +x /tmp/hermes-cron.sh
nohup /tmp/hermes-cron.sh > "$LOG_DIR/cron.log" 2>&1 &
echo "[$(date +%H:%M:%S)] cron loop started" >> "$LOG_DIR/boot.log"

# ── 6. HTTP status endpoint on port 7860 (HF requires this — keep-alive) ────
python <<'PYEOF' &
from http.server import BaseHTTPRequestHandler, HTTPServer
import json, os, sqlite3, subprocess
from pathlib import Path

class StatusHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        try:
            ledger = sqlite3.connect(os.path.expanduser('~/.claude/state/scrape-ledger.db')).execute(
                'SELECT COUNT(*) FROM scraped').fetchone()[0]
        except Exception:
            ledger = 0
        try:
            train = sum(1 for _ in open(p) for p in Path('~/.claude/state/surrogate-memory/episodes.jsonl').expanduser().glob('*'))
        except Exception:
            train = 0
        try:
            procs = subprocess.run(['pgrep', '-fc', 'discord-bot|surrogate-dev|scrape-loop'],
                                  capture_output=True, text=True).stdout.strip()
        except Exception:
            procs = '?'
        body = json.dumps({
            'status': 'ok',
            'ledger_repos': ledger,
            'episodes': train,
            'daemons_running': procs,
        }, indent=2)
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(body.encode())

    def log_message(self, *args): pass  # silence stdout

print('[hermes] status server on :7860', flush=True)
HTTPServer(('0.0.0.0', 7860), StatusHandler).serve_forever()
PYEOF

# ── Wait forever (PID 1 must not exit) ──────────────────────────────────────
echo "[$(date +%H:%M:%S)] boot complete — entering watch mode" >> "$LOG_DIR/boot.log"
tail -f "$LOG_DIR/boot.log"
