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
#
# `ws exec <target> …` is what makes the workspace's own rules satisfiable. The
# GDD permission hook denies shell composition, so the shell habit every model
# reaches for — `cd components/<target>; git checkout -b x` — is refused, and the
# denial text explains the rule without naming a way to obey it. A cold session
# spent seven denials rediscovering that and then stopped without a word. This is
# the same action as one command with no `cd` and no `;`, so the compliant path
# exists rather than only the prohibition.
ALLOWED_BASE="mcp__plugin:discord:discord__reply,mcp__plugin:discord:discord__react,mcp__plugin:discord:discord__download_attachment,Read,Glob,Grep,Edit,Write,Bash(ws orient),Bash(ws status),Bash(ws log *),Bash(ws test *),Bash(ws commit *),Bash(ws push *),Bash(ws cr *),Bash(git status*),Bash(git diff*),Bash(git log*),Bash(git checkout*),Bash(git switch*),Bash(bundle exec jekyll *)"
[ -n "${GDD_TARGET:-}" ] && ALLOWED_BASE="$ALLOWED_BASE,Bash(ws exec $GDD_TARGET *)"
ALLOWED_TOOLS="${GDD_ALLOWED_TOOLS:-$ALLOWED_BASE}"
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
# asked for. Deny beats allow, so the destructive forms are listed explicitly —
# including the source-qualified spelling (`git checkout HEAD -- path`), which
# discards identically while naming a source first.
#
# Treat this list as a speed bump, not a boundary. It matches command strings, so
# an equivalent spelled another way (`git -C . checkout -- x`) slips past. What
# actually contains this sandbox is the volume holding only in-scope repositories,
# branch protection, and a human clicking merge — the deny list just keeps the
# obvious ways to lose work out of easy reach.
#
# Note the asymmetry with ALLOWED_TOOLS above: that one an operator may replace
# wholesale, because narrowing what the agent may do is always safe. This one is
# ADDITIVE — `GDD_DENIED_TOOLS` appends. Replacing it would let an operator who
# just wanted to add a rule of their own take the merge, release and rm denials
# with them without noticing, and "never merges" is meant to be enforced rather
# than politely assumed.
DENIED_BASE="Bash(gh pr merge*),Bash(gh release*),Bash(gh repo delete*),Bash(rm *),Bash(sudo *),Bash(git push --force*),Bash(git reset --hard*),Bash(git clean *),Bash(git checkout -- *),Bash(git checkout * -- *),Bash(git restore *),Bash(git branch -d*),Bash(git branch -D*),Bash(chmod *),Bash(curl * | *),Bash(:(){*)"
DENIED_TOOLS="$DENIED_BASE${GDD_DENIED_TOOLS:+,$GDD_DENIED_TOOLS}"
# Channel-server watchdog knobs (see watch_channel below).
CHANNEL_PATTERN="${GDD_CHANNEL_PATTERN:-claude-plugins-official/discord}"
CHANNEL_GRACE="${GDD_CHANNEL_GRACE:-60}"   # let the session spawn its MCP server
CHANNEL_POLL="${GDD_CHANNEL_POLL:-30}"
# Long enough that a reachable operator can actually answer. The channel relays
# prompts as buttons, so declining after ninety seconds would cancel decisions a
# human was in the middle of making — the watchdog is for when nobody will answer,
# not for beating someone to the reply. Two polls, so roughly five minutes.
PROMPT_POLL="${GDD_PROMPT_POLL:-30}"
# How long a prompt is left alone before the watchdog declines it.
#
# The old shape — two polls of 150s — worked out to roughly three minutes, and it
# cancelled a card an operator was actively answering: notification to a phone,
# read it, decide, tap. Its own comment said that was the one thing it must not
# do. Fifteen minutes is longer than any of that and still far short of "hung
# forever", which is what this exists to prevent.
PROMPT_GRACE="${GDD_PROMPT_GRACE:-900}"
# How often the progress line grows, and how long a quiet session is given before
# the supervisor speaks for it. Ten seconds is slow enough to be cheap and fast
# enough to look alive; two minutes of nothing, with a request still unanswered,
# is well past any normal pause between tool calls.
PROGRESS_POLL="${GDD_PROGRESS_POLL:-10}"
STALL_AFTER="${GDD_STALL_AFTER:-120}"
# Narration lives in its own script so the supervisor can speak without spending
# tokens, and so tests can stand a stub in front of it. Resolved at call time —
# HERE is set further down, and a default evaluated here would be an unbound
# variable for everyone who does NOT override it, which is the whole point of a
# default. (It shipped that way for one run: the tests that set GDD_NOTIFY never
# evaluated the default and passed while every other test in the file broke.)
notify() { bash "${GDD_NOTIFY:-$HERE/notify.sh}" "$@" >/dev/null 2>&1 || true; }
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
# Overridable so the prompt watchdog can be driven against a fixture. It was
# previously untestable end to end, which is how a three-minute cancel window
# shipped without anyone measuring it against a human's reaction time.
TTY_LOG="${GDD_TTY_LOG:-/tmp/channels-tty.log}"
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
  local last="" now="" waited=0 announced=0
  sleep "$CHANNEL_GRACE"
  while pgrep -f 'claude .*--channels' >/dev/null; do
    now="$(bash "$HERE/session-log.sh" 6 "$TTY_LOG" 2>/dev/null || true)"
    if ws_prompt_pending "$now"; then
      # Say it once, immediately. The failure that prompted this: a card reached
      # the operator's DMs while the person in the channel saw only "Back
      # shortly" and then nothing at all. Both audiences need it — the person so
      # the silence has a reason, the operator so they know they are the delay.
      if [ "$announced" -eq 0 ]; then
        announced=1
        notify say "I need an approval before I can carry on — I've asked the operator. Nothing is lost; I'll pick up as soon as it comes through."
        notify operator "Session is blocked on a permission prompt and cannot proceed until it is answered. It will be declined automatically in $((PROMPT_GRACE / 60)) minutes."
      fi
      if [ -n "$last" ] && [ "$now" = "$last" ] && [ "$waited" -ge "$PROMPT_GRACE" ]; then
        # Still the ORIGINAL purpose: a prompt nobody will answer must not hang
        # the session forever. What changed is the clock — it now outlasts a
        # notification reaching a phone — and that it no longer happens silently.
        echo "supervise: declining a prompt with no human to answer it" >&2
        notify say "I couldn't get the approval I needed, so I've stopped rather than leave you waiting. The operator has the details."
        notify operator "Permission prompt went unanswered for $((PROMPT_GRACE / 60))m and was declined. The session has been unblocked but the request was not completed."
        printf '\033' > "$FIFO"     # Esc cancels, whatever the prompt's shape
        last=""; waited=0; announced=0
      else
        [ "$now" = "$last" ] && waited=$((waited + PROMPT_POLL)) || waited=0
        last="$now"
      fi
    else
      last=""; waited=0; announced=0
    fi
    sleep "$PROMPT_POLL"
  done
}

# Has the agent replied since the last thing it was asked?
#
# This is what separates "finished" from "stopped", and without it a stall
# watchdog would announce a problem after every completed request. Both markers
# live in the transcript: an inbound message carries a chat_id tag, and every
# reply records the id it sent. Whichever appears LAST wins — a reply after the
# request means answered, a request after the reply means someone is waiting.
unanswered_request() {
  local f last_in last_out
  f="$(find "${GDD_TRANSCRIPT_DIR:-$HOME/.claude/projects/-work-ws}" -maxdepth 1 -name '*.jsonl' \
        -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
  [ -n "$f" ] || return 1
  last_in="$(grep -n 'chat_id=' "$f" 2>/dev/null | tail -1 | cut -d: -f1)"
  last_out="$(grep -n 'sent (id:' "$f" 2>/dev/null | tail -1 | cut -d: -f1)"
  [ -n "$last_in" ] || return 1
  [ -n "$last_out" ] || return 0
  [ "$last_in" -gt "$last_out" ]
}

# Narrate long work, and speak up when it stops without finishing.
#
# The two failures this week ended identically: the agent went quiet and the
# person kept waiting on a reply that was never coming — once after a run of
# refusals, once after an approval was cancelled underneath it. Nobody has to be
# watching for this to be caught, and it costs nothing per tick because it never
# touches the model.
watch_progress() {
  local last_mtime="" now_mtime="" idle=0 stalled=0 ticks=0
  sleep "$CHANNEL_GRACE"
  while pgrep -f 'claude .*--channels' >/dev/null; do
    now_mtime="$(find "${GDD_TRANSCRIPT_DIR:-$HOME/.claude/projects/-work-ws}" -maxdepth 1 \
                  -name '*.jsonl' -printf '%T@\n' 2>/dev/null | sort -rn | head -1)"
    if [ -n "$now_mtime" ] && [ "$now_mtime" != "$last_mtime" ]; then
      # The transcript grows on every model event, so a changing file IS the
      # session working — a far better signal than a process being alive, which
      # stays true through every failure this design has hit.
      last_mtime="$now_mtime"; idle=0; stalled=0
      notify progress
    else
      idle=$((idle + PROGRESS_POLL))
      if [ "$idle" -ge "$STALL_AFTER" ] && [ "$stalled" -eq 0 ] && unanswered_request; then
        stalled=1        # once only: a watchdog that repeats every tick is worse than the silence
        echo "supervise: session went quiet with a request unanswered" >&2
        notify say "I've stopped before finishing what you asked, and I'm sorry — I'm not going to leave you waiting on a reply that isn't coming. The operator has been told and can pick it up."
        notify operator "Session went quiet with an unanswered request: no reply since the last inbound message, no transcript activity for ${STALL_AFTER}s. Session is alive, so this is not a crash — check the tty log."
      fi
    fi
    ticks=$((ticks + 1))
    [ -n "${SUPERVISE_MAX_TICKS:-}" ] && [ "$ticks" -ge "$SUPERVISE_MAX_TICKS" ] && return 0
    sleep "$PROGRESS_POLL"
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
  watch_progress &
  local progress_watcher=$!
  # -e so script returns the child's exit status; without it a failed session
  # looks successful and the fallback below never triggers.
  # shellcheck disable=SC2086
  script -q -e -f -c \
    "claude --channels plugin:discord@claude-plugins-official $MODEL_FLAG --permission-mode '$PERMISSION_MODE' --allowedTools '$ALLOWED_TOOLS' --disallowedTools '$DENIED_TOOLS' --append-system-prompt '$PRIMER' $cont" \
    "$TTY_LOG" < "$FIFO" || rc=$?
  kill "$w" "$watcher" "$prompt_watcher" "$progress_watcher" 2>/dev/null || true
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
