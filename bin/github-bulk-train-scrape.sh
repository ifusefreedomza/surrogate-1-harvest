#!/usr/bin/env bash
# Wrapper: delegate to ~/.claude/bin/github-bulk-train-scrape.sh (real implementation).
# Hermes cron requires scripts inside ~/.hermes/scripts/.
exec /Users/Ashira/.claude/bin/github-bulk-train-scrape.sh "$@"
