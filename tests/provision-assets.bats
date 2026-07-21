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
  run bash -c "sed 's/__ALLOWFROM__/[\"123\"]/' provision/access.json.template | jq -e '.allowFrom == [\"123\"]'"
  [ "$status" -eq 0 ]
}

@test "sandbox settings pre-allow reply and react and nothing broad" {
  run jq -e '.permissions.allow as $a
             | ($a | any(test("reply"))) and ($a | all(test("Bash") | not))' \
        provision/settings.sandbox.json
  [ "$status" -eq 0 ]
}
