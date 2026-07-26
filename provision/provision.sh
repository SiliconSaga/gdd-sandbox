#!/usr/bin/env bash
# In-container provisioning. Idempotent: seeds the workspace once, then only
# freshens on later runs. No credentials handled here (env-file carries auth).
set -euo pipefail
WS="${GDD_WORKSPACE:-/work/ws}"
SEED="${GDD_SEED:-/opt/gdd-seed}"
HERE="$(cd "$(dirname "$0")" && pwd)"

# 1. Seed the mutable workspace from the baked GDD core (first run only).
# Copy the seed's CONTENTS ("$SEED/." -> "$WS/"), not the seed directory itself:
# $WS is a mounted volume, so it already exists and `cp -a "$SEED" "$WS"` would
# nest the clone at $WS/gdd-seed instead of populating $WS.
if [ ! -e "$WS/.git" ]; then
  mkdir -p "$WS"
  cp -a "$SEED/." "$WS/"
fi

# 2. Freshen, then clone realm + target into the workspace (idempotent).
cd "$WS"
ws pull || true
[ -n "${GDD_REALM_REPO:-}" ] && [ ! -e "realms/$(basename "${GDD_REALM_REPO%.git}")/.git" ] \
  && git clone "$GDD_REALM_REPO" "realms/$(basename "${GDD_REALM_REPO%.git}")"
if [ -n "${GDD_TARGET_REPO:-}" ] && [ ! -e "components/$GDD_TARGET/.git" ]; then
  git clone "$GDD_TARGET_REPO" "components/$GDD_TARGET"
fi

# 3. Install the Discord channel plugin (brings its Bun deps).
claude plugin marketplace add anthropics/claude-plugins-official
claude plugin install discord@claude-plugins-official

# 4. Seed the allowlist + patch onboarding.
#
# UPSTREAM QUIRK (discord plugin 0.0.4) — the bot's OWN id must be allowlisted.
# The outbound gate does `ch.recipientId ?? dmChannelUsers.get(id)`, but in the
# plugin's long-lived client `ch.recipientId` resolves to the BOT rather than the
# human. Being non-null it short-circuits the `??`, so the map holding the correct
# id is never consulted and every DM reply is rejected. Including the bot's own id
# makes the plugin's own check pass. Fail-safe: if upstream starts returning the
# human's id, allowFrom still contains it, so this keeps working either way.
# `bin/check-plugin-quirks.sh` reports when this entry can be dropped.
ALLOWFROM="${GDD_ALLOWFROM:-[]}"
if [ -n "${DISCORD_BOT_TOKEN:-}" ]; then
  bot_id="$(curl -fsS -H "Authorization: Bot $DISCORD_BOT_TOKEN" \
    https://discord.com/api/v10/users/@me | jq -r '.id // empty' || true)"
  if [ -n "$bot_id" ]; then
    ALLOWFROM="$(jq -cn --argjson base "$ALLOWFROM" --arg bot "$bot_id" \
      '$base + [$bot] | unique')"
    echo "provision: allowlisted the bot's own id ($bot_id) — plugin gate quirk"
  else
    echo "provision: WARNING could not resolve the bot id; DM replies may be rejected" >&2
  fi
fi

mkdir -p "$HOME/.claude/channels/discord"
sed "s/__ALLOWFROM__/$ALLOWFROM/" "$HERE/access.json.template" \
  > "$HOME/.claude/channels/discord/access.json"
bash "$HERE/patch-onboarding.sh" "$HOME/.claude.json" "$WS"

# 5. Report whether the upstream quirks we work around still look the same.
bash "$HERE/../bin/check-plugin-quirks.sh" || true

echo "provision complete: $WS (target=$GDD_TARGET)"
