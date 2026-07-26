---
name: gdd-sandbox
description: Use when building, running, supervising, or rotating a sandboxed GDD workspace container — the scoped agent reachable over a chat channel.
---

# gdd-sandbox — operator skill

Operational guide for the sandboxed GDD workspace: a container running a scoped
GDD agent, reachable over Discord, pointed at one target component.

This is **hosting compute, not subscription sharing**. Everyone the sandbox serves
is being helped toward their own Claude plan and their own logins; hosting (whose
machine runs it) is deliberately separate from entitlement (whose subscription and
tokens it uses).

## When to Use

- Building or rebuilding the sandbox image.
- Starting a sandbox for a target component.
- Diagnosing a session that stopped answering.
- Rotating a long-lived session that has accumulated too much context.

## Build

```bash
bash bin/build.sh                          # tag gdd-sandbox:latest, context = component dir
bash bin/build.sh --tag gdd-sandbox:proto  # explicit tag
```

One tag serves every use — dependency cache-warming lives in the Dockerfile, not
in per-flavor build args. The image bakes the toolchain plus an agnostic GDD-core
seed at `/opt/gdd-seed`; **no realm, no target, no credentials** are baked in.

## Run

```bash
bash bin/run.sh --target <component> --allowfrom '["<discord-user-snowflake>"]'
```

Options: `--name` (default `gdd-sandbox-<target>`), `--secrets` (default the
workspace-root `.env`), `--target-repo` / `--realm-repo` (default resolved from
`ecosystem.local.yaml`).

`run.sh` starts the container with a named workspace volume and
`--restart unless-stopped`. The scripts are baked into the image, and its
**entrypoint** runs provisioning then supervision — so Docker's restart policy
actually restores the agent. (A supervisor started with `docker exec -d` dies with
the container, leaving it "up" with nobody listening.) Watch it come up:

```bash
ws docker exec <name> tail -f /tmp/channels-tty.log
```

## Two secret channels — keep them separate

1. **Runtime / operator secrets** — `CLAUDE_CODE_OAUTH_TOKEN` +
   `DISCORD_BOT_TOKEN`, injected via `--env-file`. Never written into the
   workspace, never git-tracked. This is the seam that later becomes k8s secrets
   or an egress-injection proxy.
2. **Workspace secret** — the user's *own* GitHub PAT, in the workspace `.env` on
   the volume (git-ignored), used by `ws push` / `gh`. Co-set once with the user
   at onboarding; the token ceremony is the genuinely hard part of a non-technical
   setup, so do it together once and let GDD handle everything after.

**Never set `ANTHROPIC_API_KEY`** — it outranks the OAuth token and silently flips
to metered API billing. `run.sh` refuses a secrets file that contains it. Env
files must be **LF-only with no BOM**; a CR rides into the token value and a
leading space breaks the variable name.

## Session lifecycle

`bin/supervise.sh` keeps a PTY-hosted `claude --channels` session alive. Two paths:

- **Crash recovery** (power loss, process death) — relaunches with `--continue`,
  recovering the single most-recent session. Automatic; capped backoff.
- **Deliberate rotation** (context has grown too large) — run:

  ```bash
  ws docker exec <name> bash /opt/gdd-sandbox/bin/rotate.sh
  ```

  This archives the current tty log and launches a **fresh** session (no
  `--continue`), which re-orients from the persistent Thalamus per `AGENTS.md`.
  Rotation is safe *because* the durable notes carry the important state — that is
  the whole point of shedding context.

A one-time interactive prompt can be answered by writing a keystroke into the
session FIFO:

```bash
ws docker exec <name> bash /opt/gdd-sandbox/bin/send.sh enter
```

## Liveness

Process-level only, so nothing leaks into a user's chat:

```bash
ws docker inspect --format '{{.State.Health.Status}}' <name>
```

The healthcheck asserts the channels process is alive *and* its tty log is fresh
(<120s). Docker's restart policy covers whole-container death; the supervisor
covers session death. A dead session that silently ghosts the person texting it is
the exact failure this design cures — treat an `unhealthy` state that does not
self-clear as urgent.

For a chat-level "is it really answering?" check, DM the bot from the operator
account. Wiring liveness into an observability stack is a later addition.

## Safety posture

- Pre-allow **only** the chat `reply`/`react` tools, via `--allowedTools` on the
  launch command in `bin/supervise.sh` (override with `GDD_ALLOWED_TOOLS`), so they
  never prompt. **Never** `--dangerously-skip-permissions` / bypass-all in
  production — the proto used bypass only to isolate the auth round-trip.
  A `--settings` file with `permissions.allow` was verified live NOT to grant MCP
  tools; `--allowedTools` is the mechanism that works. Ids are
  `mcp__plugin:discord:discord__reply` / `__react`.
- **Known gap:** anything *not* pre-allowed still relays a permission card to the
  chat user. For a non-technical user that is the rubber-stamp trap — routine work
  tools need pre-allowing and destructive ones hard-denying before a real pilot.
- The workspace holds only in-scope repos, so out-of-scope work is impossible by
  absence rather than by a rule the agent could talk around.
- Consequential decisions (merge, publish) belong in chat as **outcome** questions
  in human terms, owned by the concierge workflow — never as raw tool prompts.

## Known caveats

- `--channels` is a hidden research-preview flag; the protocol may change. Keep the
  dependency isolated behind the supervisor.
- After a container restart, the plugin's in-memory DM map is empty — always answer
  a **fresh** inbound message; replying to one that predates the restart fails the
  outbound allowlist check.
- The Claude OAuth token expires roughly yearly and does not auto-renew; rotate it
  deliberately.
- On a Windows host, native `jq` mangles leading-slash arguments via MSYS argv
  conversion. The test suite detects this and skips the affected assertion; it runs
  for real in-container. Do **not** "fix" it by toggling `MSYS2_ARG_CONV_EXCL` or
  `MSYS_NO_PATHCONV` — that has caused real Windows/Linux breakage. Use `ws docker`,
  which handles path conversion properly.
