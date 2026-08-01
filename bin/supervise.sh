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
#
# The chat tools plus the routine work tools, observed from a real request rather
# than guessed: answering "add a post" needs Read then Write, and a card for each
# is the rubber-stamp trap — a non-technical user cannot evaluate "allow Read?" and
# learns to approve everything, which is worse than no gate.
#
# Edit/Write are allowed unqualified because the container holds ONLY in-scope
# repositories: the mount boundary does the containing, not the prompt.
#
# Opening a pull request is allowed; merging never is. The agent may branch, push
# and raise a PR without prompting, because the decision belongs on the PR page —
# which carries the preview link and the before/after screenshots — rather than on
# a permission card nobody can evaluate. What protects the live site is branch
# protection plus the merge button, not a prompt.
ALLOWED_TOOLS="${GDD_ALLOWED_TOOLS:-mcp__plugin:discord:discord__reply,mcp__plugin:discord:discord__react,Read,Glob,Grep,Edit,Write,Bash(ws orient),Bash(ws status),Bash(ws log *),Bash(ws test *),Bash(ws commit *),Bash(ws push *),Bash(ws cr *),Bash(git status*),Bash(git diff*),Bash(git log*),Bash(git checkout*),Bash(git switch*),Bash(bundle exec jekyll *)}"
# Hard denials: destructive, out-of-scope, or irreversible — no card, no override.
# An "ask" has no safe answerer here; the person on the other end cannot judge it.
#
# Merging and releasing are denied explicitly rather than merely left out: `gh pr
# merge` would otherwise be reachable, and "never merges" has to be enforced, not
# implied. Publishing stays a human act on the PR page.
DENIED_TOOLS="${GDD_DENIED_TOOLS:-Bash(gh pr merge*),Bash(gh release*),Bash(gh repo delete*),Bash(rm *),Bash(sudo *),Bash(git push --force*),Bash(git reset --hard*),Bash(git clean *),Bash(chmod *),Bash(curl * | *),Bash(:(){*)}"
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
    "claude --channels plugin:discord@claude-plugins-official --allowedTools '$ALLOWED_TOOLS' --disallowedTools '$DENIED_TOOLS' --append-system-prompt '$PRIMER' $cont" \
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
