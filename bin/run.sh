#!/usr/bin/env bash
# Start + provision + supervise a gdd-sandbox for one target component.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${GDD_SANDBOX_IMAGE:-gdd-sandbox:latest}"
TARGET="" NAME="" SECRETS="$ROOT/../../.env" TARGET_REPO="" REALM_REPO="" ALLOWFROM="[]"
while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --secrets) SECRETS="$2"; shift 2 ;;
    --target-repo) TARGET_REPO="$2"; shift 2 ;;
    --realm-repo) REALM_REPO="$2"; shift 2 ;;
    --allowfrom) ALLOWFROM="$2"; shift 2 ;;
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
[ -n "$TARGET_REPO" ] || TARGET_REPO="$(yq ".components.$TARGET.repo" "$ROOT/../../ecosystem.local.yaml")"

VOL="gdd-sandbox-$TARGET-ws"
ws docker run -d --name "$NAME" --restart unless-stopped \
  --env-file "$SECRETS" \
  -e "GDD_TARGET=$TARGET" -e "GDD_TARGET_REPO=$TARGET_REPO" \
  -e "GDD_REALM_REPO=$REALM_REPO" -e "GDD_ALLOWFROM=$ALLOWFROM" \
  -e "GDD_WORKSPACE=/work/ws" -e "CLAUDE_SETTINGS=/work/gdd-sandbox/provision/settings.sandbox.json" \
  -v "$VOL:/work/ws" \
  "$IMAGE"

# Copy the operator scripts in and provision, then supervise detached.
ws docker cp "$ROOT/." "$NAME:/work/gdd-sandbox"
ws docker exec "$NAME" bash /work/gdd-sandbox/provision/provision.sh
ws docker exec -d "$NAME" bash /work/gdd-sandbox/bin/supervise.sh
echo "sandbox '$NAME' up (target=$TARGET). Tail: ws docker exec $NAME tail -f /tmp/channels-tty.log"
