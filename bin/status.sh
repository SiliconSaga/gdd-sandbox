#!/usr/bin/env bash
# One answer to "what state is this sandbox actually in?"
#
# Diagnosing a quiet agent meant half a dozen separate probes, and the failures
# that hurt most were the ones where the obvious signals all looked fine. This
# gathers them in the order they have actually failed, and asks the question the
# health check cannot: is the session sitting on a prompt nobody will answer?
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
WS="${GDD_WORKSPACE:-/work/ws}"
TARGET="${GDD_TARGET:-}"
# shellcheck source=bin/lib.sh
. "$HERE/lib.sh"

echo "== processes =="
pgrep -af 'claude .*--channels' || echo "  session: ABSENT"
pgrep -af 'claude-plugins-official/discord' || echo "  channel server: ABSENT — bot is offline"

echo
echo "== reachable? =="
if bash "$HERE/healthcheck.sh"; then
  echo "  healthy: session up, channel present, chat service reachable"
else
  echo "  UNHEALTHY — see above for which of the three failed"
fi

echo
echo "== blocked on a prompt? =="
tail_text="$(bash "$HERE/session-log.sh" 8 2>/dev/null || true)"
if ws_prompt_pending "$tail_text"; then
  echo "  YES — waiting on an answer nobody is there to give."
  echo "  The watchdog should cancel it; if this persists, it is not working."
else
  echo "  no"
fi

echo
echo "== repository =="
if [ -n "$TARGET" ] && [ -d "$WS/components/$TARGET/.git" ]; then
  git -C "$WS/components/$TARGET" status --short --branch
  echo "  --- recent commits ---"
  git -C "$WS/components/$TARGET" log --oneline -3
else
  echo "  no clone for target '${TARGET:-<unset>}'"
fi

echo
echo "== last session output =="
bash "$HERE/session-log.sh" 15 2>/dev/null || echo "  (no session log yet)"
