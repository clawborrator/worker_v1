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
        expect \
        tini && \
    rm -rf /var/lib/apt/lists/*

# Claude Code itself + the clawborrator CLI (for any in-container
# token / session inspection an operator might run) + mongodb-mcp-server
# (the canonical MongoDB MCP server used by data-grounded specialists).
# All global so `claude`, `claw`, and `mongodb-mcp-server` are on PATH
# without npx overhead — important because npx -y mongodb-mcp-server
# flattens transitive deps in a way that breaks Node's strict ESM
# resolver as non-root (a fast-string-truncated-width import explodes
# from inside fast-string-width). Globally-installed packages get the
# standard /usr/local/lib/node_modules layout where resolution works.
# mongodb-mcp-server@1.11.0 — works correctly when globally installed.
# The package's 1.11.0 release has a transitive-dep packaging issue
# (@mcp-ui/server@6.1.0's `exports.import` points at a missing .mjs)
# that surfaces ONLY when invoked via `npx -y` because of the flat
# cache layout npx uses. With `npm install -g`, the standard nested
# node_modules layout resolves the import path correctly. Verified
# in this image as worker uid 1001 before committing the pin.
RUN npm install -g \
        @anthropic-ai/claude-code \
        clawborrator-cli \
        clawborrator-mcp \
        mongodb-mcp-server@1.11.0

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
#   Auth — first-match-wins across these three, lower-priority envs unset:
#   ANTHROPIC_API_KEY            preferred for API-billed inference. Raw key
#                                          (sk-ant-api03-…); read directly from env.
#                                          Bills against API account; disables channels.
#   CLAUDE_CODE_OAUTH_TOKEN      preferred for Max-billed inference. OAuth token
#                                          (sk-ant-oat01-…) from `claude setup-token`;
#                                          read directly from env. Channels work.
#   ANTHROPIC_ACCESS_TOKEN       legacy OAuth — same token shape as above; worker
#                                          seeds ~/.claude/.credentials.json from it
#                                          on first boot. Use only when setup-token
#                                          isn't available.
#   ANTHROPIC_REFRESH_TOKEN      optional — refresh token (sk-ant-ort01-…) paired with
#                                          ANTHROPIC_ACCESS_TOKEN; required for
#                                          auto-renewal of long-lived workers on Path C.
#   ANTHROPIC_TOKEN_EXPIRES_AT   optional — unix ms expiry; defaults far-future
#   ANTHROPIC_SUBSCRIPTION_TYPE  optional — default "max"
#   ANTHROPIC_RATE_LIMIT_TIER    optional — default "default_claude_max_20x"
#   MODEL                        optional — opus | sonnet | haiku (default haiku);
#                                          entrypoint exports ANTHROPIC_MODEL with full id
#   CLAWBORRATOR_TOKEN           optional — ck_live_… channel token; if set,
#                                          the worker registers with the hub
#   CLAWBORRATOR_HUB_URL         optional — default wss://next.clawborrator.com
#   CLAWBORRATOR_ROUTING_NAME    optional — operator-supplied routing name
#                                          (e.g. "reddit-engager"). When set,
#                                          the MCP includes it in the register
#                                          frame and the hub uses it as the
#                                          candidate name instead of deriving
#                                          from cwd. Normalized to lowercase +
#                                          dash-only slug. Without it every
#                                          worker_v1 container collides on
#                                          @workspace and gets UUID-suffixed.
#                                          Requires clawborrator-mcp >= 0.0.37
#                                          and a hub deployment that honors
#                                          the field (next.clawborrator.com +
#                                          dodgevipertech do as of 2026-05-17).
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

# tini as PID 1. The base entrypoint chains into `expect` (Claude
# Code TUI wrapper) which is not a process reaper — any subprocess
# (claude itself, MCP servers spawned via npx, chromium in the
# playwright variant) that exits without being wait()'d leaves a
# zombie under PID 1. Long-running workers accumulate these until
# the container's pids.max is exhausted (~977 default on cgroup v2),
# at which point new processes can't be spawned and the worker is
# effectively dead. tini's whole job is SIGCHLD reaping, so wrapping
# entrypoint with `tini --` fixes this for every worker derived
# from this base. No effect on workers that don't accumulate
# zombies (most bench specialists) — pure upside.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD []
