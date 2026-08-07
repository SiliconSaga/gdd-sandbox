load helpers/stub

setup() {
  stub_setup
  export GDD_HARVEST_DIR="$BATS_TEST_TMPDIR/out"
  # `ws` fronts docker and the hoard lookup, so one stub answers for both. The
  # default here is the good case: clean target, a hoard to harvest into.
  make_stub ws 'case "$*" in
  *"status --porcelain"*) : ;;
  "hoard thalamus-path") echo "'"$BATS_TEST_TMPDIR"'/hoard/host-thalamus.md" ;;
  *) : ;;
esac'
  mkdir -p "$BATS_TEST_TMPDIR/hoard"
}

@test "harvest refuses while the target still has uncommitted work" {
  # Loose files copied to the host are unfinished work laundered into a directory
  # nobody reviews. It has a proper home — a branch and a pull request the sandbox
  # agent opens while it is still alive — so stop and say so.
  make_stub ws 'case "$*" in
  *"status --porcelain"*) echo " M index.html" ;;
  "hoard thalamus-path") echo "/tmp/hoard/host-thalamus.md" ;;
  *) : ;;
esac'
  run bash bin/harvest.sh --target ken-site
  [ "$status" -ne 0 ]
  [[ "$output" == *"uncommitted"* ]]
  [[ "$output" == *"--force"* ]]
}

@test "harvest proceeds on uncommitted work when told to" {
  make_stub ws 'case "$*" in
  *"status --porcelain"*) echo " M index.html" ;;
  "hoard thalamus-path") echo "'"$BATS_TEST_TMPDIR"'/hoard/host-thalamus.md" ;;
  *) : ;;
esac'
  run bash bin/harvest.sh --target ken-site --force
  [ "$status" -eq 0 ]
}

@test "harvest copies the Thalamus beside the host's own hoard" {
  bash bin/harvest.sh --target ken-site
  run cat "$STUB_LOG"
  [[ "$output" == *"docker cp gdd-sandbox-ken-site:/work/ws/Thalamus.md"* ]]
  # Kept distinct from the per-host files: when a tenant graduates to their own
  # plan and their own logins, what moves with them has to be separable.
  [[ "$output" == *"/hoard/sandboxes/ken-site-"* ]]
}

@test "harvest falls back to scratch when no hoard is active" {
  make_stub ws 'case "$*" in
  *"status --porcelain"*) : ;;
  "hoard thalamus-path") : ;;
  *) : ;;
esac'
  bash bin/harvest.sh --target ken-site
  run cat "$STUB_LOG"
  [[ "$output" == *".tmp/sandbox-harvest/ken-site-"* ]]
}

@test "harvest says what to record, since tooling does not write the Thalamus" {
  # Moving bytes is the script's job; recording what they mean is the agent's,
  # under the workspace's own rules about who writes that file.
  run bash bin/harvest.sh --target ken-site
  [[ "$output" == *"housekeeping"* ]]
  [[ "$output" == *"delete"* ]]
}

@test "recycle harvests before it destroys anything" {
  bash bin/recycle.sh --target ken-site
  run cat "$STUB_LOG"
  harvested="${output%%docker stop*}"
  [[ "$harvested" == *"docker cp gdd-sandbox-ken-site:/work/ws/Thalamus.md"* ]]
  [[ "$output" == *"docker stop gdd-sandbox-ken-site"* ]]
  [[ "$output" == *"docker rm gdd-sandbox-ken-site"* ]]
  [[ "$output" == *"volume rm gdd-sandbox-ken-site-ws gdd-sandbox-ken-site-ws-claude"* ]]
}

@test "recycle destroys nothing when the harvest refuses" {
  # The whole point of pairing them: the command that throws the sandbox away is
  # the one that rescues it first, so a hurry cannot skip the rescue.
  make_stub ws 'case "$*" in
  *"status --porcelain"*) echo " M index.html" ;;
  "hoard thalamus-path") echo "/tmp/hoard/host-thalamus.md" ;;
  *) : ;;
esac'
  run bash bin/recycle.sh --target ken-site
  [ "$status" -ne 0 ]
  run cat "$STUB_LOG"
  [[ "$output" != *"docker stop"* ]]
  [[ "$output" != *"volume rm"* ]]
}
