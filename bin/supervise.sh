#!/usr/bin/env bash
# Keep a PTY-hosted `claude --channels` session alive.
#  - crash recovery: relaunch with --continue (recover the one session)
#  - deliberate rotation: ROTATE_FLAG present ⇒ launch fresh (shed context);
#    the fresh session re-orients via AGENTS.md ("run ws orient on startup").
set -u
WS="${GDD_WORKSPACE:-/work/ws}"
ROTATE_FLAG="${ROTATE_FLAG:-/tmp/gdd-rotate}"
# Pre-allowed chat tools, passed explicitly on the command line. These must never
# prompt: relaying a raw "allow discord-reply?" card to a non-technical user is the
# rubber-stamp trap — they learn to tap Allow reflexively, which is worse than no
# gate. Ids are `mcp__<server>__<tool>`; the server is `plugin:discord:discord`
# per `claude mcp list`. Everything else stays gated.
ALLOWED_TOOLS="${GDD_ALLOWED_TOOLS:-mcp__plugin:discord:discord__reply,mcp__plugin:discord:discord__react}"
# Channel-server watchdog knobs (see watch_channel below).
CHANNEL_PATTERN="${GDD_CHANNEL_PATTERN:-claude-plugins-official/discord}"
CHANNEL_GRACE="${GDD_CHANNEL_GRACE:-60}"   # let the session spawn its MCP server
CHANNEL_POLL="${GDD_CHANNEL_POLL:-30}"
# Point the session at its briefing. Kept to a single line with no quotes: it is
# embedded in the `script -c` command string, where newlines and quoting break.
# The substance lives in the briefing file, which is versioned and testable.
BRIEFING="${GDD_BRIEFING_PATH:-/tmp/gdd-sandbox-briefing.md}"
PRIMER="You are the agent for a GDD sandboxed workspace at ${WS}, scoped to the component ${GDD_TARGET:-unknown}. Chat messages come from a non-technical person and ask for real changes to that component, not for a reply written in chat. Before your first action, read ${BRIEFING} and follow it."
LAUNCHED="$WS/.gdd-sandbox-launched"
TTY_LOG=/tmp/channels-tty.log
FIFO=/tmp/claude-stdin

# Watch the channel server for the life of a session. The agent does NOT exit when
# its channel dies — observed after a host reboot: agent alive, MCP server absent,
# bot offline, every message silently unanswered while Docker reported healthy.
# Ending the session hands recovery to the supervisor loop, which relaunches.
watch_channel() {
  sleep "$CHANNEL_GRACE"
  while pgrep -f 'claude .*--channels' >/dev/null; do
    if ! pgrep -f "$CHANNEL_PATTERN" >/dev/null; then
      echo "supervise: channel server gone; restarting the session" >&2
      pkill -f 'claude .*--channels'
      return 0
    fi
    sleep "$CHANNEL_POLL"
  done
}

launch() {
  local cont="$1"   # "--continue" or ""
  local rc=0
  : > "$TTY_LOG"; rm -f "$FIFO"; mkfifo "$FIFO"
  sleep infinity > "$FIFO" &            # hold the FIFO open (drive prompts + no EOF)
  local w=$!
  watch_channel &
  local watcher=$!
  # -e so script returns the child's exit status; without it a failed session
  # looks successful and the fallback below never triggers.
  # shellcheck disable=SC2086
  script -q -e -f -c \
    "claude --channels plugin:discord@claude-plugins-official --allowedTools '$ALLOWED_TOOLS' --append-system-prompt '$PRIMER' $cont" \
    "$TTY_LOG" < "$FIFO" || rc=$?
  kill "$w" "$watcher" 2>/dev/null || true
  return "$rc"
}

run_once() {
  cd "$WS" 2>/dev/null || true
  local cont=""
  if [ -e "$ROTATE_FLAG" ]; then
    # Deliberate rotation: archive the prior log, start fresh, clear the flag.
    [ -f "$TTY_LOG" ] && mv "$TTY_LOG" "$TTY_LOG.$(date +%s).archived" 2>/dev/null || true
    rm -f "$ROTATE_FLAG"
    cont=""
  elif [ -e "$LAUNCHED" ]; then
    cont="--continue"
  fi
  touch "$LAUNCHED"
  if launch "$cont"; then
    return 0
  fi
  # A --continue launch can fail outright — most commonly "No conversation found
  # to continue", when the session history was lost but the sentinel survived
  # (history lives in ~/.claude, the sentinel on the workspace volume, so
  # replacing the container desyncs them). Retrying --continue forever is a
  # crash loop that Docker happily reports as healthy. Fall back to a fresh
  # session instead: context is recoverable from the Thalamus, silence is not.
  if [ -n "$cont" ]; then
    echo "supervise: --continue failed; starting a fresh session" >&2
    rm -f "$LAUNCHED"
    launch "" || true
    touch "$LAUNCHED"
  fi
}

if [ "${SUPERVISE_ONCE:-0}" = "1" ]; then run_once; exit 0; fi
backoff=2
while true; do
  run_once
  sleep "$backoff"
  backoff=$(( backoff < 30 ? backoff * 2 : 30 ))
done
