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

# The runtime secrets the sandbox is allowed to receive. Deliberately a short
# allowlist: everything else in the operator's .env (GH_TOKEN, HARBOR_ADMIN_PW,
# ...) stays OUT of the container.
#
# GDD_GITHUB_TOKEN is the SANDBOX USER's own token — a dedicated machine account
# with a fine-grained grant on the target repository only. It is named distinctly
# so the operator's personal GH_TOKEN cannot be picked up by accident: same file,
# different variable, and only this one travels.
#
# It arrives through the env file rather than a command-line argument on purpose;
# arguments are visible to anyone who can list processes.
WS_RUNTIME_SECRETS='CLAUDE_CODE_OAUTH_TOKEN|DISCORD_BOT_TOKEN|GDD_GITHUB_TOKEN'

# Read one value out of an operator .env, literally.
#
# Accepts the optional `export ` prefix that `ws` allows, strips surrounding
# quotes, and never evaluates the line — a .env is data here, not a script.
# Used for the non-secret identity settings that sit alongside the token, so the
# operator configures everything in one file instead of exporting shell variables.
ws_env_value() {
    local file="$1" key="$2" line
    [ -f "$file" ] || return 0
    line="$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file" | tail -n1)" || true
    [ -n "$line" ] || return 0
    line="${line#*=}"
    line="${line%\"}"; line="${line#\"}"
    line="${line%\'}"; line="${line#\'}"
    printf '%s\n' "$line"
}

# Write a minimal env file for `docker --env-file` from an operator .env.
#
# Two transforms: keep only the allowlisted runtime secrets, and strip any
# `export ` prefix. `ws` accepts `export KEY=value`, but docker's --env-file
# parser does not — it reads "export GH_TOKEN" as the variable name and rejects
# it for containing whitespace.
#
# Returns non-zero if nothing matched, so a misconfigured secrets file fails
# loudly rather than starting a container with no credentials.
ws_write_runtime_env() {
    local src="$1" dest="$2"
    : > "$dest"
    chmod 600 "$dest" 2>/dev/null || true
    grep -E "^[[:space:]]*(export[[:space:]]+)?($WS_RUNTIME_SECRETS)=" "$src" \
        | sed -E 's/^[[:space:]]*(export[[:space:]]+)?//' >> "$dest" || true
    [ -s "$dest" ]
}
