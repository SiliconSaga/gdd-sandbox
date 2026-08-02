# Put fake executables on PATH so bats can assert how scripts call ws/docker/git/claude.
# Each stub appends its argv to "$STUB_LOG" and runs the provided body (default: exit 0).
make_stub() {
  local name="$1"; shift
  local body="${*:-true}"
  mkdir -p "$STUB_BIN"
  cat > "$STUB_BIN/$name" <<EOF
#!/usr/bin/env bash
echo "$name \$*" >> "$STUB_LOG"
$body
EOF
  chmod +x "$STUB_BIN/$name"
}

stub_setup() {
  # Exported so a stub body referring to $STUB_LOG works in the child shell.
  # Unexported, every such stub emitted a redirection error on each call — noise
  # that buried the real message when a test failed for an unrelated reason.
  export STUB_BIN="$BATS_TEST_TMPDIR/bin"
  export STUB_LOG="$BATS_TEST_TMPDIR/calls.log"
  : > "$STUB_LOG"
  mkdir -p "$STUB_BIN"
  PATH="$STUB_BIN:$PATH"
}
