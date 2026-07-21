load helpers/stub

setup() { stub_setup; make_stub ws 'exit 0'; }

@test "build.sh calls ws docker build with the default tag" {
  bash bin/build.sh
  run cat "$STUB_LOG"
  [[ "$output" == *"ws docker build -t gdd-sandbox:latest"* ]]
}

@test "build.sh honours an explicit tag" {
  bash bin/build.sh --tag gdd-sandbox:proto
  run cat "$STUB_LOG"
  [[ "$output" == *"-t gdd-sandbox:proto"* ]]
}
