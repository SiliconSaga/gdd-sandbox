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

# 2a. Declare the target in the workspace's local ecosystem config.
#
# Cloning it into components/ is not enough: `ws` resolves a component by what the
# config declares, so without this `ws push` and `ws cr` — the two commands the
# agent is allowed to use — fail with "no such target". The clone looks fine and
# the workflow is unusable, which is a hard failure to read from chat.
#
# Written rather than templated because it is machine state, not user content.
if [ -n "${GDD_TARGET_REPO:-}" ]; then
  printf 'components:\n  %s:\n    repo: %s\n' "$GDD_TARGET" "$GDD_TARGET_REPO" \
    > "$WS/ecosystem.local.yaml"
  # No identity.human_account on purpose. `ws diagnose` warns that it is unset,
  # and here that warning does not apply: it exists to fill @HUMAN_ACCOUNT in the
  # request body, and the sandbox's template has no such placeholder — provenance
  # comes from the chat identity instead. Anyone with review rights can review;
  # nobody needs mentioning, least of all a name we would have to invent.
  echo "provision: declared $GDD_TARGET in ecosystem.local.yaml"
fi

# 2b. Give the workspace the sandbox user's own GitHub identity, if one was
# provided. `ws push` / `gh` read GH_TOKEN from the workspace .env, which is
# git-ignored and lives on the volume rather than in the image.
#
# The token belongs to a dedicated machine account with a fine-grained grant on
# the target repository alone, so the blast radius is that one repo: it cannot
# see, let alone write, anything else the operator owns. Commits are attributed to
# that account, which keeps agent-authored history honest and revocation to a
# single token.
if [ -n "${GDD_GITHUB_TOKEN:-}" ]; then
  ws_env="$WS/.env"
  # Rewrite rather than append, so repeated provisioning cannot stack duplicates.
  if [ -f "$ws_env" ]; then
    grep -v '^GH_TOKEN=' "$ws_env" > "$ws_env.tmp" || true
    mv "$ws_env.tmp" "$ws_env"
  fi
  printf 'GH_TOKEN=%s\n' "$GDD_GITHUB_TOKEN" >> "$ws_env"
  chmod 600 "$ws_env" 2>/dev/null || true
  echo "provision: workspace GitHub token installed (value not logged)"

  git -C "$WS/components/$GDD_TARGET" config user.name "${GDD_GITHUB_USER:-Kencierge}" 2>/dev/null || true
  git -C "$WS/components/$GDD_TARGET" config user.email \
    "${GDD_GITHUB_EMAIL:-kencierge@users.noreply.github.com}" 2>/dev/null || true
else
  echo "provision: no GitHub token supplied — the agent can draft but not publish"
fi

# 3. Install the Discord channel plugin (brings its Bun deps). Provisioning runs
# on every container start, so skip when it is already present — re-adding the
# marketplace errors, and a restart should be fast.
if [ ! -d "$HOME/.claude/plugins/cache/claude-plugins-official/discord" ]; then
  claude plugin marketplace add anthropics/claude-plugins-official
  claude plugin install discord@claude-plugins-official
else
  echo "provision: discord plugin already installed"
fi

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

# Guild channels are OFF by default in the plugin and must be opted in per
# channel, keyed on the CHANNEL snowflake (not the guild). allowFrom covers DMs
# only, so a shared channel needs this or the agent can receive but never reply.
#
# NOT named GROUPS: that is a bash built-in array of the user's group ids, so the
# assignment is silently ignored and the value expands to a numeric gid instead of
# JSON. Cost an hour; do not reintroduce it.
CHANNEL_GROUPS="${GDD_CHANNEL_GROUPS:-}"
[ -n "$CHANNEL_GROUPS" ] || CHANNEL_GROUPS='{}'

mkdir -p "$HOME/.claude/channels/discord"
sed -e "s/__ALLOWFROM__/$ALLOWFROM/" -e "s|__GROUPS__|$CHANNEL_GROUPS|" \
  "$HERE/access.json.template" \
  > "$HOME/.claude/channels/discord/access.json"

# Install the sandbox's change-request template over the workspace default.
#
# The stock disclaimer reads "filed by agent driven by @HUMAN_ACCOUNT", which
# assumes the person driving the agent is a GitHub user working locally. Here they
# are a chat identity who may have no GitHub account at all, so a request would
# otherwise arrive claiming provenance it does not have — and the only name on it
# would be the machine account, which says nothing about who asked.
if [ -f "$HERE/change.sandbox.md" ] && [ -d "$WS/templates" ]; then
  sed "s/__GITHUB_USER__/${GDD_GITHUB_USER:-Kencierge}/g" "$HERE/change.sandbox.md" \
    > "$WS/templates/change.md"
  echo "provision: installed the chat-provenance change template"
fi

# Render the agent briefing. Without it the session is a bare Claude Code
# instance that happens to receive chat messages: asked to change the project it
# will compose a plausible reply and touch nothing, because nothing told it what
# it is, what it is scoped to, or that chat requests mean real work.
sed "s/__TARGET__/${GDD_TARGET:-unknown}/g" "$HERE/BRIEFING.md" \
  > "${GDD_BRIEFING_PATH:-/tmp/gdd-sandbox-briefing.md}"
bash "$HERE/patch-onboarding.sh" "$HOME/.claude.json" "$WS"

# 5. Report whether the upstream quirks we work around still look the same.
bash "$HERE/../bin/check-plugin-quirks.sh" || true

echo "provision complete: $WS (target=$GDD_TARGET)"
