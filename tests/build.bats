load helpers/stub

setup() { stub_setup; make_stub ws 'exit 0'; }

@test "build.sh calls ws docker build with the default tag" {
  bash bin/build.sh
  run cat "$STUB_LOG"
  [[ "$output" == *"ws docker build -t gdd-sandbox:latest"* ]]
}

@test "build.sh converts the host context path for the native docker client" {
  # `ws docker` suppresses MSYS conversion, so a /d/... host path would reach
  # docker.exe verbatim and fail. Stub cygpath to prove the conversion is applied.
  make_stub cygpath 'echo D:/converted/context'
  bash bin/build.sh
  run cat "$STUB_LOG"
  [[ "$output" == *"D:/converted/context"* ]]
}

@test "build.sh honours an explicit tag" {
  bash bin/build.sh --tag gdd-sandbox:proto
  run cat "$STUB_LOG"
  [[ "$output" == *"-t gdd-sandbox:proto"* ]]
}
