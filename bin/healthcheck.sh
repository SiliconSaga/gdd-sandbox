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
# A genuinely wedged session (alive, responsive to nothing) still needs a real
# probe; that belongs with the observability work.
set -u
MIN_UPTIME="${GDD_HEALTH_MIN_UPTIME:-30}"

pid="$(pgrep -f 'claude .*--channels' | head -n1)"
[ -n "$pid" ] || exit 1

uptime_s="$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
[ -n "$uptime_s" ] || exit 1

[ "$uptime_s" -ge "$MIN_UPTIME" ] || exit 1
exit 0
