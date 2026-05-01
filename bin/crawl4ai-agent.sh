#!/usr/bin/env bash
# Wrapper: delegate to ~/.claude/bin/crawl4ai-agent.sh (real implementation).
# Hermes cron requires scripts inside ~/.hermes/scripts/.
exec /Users/Ashira/.claude/bin/crawl4ai-agent.sh "$@"
