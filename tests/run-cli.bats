load helpers/stub
setup() {
  stub_setup
  make_stub ws 'exit 0'
  make_stub docker 'exit 0'
  make_stub yq 'echo https://example/ken-site.git'
}

@test "run.sh requires --target" {
  run bash bin/run.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"--target"* ]]
}

@test "run.sh starts a container with restart policy, named volume, env-file" {
  printf 'CLAUDE_CODE_OAUTH_TOKEN=abc\n' > "$BATS_TEST_TMPDIR/secrets.env"
  bash bin/run.sh --target ken-site --secrets "$BATS_TEST_TMPDIR/secrets.env"
  run cat "$STUB_LOG"
  [[ "$output" == *"docker run"* || "$output" == *"ws docker run"* ]]
  [[ "$output" == *"--restart unless-stopped"* ]]
  [[ "$output" == *"-v gdd-sandbox-ken-site-ws:"* ]]
  [[ "$output" == *"--env-file"* ]]
}

@test "run.sh converts the host secrets path and passes no ../.. segments" {
  make_stub cygpath 'echo D:/converted/.env'
  printf 'CLAUDE_CODE_OAUTH_TOKEN=abc\n' > "$BATS_TEST_TMPDIR/secrets.env"
  bash bin/run.sh --target ken-site --secrets "$BATS_TEST_TMPDIR/secrets.env"
  run cat "$STUB_LOG"
  [[ "$output" == *"--env-file D:/converted/.env"* ]]
  [[ "$output" != *"../.."* ]]
}

@test "runtime env keeps only allowlisted secrets and strips the export prefix" {
  # docker's --env-file parser rejects `export KEY=v` ("variable contains
  # whitespaces"), and the operator's other credentials must not reach the container.
  src="$BATS_TEST_TMPDIR/src.env"
  dest="$BATS_TEST_TMPDIR/runtime.env"
  printf 'export CLAUDE_CODE_OAUTH_TOKEN=abc\nexport GH_TOKEN=leak\nHARBOR_ADMIN_PW=nope\nDISCORD_BOT_TOKEN=def\n' > "$src"
  . bin/lib.sh
  ws_write_runtime_env "$src" "$dest"
  run cat "$dest"
  [[ "$output" == *"CLAUDE_CODE_OAUTH_TOKEN=abc"* ]]
  [[ "$output" == *"DISCORD_BOT_TOKEN=def"* ]]
  [[ "$output" != *"export"* ]]
  [[ "$output" != *"GH_TOKEN"* ]]
  [[ "$output" != *"HARBOR_ADMIN_PW"* ]]
}

@test "run.sh fails loudly when the secrets file has no runtime secrets" {
  printf 'GH_TOKEN=only-this\n' > "$BATS_TEST_TMPDIR/secrets.env"
  run bash bin/run.sh --target ken-site --secrets "$BATS_TEST_TMPDIR/secrets.env"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no runtime secrets"* ]]
}

@test "run.sh opts a shared channel in, requiring a mention by default" {
  printf 'CLAUDE_CODE_OAUTH_TOKEN=abc\n' > "$BATS_TEST_TMPDIR/secrets.env"
  bash bin/run.sh --target ken-site --secrets "$BATS_TEST_TMPDIR/secrets.env" --channel 555
  run cat "$STUB_LOG"
  [[ "$output" == *'"555"'* ]]
  [[ "$output" == *'requireMention":true'* ]]
}

@test "run.sh honours --no-mention for a single-user channel" {
  printf 'CLAUDE_CODE_OAUTH_TOKEN=abc\n' > "$BATS_TEST_TMPDIR/secrets.env"
  bash bin/run.sh --target ken-site --secrets "$BATS_TEST_TMPDIR/secrets.env" --channel 555 --no-mention
  run cat "$STUB_LOG"
  [[ "$output" == *'requireMention":false'* ]]
}

@test "run.sh reads the commit identity from the same file as the token" {
  # One place to configure: the operator should not also have to export shell
  # variables for the identity that sits beside the token.
  printf 'CLAUDE_CODE_OAUTH_TOKEN=abc\nexport GDD_GITHUB_USER=Kencierge\nGDD_GITHUB_EMAIL="311+Kencierge@users.noreply.github.com"\n' \
    > "$BATS_TEST_TMPDIR/secrets.env"
  bash bin/run.sh --target ken-site --secrets "$BATS_TEST_TMPDIR/secrets.env"
  run cat "$STUB_LOG"
  [[ "$output" == *"GDD_GITHUB_USER=Kencierge"* ]]
  # Quotes stripped, export prefix tolerated.
  [[ "$output" == *"GDD_GITHUB_EMAIL=311+Kencierge@users.noreply.github.com"* ]]
}

@test "run.sh passes the model choice through from the same file" {
  # Same reason as the identity: one place to configure. Without the pass-through
  # the variable would have to be exported into the operator's shell instead.
  printf 'CLAUDE_CODE_OAUTH_TOKEN=abc\nGDD_MODEL=sonnet\n' > "$BATS_TEST_TMPDIR/secrets.env"
  bash bin/run.sh --target ken-site --secrets "$BATS_TEST_TMPDIR/secrets.env"
  run cat "$STUB_LOG"
  [[ "$output" == *"GDD_MODEL=sonnet"* ]]
}

@test "run.sh preserves an explicitly empty model setting" {
  # `GDD_MODEL=` is the deliberate "give me whatever my account defaults to". It
  # has to survive as an empty value: dropped here it would read as unset, and
  # supervise.sh would apply its own default instead — silently undoing the choice.
  printf 'CLAUDE_CODE_OAUTH_TOKEN=abc\nGDD_MODEL=\n' > "$BATS_TEST_TMPDIR/secrets.env"
  bash bin/run.sh --target ken-site --secrets "$BATS_TEST_TMPDIR/secrets.env"
  run cat "$STUB_LOG"
  [[ "$output" == *"GDD_MODEL="* ]]
}

@test "run.sh leaves the model unset when the operator has not chosen one" {
  # Unset must reach supervise.sh as unset, so ITS default applies. Passing an
  # empty value would instead read as "inherit the account default" and silently
  # undo the pin.
  printf 'CLAUDE_CODE_OAUTH_TOKEN=abc\n' > "$BATS_TEST_TMPDIR/secrets.env"
  bash bin/run.sh --target ken-site --secrets "$BATS_TEST_TMPDIR/secrets.env"
  run cat "$STUB_LOG"
  [[ "$output" != *"GDD_MODEL"* ]]
}

@test "run.sh falls back to a sane identity when none is configured" {
  printf 'CLAUDE_CODE_OAUTH_TOKEN=abc\n' > "$BATS_TEST_TMPDIR/secrets.env"
  bash bin/run.sh --target ken-site --secrets "$BATS_TEST_TMPDIR/secrets.env"
  run cat "$STUB_LOG"
  [[ "$output" == *"GDD_GITHUB_USER=Kencierge"* ]]
}

@test "run.sh does not start the supervisor via docker exec" {
  # Regression guard: a supervisor started with `docker exec -d` dies with the
  # container, so the restart policy brings back a container with no agent
  # listening — silent ghosting. Supervision must be the image's entrypoint.
  printf 'CLAUDE_CODE_OAUTH_TOKEN=abc\n' > "$BATS_TEST_TMPDIR/secrets.env"
  bash bin/run.sh --target ken-site --secrets "$BATS_TEST_TMPDIR/secrets.env"
  run cat "$STUB_LOG"
  [[ "$output" != *"exec -d"* ]]
  [[ "$output" != *"supervise.sh"* ]]
  [[ "$output" != *"docker cp"* ]]
}

@test "run.sh refuses secrets containing ANTHROPIC_API_KEY" {
  echo 'ANTHROPIC_API_KEY=sk-xxx' > "$BATS_TEST_TMPDIR/secrets.env"
  run bash bin/run.sh --target ken-site --secrets "$BATS_TEST_TMPDIR/secrets.env"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ANTHROPIC_API_KEY"* ]]
}
