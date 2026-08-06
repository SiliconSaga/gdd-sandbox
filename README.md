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

- Restart survival: supervision is the container's entrypoint, so Docker's restart
  policy restores the agent rather than bringing back a container with nobody
  listening.

**Not yet done** (roughly in the order they should be tackled)

1. **The permission posture is bounded, not complete.** The chat tools, the routine
   work tools, and fetching a file someone dropped in chat are pre-allowed;
   destructive and irreversible ones are hard-denied. What remains is everything in
   neither list: `--permission-mode auto` classifies those, and anything it will not
   decide still relays a permission card to the chat user. Asking a non-technical
   person to approve "run jekyll build?" teaches them to tap Allow reflexively —
   worse than no gate — so a card reaching them is a gap for the operator to close,
   not a question for them to answer.
2. **An injected attachment can still cause pre-merge noise.** A file dropped in
   chat is untrusted input, and the agent reading it can write to its workspace,
   push a branch and open a pull request without a card. The briefing tells it to
   treat a file as content rather than instructions, but that is guidance, not
   enforcement. Nothing reaches the live site — publishing needs branch protection
   plus a human merge, which the agent is denied — so the exposure is a bogus PR
   in one scoped repository. Accepted knowingly: the enforcement alternative is a
   permission card in front of ordinary work, shown to someone who cannot evaluate
   it, which teaches the reflex that would defeat every other gate here.
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
- **Health** — the healthcheck asserts three things in order: the session process
  is up and past its startup window, its channel server exists, and Discord is
  actually reachable with the bot's credentials. The last one matters because the
  agent does not exit when its channel dies, so process checks alone report health
  while nobody can be reached. Nothing about liveness leaks into a user's chat.
- **What restarts, and what does not.** A dead channel *process* restarts the
  session. An unreachable *network* does not: the Discord client reconnects on its
  own, and cycling the session over a brief outage would throw away context to no
  purpose. The outage shows up as `unhealthy` and is left to resolve itself — a
  deliberate split between "broken, act" and "degraded, wait".

A dead session that silently ghosts the person texting it is the exact failure
this design cures.

**The host runtime is part of the chain.** A restart policy only fires if the
container runtime is running, so on a machine where Docker starts manually the
sandbox stays down after a reboot until someone opens it — recovery that looks
automatic in testing because a human quietly supplied the missing step. For an
always-on sandbox, enable the runtime's auto-start, or host it where the daemon
runs as a system service.

## Safety

The container holds only the in-scope repositories, so out-of-scope work is
impossible by *absence* rather than by a rule the agent could talk around. What is
pre-allowed is chat, reading and writing files in the target, the `ws` verbs up to
opening a pull request, and downloading a file the user sent; merging, releasing
and destructive commands are denied outright. Consequential decisions (merge,
publish) are asked in chat as **outcomes** in human terms — never as raw tool
prompts, which a non-technical person cannot meaningfully judge.

## Giving the sandbox a GitHub identity

The agent can draft without any GitHub access at all — it edits files on its own
volume and stops. It only needs credentials to publish, and it should have its own
rather than borrow anyone's.

**Set up once, with the person you are helping:**

1. **Create a dedicated GitHub account** for the sandbox. This is the identity its
   commits are attributed to, so agent-authored history stays honest about who
   wrote what, and revoking access is one token rather than an audit.
2. **Give that account access to the target repository only** — as a collaborator
   on that one repo. Nothing else you own is visible to it.
3. **Issue a fine-grained personal access token** on that account, scoped to that
   single repository, with Contents and Pull requests write. The scoping is what
   bounds the blast radius: not a promise the agent will behave, but a grant that
   cannot reach further.
4. **Protect the default branch** so changes have to arrive as pull requests.
5. Put the token in the operator's env file as **`GDD_GITHUB_TOKEN`**. The name is
   deliberately distinct from `GH_TOKEN`, so the operator's own credentials cannot
   be picked up by mistake — same file, different variable, and only this one is
   passed through.

Provisioning installs it into the workspace's git-ignored `.env` and sets the
commit identity. It is never written into the image, never passed as a command-line
argument (those are visible to anyone listing processes), and never logged.

**What it may and may not do with that access.** The agent can branch, commit,
push and open a pull request without prompting — that is routine mechanics, and a
permission card asking a non-technical person to approve it protects nothing.
Merging and releasing are denied outright, not merely left unapproved, so the
change reaches the live site only when a human clicks merge on a PR that shows
them the preview and the screenshots. Branch protection is what makes that hold;
without it the merge button is not the only way in.

**Why a scoped account rather than a fork.** Forking is the more usual isolation
story, but a pull request *from a fork* gets a read-only token in CI, which
disables the preview build and the visual-diff comment — exactly the evidence a
non-technical reviewer relies on. A dedicated account with a single-repo grant gets
the same practical blast radius while keeping the review surface intact. The fork
route is the right answer when the sandbox serves someone you do not know
personally, and it needs the CI split into build and trusted-publish stages first.

## Configuration

Settings live in the operator's env file (the workspace `.env` by default, or
whatever `--secrets` points at). Per-launch choices are flags on `run.sh`.

### What the sandbox needs to work

| Setting | What it is |
|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | Subscription token from `claude setup-token`. This is what the agent runs on — no API key, no metered billing. **Never set `ANTHROPIC_API_KEY`**: it outranks this and silently switches to paid API calls. `run.sh` refuses a file containing it. |
| `DISCORD_BOT_TOKEN` | The bot's token, from the Developer Portal. How it reaches the chat channel. |

With only these two, the sandbox runs and can read, edit and commit — it simply
cannot publish. That is a legitimate mode, and preflight reports it as such rather
than treating it as broken.

### What it needs to open pull requests

| Setting | What it is |
|---|---|
| `GDD_GITHUB_TOKEN` | The **sandbox's own** token, from its dedicated machine account. Deliberately not called `GH_TOKEN`, so the operator's personal credentials in the same file cannot be picked up by mistake — only this one is passed through. |
| `GDD_GITHUB_USER` | The machine account's name. Becomes the commit author. |
| `GDD_GITHUB_EMAIL` | The machine account's email. Use its **no-reply** address: if the account hides its real address, the code host rejects the push *after* the work is done. |
| `GDD_HUMAN_ACCOUNT` | The site owner's account on the code host. Plumbing that `ws cr` expects; it does not appear in the pull request body. Without it the agent stops mid-task to ask, rather than guessing a handle that might belong to a stranger. |

### Worth setting

| Setting | What it is |
|---|---|
| `GDD_OPERATOR_CHAT` | Your own chat id. When the agent is blocked, the person who asked gets plain language and **you get the technical detail by direct message**. Nothing else is watching this sandbox, so that message is the alert. |
| `GDD_BRIEFING_EXTRA` | Free text appended to the agent's briefing: what this site is, who reads it, house style — anything the shipped briefing cannot know. Takes effect on restart, no rebuild. |
| `GDD_PUBLIC_EMAIL_OK` | Set to `1` to declare that a non-no-reply commit email is deliberate, so preflight stops advising about it. |
| `GDD_MODEL` | Which model the session runs on. Defaults to `opus`: the work is published under someone else's name, and the failure that matters is a change that is literally correct and semantically wrong, which is a reasoning failure. Set `sonnet` for a cheaper, faster sandbox, or leave it **empty** to inherit whatever your account defaults to. Applies at session launch, so a running session keeps its model until it restarts or you rotate it. |

### Per-launch flags

```bash
bash bin/run.sh --target <component> [options]
```

| Flag | Meaning |
|---|---|
| `--target` | **Required.** The component the sandbox is scoped to. |
| `--allowfrom` | JSON array of chat user ids allowed to send direct messages. |
| `--channel` | A shared channel id to work in. Guild channels are disabled until opted in this way. |
| `--no-mention` | Respond to everything in that channel. Default is to require a mention, which keeps the agent quiet while humans talk to each other. |
| `--name` | Container name. Defaults to `gdd-sandbox-<target>`. |
| `--secrets` | Path to the env file. Defaults to the workspace `.env`. |
| `--target-repo`, `--realm-repo` | Override the repositories to clone; the target is otherwise resolved from ecosystem config. |

### Tuning

The watchdogs, health thresholds, permission lists and file paths are all
overridable — see the `${GDD_...:-default}` lines at the top of `bin/supervise.sh`,
`bin/healthcheck.sh` and `bin/preflight.sh`. The defaults are what this component
was tested with; change them to debug, not routinely.

**One exception, deliberately asymmetric:** `GDD_ALLOWED_TOOLS` replaces the allow
list, because narrowing what the agent may do is always safe. `GDD_DENIED_TOOLS`
*adds to* the deny list rather than replacing it — otherwise adding a rule of your
own would silently carry off the merge, release and `rm` denials, and "never
merges" is meant to be enforced rather than assumed. To drop a built-in denial you
have to edit the script, which is the sort of change that should be visible in a
diff.

### Checking it

Provisioning runs `bin/preflight.sh` on every start and reports anything missing,
graded by whether it blocks work, degrades it, or merely stores up an
interruption. The same report is written where the agent reads it, so an
under-configured sandbox says what it cannot do when asked, instead of failing
partway through. Run it any time:

```bash
ws docker exec <name> bash /opt/gdd-sandbox/bin/preflight.sh
```

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
