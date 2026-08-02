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

MIN_UPTIME="${GDD_HEALTH_MIN_UPTIME:-30}"

echo "== processes =="
# Just identity and age: the full command line is three screens of flags and
# buries everything below it.
session_pid="$(pgrep -f 'claude .*--channels' | head -n1)"
if [ -n "$session_pid" ]; then
  echo "  session: pid $session_pid, up $(ps -o etimes= -p "$session_pid" | tr -d ' ')s"
else
  echo "  session: ABSENT"
fi
channel_pid="$(pgrep -f 'claude-plugins-official/discord' | head -n1)"
if [ -n "$channel_pid" ]; then
  echo "  channel server: pid $channel_pid"
else
  echo "  channel server: ABSENT — the bot is offline"
fi

echo
echo "== reachable? =="
if bash "$HERE/healthcheck.sh"; then
  echo "  healthy: session up, channel present, chat service reachable"
elif [ -n "$session_pid" ] \
  && [ "$(ps -o etimes= -p "$session_pid" | tr -d ' ')" -lt "$MIN_UPTIME" ]; then
  # Distinguish "still starting" from "broken": reporting a fresh sandbox as
  # unhealthy sends you hunting for a fault that is just a clock.
  echo "  starting — inside the ${MIN_UPTIME}s settling window, not yet a verdict"
else
  echo "  UNHEALTHY — session, channel server, or reachability; see above"
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
