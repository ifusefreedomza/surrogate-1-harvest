#!/usr/bin/env bash
# Wrapper: delegate to ~/.claude/bin/bulk-scrape-burst.sh (real implementation).
# Hermes cron requires scripts inside ~/.hermes/scripts/.
exec /Users/Ashira/.claude/bin/bulk-scrape-burst.sh "$@"
