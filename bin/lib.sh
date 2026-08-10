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

# Where the session writes its transcript, and how to read the two markers that
# matter. Defined once because three copies were drifting apart: the supervisor
# used them to tell "finished" from "stopped", the notifier to find the message
# to edit, and a change to either the path or the marker format had to land in
# every copy. A missed copy fails silently — `unanswered_request` just returns
# false and the stall is never reported, which is the failure this all exists to
# catch.
GDD_TRANSCRIPTS_DEFAULT="${HOME}/.claude/projects/-work-ws"

ws_transcript() {
    local dir="${GDD_TRANSCRIPT_DIR:-$GDD_TRANSCRIPTS_DEFAULT}"
    find "$dir" -maxdepth 1 -name '*.jsonl' -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | head -1 | cut -d' ' -f2-
}

# The channel a conversation is happening in. Carried on every inbound message.
ws_transcript_chat_id() {
    local f="${1:-}"; [ -n "$f" ] || return 1
    grep -o 'chat_id=\\"[0-9]*\\"' "$f" 2>/dev/null | tail -1 | grep -o '[0-9]*'
}

# The id of the last message the agent sent, as reported back by the reply tool.
ws_transcript_last_message_id() {
    local f="${1:-}"; [ -n "$f" ] || return 1
    grep -o 'sent (id: [0-9]*)' "$f" 2>/dev/null | tail -1 | grep -o '[0-9]*'
}

# Line numbers of the last inbound request and the last reply. Whichever is
# later decides whether anyone is still waiting on an answer.
ws_transcript_last_in_line() {
    local f="${1:-}"; [ -n "$f" ] || return 1
    grep -n 'chat_id=' "$f" 2>/dev/null | tail -1 | cut -d: -f1
}

ws_transcript_last_out_line() {
    local f="${1:-}"; [ -n "$f" ] || return 1
    grep -n 'sent (id:' "$f" 2>/dev/null | tail -1 | cut -d: -f1
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

# Does this session output show a prompt waiting on a human?
#
# Matched against control-code-stripped text, where removing escape sequences
# joins fragments together ("Doyouwanttoproceed?"), so the pattern tolerates
# missing spaces rather than assuming them.
ws_prompt_pending() {
    printf '%s' "$1" | grep -qE 'want.{0,3}to.{0,3}proceed|1\..{0,2}Yes'
}

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
