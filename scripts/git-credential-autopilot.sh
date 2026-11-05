#!/bin/bash
# git-credential-autopilot.sh — Git credential helper using autopilot keychain/env
# Reads GITHUB_TOKEN via autopilot-env.sh (keychain first, .autopilot.env fallback).
# Install: git config --global credential.helper '/path/to/git-credential-autopilot.sh'

action="${1:-}"
if [ "$action" = "get" ]; then
  TOKEN=$(bash ~/autopilot/scripts/autopilot-env.sh env 2>/dev/null | grep "^GITHUB_TOKEN=" | cut -d= -f2-)
  if [ -n "$TOKEN" ]; then
    echo "username=x-access-token"
    echo "password=$TOKEN"
  fi
fi
# store/erase: no-op (token managed via keychain/env, not git's credential store)
