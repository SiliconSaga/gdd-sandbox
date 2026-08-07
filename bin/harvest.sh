#!/usr/bin/env bash
# Rescue what exists only inside a sandbox, before anything throws it away.
#
# A sandbox accumulates one thing the host has no copy of: its Thalamus, the
# notes the agent kept across sessions. Removing the volume deletes it, and the
# loss is silent — which is exactly the shape of mistake worth spending twenty
# lines to make impossible.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WS_ROOT="$(cd "$ROOT/../.." && pwd)"

TARGET="" NAME="" FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$TARGET" ] || { echo "error: --target <component> is required" >&2; exit 2; }
NAME="${NAME:-gdd-sandbox-$TARGET}"

# Unfinished work in the target repository is NOT harvested, and its presence
# stops the harvest outright.
#
# Copying loose files to the host launders half-done work into a directory nobody
# reviews. It has a proper home — a branch and a pull request, opened by the agent
# while the sandbox is still alive — and the only way to make that the default is
# to refuse the shortcut. `--force` is for work already judged disposable.
dirty="$(ws docker exec "$NAME" git -C "/work/ws/components/$TARGET" status --porcelain 2>/dev/null || true)"
if [ -n "$dirty" ] && [ "$FORCE" -ne 1 ]; then
  echo "error: $TARGET has uncommitted work in the sandbox:" >&2
  printf '%s\n' "$dirty" >&2
  echo "Finish it as a pull request from inside the sandbox, or pass --force if it is disposable." >&2
  exit 1
fi

# Beside the host's own thalami hoard when there is one, scratch otherwise.
#
# In its own `sandboxes/` directory rather than mixed in with the per-host files:
# this is a TENANT's memory, and the end state is that tenant running their own
# plan with their own logins. What moves with them should be separable without
# anyone having to sort it out later.
hoard="$(ws hoard thalamus-path 2>/dev/null || true)"
if [ -n "$hoard" ]; then
  dest_dir="$(dirname "$hoard")/sandboxes"
else
  dest_dir="$WS_ROOT/.tmp/sandbox-harvest"
fi
mkdir -p "$dest_dir"
dest="$dest_dir/$TARGET-$(date +%F).md"

ws docker cp "$NAME:/work/ws/Thalamus.md" "$dest"
echo "harvested: $dest"
echo
echo "Record this in your own Thalamus — tooling moves the file, you decide what it means:"
echo "  - Sandbox tenant '$TARGET' harvested to $dest. Treat as housekeeping input"
echo "    next cycle, then delete the file: its existence means that sandbox is gone."
