#!/usr/bin/env bash
# Is the channels session alive AND past its startup churn?
#
# Two things this deliberately does NOT do:
#   * It does not check log freshness. A session idling correctly between
#     messages writes nothing, so that would report a healthy sandbox unhealthy.
#   * It does not merely check the process exists. A crash-looping supervisor
#     spends part of every cycle with a live process, so a bare `pgrep` gets
#     caught mid-restart and reports healthy — observed live, and the worst
#     possible outcome: Docker says healthy while nobody is listening.
#
# Requiring a minimum uptime distinguishes "running" from "restarting forever".
#
# It also checks the CHANNEL SERVER, not just the agent. Observed after a host
# reboot: the agent process was alive and Docker reported healthy, while the
# plugin's MCP server was absent — so the bot was offline and every message went
# unanswered. The agent does not exit when its channel dies, so "agent alive" is
# not "reachable", and treating it as such reports health while nobody can be
# reached. That is the ghosting failure wearing a green badge.
set -u
MIN_UPTIME="${GDD_HEALTH_MIN_UPTIME:-30}"
CHANNEL_PATTERN="${GDD_CHANNEL_PATTERN:-claude-plugins-official/discord}"

pid="$(pgrep -f 'claude .*--channels' | head -n1)"
[ -n "$pid" ] || exit 1

uptime_s="$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
[ -n "$uptime_s" ] || exit 1

[ "$uptime_s" -ge "$MIN_UPTIME" ] || exit 1

# The channel server is spawned by the session shortly after start; only demand it
# once past the same startup window, so a healthy launch is not flagged mid-boot.
pgrep -f "$CHANNEL_PATTERN" >/dev/null || exit 1
exit 0
