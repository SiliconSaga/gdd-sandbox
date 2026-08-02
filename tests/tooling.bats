load helpers/stub

# The diagnostic tools exist because a quiet agent was expensive to investigate:
# the log was unreadable, the state took half a dozen probes, and every
# behavioural check needed a person to send a chat message and report back.

@test "ask.sh refuses clearly when the sandbox is not running" {
  # Better an explicit refusal than a write that blocks forever on a missing fifo.
  export CLAUDE_STDIN_FIFO="$BATS_TEST_TMPDIR/absent"
  run bash bin/ask.sh "do something"
  [ "$status" -ne 0 ]
  [[ "$output" == *"is the sandbox running"* ]]
}

@test "ask.sh requires something to ask" {
  export CLAUDE_STDIN_FIFO="$BATS_TEST_TMPDIR/absent"
  run bash bin/ask.sh
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage"* ]]
}

@test "session-log strips control codes so the text can be searched" {
  log="$BATS_TEST_TMPDIR/tty.log"
  # A prompt as it actually appears: split by cursor moves mid-word.
  printf 'Do\033[5Gyou\033[9Gwant\033[14Gto\033[17Gproceed?\n' > "$log"
  run bash bin/session-log.sh 20 "$log"
  [[ "$output" == *"proceed?"* ]]
  [[ "$output" != *$'\033'* ]]
}

@test "session-log drops spinner frames that would bury the content" {
  log="$BATS_TEST_TMPDIR/tty.log"
  printf '●\n●\n●\nthe agent said something\n●\n●\n' > "$log"
  run bash bin/session-log.sh 20 "$log"
  [[ "$output" == *"the agent said something"* ]]
  [[ "$output" != *"●"* ]]
}

@test "session-log says so when there is no log" {
  run bash bin/session-log.sh 10 "$BATS_TEST_TMPDIR/nope.log"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no session log"* ]]
}
