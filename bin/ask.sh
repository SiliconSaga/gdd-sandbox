#!/usr/bin/env bash
# Put a request to the agent directly, without going through the chat channel.
#
# For testing and diagnosis. Every behavioural check otherwise needs a person to
# send a chat message and report back what they saw, which is slow and puts the
# operator in the loop for things that are really about permissions, hooks, or
# repository work.
#
# What this does NOT test: the channel round-trip. The reply appears in the
# session, not in chat, so it proves nothing about delivery, allowlists, or the
# outbound gate. Use a real message for those.
#
# Usage: ask.sh <text...>
set -u
FIFO="${CLAUDE_STDIN_FIFO:-/tmp/claude-stdin}"

[ $# -gt 0 ] || { echo "usage: ask.sh <text...>" >&2; exit 2; }
[ -p "$FIFO" ] || {
  echo "no session input at $FIFO — is the sandbox running?" >&2
  exit 1
}

# Text first, then a separate carriage return: sent together the editor sometimes
# submits before the line has registered.
printf '%s' "$*" > "$FIFO"
sleep 1
printf '\r' > "$FIFO"
echo "asked: $*"
