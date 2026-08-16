load helpers/stub

setup() {
  stub_setup
  export GDD_HARVEST_DIR="$BATS_TEST_TMPDIR/out"
  # `ws` fronts docker and the hoard lookup, so one stub answers for both. The
  # default here is the good case: clean target, a hoard to harvest into.
  make_stub ws 'case "$*" in
  *"docker exec"*"[ -f /work/ws/Thalamus.md ]"*) echo PRESENT ;;
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
  *"docker exec"*"[ -f /work/ws/Thalamus.md ]"*) echo PRESENT ;;
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
  *"docker exec"*"[ -f /work/ws/Thalamus.md ]"*) echo PRESENT ;;
  *"status --porcelain"*) echo " M index.html" ;;
  "hoard thalamus-path") echo "'"$BATS_TEST_TMPDIR"'/hoard/host-thalamus.md" ;;
  *) : ;;
esac'
  run bash bin/harvest.sh --target ken-site --force
  [ "$status" -eq 0 ]
}

@test "a sandbox with no Thalamus is still recyclable" {
  # Found on first real use: the container in front of us predated the seeding,
  # so it had no notes — and refusing left the tool unable to recycle exactly the
  # containers most likely to be thrown away. Nothing to rescue is not a failure.
  make_stub ws 'case "$*" in
  *"docker exec"*"[ -f /work/ws/Thalamus.md ]"*) echo ABSENT ;;
  *"status --porcelain"*) : ;;
  "hoard thalamus-path") echo "'"$BATS_TEST_TMPDIR"'/hoard/host-thalamus.md" ;;
  *) : ;;
esac'
  run bash bin/recycle.sh --target ken-site
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to rescue"* ]]
  run cat "$STUB_LOG"
  [[ "$output" != *"docker cp"* ]]
  [[ "$output" == *"docker stop gdd-sandbox-ken-site"* ]]
}

@test "a probe that cannot run is not read as an absent Thalamus" {
  # "No file" and "the probe never ran" look identical through an exit status,
  # and one of them means the notes might still be there. Guessing wrong hands
  # recycle a green light to delete the volume — the same fail-open-toward-
  # destruction shape as the dirty-repo check, so it refuses the same way.
  make_stub ws 'case "$*" in
  *"docker exec"*"[ -f /work/ws/Thalamus.md ]"*) echo "Error: No such container" >&2; exit 1 ;;
  *"status --porcelain"*) : ;;
  "hoard thalamus-path") echo "'"$BATS_TEST_TMPDIR"'/hoard/host-thalamus.md" ;;
  *) : ;;
esac'
  run bash bin/recycle.sh --target ken-site
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not check"* ]]
  run cat "$STUB_LOG"
  [[ "$output" != *"docker stop"* ]]
  [[ "$output" != *"volume rm"* ]]
}

@test "an inspection that cannot see the workspace is not an absent Thalamus" {
  # The ws call succeeds; the look inside fails. Answering ABSENT there would
  # report "no notes" for an unmounted or unreadable volume, and recycle deletes
  # on that answer — so the container reports UNKNOWN and harvest refuses.
  make_stub ws 'case "$*" in
  *"docker exec"*"[ -f /work/ws/Thalamus.md ]"*) echo UNKNOWN ;;
  *"status --porcelain"*) : ;;
  "hoard thalamus-path") echo "'"$BATS_TEST_TMPDIR"'/hoard/host-thalamus.md" ;;
  *) : ;;
esac'
  run bash bin/recycle.sh --target ken-site
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not check"* ]]
  run cat "$STUB_LOG"
  [[ "$output" != *"docker stop"* ]]
  [[ "$output" != *"volume rm"* ]]
}

@test "harvest copies the Thalamus beside the host's own hoard" {
  bash bin/harvest.sh --target ken-site
  # The copy line specifically, source AND destination together. Asserted apart
  # they pass on any log containing both somewhere — and until the stub stopped
  # matching every mention of Thalamus.md, the probe was answering for `docker
  # cp` too, so these tests could not tell a rescue from a question.
  # Source and destination checked as one line, and the destination in full —
  # a prefix plus a stray ".md" elsewhere in the log would otherwise satisfy it.
  run bash -c "grep 'docker cp' '$STUB_LOG'"
  [[ "$output" == *"gdd-sandbox-ken-site:/work/ws/Thalamus.md"* ]]
  # Kept distinct from the per-host files: when a tenant graduates to their own
  # plan and their own logins, what moves with them has to be separable.
  [[ "$output" == *"/hoard/sandboxes/ken-site-$(date +%F).md"* ]]
}

@test "harvest falls back to scratch when no hoard is active" {
  make_stub ws 'case "$*" in
  *"docker exec"*"[ -f /work/ws/Thalamus.md ]"*) echo PRESENT ;;
  *"status --porcelain"*) : ;;
  "hoard thalamus-path") : ;;
  *) : ;;
esac'
  bash bin/harvest.sh --target ken-site
  run bash -c "grep 'docker cp' '$STUB_LOG'"
  [[ "$output" == *"gdd-sandbox-ken-site:/work/ws/Thalamus.md"* ]]
  [[ "$output" == *".tmp/sandbox-harvest/ken-site-$(date +%F).md"* ]]
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
  # Whole lines: a substring match on the workspace volume also matches inside
  # the -claude name, so it would pass with that call missing entirely.
  grep -Fxq "ws docker volume rm gdd-sandbox-ken-site-ws" "$STUB_LOG"
  grep -Fxq "ws docker volume rm gdd-sandbox-ken-site-ws-claude" "$STUB_LOG"
}

@test "a status check that fails is not read as a clean repository" {
  # Failing open here fails in the direction that destroys: an unreachable
  # container returns nothing, nothing looks clean, and recycle proceeds to
  # delete the volume the notes were on.
  make_stub ws 'case "$*" in
  *"docker exec"*"[ -f /work/ws/Thalamus.md ]"*) echo PRESENT ;;
  *"status --porcelain"*) echo "Error: No such container" >&2; exit 1 ;;
  "hoard thalamus-path") echo "/tmp/hoard/host-thalamus.md" ;;
  *) : ;;
esac'
  run bash bin/recycle.sh --target ken-site
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot inspect"* ]]
  run cat "$STUB_LOG"
  [[ "$output" != *"docker stop"* ]]
  [[ "$output" != *"volume rm"* ]]
}

@test "recycle reports failure when the container will not go away" {
  # Printing "recycled" over a container that is still running is the kind of
  # false assurance that gets discovered a week later.
  make_stub ws 'case "$*" in
  *"docker exec"*"[ -f /work/ws/Thalamus.md ]"*) echo PRESENT ;;
  *"status --porcelain"*) : ;;
  "hoard thalamus-path") echo "'"$BATS_TEST_TMPDIR"'/hoard/host-thalamus.md" ;;
  *"docker rm"*) echo "Error response from daemon: cannot remove container" >&2; exit 1 ;;
  *) : ;;
esac'
  run bash bin/recycle.sh --target ken-site
  [ "$status" -ne 0 ]
  [[ "$output" == *"has NOT been removed"* ]]
  [[ "$output" != *"recycled:"* ]]
}

@test "an already-removed container does not fail the recycle" {
  # Idempotence: "no such container" means the work is done, not that it broke.
  make_stub ws 'case "$*" in
  *"docker exec"*"[ -f /work/ws/Thalamus.md ]"*) echo PRESENT ;;
  *"status --porcelain"*) : ;;
  "hoard thalamus-path") echo "'"$BATS_TEST_TMPDIR"'/hoard/host-thalamus.md" ;;
  *"docker stop"*) echo "Error: No such container: gdd-sandbox-ken-site" >&2; exit 1 ;;
  *) : ;;
esac'
  run bash bin/recycle.sh --target ken-site
  [ "$status" -eq 0 ]
  [[ "$output" == *"recycled:"* ]]
}

@test "an absent volume cannot mask a failure removing the other one" {
  # Removing both in one call merges their output: the absent one supplies a
  # "no such volume" that makes the real failure look tolerable, and the script
  # would announce success over a volume still sitting there.
  make_stub ws 'case "$*" in
  *"docker exec"*"[ -f /work/ws/Thalamus.md ]"*) echo PRESENT ;;
  *"status --porcelain"*) : ;;
  "hoard thalamus-path") echo "'"$BATS_TEST_TMPDIR"'/hoard/host-thalamus.md" ;;
  *"volume rm gdd-sandbox-ken-site-ws") echo "Error: No such volume: gdd-sandbox-ken-site-ws" >&2; exit 1 ;;
  *"volume rm gdd-sandbox-ken-site-ws-claude") echo "Error response from daemon: volume is in use" >&2; exit 1 ;;
  *) : ;;
esac'
  run bash bin/recycle.sh --target ken-site
  [ "$status" -ne 0 ]
  [[ "$output" == *"has NOT been removed"* ]]
  [[ "$output" != *"recycled:"* ]]
  # Specifically the SECOND volume's failure — a non-zero status alone would
  # also be satisfied by aborting on the first, absent one, which is the
  # tolerated case and would mean this test never reached the masking scenario.
  [[ "$output" == *"volume is in use"* ]]
  grep -Fxq "ws docker volume rm gdd-sandbox-ken-site-ws" "$STUB_LOG"
  grep -Fxq "ws docker volume rm gdd-sandbox-ken-site-ws-claude" "$STUB_LOG"
}

@test "recycle passes force through to the harvest" {
  make_stub ws 'case "$*" in
  *"docker exec"*"[ -f /work/ws/Thalamus.md ]"*) echo PRESENT ;;
  *"status --porcelain"*) echo " M index.html" ;;
  "hoard thalamus-path") echo "'"$BATS_TEST_TMPDIR"'/hoard/host-thalamus.md" ;;
  *) : ;;
esac'
  run bash bin/recycle.sh --target ken-site --force
  [ "$status" -eq 0 ]
  run cat "$STUB_LOG"
  harvested="${output%%docker stop*}"
  [[ "$harvested" == *"docker cp gdd-sandbox-ken-site:/work/ws/Thalamus.md"* ]]
  [[ "$output" == *"volume rm"* ]]
}

@test "an option given no value fails with an argument error" {
  run bash bin/harvest.sh --target
  [ "$status" -eq 2 ]
  [[ "$output" == *"needs a value"* ]]
  [[ "$output" != *"unbound variable"* ]]
}

@test "recycle destroys nothing when the harvest refuses" {
  # The whole point of pairing them: the command that throws the sandbox away is
  # the one that rescues it first, so a hurry cannot skip the rescue.
  make_stub ws 'case "$*" in
  *"docker exec"*"[ -f /work/ws/Thalamus.md ]"*) echo PRESENT ;;
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
