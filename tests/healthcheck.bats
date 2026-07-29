load helpers/stub

setup() {
  stub_setup
  export GDD_HEALTH_MIN_UPTIME=30
  export GDD_HEALTH_PROBE_API=0   # process-level assertions; API probe has its own tests
}

@test "healthy when the session has been up past the startup window" {
  make_stub pgrep 'echo 1234'
  make_stub ps 'echo "   900"'
  run bash bin/healthcheck.sh
  [ "$status" -eq 0 ]
}

@test "unhealthy when the agent is alive but its channel server is gone" {
  # Observed after a host reboot: agent running, MCP server absent, bot offline,
  # every message unanswered — while a process-only check reported healthy.
  make_stub ps 'echo "   900"'
  make_stub pgrep 'case "$*" in *claude-plugins-official/discord*) exit 1 ;; *) echo 1234 ;; esac'
  run bash bin/healthcheck.sh
  [ "$status" -ne 0 ]
}

@test "unhealthy when no session process exists" {
  make_stub pgrep 'exit 1'
  run bash bin/healthcheck.sh
  [ "$status" -ne 0 ]
}

@test "unhealthy while crash-looping, not fooled by a just-started process" {
  # A supervisor relaunching a failing session is live part of every cycle; a
  # bare process check would call that healthy while nobody is listening.
  make_stub pgrep 'echo 1234'
  make_stub ps 'echo "   2"'
  run bash bin/healthcheck.sh
  [ "$status" -ne 0 ]
}

@test "unhealthy when Discord is unreachable though every process is alive" {
  # The state a network outage produces: processes fine, nobody reachable.
  # Verified live by disconnecting the container from its network.
  export GDD_HEALTH_PROBE_API=1 DISCORD_BOT_TOKEN=fake
  make_stub pgrep 'echo 1234'
  make_stub ps 'echo "   900"'
  make_stub curl 'exit 6'          # could not resolve host
  run bash bin/healthcheck.sh
  [ "$status" -ne 0 ]
}

@test "healthy when the reachability probe succeeds" {
  export GDD_HEALTH_PROBE_API=1 DISCORD_BOT_TOKEN=fake
  make_stub pgrep 'echo 1234'
  make_stub ps 'echo "   900"'
  make_stub curl 'exit 0'
  run bash bin/healthcheck.sh
  [ "$status" -eq 0 ]
}

@test "the probe is skipped when no bot token is present" {
  # Without a token the probe cannot be authenticated; do not fail the whole
  # healthcheck over a credential the sandbox may legitimately not have yet.
  export GDD_HEALTH_PROBE_API=1
  unset DISCORD_BOT_TOKEN
  make_stub pgrep 'echo 1234'
  make_stub ps 'echo "   900"'
  make_stub curl 'exit 6'
  run bash bin/healthcheck.sh
  [ "$status" -eq 0 ]
}

@test "unhealthy when the process vanishes between the two probes" {
  make_stub pgrep 'echo 1234'
  make_stub ps 'echo ""'
  run bash bin/healthcheck.sh
  [ "$status" -ne 0 ]
}
