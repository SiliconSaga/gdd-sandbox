#!/usr/bin/env bash
# In-container provisioning. Idempotent: seeds the workspace once, then only
# freshens on later runs. No credentials handled here (env-file carries auth).
set -euo pipefail
WS="${GDD_WORKSPACE:-/work/ws}"
SEED="${GDD_SEED:-/opt/gdd-seed}"
HERE="$(cd "$(dirname "$0")" && pwd)"

# 1. Seed the mutable workspace from the baked GDD core (first run only).
if [ ! -e "$WS/.git" ]; then
  mkdir -p "$(dirname "$WS")"
  cp -a "$SEED" "$WS"
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
mkdir -p "$HOME/.claude/channels/discord"
sed "s/__ALLOWFROM__/${GDD_ALLOWFROM:-[]}/" "$HERE/access.json.template" \
  > "$HOME/.claude/channels/discord/access.json"
bash "$HERE/patch-onboarding.sh" "$HOME/.claude.json" "$WS"
echo "provision complete: $WS (target=$GDD_TARGET)"
