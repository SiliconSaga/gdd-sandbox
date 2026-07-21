load helpers/stub
setup() {
  stub_setup
  export ROTATE_FLAG="$BATS_TEST_TMPDIR/rotate"
  make_stub pkill 'echo "pkill $*" >> "$STUB_LOG"'
}
@test "rotate.sh sets the flag and signals the session" {
  bash bin/rotate.sh
  [ -e "$ROTATE_FLAG" ]
  grep -q "pkill" "$STUB_LOG"
}
