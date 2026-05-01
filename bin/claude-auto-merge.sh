#!/bin/bash
# wrapper — hermes-cli refuses symlinks as path-traversal, so exec the real script
"/Users/Ashira/.claude/bin/claude-auto-merge.sh" "$@"
