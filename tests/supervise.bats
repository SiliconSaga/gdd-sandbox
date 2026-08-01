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

@test "launch briefs the session on what it is and what it is scoped to" {
  # Without this the session is a bare agent that happens to receive chat: asked
  # to change the project it composes a reply and touches nothing.
  export GDD_TARGET=ken-site
  bash bin/supervise.sh
  run cat "$STUB_LOG"
  [[ "$output" == *"--append-system-prompt"* ]]
  [[ "$output" == *"ken-site"* ]]
  [[ "$output" == *"gdd-sandbox-briefing.md"* ]]
  # The primer is embedded in a `script -c` string: newlines would break it.
  run bash -c "grep -c '' \"$STUB_LOG\""
  [ "$output" = "1" ]
}

@test "launch pre-allows the chat and routine work tools" {
  # Observed from a real request: "add a post" needs Read then Write, and a
  # permission card for each is the rubber-stamp trap for a non-technical user.
  bash bin/supervise.sh
  run cat "$STUB_LOG"
  [[ "$output" == *"--allowedTools"* ]]
  [[ "$output" == *"mcp__plugin:discord:discord__reply"* ]]
  [[ "$output" == *"Read"* ]]
  [[ "$output" == *"Write"* ]]
  [[ "$output" == *"ws commit"* ]]
  # Never a blanket bypass.
  [[ "$output" != *"bypassPermissions"* ]]
  [[ "$output" != *"dangerously-skip-permissions"* ]]
}

@test "launch lets the agent open a pull request" {
  # The decision belongs on the PR page, which carries the preview and the
  # before/after screenshots — not on a permission card nobody can evaluate.
  bash bin/supervise.sh
  run cat "$STUB_LOG"
  [[ "$output" == *"ws push"* ]]
  [[ "$output" == *"ws cr"* ]]
}

@test "launch never lets the agent merge or release" {
  # Denied explicitly rather than merely left out: `gh pr merge` would otherwise
  # be reachable, and "never merges" has to be enforced, not implied. What
  # protects the live site is branch protection plus a human clicking merge.
  bash bin/supervise.sh
  run cat "$STUB_LOG"
  [[ "$output" == *"gh pr merge"* ]]
  [[ "$output" == *"gh release"* ]]
  # ...and those appear in the DENY list, not the allow list.
  allow="${output%%--disallowedTools*}"
  [[ "$allow" != *"gh pr merge"* ]]
}

@test "launch hard-denies destructive commands" {
  # No card and no override: the person on the other end cannot judge these, so
  # an "ask" has no safe answerer.
  bash bin/supervise.sh
  run cat "$STUB_LOG"
  [[ "$output" == *"--disallowedTools"* ]]
  [[ "$output" == *"rm "* ]]
  [[ "$output" == *"git push --force"* ]]
  [[ "$output" == *"sudo"* ]]
}

@test "the channel watchdog ends the session when its server disappears" {
  # The agent does not exit when its channel dies, so nothing would notice.
  export GDD_CHANNEL_GRACE=0 GDD_CHANNEL_POLL=0
  # Agent present, channel server absent.
  make_stub pgrep 'case "$*" in *claude-plugins-official/discord*) exit 1 ;; *) echo 1234 ;; esac'
  make_stub pkill 'echo "pkill $*" >> "$STUB_LOG"'
  # Keep the session "running" long enough for the watchdog to act.
  make_stub script 'echo "$*" >> "$STUB_LOG"; sleep 1'
  run bash bin/supervise.sh
  [[ "$output" == *"channel server gone"* ]]
  grep -q "pkill" "$STUB_LOG"
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
