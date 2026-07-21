#!/usr/bin/env bash
# Trigger a deliberate session rotation: mark rotate + end the current session;
# the supervisor then launches a FRESH session (no --continue) that re-orients
# from the persistent Thalamus via AGENTS.md.
set -u
ROTATE_FLAG="${ROTATE_FLAG:-/tmp/gdd-rotate}"
touch "$ROTATE_FLAG"
pkill -f "claude .*--channels" || true
echo "rotation requested"
