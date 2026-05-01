#!/usr/bin/env bash
# Wrapper: delegate to ~/.claude/bin/sync-code-to-fts.sh (real implementation).
# Hermes cron requires scripts inside ~/.hermes/scripts/.
exec /Users/Ashira/.claude/bin/sync-code-to-fts.sh "$@"
