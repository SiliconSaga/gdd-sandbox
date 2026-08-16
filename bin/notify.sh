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
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/lib.sh
. "$HERE/lib.sh"
API="${GDD_DISCORD_API:-https://discord.com/api/v10}"
STATE="${GDD_PROGRESS_STATE:-/tmp/gdd-progress.state}"
# Bounded, because this runs inside the supervisor's polling loop: a connection
# that hangs would stall the very watchdog whose job is to notice that things
# have stalled. Failing a tick is nothing — the next one is seconds away.
CURL_CONNECT_TIMEOUT="${GDD_CURL_CONNECT_TIMEOUT:-5}"
CURL_MAX_TIME="${GDD_CURL_MAX_TIME:-15}"
# Discord's message ceiling. An edit over it is rejected outright.
MAX_CONTENT="${GDD_MAX_CONTENT:-2000}"
# Stop well short of that ceiling in dots. At one dot per tick this is also the
# point where "still going" stops being informative and the stall watchdog's
# message is the useful thing instead.
MAX_DOTS="${GDD_PROGRESS_MAX_DOTS:-90}"

_token() { printf '%s' "${DISCORD_BOT_TOKEN:-}"; }

_api() {
  local method="$1" path="$2" body="${3:-}"
  [ -n "$(_token)" ] || return 1
  if [ -n "$body" ]; then
    curl -fsS --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" \
      -X "$method" "$API$path" \
      -H "Authorization: Bot $(_token)" \
      -H "Content-Type: application/json" \
      -d "$body" 2>/dev/null
  else
    curl -fsS --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" \
      -X "$method" "$API$path" -H "Authorization: Bot $(_token)" 2>/dev/null
  fi
}

# The newest transcript is the only place that knows which conversation this is:
# the inbound tag carries chat_id, and every reply result carries the id of the
# message it sent. Both are needed to edit rather than pile up new messages.
_chat_id() {
  local f; f="$(ws_transcript)"
  [ -n "$f" ] || return 1
  ws_transcript_chat_id "$f"
}

_last_message_id() {
  local f; f="$(ws_transcript)"
  [ -n "$f" ] || return 1
  ws_transcript_last_message_id "$f"
}

_json_string() {
  # jq is present in the image and does the escaping correctly; a hand-rolled
  # sed would break on the first quote or newline in an error message.
  # Compact: a pretty-printed body spans lines, which turns one request into
  # several lines in any log that records the command — including the test stub,
  # where an assertion then matches the method on one line and the content on
  # another and quietly proves nothing.
  jq -cRn --arg s "$1" '{content: $s}'
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
  local chat msg base dots current
  # Follow the conversation. The agent posts as it goes, and dots accumulating on
  # a message three replies back read as stuck rather than busy — observed live:
  # the line grew on the first acknowledgement while the newer messages sat
  # still. Whenever the agent has said something newer, re-anchor to that.
  if [ -f "$STATE" ]; then
    IFS=$'\t' read -r chat msg dots base < "$STATE"
    current="$(_last_message_id)"
    [ -n "$current" ] && [ "$current" != "$msg" ] && rm -f "$STATE"
  fi
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
  # MAX_DOTS bounds the suffix, not the whole message. Re-anchoring points at the
  # agent's newest message, which can be a full-length reply rather than a short
  # acknowledgement — appending to one near the ceiling gets the edit rejected,
  # and because the state is only written on success every later tick repeats it.
  # Stop instead: the dots are a nicety, and a message that long already says the
  # agent is alive.
  [ $(( ${#base} + 1 + dots )) -le "$MAX_CONTENT" ] || return 0
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
