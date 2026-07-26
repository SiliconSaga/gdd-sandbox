# gdd-sandbox
# A sandboxed GDD workspace: toolchain + agent runtime + a baked GDD-core seed.
# Runs a scoped GDD agent reachable over a chat channel, pointed at one target
# component. Agnostic — no realm, no target, no credentials baked in; those
# arrive at run time. This is hosting compute, not subscription sharing.
#
# Base: Debian 12 (bookworm) slim. glibc x64 -> the Claude Code native binary
# and Bun both run without musl caveats.
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    # Claude Code: don't self-update inside an immutable image.
    DISABLE_AUTOUPDATER=1 \
    # Bun + Claude native launcher land under these; put them on PATH.
    BUN_INSTALL=/opt/bun \
    # /work/ws/scripts is where the seeded workspace's `ws` CLI lands at run time.
    PATH=/work/ws/scripts:/opt/bun/bin:/root/.local/bin:/usr/local/bin:/usr/bin:/bin

# ---------------------------------------------------------------------------
# 1. Core OS packages + Jekyll's Ruby build stack, in one layer.
#    - git bash curl ca-certificates jq  : core CLI toolchain
#    - gnupg                             : verify apt repo signing keys (gh)
#    - procps                            : pgrep/pkill for the supervisor + healthcheck
#    - util-linux                        : `script` (the PTY wrapper channels needs)
#    - ruby-full + build-essential + zlib/ffi headers : compile native gems
# ---------------------------------------------------------------------------
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        git bash curl wget ca-certificates gnupg jq unzip procps util-linux \
        ruby-full build-essential \
        zlib1g-dev libffi-dev libyaml-dev; \
    rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# 2. yq — mikefarah/yq (Go single binary). NOTE: Debian's apt "yq" is a
#    different (python/kislyuk) tool with incompatible syntax; GDD's ws/yq
#    reflexes assume mikefarah yq, so pull the release binary directly.
# ---------------------------------------------------------------------------
RUN set -eux; \
    curl -fsSL https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 \
        -o /usr/local/bin/yq; \
    chmod +x /usr/local/bin/yq; \
    yq --version

# ---------------------------------------------------------------------------
# 3. GitHub CLI (gh) via the official signed apt repo.
# ---------------------------------------------------------------------------
RUN set -eux; \
    mkdir -p -m 755 /etc/apt/keyrings; \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /etc/apt/keyrings/githubcli-archive-keyring.gpg; \
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg; \
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends gh; \
    rm -rf /var/lib/apt/lists/*; \
    gh --version

# ---------------------------------------------------------------------------
# 4. Node.js LTS via NodeSource. Node 22 LTS satisfies Claude Code's npm
#    engine floor (>=22) even though we install claude natively below.
# ---------------------------------------------------------------------------
RUN set -eux; \
    curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -; \
    apt-get install -y --no-install-recommends nodejs; \
    rm -rf /var/lib/apt/lists/*; \
    node --version; \
    npm --version

# ---------------------------------------------------------------------------
# 5. Bun — the Discord channel plugin's MCP server runs on Bun.
# ---------------------------------------------------------------------------
RUN set -eux; \
    curl -fsSL https://bun.sh/install | bash; \
    bun --version

# ---------------------------------------------------------------------------
# 6. Jekyll build stack (bundler + jekyll as global gems). A site's own
#    Gemfile is the source of truth at runtime; see the cache warming below.
# ---------------------------------------------------------------------------
RUN set -eux; \
    gem install --no-document bundler jekyll; \
    jekyll --version; \
    bundle --version

# ---------------------------------------------------------------------------
# 7. Claude Code CLI — official NATIVE installer. Self-contained binary at
#    /root/.local/bin/claude; no Node at runtime. Auto-update disabled above
#    so the tagged image stays reproducible.
# ---------------------------------------------------------------------------
RUN set -eux; \
    curl -fsSL https://claude.ai/install.sh | bash; \
    /root/.local/bin/claude --version

# ---------------------------------------------------------------------------
# 8. GDD core seed: bake the agnostic workspace so first run is fast and the
#    image is a known-good baseline. A runtime `ws pull` freshens it.
#    NO realm, NO target component, NO credentials — those arrive at run time.
# ---------------------------------------------------------------------------
RUN set -eux; \
    git clone --depth 1 https://github.com/SiliconSaga/yggdrasil /opt/gdd-seed; \
    test -x /opt/gdd-seed/scripts/ws

# ---------------------------------------------------------------------------
# 9. Dependency cache warming. Fetch the deps a likely target framework needs,
#    KEEP only the populated caches, and discard the throwaway source + build
#    output — the build-agent trick, so the added size is just the cache.
#    This does NOT make the image framework-specific; one tag serves every use.
# ---------------------------------------------------------------------------
ENV BUNDLE_PATH=/opt/gem-cache \
    npm_config_cache=/opt/npm-cache \
    PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers
RUN set -eux; \
    tmp="$(mktemp -d)"; cd "$tmp"; \
    printf 'source "https://rubygems.org"\ngem "github-pages", group: :jekyll_plugins\n' > Gemfile; \
    bundle install; \
    npx --yes playwright@latest install --with-deps chromium; \
    cd /; rm -rf "$tmp"

# ---------------------------------------------------------------------------
# 10. The operator scripts, baked in. They are agnostic — no realm, target, or
#     credentials — so they belong to the image, and baking them lets the
#     entrypoint own provisioning + supervision (see below). Copied late so the
#     expensive layers above stay cached when a script changes.
# ---------------------------------------------------------------------------
COPY bin/ /opt/gdd-sandbox/bin/
COPY provision/ /opt/gdd-sandbox/provision/
COPY entrypoint.sh /opt/gdd-sandbox/entrypoint.sh
RUN chmod +x /opt/gdd-sandbox/entrypoint.sh /opt/gdd-sandbox/bin/*.sh \
             /opt/gdd-sandbox/provision/*.sh

# ---------------------------------------------------------------------------
# 11. Liveness: is the channels process alive? Process-level only — nothing
#     leaks into a user's chat.
#     NOT log freshness: a session idling correctly between messages writes
#     nothing, so a healthy sandbox would report unhealthy (observed live), and
#     mtime cannot tell idle from wedged anyway. Detecting a genuinely wedged
#     session needs a real probe — that belongs with the observability work.
# ---------------------------------------------------------------------------
HEALTHCHECK --interval=30s --timeout=5s --start-period=180s --retries=3 \
  CMD /opt/gdd-sandbox/bin/healthcheck.sh

WORKDIR /work
# The supervisor is the container's main process, so Docker's restart policy
# actually restores the agent. See entrypoint.sh for why `docker exec -d` is wrong.
ENTRYPOINT ["/opt/gdd-sandbox/entrypoint.sh"]
