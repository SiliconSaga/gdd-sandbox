load helpers/stub

setup() {
  stub_setup
  export GDD_HEALTH_MIN_UPTIME=30
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

@test "unhealthy when the process vanishes between the two probes" {
  make_stub pgrep 'echo 1234'
  make_stub ps 'echo ""'
  run bash bin/healthcheck.sh
  [ "$status" -ne 0 ]
}
