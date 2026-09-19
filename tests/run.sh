#!/usr/bin/env bash
# Component self-test. Uses the workspace-vendored bats (this host has no bats on
# PATH); shellcheck runs via the koalaman container unless a host shellcheck exists.
set -euo pipefail
cd "$(dirname "$0")/.."                                  # component root
WS_ROOT="$(cd ../.. && pwd)"                             # <workspace>/components/<name> → workspace
# Prefer a real bats; else the workspace-vendored copy. Inside the sandbox image
# the baked seed's copy is used instead: a Windows checkout leaves the workspace
# copy CRLF, which /bin/bash on Linux refuses ($'\r': command not found).
BATS="$(command -v bats || true)"
if [ -z "$BATS" ] && [ -x /opt/gdd-seed/tests/vendor/bats-core/bin/bats ]; then
  BATS=/opt/gdd-seed/tests/vendor/bats-core/bin/bats
fi
BATS="${BATS:-$WS_ROOT/tests/vendor/bats-core/bin/bats}"

shellcheck_run() {
  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "$@"
  else
    ws docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable "$@"
  fi
}

case "${1:-test}" in
  test)
    # Optional selector, supplied by `ws test gdd-sandbox <selector>` through the
    # realm adapter's commands.testFilter. A path under tests/ runs that file; any
    # other value is a bats --filter regex over test names.
    sel="${2:-}"
    if [ -z "$sel" ]; then
      exec bash "$BATS" tests/
    elif [ -f "$sel" ]; then
      exec bash "$BATS" "$sel"
    fi
    # A regex matching nothing makes bats print 1..0 and exit 0 — a green run of
    # no tests, indistinguishable at a glance from the one test asked for having
    # passed. Refuse it instead; that is the whole point of declaring a filter.
    if [ "$(bash "$BATS" --count --filter "$sel" tests/)" -eq 0 ]; then
      echo "no test name matches '$sel' (a bats --filter regex over tests/)" >&2
      exit 1
    fi
    exec bash "$BATS" --filter "$sel" tests/
    ;;
  lint) shellcheck_run bin/*.sh tests/*.sh provision/*.sh ;;
  *) echo "usage: tests/run.sh {test [selector]|lint}" >&2; exit 2 ;;
esac
