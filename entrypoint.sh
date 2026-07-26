#!/usr/bin/env bash
# Container entrypoint: provision (idempotent), then supervise the session.
#
# The supervisor MUST be the container's main process. Starting it with
# `docker exec -d` looks equivalent but is not: that process dies with the
# container, so `--restart unless-stopped` brings the container back running only
# its CMD and the agent never returns. From outside, the container is "up" and
# healthy-looking while nobody is listening — silent ghosting, which is the exact
# failure this design exists to cure.
#
# Provisioning runs on every start and is idempotent: the workspace is seeded once,
# the plugin installed once, and later starts only refresh.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

bash "$HERE/provision/provision.sh"

# exec so the supervisor becomes PID 1's process image — signals reach it, and its
# exit is the container's exit.
exec bash "$HERE/bin/supervise.sh"
