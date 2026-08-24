#!/usr/bin/env bash
# Build the gdd-sandbox image (one tag; cache-warming is in the Dockerfile).
set -euo pipefail
# shellcheck source=bin/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
TAG="gdd-sandbox:latest"
CONTEXT="$(cd "$(dirname "$0")/.." && pwd)"
# Pin the GDD core to a specific upstream commit instead of current main. The
# reason to have it: reproducing an image someone else built, or bisecting which
# core release broke a sandbox. Absent, the current upstream tip is resolved below.
SEED_REF=""
while [ $# -gt 0 ]; do
  case "$1" in
    --tag) TAG="$2"; shift 2 ;;
    --context) CONTEXT="$2"; shift 2 ;;
    --seed-ref) SEED_REF="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
# Resolve the upstream commit the GDD core seed will be cloned at, and pass it as
# a build arg. Without this the seed layer is a permanent cache hit: the clone
# command never changes, so Docker reuses whatever it baked the first time and
# the sandbox silently runs a months-old workspace — measured at PR #150 while
# the hook fixes it needed were three releases newer. Naming the sha makes the
# cache correct instead of merely fast: hit while upstream is unchanged, miss the
# moment it moves.
#
# A failure here is not fatal. An offline rebuild should still produce an image;
# it just cannot promise the seed is current, so it says so rather than pretending.
# Assigned inside `if !` so `set -e` and `pipefail` cannot abort the build on an
# unreachable remote — the point is to degrade, not to fail.
if [ -z "$SEED_REF" ]; then
  if ! SEED_REF="$(git ls-remote https://github.com/SiliconSaga/yggdrasil main 2>/dev/null | cut -f1)"; then
    SEED_REF=""
  fi
fi
if [ -z "$SEED_REF" ]; then
  echo "warning: could not resolve upstream yggdrasil HEAD — the baked seed may be a stale cache hit" >&2
  SEED_REF="main"
fi
echo "seed ref: $SEED_REF"

# The build context is a HOST path: convert it, since `ws docker` suppresses
# MSYS conversion and docker.exe cannot resolve /d/... style paths.
ws docker build --build-arg "SEED_REF=$SEED_REF" -t "$TAG" "$(ws_host_path "$CONTEXT")"
