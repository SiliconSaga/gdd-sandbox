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

@test "run.sh refuses secrets containing ANTHROPIC_API_KEY" {
  echo 'ANTHROPIC_API_KEY=sk-xxx' > "$BATS_TEST_TMPDIR/secrets.env"
  run bash bin/run.sh --target ken-site --secrets "$BATS_TEST_TMPDIR/secrets.env"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ANTHROPIC_API_KEY"* ]]
}
