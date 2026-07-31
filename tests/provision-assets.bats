@test "patch-onboarding sets completion flags on an empty config" {
  cfg="$BATS_TEST_TMPDIR/claude.json"
  bash provision/patch-onboarding.sh "$cfg"
  run jq -r '.hasCompletedOnboarding' "$cfg"
  [ "$output" = "true" ]
}

@test "patch-onboarding marks a project trusted when given a path" {
  # On a Windows/Git-Bash host, native jq mangles a leading-slash --arg value via
  # MSYS argv conversion (/work/ws -> C:/Program Files/Git/work/ws), and you can't
  # exclude it without also breaking the file-path arg jq legitimately needs
  # converted. The script is correct for its real Linux-container target; detect
  # the mangling and skip here (covered in-container / CI, where jq is native Linux).
  [ "$(jq -n --arg p /x '$p')" = '"/x"' ] || skip "MSYS argv mangling on this host; runs in-container/CI"
  cfg="$BATS_TEST_TMPDIR/claude.json"
  bash provision/patch-onboarding.sh "$cfg" "/work/ws"
  run jq -r '.projects["/work/ws"].hasTrustDialogAccepted' "$cfg"
  [ "$output" = "true" ]
}

@test "access template renders to valid JSON with the snowflake" {
  run bash -c "sed -e 's/__ALLOWFROM__/[\"123\"]/' -e 's|__GROUPS__|{}|' provision/access.json.template | jq -e '.allowFrom == [\"123\"]'"
  [ "$status" -eq 0 ]
}

@test "access template leaves no unsubstituted placeholders" {
  # A stray placeholder yields invalid JSON, and the plugin then moves the file
  # aside as corrupt and silently falls back to pairing — inbound stops working.
  run bash -c "sed -e 's/__ALLOWFROM__/[\"123\"]/' -e 's|__GROUPS__|{}|' provision/access.json.template"
  [[ "$output" != *"__"* ]]
}

# Pre-allow assertions now live in tests/supervise.bats: the chat tools are
# granted via `--allowedTools` on the launch command. A `--settings` file with
# permissions.allow was verified NOT to apply them (live, 2026-07-26).
