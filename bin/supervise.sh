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
#
# download_attachment is how a dropped file — a photo of a flyer, a Word document
# of revised copy — reaches the agent at all. Fetching one is plumbing rather than
# a decision, and the person who just sent the file is the last person able to
# evaluate a permission card about it. The file lands in a local inbox and is read
# with Read, which is already allowed; nothing leaves the container.
#
# The ids keep the colon form of the server name even though the runtime reports
# them with underscores (`mcp__plugin_discord_discord__reply`) — the CLI sanitizes
# the server name when it registers the tool. The colon form is what grants: it was
# observed working under `--permission-mode default`, where no classifier could
# have approved the call instead. Do not "correct" the colons.
ALLOWED_TOOLS="${GDD_ALLOWED_TOOLS:-mcp__plugin:discord:discord__reply,mcp__plugin:discord:discord__react,mcp__plugin:discord:discord__download_attachment,Read,Glob,Grep,Edit,Write,Bash(ws orient),Bash(ws status),Bash(ws log *),Bash(ws test *),Bash(ws commit *),Bash(ws push *),Bash(ws cr *),Bash(git status*),Bash(git diff*),Bash(git log*),Bash(git checkout*),Bash(git switch*),Bash(bundle exec jekyll *)}"
# Hard denials: destructive, out-of-scope, or irreversible — no card, no override.
# An "ask" has no safe answerer here; the person on the other end cannot judge it.
#
# Merging and releasing are denied explicitly rather than merely left out: `gh pr
# merge` would otherwise be reachable, and "never merges" has to be enforced, not
# implied. Publishing stays a human act on the PR page.
#
# The git entries that discard work need naming too. `Bash(git checkout*)` is
# allowed so the agent can move between branches, and that same pattern covers
# `git checkout -- <path>`, which silently throws away the edits someone just
# asked for. Deny beats allow, so the destructive forms are listed explicitly.
#
# Treat this list as a speed bump, not a boundary. It matches command strings, so
# an equivalent spelled another way (`git -C . checkout -- x`) slips past. What
# actually contains this sandbox is the volume holding only in-scope repositories,
# branch protection, and a human clicking merge — the deny list just keeps the
# obvious ways to lose work out of easy reach.
DENIED_TOOLS="${GDD_DENIED_TOOLS:-Bash(gh pr merge*),Bash(gh release*),Bash(gh repo delete*),Bash(rm *),Bash(sudo *),Bash(git push --force*),Bash(git reset --hard*),Bash(git clean *),Bash(git checkout -- *),Bash(git restore *),Bash(git branch -d*),Bash(git branch -D*),Bash(chmod *),Bash(curl * | *),Bash(:(){*)}"
# Channel-server watchdog knobs (see watch_channel below).
CHANNEL_PATTERN="${GDD_CHANNEL_PATTERN:-claude-plugins-official/discord}"
CHANNEL_GRACE="${GDD_CHANNEL_GRACE:-60}"   # let the session spawn its MCP server
CHANNEL_POLL="${GDD_CHANNEL_POLL:-30}"
# Long enough that a reachable operator can actually answer. The channel relays
# prompts as buttons, so declining after ninety seconds would cancel decisions a
# human was in the middle of making — the watchdog is for when nobody will answer,
# not for beating someone to the reply. Two polls, so roughly five minutes.
PROMPT_POLL="${GDD_PROMPT_POLL:-150}"
# Auto mode classifies each action instead of asking a human who is not there. Its
# shipped rules already reason about the threats that matter here — exfiltration,
# credential exploration, straying outside the repository, irreversible local
# destruction — which is better grounded than a list reverse-engineered from one
# observed session. The deny list below still applies: those are project policy,
# not general safety, and no classifier can know that publishing is the owner's
# call. The prompt watchdog stays too, since anything that still asks would
# otherwise hang.
PERMISSION_MODE="${GDD_PERMISSION_MODE:-auto}"
# Which model the session runs on. Pinned rather than inherited: left to the
# account default a sandbox silently ran a different model than its operator
# believed, visible only by reading the session transcripts. The work is published
# under someone else's name, and the failure that matters here is a change that is
# literally correct and semantically wrong — a reasoning failure — so the stronger
# model is the default and the cheaper one is a deliberate downgrade.
#
# An alias, not a pinned version id: the sandbox is long-lived and an id goes stale
# where `opus` keeps meaning the current one. Set GDD_MODEL to empty to inherit the
# account default instead — an empty --model would be an error, so the flag is
# omitted entirely in that case.
MODEL="${GDD_MODEL-opus}"
MODEL_FLAG=""
[ -n "$MODEL" ] && MODEL_FLAG="--model $MODEL"
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/lib.sh
. "$HERE/lib.sh"
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
# Decline prompts nobody can answer.
#
# A headless session has no human at its terminal, so any interactive prompt hangs
# it forever: the process stays alive, the channel stays connected, the health
# check stays green, and the person waiting gets silence. Observed for real — a
# workspace hook asked to confirm a shell command and the session sat blocked for
# ten minutes with no sign of trouble anywhere.
#
# So the floor flips from ask to deny. Cancelling loses one tool call and the agent
# adapts or explains; waiting loses the conversation with no explanation at all.
# Prompts that genuinely need a person belong in chat as an outcome question, not
# as a tool confirmation.
#
# Requires the prompt to persist across two polls, so a prompt being answered by
# some other path is not cancelled out from under it.
watch_prompts() {
  local last="" now=""
  sleep "$CHANNEL_GRACE"
  while pgrep -f 'claude .*--channels' >/dev/null; do
    now="$(bash "$HERE/session-log.sh" 6 "$TTY_LOG" 2>/dev/null || true)"
    if ws_prompt_pending "$now"; then
      if [ -n "$last" ] && [ "$now" = "$last" ]; then
        echo "supervise: declining a prompt with no human to answer it" >&2
        printf '\033' > "$FIFO"     # Esc cancels, whatever the prompt's shape
        last=""
      else
        last="$now"
      fi
    else
      last=""
    fi
    sleep "$PROMPT_POLL"
  done
}

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
  watch_prompts &
  local prompt_watcher=$!
  # -e so script returns the child's exit status; without it a failed session
  # looks successful and the fallback below never triggers.
  # shellcheck disable=SC2086
  script -q -e -f -c \
    "claude --channels plugin:discord@claude-plugins-official $MODEL_FLAG --permission-mode '$PERMISSION_MODE' --allowedTools '$ALLOWED_TOOLS' --disallowedTools '$DENIED_TOOLS' --append-system-prompt '$PRIMER' $cont" \
    "$TTY_LOG" < "$FIFO" || rc=$?
  kill "$w" "$watcher" "$prompt_watcher" 2>/dev/null || true
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
