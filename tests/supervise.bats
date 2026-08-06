load helpers/stub

setup() {
  stub_setup
  export GDD_WORKSPACE="$BATS_TEST_TMPDIR/ws"; mkdir -p "$GDD_WORKSPACE"
  export ROTATE_FLAG="$BATS_TEST_TMPDIR/rotate"
  export SUPERVISE_ONCE=1
  # Every policy knob is overridable by env, so a developer shell or CI job that
  # exports one would make these tests assert the override while reporting that
  # they checked the default — the failure mode where a test passes about the
  # wrong thing.
  unset GDD_MODEL GDD_ALLOWED_TOOLS GDD_DENIED_TOOLS
  # 'script' is the PTY wrapper. make_stub already records the argv, so the body
  # stays empty — logging it again would double every count the tests assert on.
  make_stub script
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

@test "launch classifies actions rather than asking an absent human" {
  # Auto mode's shipped rules cover exfiltration, credential exploration and
  # straying outside the repository — better grounded than a list reverse-
  # engineered from one session. It does not replace the project-policy denies.
  bash bin/supervise.sh
  run cat "$STUB_LOG"
  # Quoted in the launch string, so match the flag and value separately.
  [[ "$output" == *"--permission-mode"* ]]
  [[ "$output" == *"auto"* ]]
  [[ "$output" == *"--disallowedTools"* ]]
  [[ "$output" != *"bypassPermissions"* ]]
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

@test "launch pins the model rather than inheriting whatever the account defaults to" {
  # Left unset the session silently took the account default, which was not the
  # model the operator believed it was running — invisible until someone read the
  # transcripts. The published site is written under someone else's name, so the
  # reasoning-quality choice is deliberate and recorded, not inherited.
  bash bin/supervise.sh
  run cat "$STUB_LOG"
  [[ "$output" == *"--model"* ]]
  [[ "$output" == *"opus"* ]]
}

@test "an operator can choose a different model" {
  export GDD_MODEL=sonnet
  bash bin/supervise.sh
  run cat "$STUB_LOG"
  [[ "$output" == *"--model sonnet"* ]]
  [[ "$output" != *"opus"* ]]
}

@test "an empty model setting deliberately inherits the account default" {
  # The escape hatch: an operator who wants whatever their plan gives them should
  # not have to name a model to get it, and an empty --model would be an error.
  export GDD_MODEL=
  bash bin/supervise.sh
  run cat "$STUB_LOG"
  [[ "$output" != *"--model"* ]]
}

@test "launch lets the agent open a file the user dropped in chat" {
  # A photo of a flyer or a Word document is how a non-technical owner supplies
  # content. Fetching it is plumbing, not a decision, so it must not arrive as a
  # permission card: the person who sent the file cannot evaluate a tool prompt
  # about it, and the whole point of the gate is that they never have to.
  bash bin/supervise.sh
  run cat "$STUB_LOG"
  [[ "$output" == *"mcp__plugin:discord:discord__download_attachment"* ]]
  # In the allow list, not the deny list. Checking only the allow side would pass
  # even if the same tool appeared in both, where the deny would win silently.
  allow="${output%%--disallowedTools*}"
  [[ "$allow" == *"download_attachment"* ]]
  deny="${output#*--disallowedTools}"
  [[ "$deny" != *"download_attachment"* ]]
}

@test "launch denies the git commands that throw work away" {
  # `Bash(git checkout*)` is allowed so the agent can switch branches, and that
  # same pattern would otherwise cover `git checkout -- <path>`, which silently
  # discards the edits someone just asked for. Deny beats allow, so naming the
  # destructive forms explicitly is what stops them.
  bash bin/supervise.sh
  run cat "$STUB_LOG"
  deny="${output#*--disallowedTools}"
  [[ "$deny" == *"git checkout -- "* ]]
  # `git checkout HEAD -- path` discards exactly the same way, and names a source
  # first so it slips past a pattern anchored on `checkout --`.
  [[ "$deny" == *"git checkout * -- "* ]]
  [[ "$deny" == *"git restore"* ]]
  [[ "$deny" == *"git branch -d"* ]]
  [[ "$deny" == *"git branch -D"* ]]
  # ...without losing the ability to move between branches.
  allow="${output%%--disallowedTools*}"
  [[ "$allow" == *"git checkout*"* ]]
}

@test "an operator's extra deny rules add to the baseline, never replace it" {
  # "never merges" is enforced, not implied — so it must not be possible to drop
  # it by accident. An operator adding one rule of their own would otherwise
  # silently take the merge, release and rm denials with it.
  export GDD_DENIED_TOOLS='Bash(terraform *)'
  bash bin/supervise.sh
  run cat "$STUB_LOG"
  deny="${output#*--disallowedTools}"
  [[ "$deny" == *"terraform"* ]]
  [[ "$deny" == *"gh pr merge"* ]]
  [[ "$deny" == *"rm "* ]]
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

@test "a waiting prompt is recognised, spaced or mashed together" {
  # Observed live: a workspace hook asked to confirm a shell command and the
  # session sat blocked for ten minutes — process alive, channel connected, health
  # check green, and the person waiting got silence. Stripping control codes joins
  # words together, so detection must not assume the spaces survive.
  . bin/lib.sh
  run ws_prompt_pending "Do you want to proceed?"
  [ "$status" -eq 0 ]
  run ws_prompt_pending "Doyouwanttoproceed?"
  [ "$status" -eq 0 ]
  run ws_prompt_pending " 1. Yes"
  [ "$status" -eq 0 ]
  run ws_prompt_pending "1.Yes"
  [ "$status" -eq 0 ]
}

@test "ordinary session output is not mistaken for a prompt" {
  # Cancelling on a false positive would throw away work the agent was doing.
  . bin/lib.sh
  run ws_prompt_pending "I've created the file and sent you a preview."
  [ "$status" -ne 0 ]
  run ws_prompt_pending "Do you want me to publish it? (asked in chat)"
  [ "$status" -ne 0 ]
}

@test "the channel watchdog ends the session when its server disappears" {
  # The agent does not exit when its channel dies, so nothing would notice.
  export GDD_CHANNEL_GRACE=0 GDD_CHANNEL_POLL=0
  # Agent present, channel server absent.
  make_stub pgrep 'case "$*" in *claude-plugins-official/discord*) exit 1 ;; *) echo 1234 ;; esac'
  make_stub pkill 'echo "pkill $*" >> "$STUB_LOG"'
  # Keep the session "running" long enough for the watchdog to act.
  make_stub script 'sleep 1'
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
  make_stub script 'case "$*" in *--continue*) exit 1 ;; esac'
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
