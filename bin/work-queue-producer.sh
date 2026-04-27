#!/usr/bin/env bash
# Work Queue Producer — pushes ready priorities to Redis LIST.
# Runs every 2 min via cron. Uses redislite socket (shared with hermes FalkorDB).
#
# Routing strategy (maximize free tier, local as fallback):
#   • CLOUD TIER (primary):  samba, cloudflare, groq, github — every ready priority
#                            fan-out to ALL cloud providers whose budget is OK.
#                            Best-of-N tournament synthesis picks the winner.
#   • LOCAL (fallback):      qwen-local only gets work when EITHER
#                            (a) task is small/trivial enough for 7B model
#                               (short title, no spec, known simple keywords), OR
#                            (b) all cloud providers are in budget HALT
#                               (rare — but keeps pipeline moving offline).
#
# Dedup: hermes:seen:<prio_id> TTL 30 min prevents re-enqueue of in-flight work.
set -u

LOG="$HOME/.claude/logs/work-queue-producer.log"
SHARED="$HOME/.hermes/workspace/swarm-shared"
mkdir -p "$(dirname "$LOG")"

# Try Unix socket first, then fall back to TCP 127.0.0.1:6379
REDIS_SOCK=$(/usr/bin/find /var/folders /tmp -name 'redis.socket' -type s 2>/dev/null | /usr/bin/head -1)
REDIS_MODE=""
if [[ -n "$REDIS_SOCK" ]] && [[ -S "$REDIS_SOCK" ]]; then
    REDIS_MODE="sock"
elif redis-cli -h 127.0.0.1 -p 6379 PING 2>/dev/null | grep -q PONG; then
    REDIS_MODE="tcp"
    REDIS_SOCK=""
else
    echo "[$(date '+%H:%M:%S')] no redis (sock or TCP) — queue disabled" >> "$LOG"
    exit 0
fi

[[ ! -f "$SHARED/priority.json" ]] && exit 0

/usr/bin/python3 <<PYEOF 2>>"$LOG"
import json
import subprocess
from pathlib import Path

SHARED = Path.home() / '.hermes/workspace/swarm-shared'
REDIS_MODE = "$REDIS_MODE"
SOCK = "$REDIS_SOCK"

CLOUD_PROVIDERS = ('samba', 'cloudflare', 'groq', 'github', 'cerebras', 'nvidia')
LOCAL_PROVIDER = 'qwen-local'

# Map cloud provider → budget file key (matches budget-scanner.sh output)
BUDGET_KEYS = {
    'samba': 'sambanova',
    'cloudflare': 'cloudflare',
    'groq': 'groq',
    'github': 'github',
    'cerebras': 'cerebras',
    'nvidia': 'nvidia',
}

# Keywords that mean "simple enough for local 7B" — scaffolds, renames,
# typo/doc fixes, one-liner helpers, small CLI wrappers, test stubs.
# Complex tasks (auth, multi-file features, ML, infra) always go cloud.
LOCAL_FRIENDLY_KEYWORDS = (
    'typo', 'rename', 'doc', 'readme', 'comment', 'fix lint',
    'add test', 'stub', 'scaffold', 'simple', 'small',
    'cli helper', 'format', 'logging',
)


def redis(*args):
    if REDIS_MODE == "sock":
        cmd = ['redis-cli', '-s', SOCK] + list(args)
    else:
        cmd = ['redis-cli', '-h', '127.0.0.1', '-p', '6379'] + list(args)
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
    return r.stdout.strip()


# Load per-provider budget status (cap enforcement happens upstream; we just
# avoid pushing to HALTed providers to keep queue depth honest).
budget = {}
from datetime import date as _date
budget_path = Path.home() / f".hermes/workspace/budget/tokens-{_date.today().isoformat()}.json"
if budget_path.exists():
    try:
        raw = json.loads(budget_path.read_text())
        for prov, key in BUDGET_KEYS.items():
            budget[prov] = raw.get('providers', {}).get(key, {}).get('status', 'OK')
    except Exception:
        pass

# Cloud providers that are accepting work right now.
healthy_cloud = [p for p in CLOUD_PROVIDERS if budget.get(p, 'OK') != 'HALT']
all_cloud_halted = len(healthy_cloud) == 0


def classify_for_local(priority: dict) -> bool:
    """Return True if priority is small enough for qwen-local."""
    title = (priority.get('title') or '').lower()
    desc = (priority.get('description') or '').lower()
    spec_file = SHARED / 'specs' / f"{priority.get('id','')}.md"

    # Has a detailed spec → not a local task; cloud handles it
    if spec_file.exists() and spec_file.stat().st_size > 500:
        return False
    # Explicit hint — priority author tagged it
    if priority.get('size') in ('small', 'xs', 'trivial'):
        return True
    if priority.get('complexity') in ('low', 'trivial'):
        return True
    # Keyword heuristic
    blob = f"{title} {desc}"
    return any(kw in blob for kw in LOCAL_FRIENDLY_KEYWORDS)


try:
    with open(SHARED / 'priority.json') as f:
        d = json.load(f)
except Exception as e:
    print(f"[producer] load fail: {e}")
    raise SystemExit

pushed_cloud = 0
pushed_local = 0
skipped = 0
routed = {}
# Round-robin cursor across healthy cloud providers. ONE provider per priority
# (not fan-out to all) — fan-out was hitting per-minute rate limits on Samba
# (HTTP 429) and tripping Cloudflare circuit breakers even when daily budget
# was <5% used. Tournament best-of-N still happens across priorities because
# different priorities go to different providers.
rr_cursor = 0

for p in d.get('priorities', []):
    if p.get('status') != 'ready':
        continue
    pid = p.get('id', '')
    if not pid:
        continue
    seen_key = f'hermes:seen:{pid}'
    if redis('EXISTS', seen_key) == '1':
        skipped += 1
        continue

    payload = json.dumps(p)
    goes_local = classify_for_local(p)

    # Decide target (single provider, not fan-out):
    #   - local-friendly                    → push to LOCAL only (saves free-tier)
    #   - complex + healthy cloud present   → push to 1 CLOUD (round-robin)
    #   - complex + all cloud halted        → push to LOCAL as fallback
    if goes_local:
        redis('LPUSH', f'hermes:work:coding:{LOCAL_PROVIDER}', payload)
        routed[pid] = 'local'
        pushed_local += 1
    elif healthy_cloud:
        chosen = healthy_cloud[rr_cursor % len(healthy_cloud)]
        rr_cursor += 1
        redis('LPUSH', f'hermes:work:coding:{chosen}', payload)
        routed[pid] = f"cloud[{chosen}]"
        pushed_cloud += 1
    else:
        redis('LPUSH', f'hermes:work:coding:{LOCAL_PROVIDER}', payload)
        routed[pid] = 'local-fallback'
        pushed_local += 1

    redis('SETEX', seen_key, '1800', '1')

# Per-provider queue depth for observability
for prov in CLOUD_PROVIDERS + (LOCAL_PROVIDER,):
    depth = redis('LLEN', f'hermes:work:coding:{prov}')
    halted = '(HALT)' if budget.get(prov, 'OK') == 'HALT' else ''
    print(f"  {prov}: {depth} {halted}")

print(f"[producer] cloud_pushed={pushed_cloud} local_pushed={pushed_local} skipped={skipped} "
      f"healthy_cloud={len(healthy_cloud)}/4")
for pid, target in routed.items():
    print(f"  → {pid}: {target}")
PYEOF
