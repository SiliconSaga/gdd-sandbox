load helpers/stub

setup() { stub_setup; make_stub ws 'exit 0'; }

@test "build.sh calls ws docker build with the default tag" {
  bash bin/build.sh
  run cat "$STUB_LOG"
  [[ "$output" == *"ws docker build"* ]]
  [[ "$output" == *"-t gdd-sandbox:latest"* ]]
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

@test "build.sh names the upstream commit so the seed layer cannot cache forever" {
  # The clone command never changes, so Docker reuses whatever it baked first.
  # Measured: a sandbox running a seed pinned at yggdrasil PR #150, missing every
  # hook fix shipped in the three releases since, while the image looked current.
  # Passing the resolved sha makes the cache correct — hit while upstream is
  # unchanged, miss the moment it moves.
  make_stub git 'echo "abc123def456	refs/heads/main"'
  bash bin/build.sh
  run cat "$STUB_LOG"
  [[ "$output" == *"--build-arg SEED_REF=abc123def456"* ]]
}

@test "build.sh pins an explicitly requested seed ref without asking upstream" {
  # Reproducing someone else's image, or bisecting which core release broke a
  # sandbox, both need a specific commit rather than whatever main is now. The
  # resolve step must not overwrite it — and must not even run, so the pin works
  # offline.
  make_stub git 'echo "SHOULD_NOT_RESOLVE	refs/heads/main"'
  bash bin/build.sh --seed-ref deadbeefcafe
  run cat "$STUB_LOG"
  [[ "$output" == *"--build-arg SEED_REF=deadbeefcafe"* ]]
  [[ "$output" != *"SHOULD_NOT_RESOLVE"* ]]
}

@test "build.sh still builds when upstream cannot be reached, and says why" {
  # An offline rebuild must still produce an image. What it must not do is imply
  # the seed is current when it could not check.
  make_stub git 'exit 1'
  run bash bin/build.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"may be a stale cache hit"* ]]
  run cat "$STUB_LOG"
  [[ "$output" == *"--build-arg SEED_REF=main"* ]]
}
