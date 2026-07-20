# gdd-sandbox — Sandboxed GDD Workspace — Design

**Date:** 2026-07-20
**Status:** Design (awaiting author review → writing-plans)
**Arc:** `gdd-tenant-sandbox` (thalami hoard, `Nano76Win11-thalamus.md`) — reframed; see "Vocabulary" below
**Related:** `hoards/thalami-Cervator/kencierge-sandbox/` (proven channels-gate recreate kit), `templates/components/gh-pages/` (the site stack the first pilot targets), `docs/gdd/roadmap.md` (Assisted access + Sandboxed workspaces tracks), `docs/plans/2026-07-16-pr-preview-unit1.md` + `2026-07-19-pr-preview-unit2.md` (the preview/diff pipeline a concierge later drives).

---

## Purpose

Build and run a **sandboxed GDD workspace**: a Docker container holding a
scoped GDD agent, reachable over a chat channel (Discord today), pointed at one
target component to work on. A non-technical person collaborates with the agent
over chat; the agent does real GDD work (edit → commit → PR → merge) inside the
container.

This spec (#1) covers the **runtime only** — a robust, safe container that stays
alive, recovers, and is positively scoped. The web-development *persona* that
drives a site for a non-technical user, the gh-pages template enhancements it
relies on, and the user-support features around it are **separate, later specs**
(see "Layered scope" and "Out of scope").

### Vocabulary — this is not subscription sharing

The word "tenant" is retired from this work. The sandbox is **not** a way to
share one Claude subscription with other people. Every person it serves is being
helped toward **their own** Claude plan and their own logins. The project splits
cleanly into:

- **Hosting** (compute — the author's box or cluster runs the container), and
- **Entitlement** (the Claude plan, GitHub token, Discord bot — owned by the
  person being served).

The sandbox is about hosting compute and shaping the workflow so a non-technical
user can get productive and, ultimately, self-sufficient — never about resold or
shared entitlement. Docs and code both state this plainly.

## Layered scope (what this component is, and is not)

Four layers came out of the design discussion. This component is **Layer A only**:

- **A — Sandboxed workspace (this component, `gdd-sandbox`).** The general,
  agnostic capability: build + run the container, wire the chat channel, keep it
  alive, keep it scoped. No user- or site-specific content ever.
- **B — `gdd-webdev-concierge` (a root GDD skill, later).** The non-technical
  web-user *persona*: drive edit → PR → preview → visual-diff → "ship it" against
  a gh-pages site. Independent of the sandbox (works attended too); softly pairs
  with it and with the enhanced gh-pages template.
- **C — gh-pages template + tutorial enhancements (later).** Graduate the
  PR-preview + visual-diff pipeline (Units 1+2, already shipped on `ken-site`)
  into `templates/components/gh-pages/` so a concierge has previews to rely on.
- **D — User support (later).** `ws share` transcript handoff, observability-stack
  liveness wiring. Advanced.

The first pilot — helping a non-technical friend maintain a GitHub-Pages campaign
site — is the **validation vehicle** for Layer A, not extra scope. All
user-specific opinionation for that pilot lives in the user's own realm repo and
their site component, never here.

## Design decisions (author-approved 2026-07-20)

| Decision | Choice | Rationale |
|---|---|---|
| Component name | `gdd-sandbox` | Agnostic from day one; no rename debt. "kencierge" is only informal shorthand for a specific running instance. |
| Scope of spec #1 | Layer A runtime only (3a) | Robustness + safety validate cleanly without the web persona; protects the agnostic boundary. |
| Workspace model | Self-contained GDD workspace in the container | Gives `ws`, orientation, skills, realm, Thalamus — needed for session rotation + re-orientation; works for a remote user with no host workspace. |
| Immutability split | Toolchain **baked** (immutable, tagged image); workspace **mutable** git checkout on a named volume | GDD stays improvable from inside and the site stays git-tracked; reproducibility lives at the toolchain layer. |
| Workspace seeding | GDD core **baked at build** as a seed, freshened by `ws pull`; realm + target cloned at run | Fast first start + known-good baseline; base image stays agnostic. |
| Dependency caches | Optional **per-flavor build layer** (`--build-arg FLAVOR=…`) warms gem / Node / Playwright caches | Runtime builds start warm once Layer C adds heavy deps; base image stays agnostic. |
| Crash recovery | supervisor relaunch with `claude --continue` | One session ever → continue-most-recent needs no session-id tracking. |
| Context hygiene | deliberate **session rotation** (archive → fresh → re-orient), primitive here; watch/advise later | Long-lived sessions bloat toward compaction; a fresh session re-orients from the persistent Thalamus. |
| Safety posture | pre-allow only `reply`/`react`; deny-by-absence via workspace content; **no bypass-all** | Trusted-pilot posture; the container holds only in-scope repos, so out-of-scope simply does not exist. |
| Channel (pilot) | shared private Discord channel (operator + user + bot) | Better visibility + live 3-way collaboration than a user-only DM. |
| Secrets | two channels — runtime (`--env-file`) vs workspace (`.env` on the volume) | Runtime auth never touches the workspace; the user's push token lives with the workspace, git-ignored. |

## Architecture

### Component layout

```
components/gdd-sandbox/
  AGENTS.md                             # small — points the agent at the operator skill
  README.md                             # operator how-to (WIP stub exists)
  Dockerfile                            # base toolchain image (from the recovered kit)
  .agent/skills/gdd-sandbox/SKILL.md    # component-level operator skill (first of its kind)
  bin/
    build.sh                            # build the image (ws docker, Windows-path aware)
    run.sh                              # run a sandbox: --target <component> [...]
    supervise.sh                        # in-container supervisor (script+FIFO+--continue) + rotation
    send.sh                             # keystroke driver for one-time prompts (from kit)
  provision/
    patch-onboarding.py                 # mark Claude first-run onboarding complete (from kit)
    access.json.template                # Discord allowlist template (snowflakes injected at run)
  docs/plans/                           # this design doc
```

### The image (baked toolchain + GDD-core seed)

Debian-slim, from the proven kit: git/bash/curl/jq/unzip, mikefarah `yq`, `gh`,
Node LTS, Bun (the Discord channel plugin's MCP server runtime), Ruby + Jekyll +
Bundler, and the `claude` native binary — plus the `ws` CLI prerequisites so a full
GDD workspace runs. Auto-update disabled so the tagged image is reproducible.

The image also **bakes a clone of the agnostic GDD core** (the `yggdrasil`
workspace root) as a seed, so first-run startup is fast and the image is a
known-good baseline; a runtime `ws pull` freshens it if the image has aged. It
bakes **no realm, no target component, and no credentials** — those are
per-instance and arrive at run time (realm + target cloned into the workspace,
secrets injected). Baking only the agnostic core keeps the image reusable across
pilots.

**Optional dependency cache-warming (build-arg driven).** A build can pre-warm the
caches a target flavor needs — for gh-pages that means the `bundle install` gem set
and the visual-diff Node/**Playwright** stack (the browser binaries are the
expensive download). Structured as a **per-flavor build layer**
(`--build-arg FLAVOR=gh-pages`) so the base image stays agnostic and each flavor
warms its own deps. The concrete gh-pages dep set lands when Layer C graduates the
preview/diff pipeline into the template; the *mechanism* is specced now (and
dovetails with the roadmap's "more template flavors" item).

### The workspace (mutable, on a volume)

On first run the container **seeds** a self-contained GDD workspace onto a named
volume from the baked-in `yggdrasil` clone, runs `ws pull` to freshen it, then
clones the **realm** and the one **target component** (under
`components/<target>/`) per the run args. Working dir is the **workspace root**
(where `ws orient` runs), *not* the target directory. Public repos clone read-only
with no token; pushing needs the workspace push token (below). The volume persists
across restarts, carrying the git checkouts, the Thalamus, and
`~/.claude/channels/` (pairing) + session history for `--continue`. On a restart
where the volume already holds a workspace, the seed step is skipped and `ws pull`
just freshens.

**Scoping fence = workspace content.** Only in-scope repos are cloned, so
out-of-scope repos do not exist inside the container to be touched — positive
scoping by absence, under the hook layer, not a rule the agent can talk around.

### Build + run interface

- `build.sh` → `ws docker build -t gdd-sandbox:<tag> <context>` (Windows-style
  build-context path; MSYS mangles `/d/…`). Accepts an optional `--flavor <name>`
  → `--build-arg FLAVOR=<name>` to warm that flavor's dependency caches (above).
- `run.sh --target <component> [--name <n>] [--channel …]`:
  1. Resolve the target's repo from `ecosystem`/realm config.
  2. `ws docker run -d --restart unless-stopped --env-file <runtime-secrets>`
     with the workspace named volume attached; **no host repo mounts**.
  3. Provision: seed the workspace from the baked GDD-core clone + `ws pull`, then
     clone realm + target (first run only); `claude plugin marketplace add` +
     `plugin install discord@…`, seed `access.json` from the template +
     snowflakes, patch onboarding.
  4. Start `supervise.sh`.

  `--target` takes one component now; the argument shape allows multiple later
  (a workspace can hold more than one in-scope component).

### Runtime robustness

`supervise.sh` owns the session lifecycle. Two distinct paths:

- **Crash recovery** (power loss, process death): relaunch the PTY session
  (`script` + a FIFO held open by a background writer) running
  `claude --continue --channels plugin:discord@… --permission-mode <safe>`.
  `--continue` recovers the single most-recent session; the first launch starts
  fresh. Backoff between relaunches; log to a tty log the healthcheck reads.
- **Deliberate rotation** (context pressure, on a clear signal): **archive** the
  current session, start a **fresh** session (no `--continue`), and **re-orient**
  by running `ws orient` — which reads the persistent Thalamus — then confirm the
  bot is back online. This is how a long-lived pilot sheds accumulated context
  without losing the important details, which live in durable notes anyway.

Supporting mechanisms:

- **Docker `--restart unless-stopped`** restarts the whole container if it dies.
- **`HEALTHCHECK`** = claude process alive + tty-log freshness (process-level; no
  chat involved, so nothing leaks to an open channel).
- **Chat-level liveness** ("is it really answering?") rides the operator's private
  PM to the agent — manual now, scriptable later. Full observability-stack wiring
  is Layer D.

### Safety posture

- **Pre-allow only** the Discord `reply`/`react` tools (namespaced
  `mcp__…discord…`) so they never prompt; everything else stays gated by the stock
  hooks. **No `--dangerously-skip-permissions` / bypass-all** — the validation
  container's bypass mode is explicitly *not* the production posture.
- **Deny-by-absence** via workspace content (above): the container holds only
  in-scope repos.
- **Consequential decisions** (merge / publish) surface as **chat questions in
  human terms** ("here's the preview + diff — say 'ship it'"), owned by the
  concierge skill later, not by the permission system. The user approves
  *outcomes*, never raw tool calls — relaying a raw "allow this tool?" prompt to a
  non-technical user is the rubber-stamp trap we avoid.
- **Deferred to the untrusted / OpenShell phase:** a real hook deny-globs policy
  (GDD has no clean knob for this today). Trusted-pilot + content-scoping covers
  spec #1.

### Component-level skill + `AGENTS.md`

`gdd-sandbox` carries GDD's **first component-level skill** — the operator skill
that knows how to build, run, provision, supervise, and rotate the sandbox. The
agent discovers it via the component's `AGENTS.md` when working here (the standard
agent-instructions convention). Whether `ws orient` should also surface a
component-skill *tier* is a small **open follow-up** to confirm during planning —
not a blocker, since `AGENTS.md` discovery already works.

### Secrets — two channels

1. **Runtime / operator secrets** — Claude OAuth token (`CLAUDE_CODE_OAUTH_TOKEN`)
   + Discord bot token (`DISCORD_BOT_TOKEN`) → injected via `--env-file` at
   `docker run`, from the operator's `.env`. Never written into the workspace,
   never git-tracked. **Never `ANTHROPIC_API_KEY`** — it outranks the OAuth token
   and silently flips to metered billing. LF-only env file (CRLF/BOM corrupts
   `--env-file`). This is the seam that later becomes k8s-secrets / OpenShell
   egress-injection without changing the launch contract.
2. **Workspace secret** — the target repo's **push token = the user's own GitHub
   PAT** → lives in the workspace `.env` on the volume (git-ignored), used by
   `ws push` / `gh`. For spec #1 the operator **co-sets it once at onboarding**
   (the token ceremony is the genuinely hard part of a non-technical setup — do it
   together once, then GDD does the rest). The self-service path — GDD hands the
   user a prepopulated token-create URL, they paste the result to the bot, the
   sandbox writes it — is a concierge/onboarding feature (Layer B, later).

### Hosting spectrum (design seam, not spec-#1 work)

The runtime-secret resolver in `run.sh` is a seam so the same container carries a
progression the pilot user never sees:

1. **Now:** plain Docker on the operator's homelab box, operator's `.env`.
2. **Next:** the user's *own* Claude plan + token, fed to a Docker workspace still
   hosted by the operator.
3. **Further out:** the workspace as a **pod in the operator's k8s cluster**,
   pulling the token from k8s secrets — all out of the non-technical user's sight.

"GDD-via-k8s" as a general execution target is a post-OpenShell future, explicitly
out of scope here but noted so the token seam does not wall it out.

## Validation plan

- **Spike A — `--continue` + `--channels`:** does a restarted session recover
  context under the channel plugin? If not, the supervisor falls back to
  fresh-session semantics (rotation-style, no continue); acceptable because the
  Thalamus persists the important details regardless.
- **Re-confirm the channels round-trip** on the rebuilt image (proven once on
  `gdd-sandbox:proto`, 2026-07-18).
- **Anti-ghosting proof:** kill the session → supervisor restarts → a *fresh*
  inbound is still answered (the exact failure mode being cured).
- **Rotation proof:** trigger a deliberate rotation → old session archived, fresh
  session re-oriented from the Thalamus, bot back online.
- **Pilot:** shared private Discord channel (operator + user + bot); a basic
  exchange proves liveness + supervision + posture end-to-end.
- **Tests:** the component's `ws test` adapter — shellcheck/bats over the scripts;
  an opt-in smoke test that builds the image and runs the round-trip when a token
  is present (skips cleanly without secrets, e.g. in CI).

## Out of scope (deferred — later specs / arcs)

- **`gdd-webdev-concierge` skill** (Layer B) — the web-user persona + the
  context-watch-and-advise logic (the gentle "time to restart?" prompt), beyond the
  operator-notify-during-dev slice.
- **gh-pages template + tutorial enhancements** (Layer C) — graduating Units 1+2.
- **User support** (Layer D) — `ws share`, observability-stack liveness wiring.
- **Hosting evolution** — user-owned token, GKE pod, k8s secrets; GDD-via-k8s.
- **Untrusted users / OpenShell** — egress token injection, boundary-enforced
  policy, hook deny-globs. The same image drops in via BYOC when that phase comes.
- **Multi-target execution** — the `--target` shape allows it; only single-target
  is implemented now.
- **Container-per-session isolation for the operator's own parallel work** — a
  real general-purpose upside (isolates 2-3 concurrent agent sessions), noted but
  not built here.

## Success criteria

- A `gdd-sandbox` container runs a self-contained GDD workspace scoped to one
  target component and is reachable over a private Discord channel.
- It survives process death and container restart, answering a fresh inbound
  afterward — no silent ghosting.
- A deliberate session rotation archives the old session and brings up a fresh,
  re-oriented one.
- The safety posture holds: only `reply`/`react` are pre-allowed, no bypass-all,
  and out-of-scope repos are absent from the container.
- Nothing in the component is user- or site-specific, and the docs state plainly
  that this is hosting, not subscription sharing.
