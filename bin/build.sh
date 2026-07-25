#!/usr/bin/env bash
# Build the gdd-sandbox image (one tag; cache-warming is in the Dockerfile).
set -euo pipefail
# shellcheck source=bin/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
TAG="gdd-sandbox:latest"
CONTEXT="$(cd "$(dirname "$0")/.." && pwd)"
while [ $# -gt 0 ]; do
  case "$1" in
    --tag) TAG="$2"; shift 2 ;;
    --context) CONTEXT="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
# The build context is a HOST path: convert it, since `ws docker` suppresses
# MSYS conversion and docker.exe cannot resolve /d/... style paths.
ws docker build -t "$TAG" "$(ws_host_path "$CONTEXT")"
