# syntax=docker/dockerfile:1
#
# worker_v1 — headless Claude Code in a container.
#
# Boots a single `claude` process inside /workspace. Optional
# clawborrator integration: pass a channel token and the worker
# registers with the hub on first run, accepting remote prompts
# from any operator with access to the session.
#
# Process model: ONE Claude Code per container, foreground, no
# supervisor daemon. Container exits when claude exits. For
# multi-session-per-host, use the desktop_v1 supervisor pattern
# instead — this image is the "ephemeral worker / CI agent / one-
# off task runner" shape.

FROM node:22-bookworm-slim

# git + ca-certificates for the optional repo-clone path; curl + jq
# left in for debugging (small, useful in CC's Bash environment).
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        git \
        ca-certificates \
        curl \
        jq \
        gosu \
        expect && \
    rm -rf /var/lib/apt/lists/*

# Claude Code itself + the clawborrator CLI (for any in-container
# token / session inspection an operator might run). Both global so
# `claude` and `claw` are on PATH without npx overhead.
RUN npm install -g \
        @anthropic-ai/claude-code \
        clawborrator-cli

# Docker CLI (client only, no daemon). Enables the "Docker outside of
# Docker" pattern: when /var/run/docker.sock is bind-mounted in, the
# worker can spawn sibling containers on the host daemon. Pinned to a
# specific version for reproducible builds; bump as needed. The
# tarball ships static binaries — just pull out the client.
#
# Security caveat: mounting docker.sock = root on host. Only do it
# when you want the swarm pattern. See README.
ARG DOCKER_CLI_VERSION=27.4.0
RUN curl -fsSL "https://download.docker.com/linux/static/stable/x86_64/docker-${DOCKER_CLI_VERSION}.tgz" \
      | tar -xz -C /tmp \
    && mv /tmp/docker/docker /usr/local/bin/docker \
    && rm -rf /tmp/docker \
    && docker --version

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY claude-with-autoenter.expect /usr/local/bin/claude-with-autoenter.expect
# Swarm-orchestration helpers. Only meaningful in workers that have
# /var/run/docker.sock mounted in (see compose); they shell out to
# the `docker` CLI installed above. Always available on PATH so
# claude doesn't have to hunt for them.
COPY spawn-worker.sh /usr/local/bin/spawn-worker
COPY terminate-worker.sh /usr/local/bin/terminate-worker
RUN chmod +x /usr/local/bin/entrypoint.sh \
             /usr/local/bin/claude-with-autoenter.expect \
             /usr/local/bin/spawn-worker \
             /usr/local/bin/terminate-worker

# Non-root identity. Claude Code's --dangerously-skip-permissions
# refuses to run as root ("for security reasons"), so when
# CLAUDE_SKIP_PERMISSIONS=1 we need a real user. uid 1001 matches
# the default non-system uid on most Linux hosts.
#
# Container STARTS as root so the entrypoint can chown bind-mounted
# /workspace (which Docker may have created with host-side ownership
# the container user can't write to) and write the credentials files
# under the worker's HOME. Last action of entrypoint is
# `exec gosu worker claude …` — actual claude process runs unprivileged.
RUN useradd --create-home --uid 1001 --shell /bin/bash worker && \
    mkdir -p /workspace && \
    chown -R worker:worker /workspace

WORKDIR /workspace

# Environment contract (full doc in README.md):
#   ANTHROPIC_API_KEY            one of two — raw API key (sk-ant-api03-…); used
#                                          directly by claude (no credentials.json).
#                                          Bills against API account, not Max.
#   ANTHROPIC_ACCESS_TOKEN       one of two — OAuth access token (sk-ant-oat01-…);
#                                          written into ~/.claude/.credentials.json.
#                                          Bills against Max subscription.
#   ANTHROPIC_REFRESH_TOKEN      optional — refresh token (sk-ant-ort01-…);
#                                          required for auto-renewal of long-lived workers
#   ANTHROPIC_TOKEN_EXPIRES_AT   optional — unix ms expiry; defaults far-future
#   ANTHROPIC_SUBSCRIPTION_TYPE  optional — default "max"
#   ANTHROPIC_RATE_LIMIT_TIER    optional — default "default_claude_max_20x"
#   MODEL                        optional — opus | sonnet | haiku (default haiku);
#                                          entrypoint exports ANTHROPIC_MODEL with full id
#   CLAWBORRATOR_TOKEN           optional — ck_live_… channel token; if set,
#                                          the worker registers with the hub
#   CLAWBORRATOR_HUB_URL         optional — default wss://next.clawborrator.com
#   REPO_URL                     optional — git clone into /workspace on first run
#   REPO_REF                     optional — branch / tag / sha to checkout after clone
#   REPO_PAT                     optional — PAT spliced into REPO_URL for private clones
#   REPO_PAT_USER                optional — username paired with REPO_PAT (default x-access-token)
#   REPO_DIR_NAME                optional — subdir under /workspace for the clone (default `repo`)
#   GIT_USER_EMAIL               optional — `git config --global user.email` for commits inside the worker
#   GIT_USER_NAME                optional — `git config --global user.name`  for commits inside the worker
#   CLAUDE_SKIP_PERMISSIONS      optional — "1" to pass --dangerously-skip-permissions
#                                          (only safe in a sandboxed/throwaway container)
#   CLAUDE_INITIAL_PROMPT        optional — single prompt to feed claude on startup
#   DISABLE_AUTOENTER            optional — "1" to skip the expect wrapper that
#                                          auto-dismisses startup prompts (so you
#                                          can `docker attach` and answer them)
#
# Anything after the image name on `docker run` becomes extra args
# forwarded verbatim to `claude`.

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD []
