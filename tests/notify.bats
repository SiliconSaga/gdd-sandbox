load helpers/stub

setup() {
  stub_setup
  export DISCORD_BOT_TOKEN="fake-token"
  export GDD_PROGRESS_STATE="$BATS_TEST_TMPDIR/progress.state"
  export GDD_TRANSCRIPT_DIR="$BATS_TEST_TMPDIR/projects"
  export GDD_OPERATOR_CHAT="9999"
  mkdir -p "$GDD_TRANSCRIPT_DIR"
  # A transcript shaped like the real one: the inbound tag carries chat_id, and
  # each reply result carries the id of the message it sent.
  cat > "$GDD_TRANSCRIPT_DIR/session.jsonl" <<'JSON'
{"type":"user","message":{"content":"<channel source=\"discord\" chat_id=\"555\" message_id=\"1\">hi"}}
{"type":"user","toolUseResult":[{"type":"text","text":"sent (id: 777)"}]}
JSON
  # curl stands in for Discord. GET returns the message the agent already sent.
  make_stub curl 'case "$*" in
  *"GET"*) echo "{\"content\": \"Got it — taking a look.\"}" ;;
  *) : ;;
esac'
}

@test "progress appends a dot to the agent's own last message" {
  # A growing line reads as "still going" at a glance. A stream of new messages
  # would bury the conversation it is supposed to be reassuring someone about.
  bash bin/notify.sh progress
  run cat "$STUB_LOG"
  [[ "$output" == *"PATCH"* ]]
  [[ "$output" == *"/channels/555/messages/777"* ]]
  [[ "$output" == *"Got it — taking a look. ."* ]]
}

@test "progress grows the line rather than restarting it" {
  bash bin/notify.sh progress
  bash bin/notify.sh progress
  bash bin/notify.sh progress
  run cat "$STUB_LOG"
  [[ "$output" == *"Got it — taking a look. ..."* ]]
}

@test "progress reads the message once, not on every tick" {
  # Editing every few seconds must not also mean fetching every few seconds:
  # that is two API calls per tick for one line of output.
  bash bin/notify.sh progress
  bash bin/notify.sh progress
  run bash -c "grep -c GET '$STUB_LOG'"
  [ "$output" = "1" ]
}

@test "progress stops growing at the cap" {
  # Past the cap the dots stop being information, and the message has a hard
  # length limit. The stall watchdog's words are the useful thing by then.
  export GDD_PROGRESS_MAX_DOTS=2
  bash bin/notify.sh progress
  bash bin/notify.sh progress
  bash bin/notify.sh progress
  run bash -c "grep -c PATCH '$STUB_LOG'"
  [ "$output" = "2" ]
}

@test "reset makes the next tick track a fresh message" {
  bash bin/notify.sh progress
  bash bin/notify.sh reset
  bash bin/notify.sh progress
  run cat "$STUB_LOG"
  # Two GETs: the tracked message was forgotten, so the second tick re-read.
  run bash -c "grep -c GET '$STUB_LOG'"
  [ "$output" = "2" ]
}

@test "say posts into the user's own channel" {
  bash bin/notify.sh say "the build finished"
  run cat "$STUB_LOG"
  [[ "$output" == *"POST"* ]]
  [[ "$output" == *"/channels/555/messages"* ]]
  [[ "$output" == *"the build finished"* ]]
}

@test "operator messages go to the operator, not the user" {
  bash bin/notify.sh operator "exit 1 from ws push"
  run cat "$STUB_LOG"
  [[ "$output" == *"/channels/9999/messages"* ]]
  [[ "$output" != *"/channels/555/messages"* ]]
}

@test "text with quotes and newlines survives intact" {
  # Error detail is exactly what gets sent to the operator, and it is full of
  # quotes and line breaks. Hand-rolled escaping would corrupt the first one.
  bash bin/notify.sh operator 'failed: "ws push" said
no such remote'
  run cat "$STUB_LOG"
  [[ "$output" == *'\"ws push\"'* ]]
  [[ "$output" == *'\n'* ]]
}

@test "no token means no call, and no crash" {
  # A sandbox can run without chat configured at all; the supervisor must not
  # die because it could not narrate.
  unset DISCORD_BOT_TOKEN
  run bash bin/notify.sh say "anything"
  [ "$status" -ne 0 ]
  run cat "$STUB_LOG"
  [[ "$output" != *"POST"* ]]
}
