# gdd-sandbox Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the `gdd-sandbox` runtime — a Docker image + host/in-container scripts that run a scoped, self-contained GDD workspace reachable over Discord, that stays alive (crash recovery + deliberate session rotation) and is positively scoped.

**Architecture:** A baked toolchain image (immutable, one tag) carries the GDD core as a seed; at run time a host script (`run.sh`) starts the container, an in-container script (`provision.sh`) seeds the mutable workspace onto a named volume and installs the Discord channel plugin, and a supervisor (`supervise.sh`) keeps a PTY-hosted `claude --channels` session alive — `--continue` on crash recovery, fresh-and-re-oriented on deliberate rotation. Script logic is TDD'd with bats; the container/live pieces are validated by explicit build + round-trip spikes.

**Tech Stack:** Bash, bats-core (test runner), shellcheck (lint), Docker (via `ws docker`), Debian-slim base, `claude` native CLI + the official Discord channel plugin (Bun MCP server), Python 3 (onboarding patch), `ws` CLI.

## Global Constraints

Copy these verbatim into every relevant task — they are project-wide:

- **Never set `ANTHROPIC_API_KEY`** in the container env — it outranks `CLAUDE_CODE_OAUTH_TOKEN` and silently flips to metered API billing.
- **Env files are LF-only, no BOM, no leading whitespace** — CRLF/BOM corrupts `--env-file` (the CR rides into the token; leading WS breaks the var name).
- **`--continue`, never `--resume`** — one session ever, so continue-most-recent needs no session-id tracking.
- **Production posture: pre-allow ONLY the Discord `reply`/`react` tools; NO `--dangerously-skip-permissions` / `bypassPermissions`.** The proto's bypass mode was validation-only.
- **The image bakes only the agnostic GDD core (`yggdrasil`) + toolchain.** No realm, no target component, no credentials, no user/site content — those arrive at run time.
- **One image tag.** Cache-warming is plain Dockerfile lines (keep the cache, discard source/build output), not per-flavor build-args.
- **`--channels` is a hidden research-preview flag** — isolate its use behind the supervisor; do not hard-depend on the protocol shape.
- **Docs (README/AGENTS.md/SKILL.md) must state plainly: this is hosting compute, not subscription sharing.** Every served user runs toward their *own* Claude plan + logins.
- **Shell:** all scripts `#!/usr/bin/env bash`, `set -euo pipefail` (or `set -u` where a nonzero exit is expected/handled); pass `shellcheck`.
- **Line endings:** ship a `.gitattributes` with `* text=auto eol=lf` and `*.sh eol=lf` (the repo tripped CRLF warnings on Windows).
- **Test environment (this host is lean — verified 2026-07-20):** `bats` is NOT on PATH but the workspace vendors a pure-bash copy at `<workspace>/tests/vendor/bats-core/bin/bats` (Bats 1.11.0, runs under Git Bash); a component sits at `<workspace>/components/<name>/`, so reach it at `../../../tests/vendor/...` from `tests/run.sh`. Do **not** copy bats into the component. `shellcheck` and `python3` are NOT on PATH; `jq` and `yq` ARE. Use **`jq` (not python3)** for JSON work, and run **`shellcheck` via `ws docker run --rm koalaman/shellcheck:stable`** (verified 0.11.0) with a PATH fallback if a host `shellcheck` ever exists. `node` is absent on the host (the visual-diff deps live only in the image).

## File Structure

```
components/gdd-sandbox/
  .gitattributes                        # LF normalization
  .dockerignore                         # keep build context tiny
  AGENTS.md                             # points the operating agent at the skill; "orient on startup"
  README.md                             # operator how-to (replaces the WIP stub)
  Dockerfile                            # toolchain + GDD-core seed + cache warming + HEALTHCHECK
  .agent/skills/gdd-sandbox/SKILL.md    # component-level operator skill (first of its kind)
  bin/
    build.sh                            # host: build the image (one tag)
    run.sh                              # host: start + provision + supervise a sandbox
    supervise.sh                        # in-container: session lifecycle (crash loop + rotation)
    rotate.sh                           # in-container: trigger a deliberate rotation
    send.sh                             # in-container: write a keystroke into the session FIFO
  provision/
    provision.sh                        # in-container: seed workspace, ws pull, clone realm+target, install plugin, seed access, onboarding
    patch-onboarding.sh                 # in-container: mark Claude onboarding complete (jq)
    access.json.template                # Discord allowlist template
    settings.sandbox.json               # pre-allow reply/react only (the safe posture)
  tests/
    run.sh                              # adapter entry: {test|lint}
    *.bats                              # bats suites per script
    helpers/stub.bash                   # PATH-stub helper for ws/docker/git/claude
  docs/plans/                           # this plan + the design doc
```

**Responsibilities:** host scripts (`build.sh`, `run.sh`) construct Docker commands and never touch repos directly; in-container scripts (`provision.sh`, `supervise.sh`, `rotate.sh`, `send.sh`) run against the mounted workspace + FIFO; `provision/*` are static assets + the onboarding patch. Tests stub external commands (`ws`, `docker`, `git`, `claude`, `script`) via a PATH shim so logic is unit-testable without Docker or tokens.

---

## Task 1: Test harness, LF hygiene, and `send.sh`

Establishes bats + shellcheck + the stub helper, LF `.gitattributes`, and the simplest script (keystroke → FIFO) with a real test.

**Files:**
- Create: `.gitattributes`, `tests/run.sh`, `tests/helpers/stub.bash`, `bin/send.sh`, `tests/send.bats`

**Interfaces:**
- Produces: `bin/send.sh <key>` writes one keystroke to `${CLAUDE_STDIN_FIFO:-/tmp/claude-stdin}`; keys: `enter down up space tab esc` (named) or any literal string.
- Produces: `tests/run.sh test|lint` — the adapter entry later realms wire to.
- Produces: `tests/helpers/stub.bash` — `make_stub <name> <body>` puts an executable on a test-local PATH.

- [ ] **Step 1: Create `.gitattributes`**

```gitattributes
* text=auto eol=lf
*.sh eol=lf
```

- [ ] **Step 2: Write the stub helper** `tests/helpers/stub.bash`

```bash
# Put fake executables on PATH so bats can assert how scripts call ws/docker/git/claude.
# Each stub appends its argv to "$STUB_LOG" and runs the provided body (default: exit 0).
make_stub() {
  local name="$1"; shift
  local body="${*:-true}"
  mkdir -p "$STUB_BIN"
  cat > "$STUB_BIN/$name" <<EOF
#!/usr/bin/env bash
echo "$name \$*" >> "$STUB_LOG"
$body
EOF
  chmod +x "$STUB_BIN/$name"
}

stub_setup() {
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  STUB_LOG="$BATS_TEST_TMPDIR/calls.log"
  : > "$STUB_LOG"
  mkdir -p "$STUB_BIN"
  PATH="$STUB_BIN:$PATH"
}
```

- [ ] **Step 3: Write the failing test** `tests/send.bats`

```bash
setup() {
  export CLAUDE_STDIN_FIFO="$BATS_TEST_TMPDIR/fifo"   # a regular file in tests → no blocking
  : > "$CLAUDE_STDIN_FIFO"
}

@test "send.sh enter writes a carriage return" {
  bash bin/send.sh enter
  run cat "$CLAUDE_STDIN_FIFO"
  [ "$output" = "$(printf '\r')" ]
}

@test "send.sh passes an unknown token through literally" {
  bash bin/send.sh "yes"
  run cat "$CLAUDE_STDIN_FIFO"
  [ "$output" = "yes" ]
}
```

- [ ] **Step 4: Write `tests/run.sh`**

```bash
#!/usr/bin/env bash
# Component self-test. Uses the workspace-vendored bats (this host has no bats on
# PATH); shellcheck runs via the koalaman container unless a host shellcheck exists.
set -euo pipefail
cd "$(dirname "$0")/.."                                  # component root
WS_ROOT="$(cd ../.. && pwd)"                             # <workspace>/components/<name> → workspace
BATS="$(command -v bats || echo "$WS_ROOT/tests/vendor/bats-core/bin/bats")"

shellcheck_run() {
  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "$@"
  else
    ws docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable "$@"
  fi
}

case "${1:-test}" in
  test) exec bash "$BATS" tests/ ;;
  lint) shellcheck_run bin/*.sh tests/*.sh provision/*.sh ;;
  *) echo "usage: tests/run.sh {test|lint}" >&2; exit 2 ;;
esac
```

- [ ] **Step 5: Run the test to verify it fails**

Run: `bash tests/run.sh test`
Expected: FAIL — `bin/send.sh` does not exist yet.

- [ ] **Step 6: Write `bin/send.sh`**

```bash
#!/usr/bin/env bash
# Write a keystroke into the claude PTY FIFO. Usage: send.sh <key>
set -u
FIFO="${CLAUDE_STDIN_FIFO:-/tmp/claude-stdin}"
case "$1" in
  enter) printf '\r'      > "$FIFO" ;;
  down)  printf '\033[B'  > "$FIFO" ;;
  up)    printf '\033[A'  > "$FIFO" ;;
  space) printf ' '       > "$FIFO" ;;
  tab)   printf '\t'      > "$FIFO" ;;
  esc)   printf '\033'    > "$FIFO" ;;
  *)     printf '%s' "$1" > "$FIFO" ;;
esac
```

- [ ] **Step 7: Run tests + lint to verify pass**

Run: `bash tests/run.sh test` → Expected: PASS (2 tests)
Run: `bash tests/run.sh lint` → Expected: no output, exit 0

- [ ] **Step 8: Commit**

Write `.commits/gdd-sandbox-t1.md` (frontmatter `add:` the 5 files) and:
`ws commit gdd-sandbox .commits/gdd-sandbox-t1.md`
Message: `feat(gdd-sandbox): test harness + send.sh keystroke driver`

---

## Task 2: Provisioning assets — onboarding patch, access template, safe-posture settings

Static assets + the onboarding patch, each with a validation test. No Docker.

**Files:**
- Create: `provision/patch-onboarding.sh`, `provision/access.json.template`, `provision/settings.sandbox.json`, `tests/provision-assets.bats`

**Interfaces:**
- Produces: `patch-onboarding.sh [config-path] [project-path]` — sets onboarding-complete flags in the Claude config JSON via `jq` (default `~/.claude.json`); if `project-path` given, marks that project trusted.
- Produces: `access.json.template` with `__ALLOWFROM__` placeholder (a JSON array of snowflakes) rendered by `provision.sh`.
- Produces: `settings.sandbox.json` — `permissions.allow` listing ONLY the Discord reply/react tool ids.

- [ ] **Step 1: Write the failing test** `tests/provision-assets.bats` (uses `jq`, which is present; no python3)

```bash
@test "patch-onboarding sets completion flags on an empty config" {
  cfg="$BATS_TEST_TMPDIR/claude.json"
  bash provision/patch-onboarding.sh "$cfg"
  run jq -r '.hasCompletedOnboarding' "$cfg"
  [ "$output" = "true" ]
}

@test "patch-onboarding marks a project trusted when given a path" {
  cfg="$BATS_TEST_TMPDIR/claude.json"
  bash provision/patch-onboarding.sh "$cfg" "/work/ws"
  run jq -r '.projects["/work/ws"].hasTrustDialogAccepted' "$cfg"
  [ "$output" = "true" ]
}

@test "access template renders to valid JSON with the snowflake" {
  run bash -c "sed 's/__ALLOWFROM__/[\"123\"]/' provision/access.json.template | jq -e '.allowFrom == [\"123\"]'"
  [ "$status" -eq 0 ]
}

@test "sandbox settings pre-allow reply and react and nothing broad" {
  run jq -e '.permissions.allow as $a
             | ($a | any(test("reply"))) and ($a | all(test("Bash") | not))' \
        provision/settings.sandbox.json
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash "$(cd ../.. && pwd)/tests/vendor/bats-core/bin/bats" tests/provision-assets.bats` (or `bash tests/run.sh test`)
Expected: FAIL — assets do not exist.

- [ ] **Step 3: Write `provision/patch-onboarding.sh`**

```bash
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
```

- [ ] **Step 4: Write `provision/access.json.template`**

```json
{
  "dmPolicy": "allowlist",
  "allowFrom": __ALLOWFROM__,
  "ackReaction": "👀"
}
```

- [ ] **Step 5: Write `provision/settings.sandbox.json`**

> NOTE: confirm the exact tool ids from the running plugin during Task 8 / the spike (`claude mcp` tool list). The `mcp__discord__*` shape matches the plugin marketplace name `discord@claude-plugins-official`.

```json
{
  "permissions": {
    "allow": [
      "mcp__discord__reply",
      "mcp__discord__react"
    ]
  }
}
```

- [ ] **Step 6: Run to verify pass**

Run: `bash tests/run.sh test` → Expected: PASS (all suites, incl. 4 provision-assets tests)
Run: `bash tests/run.sh lint` → Expected: clean

- [ ] **Step 7: Commit** — `feat(gdd-sandbox): provisioning assets (onboarding, access, safe posture)`

---

## Task 3: `bin/build.sh` — one-tag image build

Host script constructing the `ws docker build`. TDD via stubbed `ws`.

**Files:**
- Create: `bin/build.sh`, `tests/build.bats`

**Interfaces:**
- Produces: `build.sh [--tag <tag>] [--context <path>]` → runs `ws docker build -t <tag> <context>`; default tag `gdd-sandbox:latest`; default context = the component dir as a Windows-style absolute path.

- [ ] **Step 1: Write the failing test** `tests/build.bats`

```bash
load helpers/stub

setup() { stub_setup; make_stub ws 'exit 0'; }

@test "build.sh calls ws docker build with the default tag" {
  bash bin/build.sh
  run cat "$STUB_LOG"
  [[ "$output" == *"ws docker build -t gdd-sandbox:latest"* ]]
}

@test "build.sh honours an explicit tag" {
  bash bin/build.sh --tag gdd-sandbox:proto
  run cat "$STUB_LOG"
  [[ "$output" == *"-t gdd-sandbox:proto"* ]]
}
```

- [ ] **Step 2: Run to verify it fails** — `bats tests/build.bats` → FAIL (no `bin/build.sh`).

- [ ] **Step 3: Write `bin/build.sh`**

```bash
#!/usr/bin/env bash
# Build the gdd-sandbox image (one tag; cache-warming is in the Dockerfile).
set -euo pipefail
TAG="gdd-sandbox:latest"
CONTEXT="$(cd "$(dirname "$0")/.." && pwd)"
while [ $# -gt 0 ]; do
  case "$1" in
    --tag) TAG="$2"; shift 2 ;;
    --context) CONTEXT="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
# ws docker handles Windows path conversion; MSYS mangles /d/... so prefer D:/...
ws docker build -t "$TAG" "$CONTEXT"
```

- [ ] **Step 4: Run to verify pass** — `bats tests/build.bats` → PASS; `bash tests/run.sh lint` → clean.

- [ ] **Step 5: Commit** — `feat(gdd-sandbox): build.sh`

---

## Task 4: Dockerfile — toolchain + GDD-core seed + cache warming (+ build smoke)

Not unit-TDD: validated by lint + an actual build + a smoke run. Adapt the proven kit Dockerfile (`hoards/thalami-Cervator/kencierge-sandbox/Dockerfile`) and add the three new layers.

**Files:**
- Create: `Dockerfile`, `.dockerignore`

**Interfaces:**
- Produces: image `gdd-sandbox:latest` containing the toolchain, a baked clone at `/opt/gdd-seed` (the GDD core), and warmed gem/npm/Playwright caches.

- [ ] **Step 1: Write `.dockerignore`**

```dockerignore
tests/
docs/
.git/
.commits/
```

- [ ] **Step 2: Write `Dockerfile`** — start from the kit's proven base (git/bash/curl/jq/unzip, mikefarah yq, gh, Node LTS, Bun, Ruby+Jekyll+Bundler, native `claude`), then append:

```dockerfile
# --- GDD core seed: bake the agnostic workspace so first run is fast --------
# Cloned public; a runtime `ws pull` freshens it. No realm/target/creds baked.
RUN set -eux; \
    git clone --depth 1 https://github.com/SiliconSaga/yggdrasil /opt/gdd-seed

# --- Dependency cache warming (a few lines; keep cache, drop source) --------
# Warms the gem set + the visual-diff Node/Playwright stack (browser binaries =
# the expensive download) so runtime builds start warm. One image tag; this does
# NOT make the image gh-pages-specific.
ENV BUNDLE_PATH=/opt/gem-cache \
    npm_config_cache=/opt/npm-cache \
    PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers
RUN set -eux; \
    tmp="$(mktemp -d)"; cd "$tmp"; \
    printf 'source "https://rubygems.org"\ngem "github-pages", group: :jekyll_plugins\n' > Gemfile; \
    bundle install; \
    npm i -g playwright pixelmatch pngjs >/dev/null 2>&1 || true; \
    npx --yes playwright install chromium; \
    cd /; rm -rf "$tmp"      # discard source + build output; keep only the caches

# --- Liveness: process alive + tty-log fresh (<120s) ------------------------
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD pgrep -f "claude .*--channels" >/dev/null \
      && [ -f /tmp/channels-tty.log ] \
      && [ "$(( $(date +%s) - $(stat -c %Y /tmp/channels-tty.log) ))" -lt 120 ] \
      || exit 1

WORKDIR /work
CMD ["sleep", "infinity"]
```

- [ ] **Step 3: Lint** — Run: `ws docker run --rm -i hadolint/hadolint < Dockerfile`
Expected: no errors (info/style warnings acceptable; fix any error-level).

- [ ] **Step 4: Build** — Run: `bash bin/build.sh --tag gdd-sandbox:latest`
Expected: build completes exit 0. (Requires Docker + network for the clone and cache warm.)

- [ ] **Step 5: Smoke-test the image**

Run each and confirm:
```bash
ws docker run --rm gdd-sandbox:latest claude --version        # prints a version
ws docker run --rm gdd-sandbox:latest bash -lc 'ls /opt/gdd-seed/ws'   # ws present in seed
ws docker run --rm gdd-sandbox:latest bash -lc 'ls /opt/pw-browsers'   # chromium cached
ws docker run --rm gdd-sandbox:latest jekyll --version
```
Expected: all succeed.

- [ ] **Step 6: Commit** — `feat(gdd-sandbox): Dockerfile with GDD-core seed + warmed caches`

---

## Task 5: `provision/provision.sh` — in-container workspace seeding + plugin install

Runs once inside the container. Seeds the mutable workspace from `/opt/gdd-seed`, freshens, clones realm+target, installs the Discord plugin, renders access + onboarding. TDD the seed-idempotency + clone-orchestration with stubs.

**Files:**
- Create: `provision/provision.sh`, `tests/provision.bats`

**Interfaces:**
- Consumes: env `GDD_WORKSPACE` (default `/work/ws`), `GDD_TARGET` (component name), `GDD_TARGET_REPO` (git URL), `GDD_REALM_REPO` (git URL, optional), `GDD_ALLOWFROM` (JSON array).
- Produces: a populated `$GDD_WORKSPACE` (seeded once, then left alone on re-run), plugin installed, `~/.claude/channels/discord/access.json` seeded, onboarding patched.

- [ ] **Step 1: Write the failing test** `tests/provision.bats`

```bash
load helpers/stub

setup() {
  stub_setup
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"   # never touch the real ~/.claude
  export GDD_WORKSPACE="$BATS_TEST_TMPDIR/ws"
  export GDD_TARGET="ken-site" GDD_TARGET_REPO="https://example/ken-site.git"
  export GDD_ALLOWFROM='["123"]'
  export GDD_SEED="$BATS_TEST_TMPDIR/seed"; mkdir -p "$GDD_SEED/.git"
  make_stub git 'exit 0'
  make_stub ws 'exit 0'
  make_stub claude 'exit 0'
  # jq is real (present on host + image); patch-onboarding.sh uses it against $HOME.
}

@test "provision seeds the workspace from the seed when absent" {
  bash provision/provision.sh
  [ -d "$GDD_WORKSPACE" ]
  grep -q "git clone .*$GDD_TARGET_REPO" "$STUB_LOG"
}

@test "provision skips the seed when the workspace already exists" {
  mkdir -p "$GDD_WORKSPACE/.git"
  bash provision/provision.sh
  run grep -c "cp -a $GDD_SEED" "$STUB_LOG"
  [ "$output" = "0" ]     # no re-seed
  grep -q "ws pull" "$STUB_LOG"   # but it still freshens
}
```

- [ ] **Step 2: Run to verify it fails** — FAIL (no `provision.sh`).

- [ ] **Step 3: Write `provision/provision.sh`**

```bash
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
```

- [ ] **Step 4: Run to verify pass** — `bats tests/provision.bats` → PASS; `bash tests/run.sh lint` → clean.

- [ ] **Step 5: Commit** — `feat(gdd-sandbox): in-container provisioning`

---

## Task 6: `bin/supervise.sh` — crash-recovery loop with `--continue` + safe posture

The always-on session supervisor. TDD the loop control (first-launch vs relaunch flag, rotation-vs-continue branch, command construction) by making the launch step a stubbable function; the real PTY run is exercised in the spike (Task 9).

**Files:**
- Create: `bin/supervise.sh`, `tests/supervise.bats`

**Interfaces:**
- Consumes: env `GDD_WORKSPACE`, `CLAUDE_SETTINGS` (path to `settings.sandbox.json`), `SUPERVISE_ONCE=1` (test hook: run one iteration), `ROTATE_FLAG` (path; presence ⇒ fresh launch).
- Produces: launches `claude --channels plugin:discord@claude-plugins-official --settings <safe>` under a PTY; adds `--continue` on a relaunch unless a rotation is pending; writes `/tmp/channels-tty.log`.

- [ ] **Step 1: Write the failing test** `tests/supervise.bats`

```bash
load helpers/stub

setup() {
  stub_setup
  export GDD_WORKSPACE="$BATS_TEST_TMPDIR/ws"; mkdir -p "$GDD_WORKSPACE"
  export CLAUDE_SETTINGS="$BATS_TEST_TMPDIR/settings.json"; echo '{}' > "$CLAUDE_SETTINGS"
  export ROTATE_FLAG="$BATS_TEST_TMPDIR/rotate"
  export SUPERVISE_ONCE=1
  # 'script' is the PTY wrapper; stub it to just log the claude command it was given.
  make_stub script 'echo "$*" >> "$STUB_LOG"'
  make_stub ws 'exit 0'
}

@test "first launch does not pass --continue" {
  bash bin/supervise.sh
  run grep -c -- "--continue" "$STUB_LOG"
  [ "$output" = "0" ]
}

@test "a relaunch passes --continue" {
  touch "$GDD_WORKSPACE/.gdd-sandbox-launched"   # simulate a prior launch
  bash bin/supervise.sh
  grep -q -- "--continue" "$STUB_LOG"
}

@test "a pending rotation launches fresh (no --continue) and clears the flag" {
  touch "$GDD_WORKSPACE/.gdd-sandbox-launched"
  touch "$ROTATE_FLAG"
  bash bin/supervise.sh
  run grep -c -- "--continue" "$STUB_LOG"
  [ "$output" = "0" ]
  [ ! -e "$ROTATE_FLAG" ]
}
```

- [ ] **Step 2: Run to verify it fails** — FAIL (no `supervise.sh`).

- [ ] **Step 3: Write `bin/supervise.sh`**

```bash
#!/usr/bin/env bash
# Keep a PTY-hosted `claude --channels` session alive.
#  - crash recovery: relaunch with --continue (recover the one session)
#  - deliberate rotation: ROTATE_FLAG present ⇒ launch fresh (shed context);
#    the fresh session re-orients via AGENTS.md ("run ws orient on startup").
set -u
WS="${GDD_WORKSPACE:-/work/ws}"
SETTINGS="${CLAUDE_SETTINGS:-/work/ws/.claude/settings.sandbox.json}"
ROTATE_FLAG="${ROTATE_FLAG:-/tmp/gdd-rotate}"
LAUNCHED="$WS/.gdd-sandbox-launched"
TTY_LOG=/tmp/channels-tty.log
FIFO=/tmp/claude-stdin

launch() {
  local cont="$1"   # "--continue" or ""
  : > "$TTY_LOG"; rm -f "$FIFO"; mkfifo "$FIFO"
  sleep infinity > "$FIFO" &            # hold the FIFO open (drive prompts + no EOF)
  local w=$!
  # shellcheck disable=SC2086
  script -q -f -c \
    "claude --channels plugin:discord@claude-plugins-official --settings '$SETTINGS' $cont" \
    "$TTY_LOG" < "$FIFO"
  kill "$w" 2>/dev/null || true
}

run_once() {
  cd "$WS" 2>/dev/null || true
  local cont=""
  if [ -e "$ROTATE_FLAG" ]; then
    # Deliberate rotation: archive the prior log, start fresh, clear the flag.
    [ -f "$TTY_LOG" ] && mv "$TTY_LOG" "$TTY_LOG.$(date +%s).archived" 2>/dev/null || true
    rm -f "$ROTATE_FLAG"
    cont=""
  elif [ -e "$LAUNCHED" ]; then
    cont="--continue"
  fi
  touch "$LAUNCHED"
  launch "$cont"
}

if [ "${SUPERVISE_ONCE:-0}" = "1" ]; then run_once; exit 0; fi
backoff=2
while true; do
  run_once
  sleep "$backoff"
  backoff=$(( backoff < 30 ? backoff * 2 : 30 ))
done
```

- [ ] **Step 4: Run to verify pass** — `bats tests/supervise.bats` → PASS (3 tests); `bash tests/run.sh lint` → clean.

- [ ] **Step 5: Commit** — `feat(gdd-sandbox): session supervisor (crash recovery + rotation branch)`

---

## Task 7: `bin/rotate.sh` — trigger a deliberate rotation

The rotation primitive an operator (or later the concierge skill) invokes when context has grown too large.

**Files:**
- Create: `bin/rotate.sh`, `tests/rotate.bats`

**Interfaces:**
- Consumes: env `ROTATE_FLAG`, `GDD_WORKSPACE`.
- Produces: sets `ROTATE_FLAG` and ends the current `claude --channels` process so the supervisor relaunches fresh.

- [ ] **Step 1: Write the failing test** `tests/rotate.bats`

```bash
load helpers/stub
setup() {
  stub_setup
  export ROTATE_FLAG="$BATS_TEST_TMPDIR/rotate"
  make_stub pkill 'echo "pkill $*" >> "$STUB_LOG"'
}
@test "rotate.sh sets the flag and signals the session" {
  bash bin/rotate.sh
  [ -e "$ROTATE_FLAG" ]
  grep -q "pkill" "$STUB_LOG"
}
```

- [ ] **Step 2: Run to verify it fails** — FAIL.

- [ ] **Step 3: Write `bin/rotate.sh`**

```bash
#!/usr/bin/env bash
# Trigger a deliberate session rotation: mark rotate + end the current session;
# the supervisor then launches a FRESH session (no --continue) that re-orients
# from the persistent Thalamus via AGENTS.md.
set -u
ROTATE_FLAG="${ROTATE_FLAG:-/tmp/gdd-rotate}"
touch "$ROTATE_FLAG"
pkill -f "claude .*--channels" || true
echo "rotation requested"
```

- [ ] **Step 4: Run to verify pass** — `bats tests/rotate.bats` → PASS; lint clean.

- [ ] **Step 5: Commit** — `feat(gdd-sandbox): rotation primitive`

---

## Task 8: `bin/run.sh` — host orchestration (start + provision + supervise)

Ties host-side together: validate args, `ws docker run` with the named volume + env-file + restart policy, copy in `provision/` + `bin/`, run provisioning, launch the supervisor detached.

**Files:**
- Create: `bin/run.sh`, `tests/run-cli.bats`

**Interfaces:**
- Consumes: `--target <component>` (required), `--name <n>` (default `gdd-sandbox-<target>`), `--secrets <path>` (default `../../.env` resolved to LF), `--target-repo <url>` / `--realm-repo <url>` (default resolved from `ecosystem.local.yaml` via `yq`).
- Produces: a running, provisioned, supervised container.

- [ ] **Step 1: Write the failing test** `tests/run-cli.bats`

```bash
load helpers/stub
setup() {
  stub_setup
  make_stub ws 'exit 0'
  make_stub docker 'exit 0'
  make_stub yq 'echo https://example/ken-site.git'
}

@test "run.sh requires --target" {
  run bash bin/run.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"--target"* ]]
}

@test "run.sh starts a container with restart policy, named volume, env-file" {
  bash bin/run.sh --target ken-site --secrets "$BATS_TEST_TMPDIR/secrets.env"
  : > "$BATS_TEST_TMPDIR/secrets.env"
  run cat "$STUB_LOG"
  [[ "$output" == *"docker run"* || "$output" == *"ws docker run"* ]]
  [[ "$output" == *"--restart unless-stopped"* ]]
  [[ "$output" == *"-v gdd-sandbox-ken-site-ws:"* ]]
  [[ "$output" == *"--env-file"* ]]
}

@test "run.sh refuses secrets containing ANTHROPIC_API_KEY" {
  echo 'ANTHROPIC_API_KEY=sk-xxx' > "$BATS_TEST_TMPDIR/secrets.env"
  run bash bin/run.sh --target ken-site --secrets "$BATS_TEST_TMPDIR/secrets.env"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ANTHROPIC_API_KEY"* ]]
}
```

- [ ] **Step 2: Run to verify it fails** — FAIL.

- [ ] **Step 3: Write `bin/run.sh`**

```bash
#!/usr/bin/env bash
# Start + provision + supervise a gdd-sandbox for one target component.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${GDD_SANDBOX_IMAGE:-gdd-sandbox:latest}"
TARGET="" NAME="" SECRETS="$ROOT/../../.env" TARGET_REPO="" REALM_REPO="" ALLOWFROM="[]"
while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --secrets) SECRETS="$2"; shift 2 ;;
    --target-repo) TARGET_REPO="$2"; shift 2 ;;
    --realm-repo) REALM_REPO="$2"; shift 2 ;;
    --allowfrom) ALLOWFROM="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$TARGET" ] || { echo "error: --target <component> is required" >&2; exit 2; }
NAME="${NAME:-gdd-sandbox-$TARGET}"

# Safety: never let ANTHROPIC_API_KEY into the container (metered-billing trap).
if [ -f "$SECRETS" ] && grep -q '^ANTHROPIC_API_KEY=' "$SECRETS"; then
  echo "error: $SECRETS sets ANTHROPIC_API_KEY — remove it (outranks the OAuth token)" >&2
  exit 2
fi
# Resolve the target repo from ecosystem if not given.
[ -n "$TARGET_REPO" ] || TARGET_REPO="$(yq ".components.$TARGET.repo" "$ROOT/../../ecosystem.local.yaml")"

VOL="gdd-sandbox-$TARGET-ws"
ws docker run -d --name "$NAME" --restart unless-stopped \
  --env-file "$SECRETS" \
  -e "GDD_TARGET=$TARGET" -e "GDD_TARGET_REPO=$TARGET_REPO" \
  -e "GDD_REALM_REPO=$REALM_REPO" -e "GDD_ALLOWFROM=$ALLOWFROM" \
  -e "GDD_WORKSPACE=/work/ws" -e "CLAUDE_SETTINGS=/work/gdd-sandbox/provision/settings.sandbox.json" \
  -v "$VOL:/work/ws" \
  "$IMAGE"

# Copy the operator scripts in and provision, then supervise detached.
ws docker cp "$ROOT/." "$NAME:/work/gdd-sandbox"
ws docker exec "$NAME" bash /work/gdd-sandbox/provision/provision.sh
ws docker exec -d "$NAME" bash /work/gdd-sandbox/bin/supervise.sh
echo "sandbox '$NAME' up (target=$TARGET). Tail: ws docker exec $NAME tail -f /tmp/channels-tty.log"
```

- [ ] **Step 4: Run to verify pass** — `bats tests/run-cli.bats` → PASS; lint clean.

- [ ] **Step 5: Commit** — `feat(gdd-sandbox): run.sh host orchestration`

---

## Task 9: SPIKE A — validate `--continue` + `--channels` end-to-end (live)

The one real unknown. Needs Docker + the real tokens in root `.env` + a Discord bot + your snowflake. **Time-box it.** Explicit success + fallback.

**Files:**
- Modify (only on the fallback branch): `bin/supervise.sh`

- [ ] **Step 1: Prepare secrets** — confirm root `.env` has `CLAUDE_CODE_OAUTH_TOKEN` + `DISCORD_BOT_TOKEN`, LF-only, no `ANTHROPIC_API_KEY`. Normalize CRLF if needed:
Run: `ws docker run --rm -v "$PWD:/w" gdd-sandbox:latest bash -lc "sed -i 's/\r$//' /w/.env"` (or a local sed).

- [ ] **Step 2: Launch** — Run: `bash bin/run.sh --target ken-site --allowfrom '["<your-snowflake>"]'`
Expected: container up; `tail -f /tmp/channels-tty.log` shows the Discord gateway connecting; the bot shows online.

- [ ] **Step 3: Round-trip** — DM the bot a message that establishes context, e.g. *"Remember the word BLUEBIRD."* Expect a 👀 ack + a reply.

- [ ] **Step 4: Kill + recover** — Run: `ws docker exec gdd-sandbox-ken-site pkill -f 'claude .*--channels'`
Wait for the supervisor to relaunch (watch the log). Then DM a **fresh** message: *"What word did I ask you to remember?"*
- **Success:** it answers *BLUEBIRD* → `--continue` recovers context. Leave supervisor as-is.
- **Fallback:** it does not recall → `--continue` does not compose with `--channels`. Apply the fallback below.

- [ ] **Step 5 (fallback only): flip the supervisor to fresh-session semantics** — in `bin/supervise.sh`, change the `elif [ -e "$LAUNCHED" ]; then cont="--continue"` branch to `cont=""` (always fresh) and add a comment referencing this spike. Re-run tests (the "relaunch passes --continue" test becomes a fresh-launch test — update it to assert no `--continue`). Context loss on restart is acceptable because the Thalamus persists the important details.

- [ ] **Step 6: Record the result** — append the outcome (success or fallback) to the design doc's Validation section and the Thalamus arc note. Commit any code change: `fix(gdd-sandbox): spike A outcome — <continue works | fresh-session fallback>`.

---

## Task 10: Integration proofs — anti-ghosting, rotation, healthcheck

Live validation of the resilience guarantees. Same running container from Task 9.

- [ ] **Step 1: Anti-ghosting** — kill the session (`pkill -f 'claude .*--channels'`), confirm the supervisor relaunches (log), DM a fresh message, confirm it is answered. This proves a dead session does not silently ghost the user.

- [ ] **Step 2: Rotation** — Run: `ws docker exec gdd-sandbox-ken-site bash /work/gdd-sandbox/bin/rotate.sh`
Confirm: the tty log is archived (`ls /tmp/channels-tty.log.*.archived`), a fresh session launches, the bot comes back online, and a fresh DM is answered. If AGENTS.md's "orient on startup" is wired (Task 11), confirm the fresh session ran `ws orient`.

- [ ] **Step 3: Healthcheck** — Run: `ws docker inspect --format '{{.State.Health.Status}}' gdd-sandbox-ken-site`
Expected: `healthy` while the session runs; `unhealthy` after a kill until relaunch.

- [ ] **Step 4: Record** — note results in the Thalamus arc. No commit (validation only) unless a fix was needed.

---

## Task 11: `AGENTS.md`, operator `SKILL.md`, README

The component-level skill (GDD's first) + the agent-facing instructions + operator how-to. Includes the "orient on startup" instruction the rotation relies on.

**Files:**
- Create: `AGENTS.md`, `.agent/skills/gdd-sandbox/SKILL.md`
- Modify: `README.md` (replace WIP stub)

- [ ] **Step 1: Write `AGENTS.md`** — small; points at the skill and instructs startup orientation:

```markdown
# gdd-sandbox — agent instructions

This component builds and runs a sandboxed GDD workspace. When operating it,
load the **`gdd-sandbox` skill** at `.agent/skills/gdd-sandbox/SKILL.md`.

**On startup inside a running sandbox, run `ws orient` first** — after a
deliberate session rotation this is how a fresh session recovers context from
the persistent Thalamus. Do not treat a rotation as a loss; the notes carry the
important state.

This is hosting compute, not subscription sharing: every served user runs
toward their own Claude plan and logins.
```

- [ ] **Step 2: Write `.agent/skills/gdd-sandbox/SKILL.md`** — operator skill covering: build (`bin/build.sh`), run (`bin/run.sh --target …`), the two secret channels, provisioning, the supervisor (crash `--continue` vs rotation), `bin/rotate.sh`, the safe posture (reply/react only, no bypass-all), and the known caveats (research-preview `--channels`; answer a *fresh* inbound after a restart; ~1yr token rotation). Use the design doc as the source; keep it operational (commands + when to use them), not a re-derivation.

- [ ] **Step 3: Rewrite `README.md`** — operator how-to: prerequisites (Docker, a Claude setup-token, a Discord bot, your snowflake), the build+run quickstart, and the "hosting not sharing" statement. Fold in the proven kit's prerequisite/caveat prose from `hoards/thalami-Cervator/kencierge-sandbox/README.md`.

- [ ] **Step 4: Lint docs** (if `markdownlint` available) — Run: `markdownlint AGENTS.md README.md .agent/skills/gdd-sandbox/SKILL.md` → fix errors.

- [ ] **Step 5: Commit** — `docs(gdd-sandbox): operator skill, AGENTS.md, README`

---

## Task 12: Finishing — realm adapter wiring + push

Make `ws test/lint gdd-sandbox` work and publish the repo.

- [ ] **Step 1: Wire the adapter** — add a `gdd-sandbox` adapter entry in the active realm pointing `commands.test`/`commands.lint` at `bash tests/run.sh test` / `bash tests/run.sh lint` (mirror the `nordri` adapter). Confirm: `ws test gdd-sandbox` runs the bats suite green; `ws lint gdd-sandbox` is clean.

- [ ] **Step 2: Create the remote + push** — `gh repo create SiliconSaga/gdd-sandbox --public --source components/gdd-sandbox --remote SiliconSaga --push` (use a personal PAT if the agent token can't create under the org, per the gh-pages Ch1 auth-wrinkle). Confirm the repo exists and CI (if any) is green.

- [ ] **Step 3: Update the Thalamus** — flip the arc note to reflect the runtime shipped; record the Spike A outcome and any deferred follow-ups (the `ws orient` component-skill-tier question; exact reply/react tool ids).

---

## Self-Review

**Spec coverage** (design § → task):
- Baked toolchain + GDD-core seed → T4. Mutable workspace volume + seed-idempotency → T5. Cache warming → T4. Build/run interface → T3/T8. Crash recovery `--continue` → T6/T9. Session rotation + re-orient → T7/T6/T11. Healthcheck + restart → T4/T8/T10. Safe posture (reply/react, no bypass) → T2/T6. Deny-by-absence (workspace content) → T5/T8 (only in-scope repos cloned; no host mounts). Two secret channels → T2/T8 (runtime env-file; workspace `.env`/PAT co-set — the co-set-at-onboarding step is operator-manual, documented in T11). Component-level skill + AGENTS.md → T11. Token seam → T8 (`--secrets` resolver). Validation plan → T9/T10. Tests via adapter → T1/T12.
- **Gap noted:** the workspace-side GitHub PAT co-set at onboarding is documented (T11) but not automated — correct per design (self-service is Layer B, deferred).
- **Gap noted:** exact `mcp__discord__*` tool ids are best-effort in T2 and confirmed live in T9 — flagged inline.

**Placeholder scan:** no TBD/TODO left; every code step carries real content. The two "confirm live" items (tool ids, Spike A branch) are explicit decision points with both outcomes specified, not placeholders.

**Type/name consistency:** env var names (`GDD_WORKSPACE`, `GDD_TARGET`, `GDD_TARGET_REPO`, `GDD_REALM_REPO`, `GDD_ALLOWFROM`, `ROTATE_FLAG`, `CLAUDE_SETTINGS`, `GDD_SEED`), the volume name pattern `gdd-sandbox-<target>-ws`, `LAUNCHED` sentinel, and `/tmp/channels-tty.log` are used consistently across T5/T6/T7/T8.
