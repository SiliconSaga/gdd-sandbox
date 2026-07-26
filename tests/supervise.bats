load helpers/stub

setup() {
  stub_setup
  export GDD_WORKSPACE="$BATS_TEST_TMPDIR/ws"; mkdir -p "$GDD_WORKSPACE"
  export ROTATE_FLAG="$BATS_TEST_TMPDIR/rotate"
  export SUPERVISE_ONCE=1
  # 'script' is the PTY wrapper; stub it to just log the claude command it was given.
  make_stub script 'echo "$*" >> "$STUB_LOG"'
  make_stub ws 'exit 0'
}

@test "launch pre-allows only the chat reply/react tools" {
  bash bin/supervise.sh
  run cat "$STUB_LOG"
  [[ "$output" == *"--allowedTools"* ]]
  [[ "$output" == *"mcp__plugin:discord:discord__reply"* ]]
  [[ "$output" == *"mcp__plugin:discord:discord__react"* ]]
  # Nothing broad, and never a blanket bypass.
  [[ "$output" != *"Bash"* ]]
  [[ "$output" != *"bypassPermissions"* ]]
  [[ "$output" != *"dangerously-skip-permissions"* ]]
}

@test "a failed --continue falls back to a fresh session" {
  # Session history lives in ~/.claude, the sentinel on the workspace volume, so
  # they can desync ("No conversation found to continue"). Retrying --continue
  # forever is a crash loop Docker reports as healthy.
  touch "$GDD_WORKSPACE/.gdd-sandbox-launched"
  # Fail only the --continue attempt; succeed when launched fresh.
  make_stub script 'echo "$*" >> "$STUB_LOG"; case "$*" in *--continue*) exit 1 ;; esac'
  run bash bin/supervise.sh
  [[ "$output" == *"--continue failed"* ]]
  run grep -c -- "--continue" "$STUB_LOG"
  [ "$output" = "1" ]          # tried once
  run grep -c "claude --channels" "$STUB_LOG"
  [ "$output" = "2" ]          # then relaunched fresh
}

@test "first launch does not pass --continue" {
  bash bin/supervise.sh
  run grep -c -- "--continue" "$STUB_LOG"
  [ "$output" = "0" ]
}

@test "a relaunch passes --continue" {
  touch "$GDD_WORKSPACE/.gdd-sandbox-launched"   # simulate a prior launch
  bash bin/supervise.sh
  grep -q -- "--continue" "$STUB_LOG"
}

@test "a pending rotation launches fresh (no --continue) and clears the flag" {
  touch "$GDD_WORKSPACE/.gdd-sandbox-launched"
  touch "$ROTATE_FLAG"
  bash bin/supervise.sh
  run grep -c -- "--continue" "$STUB_LOG"
  [ "$output" = "0" ]
  [ ! -e "$ROTATE_FLAG" ]
}
