#!/usr/bin/env bash
# wrapper — hermes-cli refuses symlinks as path-traversal, so exec the real script
exec /Users/Ashira/.claude/bin/budget-auto-throttle.sh "$@"
