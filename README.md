# gdd-sandbox

A GDD **sandboxed workspace**: a Docker container running a scoped GDD agent,
reachable over a chat channel (Discord today), pointed at one target component.
Someone collaborates with the agent over chat while it does real GDD work —
edit, commit, PR, merge — inside the container.

The capability is **agnostic**: it is not tied to any one site or person. No
user- or site-specific content lives here (that belongs in the user's own realm
repo and their site component).

> **This is not a way to share a Claude subscription.** Everyone the sandbox
> serves is being helped toward *their own* Claude plan and their own logins.
> Hosting (whose machine runs the container) is deliberately separate from
> entitlement (whose subscription and tokens it uses) — managed hosting, not a
> shared account, with the end goal of a self-sufficient user.

## Prerequisites (one-time, human)

1. **Docker** running. Use `ws docker …`, which handles Windows path conversion.
2. A **Claude setup-token**: run `claude setup-token` once on a machine with a
   browser and a subscription; it prints a long-lived OAuth token. Put it in your
   secrets file as `CLAUDE_CODE_OAUTH_TOKEN`.
3. A **Discord bot**: Developer Portal → New Application → Bot tab → enable
   **Message Content Intent**, turn **off** Public Bot, Reset Token (→
   `DISCORD_BOT_TOKEN`); OAuth2 URL Generator → scope `bot` with View Channels,
   Send Messages, Send in Threads, Read Message History, Attach Files, Add
   Reactions → Guild Install → add it to a private server you own.
4. Your **Discord user snowflake** (enable Developer Mode → right-click your
   avatar → Copy User ID) for the allowlist.

The secrets file must be **LF-only, no BOM, no leading whitespace** — a CR rides
into the token value and leading space breaks the variable name. **Never add
`ANTHROPIC_API_KEY`**: it outranks the OAuth token and silently switches to
metered API billing (`bin/run.sh` refuses a secrets file containing it).

## Quickstart

```bash
# Build the image (one tag; cache-warming lives in the Dockerfile).
bash bin/build.sh

# Start a sandbox for one target component.
bash bin/run.sh --target <component> --allowfrom '["<your-snowflake>"]'

# Watch it come up.
ws docker exec gdd-sandbox-<component> tail -f /tmp/channels-tty.log
```

Then DM the bot from Discord. It reacts 👀 when a message is received and
allowlisted, and replies when the agent has an answer.

## How it stays alive

- **Crash recovery** — a supervisor relaunches the session with `--continue`,
  recovering the single most-recent session.
- **Deliberate rotation** — when context has grown too large, `bin/rotate.sh`
  archives the session and starts a fresh one that re-orients from the persistent
  Thalamus. Safe precisely because the durable notes carry the important state.
- **Health** — a container healthcheck asserts the session process is alive and
  its log is fresh; Docker's restart policy covers whole-container death. Nothing
  about liveness leaks into a user's chat.

A dead session that silently ghosts the person texting it is the exact failure
this design cures.

## Safety

The container holds only the in-scope repositories, so out-of-scope work is
impossible by *absence* rather than by a rule the agent could talk around. Only
the chat `reply`/`react` tools are pre-allowed; everything else stays gated.
Consequential decisions (merge, publish) are asked in chat as **outcomes** in
human terms — never as raw tool prompts, which a non-technical person cannot
meaningfully judge.

## What's here

| Path | What |
|---|---|
| `Dockerfile` | Toolchain + baked agnostic GDD-core seed + warmed dependency caches + healthcheck |
| `bin/build.sh` · `bin/run.sh` | Host: build the image; start + provision + supervise a sandbox |
| `bin/supervise.sh` · `bin/rotate.sh` · `bin/send.sh` | In-container: session lifecycle, rotation trigger, keystroke driver |
| `provision/` | Provisioning: workspace seeding, onboarding patch, access allowlist, safe-posture settings |
| `.agent/skills/gdd-sandbox/` | The operator skill — the detailed how-to |
| `docs/plans/` | Design and implementation plan |

Run the tests with `ws test gdd-sandbox` and the linter with `ws lint gdd-sandbox`.
