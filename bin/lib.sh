#!/usr/bin/env bash
# Shared helpers for the gdd-sandbox host scripts.

# Convert a HOST path into the form the native docker client expects.
#
# `ws docker` exports MSYS_NO_PATHCONV=1 so CONTAINER-side paths (/work/ws,
# -v vol:/path) reach docker unrewritten. The trade-off is that HOST paths are
# no longer translated either, so a Git Bash path like /d/Dev/... arrives at
# docker.exe verbatim and fails ("The system cannot find the path specified").
# Emit the mixed form (D:/Dev/...) instead. No-op on macOS/Linux.
#
# Apply this ONLY to host paths (build context, --env-file, `docker cp` source),
# never to container paths or named volumes.
ws_host_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1"
    else
        printf '%s\n' "$1"
    fi
}
