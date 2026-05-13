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

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY claude-with-autoenter.expect /usr/local/bin/claude-with-autoenter.expect
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/claude-with-autoenter.expect

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
#   ANTHROPIC_ACCESS_TOKEN       required — OAuth access token (sk-ant-oat01-…);
#                                          written into ~/.claude/.credentials.json
#   ANTHROPIC_REFRESH_TOKEN      optional — refresh token (sk-ant-ort01-…);
#                                          required for auto-renewal of long-lived workers
#   ANTHROPIC_TOKEN_EXPIRES_AT   optional — unix ms expiry; defaults far-future
#   ANTHROPIC_SUBSCRIPTION_TYPE  optional — default "max"
#   ANTHROPIC_RATE_LIMIT_TIER    optional — default "default_claude_max_20x"
#   CLAWBORRATOR_TOKEN           optional — ck_live_… channel token; if set,
#                                          the worker registers with the hub
#   CLAWBORRATOR_HUB_URL         optional — default wss://next.clawborrator.com
#   REPO_URL                     optional — git clone into /workspace on first run
#   REPO_REF                     optional — branch / tag / sha to checkout after clone
#   CLAUDE_SKIP_PERMISSIONS      optional — "1" to pass --dangerously-skip-permissions
#                                          (only safe in a sandboxed/throwaway container)
#   CLAUDE_INITIAL_PROMPT        optional — single prompt to feed claude on startup
#
# Anything after the image name on `docker run` becomes extra args
# forwarded verbatim to `claude`.

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD []
