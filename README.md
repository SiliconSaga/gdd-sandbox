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

## Status

Validated live on 2026-07-26 against a real Discord bot and a real site component
(`ken-site`), on a Claude subscription token in a plain Docker container.

**Working end to end**

- Provisioning: workspace seeded from the baked GDD core, target component cloned,
  channel plugin installed, allowlist and onboarding configured.
- The chat loop: a direct message reaches the agent and a reply comes back, with no
  permission card and no API key.
- Crash recovery: the supervisor relaunches a dead session with `--continue`, and
  context survives — a session recalled a fact set the previous day, across a full
  container stop/start.
- Deliberate rotation: `rotate.sh` archives the session and brings up a fresh one.

**Not yet done** (roughly in the order they should be tackled)

1. **A container restart does not restore the session.** `supervise.sh` is started
   with `docker exec -d`, so it dies with the container; the restart policy then
   brings the container back running only `sleep infinity`. This breaks the central
   promise — an agent that stops answering with no outward sign is the exact failure
   this design exists to cure. Fix: bake the scripts into the image and make the
   entrypoint run provisioning then supervision, so Docker's restart policy actually
   restores the agent.
2. **The healthcheck is wrong.** It requires the session log to be recent, but a
   session idling correctly between messages writes nothing, so a healthy sandbox
   reports `unhealthy`. Use process liveness; detecting a genuinely wedged session
   needs a real probe.
3. **The permission posture is incomplete.** Only the chat `reply`/`react` tools are
   pre-allowed, so anything else still relays a permission card to the chat user.
   Asking a non-technical person to approve "run jekyll build?" teaches them to tap
   Allow reflexively — worse than no gate. Routine work tools need pre-allowing and
   destructive ones hard-denying before any real pilot.
4. **Shared channels are unsupported.** `access.json.template` only expresses direct
   messages. A shared channel (operator + user + agent, the intended pilot setup)
   needs a `groups` entry keyed on the channel id plus a mention policy, and `run.sh`
   needs a flag to pass one.

**A failure mode worth knowing about.** A long-lived session can accumulate
*failure* context and reason itself into not attempting an action at all — not
broken, just confidently unhelpful, which from the outside looks identical to a
working agent with nothing to say. Rotation clears it. This is why "is the process
alive?" is a weak health signal, and why an agent declining to act should surface to
the operator rather than only to the person waiting on a reply.

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

## Known upstream quirks

Workarounds we carry for bugs in dependencies. Each states the condition under
which it should be **removed** — a workaround without a removal test becomes a
mystery nobody dares delete.

### The bot's own id must be in the Discord allowlist

- **Observed in:** `discord@claude-plugins-official` **0.0.4**
- **Symptom:** an inbound DM is received (👀 reaction fires, the agent composes an
  answer) but every reply is rejected as *"channel … isn't allowlisted"*.
- **Cause:** the outbound gate does `ch.recipientId ?? dmChannelUsers.get(id)`. In
  the plugin's long-lived client `ch.recipientId` resolves to the **bot's own id**,
  not the human's. Being non-null it short-circuits the `??`, so the map holding
  the correct id is never consulted and the allowlist check fails.
- **Workaround:** `provision.sh` reads the bot's id from `/users/@me` and adds it to
  `allowFrom`, so the plugin's own check passes. Nothing is hardcoded.
- **Why it is safe:** the bot never DMs itself, and replies only ever target
  channels a message arrived on. It is also fail-safe — if upstream starts
  returning the human's id, `allowFrom` still contains it.
- **Remove when:** `bin/check-plugin-quirks.sh` reports the plugin version or the
  gate expression has changed *and* a live DM reply succeeds without the bot's id
  in `allowFrom`.

**Do not "verify" this with a standalone probe.** Fetching the channel with a
fresh client returns the *correct* recipient id, so a probe reports the bug fixed
while the live path still fails. Reproducing it requires the plugin's own
long-lived client state. That false signal cost two debugging sessions; the canary
therefore watches for upstream *change* rather than trying to re-detect the bug.

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
