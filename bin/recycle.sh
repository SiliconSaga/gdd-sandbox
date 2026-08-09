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
need_value() { [ "$1" -ge 2 ] || { echo "error: $2 needs a value" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --target) need_value "$#" "$1"; TARGET="$2"; shift 2 ;;
    --name) need_value "$#" "$1"; NAME="$2"; shift 2 ;;
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

# Tolerate "already gone", fail on everything else.
#
# A blanket `|| true` would let a stopped daemon, a container that refused to
# stop, or a volume still mounted elsewhere pass silently — and then print that
# the sandbox is gone when it is sitting right there. The only failure that is
# genuinely fine is the one that means the work is already done.
docker_step() {
  local out rc=0
  out="$("$@" 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] && return 0
  case "$out" in
    *"No such container"*|*"no such container"*|*"No such volume"*|*"no such volume"*)
      return 0 ;;
  esac
  printf '%s\n' "$out" >&2
  echo "error: cleanup step failed: $* — the sandbox has NOT been removed." >&2
  exit 1
}

docker_step ws docker stop "$NAME"
docker_step ws docker rm "$NAME"
docker_step ws docker volume rm "gdd-sandbox-$TARGET-ws" "gdd-sandbox-$TARGET-ws-claude"
echo "recycled: $NAME and its volumes are gone"
