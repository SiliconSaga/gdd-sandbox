load helpers/stub

# The entrypoint is what makes the restart policy meaningful: it provisions, then
# hands the container's main process to the supervisor.

setup() {
  stub_setup
  APP="$BATS_TEST_TMPDIR/app"
  mkdir -p "$APP/provision" "$APP/bin"
  cp entrypoint.sh "$APP/entrypoint.sh"
}

@test "entrypoint provisions before supervising" {
  printf '#!/usr/bin/env bash\necho PROVISIONED\n' > "$APP/provision/provision.sh"
  printf '#!/usr/bin/env bash\n[ -n "$1" ] || echo SUPERVISING\n' > "$APP/bin/supervise.sh"
  run bash "$APP/entrypoint.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PROVISIONED"* ]]
  [[ "$output" == *"SUPERVISING"* ]]
  # Ordering matters: a supervisor started before provisioning would launch a
  # session against an unseeded workspace.
  [[ "${lines[0]}" == "PROVISIONED" ]]
}

@test "entrypoint fails loudly when provisioning fails" {
  # Better a visible crash-loop than a container that looks up with no agent.
  printf '#!/usr/bin/env bash\nexit 3\n' > "$APP/provision/provision.sh"
  printf '#!/usr/bin/env bash\necho SUPERVISING\n' > "$APP/bin/supervise.sh"
  run bash "$APP/entrypoint.sh"
  [ "$status" -ne 0 ]
  [[ "$output" != *"SUPERVISING"* ]]
}
