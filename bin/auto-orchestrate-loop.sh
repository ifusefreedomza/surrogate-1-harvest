#!/usr/bin/env bash
# Auto-orchestrate loop — fires architect → dev → qa → reviewer chain autonomously.
#
# Strategy: pick a real TODO/FIXME from any axentx/develope project, run the
# full pipeline, auto-commit on APPROVE. Runs every 20 min via LaunchAgent.
#
# Pairs with surrogate-dev-loop (light/fast) — this one does HEAVY work that
# needs multi-stage review.
set -uo pipefail
set -a; source "$HOME/.hermes/.env" 2>/dev/null; set +a

LOG="$HOME/.surrogate/logs/auto-orchestrate-loop.log"
mkdir -p "$(dirname "$LOG")"

# Resource guard: 20% headroom
LOAD=$(uptime | awk -F'load averages:' '{print $2}' | awk '{print int($1)}')
FREE=$(vm_stat | awk '/Pages free/{gsub("[.]","",$3); print int($3)}')
if [[ $LOAD -gt 8 ]] || [[ $FREE -lt 50000 ]]; then
    echo "[$(date +%H:%M:%S)] resource-pause: load=$LOAD free=$FREE — skip" >> "$LOG"
    exit 0
fi

# Pick a real task: one TODO/FIXME from a randomly-chosen project
TASK_INFO=$(python3 <<'PYEOF'
import os, random, re, subprocess, json
from pathlib import Path

PROJECTS = [
    Path.home() / 'axentx/Costinel',
    Path.home() / 'axentx/Vanguard',
    Path.home() / 'axentx/arkship',
    Path.home() / 'axentx/AxiomOps',
    Path.home() / 'axentx/workio',
]
PROJECTS = [p for p in PROJECTS if (p/'.git').exists()]
if not PROJECTS:
    print("{}"); exit()

random.shuffle(PROJECTS)
for proj in PROJECTS:
    cmd = ['rg', '--no-heading', '-n', '-m', '5',
           '--type', 'py', '--type', 'ts', '--type', 'go', '--type', 'sh',
           '-g', '!node_modules', '-g', '!.venv', '-g', '!__pycache__',
           '-g', '!.git', '-g', '!dist', '-g', '!build',
           r'(TODO|FIXME)[:\s]', str(proj)]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=8)
        lines = [l for l in r.stdout.splitlines() if l.strip()]
        if not lines:
            continue
        line = random.choice(lines)
        m = re.match(r'^([^:]+):(\d+):(.+)$', line)
        if not m:
            continue
        path, lineno, content = m.groups()
        rel = os.path.relpath(path, proj)
        # Filter out trivial / meta TODOs
        c = content.strip().lower()
        if any(skip in c for skip in ['#todo:', 'todo: fix', 'todo:', '// todo', 'todo()']) and len(content) < 30:
            continue
        print(json.dumps({
            'project': str(proj),
            'project_name': proj.name,
            'file': rel,
            'line': int(lineno),
            'content': content.strip()[:300],
        }))
        exit()
    except Exception:
        continue
print("{}")
PYEOF
)

if [[ -z "$TASK_INFO" ]] || [[ "$TASK_INFO" == "{}" ]]; then
    echo "[$(date +%H:%M:%S)] no task found — skip" >> "$LOG"
    exit 0
fi

PROJECT=$(echo "$TASK_INFO" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['project'])")
PROJ_NAME=$(echo "$TASK_INFO" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['project_name'])")
FILE=$(echo "$TASK_INFO" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['file'])")
LINE=$(echo "$TASK_INFO" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['line'])")
CONTENT=$(echo "$TASK_INFO" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['content'])")

# Per-task throttle: don't redo same TODO within 4 hours
TASK_HASH=$(echo "${PROJ_NAME}:${FILE}:${LINE}" | md5 | cut -c1-12)
LOCK_DIR="$HOME/.hermes/workspace/auto-orchestrate-locks"
mkdir -p "$LOCK_DIR"
LOCK="$LOCK_DIR/${TASK_HASH}"
if [[ -f "$LOCK" ]]; then
    AGE=$(( $(date +%s) - $(stat -f %m "$LOCK" 2>/dev/null || echo 0) ))
    if [[ $AGE -lt 14400 ]]; then
        echo "[$(date +%H:%M:%S)] task ${TASK_HASH} done ${AGE}s ago — skip" >> "$LOG"
        exit 0
    fi
fi
touch "$LOCK"

START=$(date +%s)
echo "[$(date +%H:%M:%S)] orchestrate start: $PROJ_NAME/$FILE:$LINE" >> "$LOG"
echo "  task: $CONTENT" >> "$LOG"

# Build the prompt for architect → dev → qa → reviewer
TASK_DESC="Resolve this TODO/FIXME in $PROJ_NAME at $FILE:$LINE: \"$CONTENT\". Implement a real fix (not stub), keep changes scoped to the file/function. Match existing code style."

cd "$PROJECT" || { echo "[$(date +%H:%M:%S)] cd failed" >> "$LOG"; exit 1; }

# Run the orchestrate pipeline (auto-commits on APPROVE)
bash "$HOME/.surrogate/bin/surrogate-orchestrate.sh" "$TASK_DESC" >> "$LOG" 2>&1
RC=$?
DUR=$(( $(date +%s) - START ))

echo "[$(date +%H:%M:%S)] orchestrate done in ${DUR}s rc=$RC" >> "$LOG"

# Discord notification
NOTIFY="$HOME/.surrogate/bin/notify-discord.sh"
if [[ -x "$NOTIFY" ]]; then
    if [[ $RC -eq 0 ]]; then
        "$NOTIFY" task "Auto-orchestrate: $PROJ_NAME" "$FILE:$LINE — \`$(echo "$CONTENT" | head -c 80)\` · ${DUR}s" 2>/dev/null &
    else
        "$NOTIFY" warn "Auto-orchestrate failed" "$PROJ_NAME · $FILE:$LINE · rc=$RC · ${DUR}s" 2>/dev/null &
    fi
fi
