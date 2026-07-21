#!/usr/bin/env bash
# Mark Claude Code first-run onboarding complete so an interactive --channels
# session does not stall on theme/login/trust prompts. Production-safe: does NOT
# pre-accept bypass mode (the sandbox uses default mode + an allow-list posture).
set -euo pipefail
CFG="${1:-$HOME/.claude.json}"
PROJECT="${2:-}"
[ -f "$CFG" ] || echo '{}' > "$CFG"
tmp="$(mktemp)"
jq --arg proj "$PROJECT" '
    .hasCompletedOnboarding = true
  | .theme = (.theme // "dark")
  | if $proj != "" then
      .projects[$proj].hasTrustDialogAccepted = true
      | .projects[$proj].hasCompletedProjectOnboarding = true
    else . end
' "$CFG" > "$tmp"
mv "$tmp" "$CFG"
echo "patched $CFG"
