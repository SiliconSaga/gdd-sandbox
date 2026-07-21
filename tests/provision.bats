load helpers/stub

setup() {
  stub_setup
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"   # never touch the real ~/.claude
  export GDD_WORKSPACE="$BATS_TEST_TMPDIR/ws"
  export GDD_TARGET="ken-site" GDD_TARGET_REPO="https://example/ken-site.git"
  export GDD_ALLOWFROM='["123"]'
  export GDD_SEED="$BATS_TEST_TMPDIR/seed"; mkdir -p "$GDD_SEED/.git"
  make_stub git 'exit 0'
  make_stub ws 'exit 0'
  make_stub claude 'exit 0'
  # jq is real (present on host + image); patch-onboarding.sh uses it against $HOME.
}

@test "provision seeds the workspace from the seed when absent" {
  bash provision/provision.sh
  [ -d "$GDD_WORKSPACE" ]
  grep -q "git clone .*$GDD_TARGET_REPO" "$STUB_LOG"
}

@test "provision skips the seed when the workspace already exists" {
  mkdir -p "$GDD_WORKSPACE/.git"
  bash provision/provision.sh
  run grep -c "cp -a $GDD_SEED" "$STUB_LOG"
  [ "$output" = "0" ]     # no re-seed
  grep -q "ws pull" "$STUB_LOG"   # but it still freshens
}
