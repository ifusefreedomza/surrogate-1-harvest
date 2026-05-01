#!/bin/bash
# wrapper — hermes-cli refuses symlinks as path-traversal, so exec the real script
exec "/Users/Ashira/.claude/bin/scrape-security-deep.sh" "$@"
