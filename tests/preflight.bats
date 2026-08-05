load helpers/stub

# Preflight exists because every stall in the first real run was a missing config
# value found mid-task, one at a time, with a person waiting.

setup() {
  stub_setup
  export HOME="$BATS_TEST_TMPDIR/home"
  export GDD_WORKSPACE="$BATS_TEST_TMPDIR/ws"
  export GDD_TARGET="ken-site"
  export GDD_BRIEFING_PATH="$BATS_TEST_TMPDIR/briefing.md"
  export GDD_PREFLIGHT_REPORT="$BATS_TEST_TMPDIR/preflight.md"
  unset GDD_OPERATOR_CHAT

  # A fully configured sandbox; individual tests break one thing.
  mkdir -p "$GDD_WORKSPACE/components/ken-site/.git" \
           "$HOME/.claude/channels/discord"
  printf 'components:\n  ken-site:\n    repo: x\nidentity:\n  human_account: cervator\n' \
    > "$GDD_WORKSPACE/ecosystem.local.yaml"
  printf '{"allowFrom": ["123"]}\n' > "$HOME/.claude/channels/discord/access.json"
  printf 'briefing\n' > "$GDD_BRIEFING_PATH"
  printf 'GH_TOKEN=abc\n' > "$GDD_WORKSPACE/.env"
  export GDD_OPERATOR_CHAT="999"
  make_stub gh 'echo Kencierge'
  make_stub git 'case "$*" in *user.email*) echo a@users.noreply.github.com ;; *user.name*) echo Kencierge ;; esac'
}

@test "a fully configured sandbox reports ready" {
  run bash bin/preflight.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"ready"* ]]
}

@test "an undeclared target is blocking, not a warning" {
  # The clone looks fine; `ws push` and `ws cr` fail with "no such target".
  printf 'components:\n  other:\n    repo: x\n' > "$GDD_WORKSPACE/ecosystem.local.yaml"
  run bash bin/preflight.sh
  [ "$status" -eq 2 ]
  [[ "$output" == *"not declared"* ]]
}

@test "a working token is not reported as broken" {
  # The token lives in the workspace .env, which `ws` loads and a bare `gh` does
  # not. Checking without passing it explicitly reports a good token as broken —
  # observed live, and a check that cries wolf is worse than no check.
  make_stub gh 'case "${GH_TOKEN:-}" in "") exit 1 ;; *) echo Kencierge ;; esac'
  run bash bin/preflight.sh
  [ "$status" -eq 0 ]
  [[ "$output" != *"does not authenticate"* ]]
}

@test "a rejected token is reported even though it prints an error body" {
  # The real tool writes its refusal to stdout and exits non-zero. A stub that
  # merely exits silently is more polite than reality, and let a broken check
  # pass — judging by output rather than exit status read the refusal as success.
  make_stub gh 'echo "{\"message\": \"Bad credentials\", \"status\": \"401\"}"; exit 1'
  run bash bin/preflight.sh
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not authenticate"* ]]
}

@test "a missing token degrades rather than blocks" {
  # Drafting is still useful; refusing to start would turn partial capability
  # into silence.
  rm -f "$GDD_WORKSPACE/.env"
  run bash bin/preflight.sh
  [ "$status" -eq 1 ]
  [[ "$output" == *"draft but cannot open a pull request"* ]]
}

@test "a real commit email is flagged before it costs a rejected push" {
  make_stub git 'case "$*" in *user.email*) echo someone@gmail.com ;; *user.name*) echo Kencierge ;; esac'
  run bash bin/preflight.sh
  [[ "$output" == *"not a no-reply address"* ]]
}

@test "a public commit email can be declared deliberate" {
  # Using a public address is a legitimate choice; an advisory that fires when
  # everything is intentional teaches people to skim past the whole report.
  make_stub git 'case "$*" in *user.email*) echo someone@gmail.com ;; *user.name*) echo Kencierge ;; esac'
  export GDD_PUBLIC_EMAIL_OK=1
  run bash bin/preflight.sh
  [ "$status" -eq 0 ]
  [[ "$output" != *"no-reply address"* ]]
}

@test "an unset human account is flagged as a coming interruption" {
  printf 'components:\n  ken-site:\n    repo: x\n' > "$GDD_WORKSPACE/ecosystem.local.yaml"
  run bash bin/preflight.sh
  [[ "$output" == *"stop to ask"* ]]
}

@test "nobody able to reach the sandbox is blocking" {
  printf '{"allowFrom": []}\n' > "$HOME/.claude/channels/discord/access.json"
  run bash bin/preflight.sh
  [ "$status" -eq 2 ]
  [[ "$output" == *"Nobody is allowed to talk"* ]]
}

@test "every problem is reported in one pass, not just the first" {
  # Finding them one at a time is what cost four round-trips.
  rm -f "$GDD_WORKSPACE/.env"
  printf 'components:\n  other:\n    repo: x\n' > "$GDD_WORKSPACE/ecosystem.local.yaml"
  run bash bin/preflight.sh
  [[ "$output" == *"not declared"* ]]
  [[ "$output" == *"cannot open a pull request"* ]]
  [[ "$output" == *"stop to ask"* ]]
}

@test "the report tells the agent to speak up rather than start" {
  rm -f "$GDD_WORKSPACE/.env"
  bash bin/preflight.sh || true
  run cat "$GDD_PREFLIGHT_REPORT"
  [[ "$output" == *"Say so when a request arrives"* ]]
  [[ "$output" == *"cannot open a pull request"* ]]
}

@test "a clean run still leaves a report saying so" {
  bash bin/preflight.sh
  run cat "$GDD_PREFLIGHT_REPORT"
  [[ "$output" == *"Everything checked out"* ]]
}
