#!/usr/bin/env bash
# Rescue what exists only inside a sandbox, before anything throws it away.
#
# A sandbox accumulates one thing the host has no copy of: its Thalamus — what
# the agent wrote down as it worked. Useful within one session, recovered from
# on rotation if it lives that long, and at the end the only record of how the
# thing actually went. Removing the volume deletes it, and the loss is silent —
# exactly the shape of mistake worth spending twenty lines to make impossible.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WS_ROOT="$(cd "$ROOT/../.." && pwd)"
# shellcheck source=bin/lib.sh
. "$HERE/lib.sh"

TARGET="" NAME="" FORCE=0
# `set -u` turns a value-less --target into an unbound-variable trace rather than
# the argument error the script is meant to give, so check before expanding $2.
need_value() { [ "$1" -ge 2 ] || { echo "error: $2 needs a value" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --target) need_value "$#" "$1"; TARGET="$2"; shift 2 ;;
    --name) need_value "$#" "$1"; NAME="$2"; shift 2 ;;
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
#
# A failed status call must NOT read as "clean". Silencing it would turn a
# stopped container or a wrong path into an empty result, and the empty result is
# the one that lets recycle.sh go on to delete everything — the check would fail
# open, in the direction that destroys.
if ! dirty="$(ws docker exec "$NAME" git -C "/work/ws/components/$TARGET" status --porcelain)"; then
  echo "error: cannot inspect $TARGET inside $NAME — refusing to harvest." >&2
  echo "Is the container running? 'ws docker ps' to check." >&2
  exit 1
fi
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

# Nothing to rescue is not a failure. A sandbox provisioned before the Thalamus
# was seeded — or one that never finished provisioning — has no notes, and
# refusing to recycle it would leave the operator unable to use this tool at all
# on the very containers most likely to be thrown away. Say so and continue: the
# guard that matters is the uncommitted-work one above.
# The probe must say which of three things it found, because two of them look
# identical through an exit status: the file is absent, or the probe itself never
# ran. Treating a failed probe as "absent" would hand recycle.sh a green light to
# delete a volume whose notes were never checked — the same fail-open-toward-
# destruction shape as the dirty-repo check above, which is why that one refuses
# too. So the container answers in words, and anything else is a failure.
# Two conditions must BOTH hold before this counts as an answer: the call
# succeeded, and the container said one of exactly two words. `if !` rather than
# `|| true` so a failed call reaches the refusal instead of tripping `set -e` at
# the assignment, which would exit with no explanation — the silent stop this
# script exists to avoid.
#
# Matched exactly, not by wildcard: a warning line or a stray banner containing
# the word ABSENT would otherwise be read as "verified missing" and hand
# recycle.sh permission to delete the volume.
if ! probe="$(ws docker exec "$NAME" sh -c 'if [ -f /work/ws/Thalamus.md ]; then echo PRESENT; else echo ABSENT; fi' 2>/dev/null)"; then
  probe=""
fi
probe="$(printf '%s' "$probe" | tr -d '\r\n')"
case "$probe" in
  PRESENT) : ;;
  ABSENT)
    echo "harvest: no Thalamus in $NAME — nothing to rescue."
    exit 0 ;;
  *)
    echo "error: could not check for a Thalamus in $NAME — refusing to harvest." >&2
    echo "Is the container running? 'ws docker ps' to check." >&2
    exit 1 ;;
esac

# The destination is a HOST path handed to docker, so it needs the same
# conversion run.sh does for its env-file. Without it an MSYS path arrives as
# `D:\d\Dev\…` — the drive letter prepended to a path that already had one — and
# docker rejects a directory that very much exists. Unit tests stub `ws`, so this
# only ever shows up on a real invocation.
ws docker cp "$NAME:/work/ws/Thalamus.md" "$(ws_host_path "$dest")"
echo "harvested: $dest"
echo
echo "Record this in your own Thalamus — tooling moves the file, you decide what it means:"
echo "  - Sandbox tenant '$TARGET' harvested to $dest. Treat as housekeeping input"
echo "    next cycle; delete it once its observations are recorded AND that sandbox"
echo "    has actually been recycled — a harvest on its own destroys nothing."
