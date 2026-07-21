#!/usr/bin/env bash
# Component self-test. Uses the workspace-vendored bats (this host has no bats on
# PATH); shellcheck runs via the koalaman container unless a host shellcheck exists.
set -euo pipefail
cd "$(dirname "$0")/.."                                  # component root
WS_ROOT="$(cd ../.. && pwd)"                             # <workspace>/components/<name> → workspace
BATS="$(command -v bats || echo "$WS_ROOT/tests/vendor/bats-core/bin/bats")"

shellcheck_run() {
  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "$@"
  else
    ws docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable "$@"
  fi
}

case "${1:-test}" in
  test) exec bash "$BATS" tests/ ;;
  lint) shellcheck_run bin/*.sh tests/*.sh provision/*.sh ;;
  *) echo "usage: tests/run.sh {test|lint}" >&2; exit 2 ;;
esac
