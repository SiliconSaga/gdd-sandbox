#!/usr/bin/env bash
# Start + provision + supervise a gdd-sandbox for one target component.
set -euo pipefail
# shellcheck source=bin/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Normalized workspace root (…/components/<name> -> workspace). Keep it free of
# '../..' segments: docker rejects an unnormalized --env-file path.
WS_ROOT="$(cd "$ROOT/../.." && pwd)"
IMAGE="${GDD_SANDBOX_IMAGE:-gdd-sandbox:latest}"
TARGET="" NAME="" SECRETS="$WS_ROOT/.env" TARGET_REPO="" REALM_REPO="" ALLOWFROM="[]"
CHANNEL="" REQUIRE_MENTION="true"
while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --secrets) SECRETS="$2"; shift 2 ;;
    --target-repo) TARGET_REPO="$2"; shift 2 ;;
    --realm-repo) REALM_REPO="$2"; shift 2 ;;
    --allowfrom) ALLOWFROM="$2"; shift 2 ;;
    --channel) CHANNEL="$2"; shift 2 ;;
    --no-mention) REQUIRE_MENTION="false"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$TARGET" ] || { echo "error: --target <component> is required" >&2; exit 2; }
NAME="${NAME:-gdd-sandbox-$TARGET}"

# Safety: never let ANTHROPIC_API_KEY into the container (metered-billing trap).
if [ -f "$SECRETS" ] && grep -q '^ANTHROPIC_API_KEY=' "$SECRETS"; then
  echo "error: $SECRETS sets ANTHROPIC_API_KEY — remove it (outranks the OAuth token)" >&2
  exit 2
fi
# Resolve the target repo from ecosystem if not given.
[ -n "$TARGET_REPO" ] || TARGET_REPO="$(yq ".components.$TARGET.repo" "$WS_ROOT/ecosystem.local.yaml")"

# Hand docker a MINIMAL env file: only the allowlisted runtime secrets, with any
# `export ` prefix stripped (docker's --env-file parser rejects it). Keeps the
# operator's other credentials out of the container entirely.
RUNTIME_ENV="$(mktemp)"
trap 'rm -f "$RUNTIME_ENV"' EXIT
if ! ws_write_runtime_env "$SECRETS" "$RUNTIME_ENV"; then
  echo "error: no runtime secrets ($WS_RUNTIME_SECRETS) found in $SECRETS" >&2
  exit 2
fi

# Two volumes: the workspace, and ~/.claude. The latter carries the plugin
# install, the channel pairing, and the session history `--continue` reads. Left
# in the container layer it dies with the container while the launch sentinel on
# the workspace volume survives — every relaunch then asks to continue a session
# that no longer exists.
# A shared channel (operator + user + agent) is a guild channel, which the plugin
# leaves disabled until opted in by CHANNEL id. requireMention keeps the agent
# quiet while the humans talk to each other; --no-mention suits a channel
# dedicated to one user, who should not have to remember to tag anyone.
#
# NOT named GROUPS: that is a bash built-in array of the user's group ids, so the
# assignment is silently ignored and the value expands to a numeric gid instead of
# JSON. Cost an hour; do not reintroduce it.
CHANNEL_GROUPS='{}'
if [ -n "$CHANNEL" ]; then
  CHANNEL_GROUPS="$(jq -cn --arg ch "$CHANNEL" --argjson mention "$REQUIRE_MENTION" \
    '{($ch): {requireMention: $mention, allowFrom: []}}')"
fi

VOL="gdd-sandbox-$TARGET-ws"
ws docker run -d --name "$NAME" --restart unless-stopped \
  --env-file "$(ws_host_path "$RUNTIME_ENV")" \
  -e "GDD_TARGET=$TARGET" -e "GDD_TARGET_REPO=$TARGET_REPO" \
  -e "GDD_REALM_REPO=$REALM_REPO" -e "GDD_ALLOWFROM=$ALLOWFROM" \
  -e "GDD_CHANNEL_GROUPS=$CHANNEL_GROUPS" \
  -e "GDD_WORKSPACE=/work/ws" \
  -v "$VOL:/work/ws" \
  -v "$VOL-claude:/root/.claude" \
  "$IMAGE"

# No `docker cp` / `exec` here on purpose: the image bakes the scripts and its
# entrypoint runs provisioning then supervision. A supervisor started with
# `docker exec -d` would die with the container, leaving the restart policy to
# bring back a container with no agent listening.
echo "sandbox '$NAME' up (target=$TARGET). Tail: ws docker exec $NAME tail -f /tmp/channels-tty.log"
