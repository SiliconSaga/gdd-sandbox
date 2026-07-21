#!/usr/bin/env bash
# Build the gdd-sandbox image (one tag; cache-warming is in the Dockerfile).
set -euo pipefail
TAG="gdd-sandbox:latest"
CONTEXT="$(cd "$(dirname "$0")/.." && pwd)"
while [ $# -gt 0 ]; do
  case "$1" in
    --tag) TAG="$2"; shift 2 ;;
    --context) CONTEXT="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
# ws docker handles Windows path conversion; MSYS mangles /d/... so prefer D:/...
ws docker build -t "$TAG" "$CONTEXT"
