#!/usr/bin/env bash
# Print the session log with terminal control codes stripped.
#
# The raw capture is a screen recording, not a transcript: it is painful to read
# and, worse, it defeats search. Escape sequences land mid-word, so grepping for
# text plainly visible on screen returns nothing — a false negative that reads as
# "it never happened". Strip them first, then search.
#
# Usage: session-log.sh [lines] [logfile]
set -u
LINES="${1:-80}"
LOG="${2:-/tmp/channels-tty.log}"

[ -f "$LOG" ] || { echo "no session log at $LOG" >&2; exit 1; }

# CSI sequences, charset selects, OSC titles, then carriage returns to newlines so
# redrawn lines separate instead of overwriting each other.
sed -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g' \
    -e 's/\x1b][^\x07]*\x07//g' \
    -e 's/\x1b[()][A-Za-z0-9]//g' \
    -e 's/\x1b[>=]//g' \
    -e 's/\r/\n/g' "$LOG" \
  | grep -v '^[[:space:]]*$' \
  | grep -vE '^[[:space:]]*[●✻✽✶✢✳·*⏸❯]+[[:space:]]*$' \
  | grep -vE '^[[:space:]]*(─|╌|━)+[[:space:]]*$' \
  | tail -n "$LINES"
