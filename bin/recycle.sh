#!/usr/bin/env bash
# Throw a sandbox away — harvesting it first, in one command.
#
# Deliberately not two commands with a note in the README saying to run them in
# order. The rescue has to be part of the destruction, or a hurry skips it: that
# is precisely how a wipe once nearly lost two drafts and a session's notes, saved
# only because someone happened to copy them out by hand first.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

TARGET="" NAME="" FORCE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --force) FORCE="--force"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$TARGET" ] || { echo "error: --target <component> is required" >&2; exit 2; }
NAME="${NAME:-gdd-sandbox-$TARGET}"

# set -e already aborts here on a refusal; stated explicitly because the ordering
# IS the feature. Nothing below runs unless the notes are safely on the host.
if [ -n "$FORCE" ]; then
  bash "$HERE/harvest.sh" --target "$TARGET" --name "$NAME" "$FORCE"
else
  bash "$HERE/harvest.sh" --target "$TARGET" --name "$NAME"
fi

ws docker stop "$NAME" || true
ws docker rm "$NAME" || true
ws docker volume rm "gdd-sandbox-$TARGET-ws" "gdd-sandbox-$TARGET-ws-claude" || true
echo "recycled: $NAME and its volumes are gone"
