#!/usr/bin/env bash
# Say something in chat from OUTSIDE the agent.
#
# Everything here runs in the supervisor, not the session: no tokens are spent,
# and it keeps working precisely when the agent has stopped — which is when the
# person waiting most needs to hear something. The agent speaks for itself while
# it can; this covers the gaps where it cannot.
#
#   notify.sh progress          append one dot to the agent's last message
#   notify.sh reset             forget the tracked message (next progress re-reads)
#   notify.sh say <text>        post a new message in the user's channel
#   notify.sh operator <text>   direct-message the operator
set -uo pipefail
API="${GDD_DISCORD_API:-https://discord.com/api/v10}"
STATE="${GDD_PROGRESS_STATE:-/tmp/gdd-progress.state}"
PROJECTS="${GDD_TRANSCRIPT_DIR:-$HOME/.claude/projects/-work-ws}"
# 2000 is Discord's message ceiling; stop well short. At one dot per tick this is
# also the point where "still going" stops being informative and the stall
# watchdog's message is the useful thing instead.
MAX_DOTS="${GDD_PROGRESS_MAX_DOTS:-90}"

_token() { printf '%s' "${DISCORD_BOT_TOKEN:-}"; }

_api() {
  local method="$1" path="$2" body="${3:-}"
  [ -n "$(_token)" ] || return 1
  if [ -n "$body" ]; then
    curl -fsS -X "$method" "$API$path" \
      -H "Authorization: Bot $(_token)" \
      -H "Content-Type: application/json" \
      -d "$body" 2>/dev/null
  else
    curl -fsS -X "$method" "$API$path" -H "Authorization: Bot $(_token)" 2>/dev/null
  fi
}

# The newest transcript is the only place that knows which conversation this is:
# the inbound tag carries chat_id, and every reply result carries the id of the
# message it sent. Both are needed to edit rather than pile up new messages.
_transcript() {
  find "$PROJECTS" -maxdepth 1 -name '*.jsonl' -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn | head -1 | cut -d' ' -f2-
}

_chat_id() {
  local f; f="$(_transcript)" || return 1
  [ -n "$f" ] || return 1
  grep -o 'chat_id=\\"[0-9]*\\"' "$f" 2>/dev/null | tail -1 | grep -o '[0-9]*'
}

_last_message_id() {
  local f; f="$(_transcript)" || return 1
  [ -n "$f" ] || return 1
  grep -o 'sent (id: [0-9]*)' "$f" 2>/dev/null | tail -1 | grep -o '[0-9]*'
}

_json_string() {
  # jq is present in the image and does the escaping correctly; a hand-rolled
  # sed would break on the first quote or newline in an error message.
  jq -Rn --arg s "$1" '{content: $s}'
}

cmd_say() {
  local text="$1" chat; chat="$(_chat_id)" || return 1
  [ -n "$chat" ] || { echo "notify: no chat_id yet — nothing to say to" >&2; return 1; }
  _api POST "/channels/$chat/messages" "$(_json_string "$text")" >/dev/null
}

cmd_operator() {
  local text="$1" chat="${GDD_OPERATOR_CHAT:-}"
  [ -n "$chat" ] || { echo "notify: no operator channel configured" >&2; return 1; }
  _api POST "/channels/$chat/messages" "$(_json_string "$text")" >/dev/null
}

cmd_reset() { rm -f "$STATE"; }

# Append one dot to the agent's own last message, rather than posting a stream of
# new ones. A growing line reads as "still going" at a glance and costs the
# reader nothing; a dozen "working…" messages would bury the conversation. Edits
# also do not fire push notifications, so a phone stays quiet until there is
# something to say.
cmd_progress() {
  local chat msg base dots
  if [ -f "$STATE" ]; then
    IFS=$'\t' read -r chat msg dots base < "$STATE"
  else
    chat="$(_chat_id)"; msg="$(_last_message_id)"; dots=0
    [ -n "$chat" ] && [ -n "$msg" ] || return 1
    base="$(_api GET "/channels/$chat/messages/$msg" | jq -r '.content // empty')"
    [ -n "$base" ] || return 1
    # Newlines would break the single-line state file; the base is a short
    # acknowledgement in practice, so flattening loses nothing that matters.
    base="$(printf '%s' "$base" | tr '\n' ' ')"
  fi
  dots=$((dots + 1))
  [ "$dots" -le "$MAX_DOTS" ] || return 0
  local suffix=""
  local i=0
  while [ "$i" -lt "$dots" ]; do suffix="$suffix."; i=$((i + 1)); done
  _api PATCH "/channels/$chat/messages/$msg" "$(_json_string "$base $suffix")" >/dev/null || return 1
  printf '%s\t%s\t%s\t%s\n' "$chat" "$msg" "$dots" "$base" > "$STATE"
}

case "${1:-}" in
  progress) cmd_progress ;;
  reset)    cmd_reset ;;
  say)      shift; cmd_say "${1:-}" ;;
  operator) shift; cmd_operator "${1:-}" ;;
  *) echo "usage: notify.sh {progress|reset|say <text>|operator <text>}" >&2; exit 2 ;;
esac
