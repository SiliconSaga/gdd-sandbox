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
  bash bin/run.sh --target ken-site --secrets "$BATS_TEST_TMPDIR/secrets.env"
  : > "$BATS_TEST_TMPDIR/secrets.env"
  run cat "$STUB_LOG"
  [[ "$output" == *"docker run"* || "$output" == *"ws docker run"* ]]
  [[ "$output" == *"--restart unless-stopped"* ]]
  [[ "$output" == *"-v gdd-sandbox-ken-site-ws:"* ]]
  [[ "$output" == *"--env-file"* ]]
}

@test "run.sh converts the host secrets path and passes no ../.. segments" {
  make_stub cygpath 'echo D:/converted/.env'
  bash bin/run.sh --target ken-site --secrets "$BATS_TEST_TMPDIR/secrets.env"
  run cat "$STUB_LOG"
  [[ "$output" == *"--env-file D:/converted/.env"* ]]
  [[ "$output" != *"../.."* ]]
}

@test "run.sh refuses secrets containing ANTHROPIC_API_KEY" {
  echo 'ANTHROPIC_API_KEY=sk-xxx' > "$BATS_TEST_TMPDIR/secrets.env"
  run bash bin/run.sh --target ken-site --secrets "$BATS_TEST_TMPDIR/secrets.env"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ANTHROPIC_API_KEY"* ]]
}
