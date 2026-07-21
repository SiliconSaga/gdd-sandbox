#!/usr/bin/env bash
# Write a keystroke into the claude PTY FIFO. Usage: send.sh <key>
set -u
FIFO="${CLAUDE_STDIN_FIFO:-/tmp/claude-stdin}"
case "$1" in
  enter) printf '\r'      > "$FIFO" ;;
  down)  printf '\033[B'  > "$FIFO" ;;
  up)    printf '\033[A'  > "$FIFO" ;;
  space) printf ' '       > "$FIFO" ;;
  tab)   printf '\t'      > "$FIFO" ;;
  esc)   printf '\033'    > "$FIFO" ;;
  *)     printf '%s' "$1" > "$FIFO" ;;
esac
