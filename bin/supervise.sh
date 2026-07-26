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
LAUNCHED="$WS/.gdd-sandbox-launched"
TTY_LOG=/tmp/channels-tty.log
FIFO=/tmp/claude-stdin

launch() {
  local cont="$1"   # "--continue" or ""
  local rc=0
  : > "$TTY_LOG"; rm -f "$FIFO"; mkfifo "$FIFO"
  sleep infinity > "$FIFO" &            # hold the FIFO open (drive prompts + no EOF)
  local w=$!
  # -e so script returns the child's exit status; without it a failed session
  # looks successful and the fallback below never triggers.
  # shellcheck disable=SC2086
  script -q -e -f -c \
    "claude --channels plugin:discord@claude-plugins-official --allowedTools '$ALLOWED_TOOLS' $cont" \
    "$TTY_LOG" < "$FIFO" || rc=$?
  kill "$w" 2>/dev/null || true
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
