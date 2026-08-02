#!/usr/bin/env bash
# Check the sandbox is actually able to do its job — before it is asked to.
#
# Every stall in the first real run was a missing configuration value rather than
# a logic bug: an undeclared target, an unset email, an unset account. The system
# behaved correctly each time, and each time a human supplied the missing piece
# mid-task with someone waiting. Found serially, they cost four round-trips.
#
# So this reports EVERY problem in one pass, and grades them, because the
# difference between "cannot start" and "can draft but not publish" decides
# whether to fix it now or carry on.
#
# It does not block startup. A sandbox that can draft is useful, and refusing to
# run would turn a partial capability into silence — the failure this project
# exists to remove. Instead it writes a report the AGENT reads, so it can say "I
# am not set up to publish yet" when a request arrives, rather than discovering it
# three steps in.
#
# Exit: 0 all clear, 1 degraded, 2 cannot work.
set -u
WS="${GDD_WORKSPACE:-/work/ws}"
TARGET="${GDD_TARGET:-}"
REPORT="${GDD_PREFLIGHT_REPORT:-/tmp/gdd-sandbox-preflight.md}"

fatal=0 degraded=0 advisory=0
lines=""

note() { # severity, message, remedy
  case "$1" in
    fatal)    fatal=$((fatal + 1)) ;;
    degraded) degraded=$((degraded + 1)) ;;
    *)        advisory=$((advisory + 1)) ;;
  esac
  lines="${lines}- **$1**: $2
  - *Fix*: $3
"
}

# --- Can it work in the repository at all? --------------------------------
[ -n "$TARGET" ] || note fatal \
  "No target component configured." \
  "Pass --target to run.sh."

if [ -n "$TARGET" ] && [ ! -d "$WS/components/$TARGET/.git" ]; then
  note fatal "Target '$TARGET' is not cloned at components/$TARGET." \
    "Check GDD_TARGET_REPO and the network; provisioning clones it."
fi

# Cloning is not the same as being declared — `ws push` and `ws cr` resolve a
# component from the config, and without this they fail with "no such target"
# while the clone looks perfectly fine.
if ! grep -q "^  ${TARGET}:" "$WS/ecosystem.local.yaml" 2>/dev/null; then
  note fatal "Target '$TARGET' is not declared in ecosystem.local.yaml." \
    "Provisioning writes this; check GDD_TARGET_REPO is set."
fi

# --- Can it be reached? ---------------------------------------------------
access="$HOME/.claude/channels/discord/access.json"
if [ ! -f "$access" ]; then
  note fatal "No channel access config." "Provisioning writes it; check GDD_ALLOWFROM."
elif ! grep -q '"allowFrom": *\[ *"' "$access" && ! grep -q '"groups": *{ *"' "$access"; then
  note fatal "Nobody is allowed to talk to this sandbox." \
    "Set --allowfrom (direct messages) or --channel (a shared channel)."
fi

[ -f "${GDD_BRIEFING_PATH:-/tmp/gdd-sandbox-briefing.md}" ] || note fatal \
  "The agent has no briefing — it will not know what it is scoped to." \
  "Provisioning renders it from BRIEFING.md."

# --- Can it publish? ------------------------------------------------------
if ! grep -q '^GH_TOKEN=' "$WS/.env" 2>/dev/null; then
  note degraded "No code-host token: the agent can draft but cannot open a pull request." \
    "Set GDD_GITHUB_TOKEN in the operator env file."
else
  # Pass the token explicitly. It lives in the workspace .env, which `ws` loads
  # and a bare `gh` does not — checking without it reports a perfectly good token
  # as broken, and a check that cries wolf is worse than no check at all.
  tok="$(grep -m1 '^GH_TOKEN=' "$WS/.env" 2>/dev/null || true)"
  tok="${tok#GH_TOKEN=}"
  who="$(GH_TOKEN="$tok" gh api user --jq .login 2>/dev/null || true)"
  if [ -z "$who" ]; then
    note degraded "The token is present but does not authenticate." \
      "Check it has not expired and is scoped to this repository."
  fi
fi

email="$(git -C "$WS/components/$TARGET" config user.email 2>/dev/null || true)"
name="$(git -C "$WS/components/$TARGET" config user.name 2>/dev/null || true)"
if [ -z "$email" ] || [ -z "$name" ]; then
  note degraded "No commit identity — commits will fail or be misattributed." \
    "Set GDD_GITHUB_USER and GDD_GITHUB_EMAIL."
elif [ "${email#*@users.noreply.}" = "$email" ] && [ "${GDD_PUBLIC_EMAIL_OK:-0}" != "1" ]; then
  # A real address is rejected outright when the account keeps its email private,
  # and the push fails after the work is done — the most wasteful moment to find
  # out. But a public address is a legitimate choice, so this is suppressible:
  # an advisory that fires when everything is intentional is noise, and noise
  # teaches people to skim past the whole report.
  note advisory "Commit email '$email' is not a no-reply address." \
    "If the account hides its email, pushes are rejected. Use its no-reply address, or set GDD_PUBLIC_EMAIL_OK=1 to say the public address is deliberate."
fi

# --- Will it stall on a question? -----------------------------------------
grep -q 'human_account' "$WS/ecosystem.local.yaml" 2>/dev/null || note advisory \
  "identity.human_account is unset — the agent will stop to ask for it." \
  "Set GDD_HUMAN_ACCOUNT to the site owner's account on the code host."

[ -n "${GDD_OPERATOR_CHAT:-}" ] || note advisory \
  "No operator address — technical detail about problems has nowhere to go." \
  "Set GDD_OPERATOR_CHAT to your direct-message channel."

# --- Write the report the agent reads -------------------------------------
{
  echo "# Sandbox readiness"
  echo
  if [ "$fatal" -eq 0 ] && [ "$degraded" -eq 0 ] && [ "$advisory" -eq 0 ]; then
    echo "Everything checked out. You can read, change, commit and open pull requests."
  else
    echo "Some things are not configured. **Say so when a request arrives** rather"
    echo "than starting work you cannot finish — and tell the operator the detail."
    echo
    printf '%s' "$lines"
  fi
} > "$REPORT"

printf '%s' "$lines"
if [ "$fatal" -gt 0 ]; then
  echo "preflight: $fatal blocking, $degraded degrading, $advisory advisory" >&2
  exit 2
fi
if [ "$degraded" -gt 0 ]; then
  echo "preflight: $degraded degrading, $advisory advisory" >&2
  exit 1
fi
echo "preflight: ready ($advisory advisory)"
exit 0
