load helpers/stub

# The canary watches for CHANGE in the upstream code we depend on — version and
# the exact gate expression. It deliberately does not probe recipientId: a
# fresh-client probe reports "fixed" while the live path still fails.

setup() {
  stub_setup
  export DISCORD_PLUGIN_ROOT="$BATS_TEST_TMPDIR/discord"
  export GDD_DISCORD_PLUGIN_VERSION="0.0.4"
  mkdir -p "$DISCORD_PLUGIN_ROOT/0.0.4"
  printf 'const userId = ch.recipientId ?? dmChannelUsers.get(id)\n' \
    > "$DISCORD_PLUGIN_ROOT/0.0.4/server.ts"
}

@test "quirk check is quiet while the plugin is unchanged" {
  run bash bin/check-plugin-quirks.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"unchanged"* ]]
}

@test "quirk check flags a plugin version bump" {
  mv "$DISCORD_PLUGIN_ROOT/0.0.4" "$DISCORD_PLUGIN_ROOT/0.0.5"
  run bash bin/check-plugin-quirks.sh
  [ "$status" -eq 1 ]
  [[ "$output" == *"version changed"* ]]
  [[ "$output" == *"re-verify"* ]]
}

@test "quirk check flags the gate expression being rewritten upstream" {
  printf 'const userId = dmChannelUsers.get(id) ?? ch.recipientId\n' \
    > "$DISCORD_PLUGIN_ROOT/0.0.4/server.ts"
  run bash bin/check-plugin-quirks.sh
  [ "$status" -eq 1 ]
  [[ "$output" == *"outbound-gate expression changed"* ]]
}

@test "quirk check skips quietly when the plugin is absent" {
  export DISCORD_PLUGIN_ROOT="$BATS_TEST_TMPDIR/nope"
  run bash bin/check-plugin-quirks.sh
  [ "$status" -eq 0 ]
}
