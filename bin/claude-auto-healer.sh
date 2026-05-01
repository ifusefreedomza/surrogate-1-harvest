#!/bin/bash
# wrapper — hermes-cli refuses symlinks as path-traversal, so exec the real script
exec "/Users/Ashira/.claude/bin/claude-auto-healer.sh" "$@"
