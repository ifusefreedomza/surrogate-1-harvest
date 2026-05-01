#!/usr/bin/env bash
# wrapper — hermes-cli refuses symlinks as path-traversal, so exec the real script
exec /bin/bash "/Users/Ashira/.claude/bin/axentx-backup-sync.sh" "$@"
