#!/usr/bin/env bash
# Wrapper: delegate to ~/.claude/bin/chroma-to-training-pairs.sh (real implementation).
# Hermes cron requires scripts inside ~/.hermes/scripts/.
exec /Users/Ashira/.claude/bin/chroma-to-training-pairs.sh "$@"
