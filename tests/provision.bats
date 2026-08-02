load helpers/stub

setup() {
  stub_setup
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"   # never touch the real ~/.claude
  export GDD_WORKSPACE="$BATS_TEST_TMPDIR/ws"
  export GDD_TARGET="ken-site" GDD_TARGET_REPO="https://example/ken-site.git"
  export GDD_ALLOWFROM='["123"]'
  export GDD_SEED="$BATS_TEST_TMPDIR/seed"; mkdir -p "$GDD_SEED/.git"
  # Start from a known state: tests that want a token or a channel export their
  # own. Without this, a value set by an earlier test decides a later one's
  # outcome, which is how a passing suite hides a broken assertion.
  unset GDD_GITHUB_TOKEN GDD_GITHUB_USER GDD_GITHUB_EMAIL GDD_CHANNEL_GROUPS
  make_stub git 'exit 0'
  make_stub ws 'exit 0'
  make_stub claude 'exit 0'
  # jq is real (present on host + image); patch-onboarding.sh uses it against $HOME.
}

@test "provision allowlists the bot's own id alongside the human's" {
  # Upstream gate quirk: ch.recipientId resolves to the BOT, short-circuiting the
  # fallback to dmChannelUsers, so the bot's own id must be in allowFrom.
  export DISCORD_BOT_TOKEN="fake-token"
  make_stub curl 'echo "{\"id\":\"999000111\"}"'
  bash provision/provision.sh
  run cat "$HOME/.claude/channels/discord/access.json"
  [[ "$output" == *"999000111"* ]]
  [[ "$output" == *"123"* ]]
}

@test "provision warns but continues when the bot id cannot be resolved" {
  export DISCORD_BOT_TOKEN="fake-token"
  make_stub curl 'echo ""'
  run bash provision/provision.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not resolve the bot id"* ]]
}

@test "provision installs the workspace GitHub token without logging it" {
  export GDD_GITHUB_TOKEN="ghp_secret_value"
  run bash provision/provision.sh
  [[ "$output" != *"ghp_secret_value"* ]]
  run grep -c '^GH_TOKEN=ghp_secret_value$' "$GDD_WORKSPACE/.env"
  [ "$output" = "1" ]
}

@test "provision does not stack duplicate tokens across restarts" {
  # Provisioning runs on every container start; appending blindly would leave a
  # stale token above the current one.
  export GDD_GITHUB_TOKEN="tok_one"
  bash provision/provision.sh
  export GDD_GITHUB_TOKEN="tok_two"
  bash provision/provision.sh
  run grep -c '^GH_TOKEN=' "$GDD_WORKSPACE/.env"
  [ "$output" = "1" ]
  run grep -c '^GH_TOKEN=tok_two$' "$GDD_WORKSPACE/.env"
  [ "$output" = "1" ]
}

@test "provision says plainly when no GitHub token is supplied" {
  run bash provision/provision.sh
  [[ "$output" == *"draft but not publish"* ]]
}

@test "the operator's own GH_TOKEN never reaches the container" {
  # Same file, different variable: only the sandbox user's token travels.
  src="$BATS_TEST_TMPDIR/op.env"
  dest="$BATS_TEST_TMPDIR/runtime.env"
  printf 'GH_TOKEN=operator_personal\nGDD_GITHUB_TOKEN=sandbox_machine\n' > "$src"
  . bin/lib.sh
  ws_write_runtime_env "$src" "$dest"
  run cat "$dest"
  [[ "$output" == *"GDD_GITHUB_TOKEN=sandbox_machine"* ]]
  [[ "$output" != *"operator_personal"* ]]
}

@test "provision declares the target so ws can resolve it" {
  # Cloning into components/ is not enough — `ws push` and `ws cr` resolve a
  # component from the config, and without this they fail with "no such target"
  # while the clone looks perfectly fine.
  bash provision/provision.sh
  run cat "$GDD_WORKSPACE/ecosystem.local.yaml"
  [[ "$output" == *"ken-site:"* ]]
  [[ "$output" == *"https://example/ken-site.git"* ]]
}

@test "provision does not invent a reviewer identity" {
  # `ws diagnose` warns that identity.human_account is unset; that warning does
  # not apply here, because the sandbox template has no @HUMAN_ACCOUNT to fill.
  # Provenance is the chat identity, and anyone with review rights can review.
  bash provision/provision.sh
  run cat "$GDD_WORKSPACE/ecosystem.local.yaml"
  [[ "$output" != *"human_account"* ]]
}

@test "provision installs the chat-provenance change template" {
  # The stock disclaimer credits a GitHub user driving the agent locally, which is
  # not what happened here — and would leave the machine account as the only name.
  mkdir -p "$GDD_WORKSPACE/templates"
  printf 'driven by @HUMAN_ACCOUNT\n' > "$GDD_WORKSPACE/templates/change.md"
  export GDD_GITHUB_USER="Kencierge"
  bash provision/provision.sh
  run cat "$GDD_WORKSPACE/templates/change.md"
  [[ "$output" == *"requested over chat"* ]]
  [[ "$output" == *"Kencierge"* ]]
  [[ "$output" != *"@HUMAN_ACCOUNT"* ]]
  [[ "$output" != *"__GITHUB_USER__"* ]]
}

@test "the provenance template never mentions the requester as a code-host user" {
  # `@name` would notify whoever owns that handle on the code host — possibly a
  # stranger with no connection to this project.
  run cat provision/change.sandbox.md
  [[ "$output" == *"not a GitHub user"* ]]
  [[ "$output" != *"@[chat display name]"* ]]
}

@test "provision tells the agent where to send technical detail" {
  # That direct message is the only alert this sandbox has — nobody is watching a
  # dashboard, so losing it means the first sign of trouble is a person waiting.
  export GDD_BRIEFING_PATH="$BATS_TEST_TMPDIR/briefing.md"
  export GDD_OPERATOR_CHAT="1528091545549406271"
  bash provision/provision.sh
  run cat "$GDD_BRIEFING_PATH"
  [[ "$output" == *"1528091545549406271"* ]]
  [[ "$output" != *"__OPERATOR_CHAT__"* ]]
}

@test "provision says plainly when no operator address is configured" {
  # An unfilled placeholder would read as an address and send the alert nowhere.
  export GDD_BRIEFING_PATH="$BATS_TEST_TMPDIR/briefing.md"
  bash provision/provision.sh
  run cat "$GDD_BRIEFING_PATH"
  [[ "$output" == *"none configured"* ]]
  [[ "$output" != *"__OPERATOR_CHAT__"* ]]
}

@test "provision appends the operator's own briefing notes" {
  # The shipped briefing cannot know what this site is or who reads it; the
  # operator sets that stage without needing a rebuild.
  export GDD_BRIEFING_PATH="$BATS_TEST_TMPDIR/briefing.md"
  export GDD_BRIEFING_EXTRA="The site belongs to a local election candidate. Keep the tone plain."
  bash provision/provision.sh
  run cat "$GDD_BRIEFING_PATH"
  [[ "$output" == *"local election candidate"* ]]
  # ...after the shipped content, not instead of it.
  [[ "$output" == *"components/ken-site"* ]]
}

@test "provision renders the briefing with the target substituted" {
  export GDD_BRIEFING_PATH="$BATS_TEST_TMPDIR/briefing.md"
  bash provision/provision.sh
  run cat "$GDD_BRIEFING_PATH"
  [[ "$output" == *"components/ken-site"* ]]
  [[ "$output" != *"__TARGET__"* ]]
}

@test "provision opts a shared guild channel into the access config" {
  # allowFrom covers DMs only; a guild channel stays disabled until opted in by
  # channel id, so a shared channel can receive but never reply without this.
  export GDD_CHANNEL_GROUPS='{"999":{"requireMention":true,"allowFrom":[]}}'
  bash provision/provision.sh
  run jq -e '.groups["999"].requireMention == true' "$HOME/.claude/channels/discord/access.json"
  [ "$status" -eq 0 ]
}

@test "provision writes valid access json with no channel configured" {
  bash provision/provision.sh
  run jq -e '.groups == {} and (.allowFrom | length > 0)' "$HOME/.claude/channels/discord/access.json"
  [ "$status" -eq 0 ]
}

@test "provision seeds the workspace from the seed when absent" {
  bash provision/provision.sh
  [ -d "$GDD_WORKSPACE" ]
  grep -q "git clone .*$GDD_TARGET_REPO" "$STUB_LOG"
}

@test "provision populates an existing empty workspace dir, not a nested copy" {
  # A Docker volume mounts as an existing empty dir, so the seed must copy its
  # CONTENTS in; `cp -a $SEED $WS` would nest the clone at $WS/gdd-seed.
  mkdir -p "$GDD_WORKSPACE"
  touch "$GDD_SEED/marker-file"
  bash provision/provision.sh
  [ -e "$GDD_WORKSPACE/marker-file" ]
  [ ! -e "$GDD_WORKSPACE/$(basename "$GDD_SEED")" ]
}

@test "provision skips the seed when the workspace already exists" {
  mkdir -p "$GDD_WORKSPACE/.git"
  bash provision/provision.sh
  run grep -c "cp -a $GDD_SEED" "$STUB_LOG"
  [ "$output" = "0" ]     # no re-seed
  grep -q "ws pull" "$STUB_LOG"   # but it still freshens
}
