#!/usr/bin/env bash
# Detect when an upstream quirk we work around has changed.
#
# A workaround should carry a test for its own obsolescence, or it becomes a
# mystery entry nobody dares delete. This does NOT try to prove the bug is fixed
# — probing it needs the plugin's long-lived client state, and a fresh-client
# probe reports "fixed" while the live path still fails (that false signal cost
# us two sessions). Instead it watches the two things that mean "re-verify":
# the plugin version, and the exact gate expression we depend on.
#
# Exit 0 = unchanged, workaround still justified.
# Exit 1 = changed, re-verify and consider removing the workaround.
set -u

PLUGIN_ROOT="${DISCORD_PLUGIN_ROOT:-$HOME/.claude/plugins/cache/claude-plugins-official/discord}"
EXPECTED_VERSION="${GDD_DISCORD_PLUGIN_VERSION:-0.0.4}"
# The buggy expression: ch.recipientId resolves to the BOT's own id in the
# plugin's long-lived client, and being non-null it short-circuits the `??`, so
# dmChannelUsers (which holds the correct human id) is never consulted.
GATE_PATTERN='ch.recipientId ?? dmChannelUsers.get(id)'

changed=0

if [ ! -d "$PLUGIN_ROOT" ]; then
  echo "quirk-check: plugin not found at $PLUGIN_ROOT — skipping" >&2
  exit 0
fi

installed=""
for d in "$PLUGIN_ROOT"/*/; do
  [ -d "$d" ] || continue
  installed="$(basename "$d")"
  break
done
if [ -z "$installed" ]; then
  echo "quirk-check: no installed version under $PLUGIN_ROOT — skipping" >&2
  exit 0
fi

if [ "$installed" != "$EXPECTED_VERSION" ]; then
  echo "quirk-check: discord plugin version changed ($EXPECTED_VERSION -> $installed)."
  changed=1
fi

server="$PLUGIN_ROOT/$installed/server.ts"
if [ ! -f "$server" ]; then
  echo "quirk-check: $server missing — re-verify the workarounds." >&2
  exit 1
fi

if ! grep -qF "$GATE_PATTERN" "$server"; then
  echo "quirk-check: the DM outbound-gate expression changed."
  echo "  Expected: $GATE_PATTERN"
  changed=1
fi

if [ "$changed" -eq 1 ]; then
  cat <<'MSG'
  ACTION: re-verify the bot-id workaround. provision.sh adds the bot's OWN user
  id to access.json allowFrom so the plugin's DM gate passes. If upstream now
  resolves the human's id, that entry is no longer needed and should be dropped.
  See the "Known upstream quirks" section in README.md.
MSG
  exit 1
fi

echo "quirk-check: discord plugin $installed unchanged — bot-id workaround still required."
exit 0
