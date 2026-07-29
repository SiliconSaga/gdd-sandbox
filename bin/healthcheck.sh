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

# Finally, prove we can actually reach Discord with our credentials, rather than
# inferring it from a process listing. Catches network loss and an expired or
# revoked token — states where every process check passes and nobody is reachable.
#
# Rejected alternative: looking for an ESTABLISHED socket to Discord. A dropped
# network leaves the old socket sitting in retransmit for minutes, so it reports
# connected long after it isn't (verified by disconnecting the container).
#
# Honest limit: this proves the API is reachable and the token valid, not that the
# gateway session is live. Closing that last gap needs the channel plugin to expose
# its connection state.
if [ "${GDD_HEALTH_PROBE_API:-1}" = "1" ] && [ -n "${DISCORD_BOT_TOKEN:-}" ]; then
  curl -fsS --max-time "${GDD_HEALTH_PROBE_TIMEOUT:-5}" -o /dev/null \
    -H "Authorization: Bot $DISCORD_BOT_TOKEN" \
    "${GDD_HEALTH_PROBE_URL:-https://discord.com/api/v10/users/@me}" || exit 1
fi
exit 0
