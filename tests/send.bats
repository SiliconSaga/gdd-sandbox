setup() {
  export CLAUDE_STDIN_FIFO="$BATS_TEST_TMPDIR/fifo"   # a regular file in tests → no blocking
  : > "$CLAUDE_STDIN_FIFO"
}

@test "send.sh enter writes a carriage return" {
  bash bin/send.sh enter
  run cat "$CLAUDE_STDIN_FIFO"
  [ "$output" = "$(printf '\r')" ]
}

@test "send.sh passes an unknown token through literally" {
  bash bin/send.sh "yes"
  run cat "$CLAUDE_STDIN_FIFO"
  [ "$output" = "yes" ]
}
