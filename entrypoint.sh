#!/bin/sh
# worker_v1 entrypoint. Two-phase script:
#
#   Phase 1 (root): validate env, write
#       ~/.claude/.credentials.json, seed onboarding state in
#       ~/.claude.json + ~/.claude/settings.json, chown
#       /workspace + ~worker so the bind mount and config files
#       are writable by the worker user, then re-exec self under
#       gosu as `worker`.
#
#   Phase 2 (worker): cd /workspace, optional repo clone, optional
#       .mcp.json write for clawborrator integration, exec claude
#       with the right flag set.
#
# Why two phases:
#   - Claude Code's --dangerously-skip-permissions refuses to run
#     as root.
#   - Bind-mounted /workspace can arrive owned by a uid the worker
#     user can't write to (Docker creates the dir as root if it
#     didn't exist on the host).
#
# Idempotent on restart: priv'd writes overwrite, clone skips if
# .git is already present. The actual workspace state (CC's
# persisted session, .claude/clawborrator/identity.json, uncommitted
# edits) survives across restarts via the /workspace volume.

set -e

WORKER_USER="worker"
WORKER_HOME="/home/${WORKER_USER}"

# ════════════════════════════════════════════════════════════════
# Phase 1 — root setup
# ════════════════════════════════════════════════════════════════
if [ "$(id -u)" = "0" ]; then

  # ─── Required env ──────────────────────────────────────────────
  # Two auth paths, in order of preference:
  #   1. ANTHROPIC_API_KEY  — sk-ant-api03-… raw API key. Claude
  #      Code reads it directly from env; no .credentials.json
  #      needed. Simplest, doesn't rotate, doesn't share a refresh
  #      chain with any other process. Billed against the API
  #      account (NOT the Max subscription).
  #   2. ANTHROPIC_ACCESS_TOKEN  — sk-ant-oat01-… OAuth access
  #      token from a Claude Max account. Entrypoint seeds
  #      ~/.claude/.credentials.json from env on first boot;
  #      claude refreshes the token chain itself thereafter via
  #      the persisted volume. Bills against the Max subscription.
  #
  # Exactly one is required. If ANTHROPIC_API_KEY is set we skip
  # the OAuth credentials seeding entirely — the API key path
  # doesn't need a .credentials.json file at all.
  CREDS_DIR="${WORKER_HOME}/.claude"
  CREDS_FILE="${CREDS_DIR}/.credentials.json"
  GLOBAL_CFG="${WORKER_HOME}/.claude.json"
  SETTINGS_FILE="${CREDS_DIR}/settings.json"
  mkdir -p "${CREDS_DIR}"

  if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    # API key path — nothing to seed on disk. Claude Code reads
    # ANTHROPIC_API_KEY directly from env at startup. We still
    # need ~/.claude/ to exist (for project state, hooks,
    # settings.local) but the credentials file isn't part of it.
    echo "[worker] using ANTHROPIC_API_KEY (raw API auth — bills against API account, not Max)"
  elif [ -n "${ANTHROPIC_ACCESS_TOKEN:-}" ]; then
    # ─── Write OAuth credentials file ──────────────────────────────
    # Schema mirrors what `claude` writes after an interactive OAuth
    # login: a single `claudeAiOauth` block. jq binds secrets as
    # parameters so a token with an odd char can't break the JSON.
    #
    # First-boot seed only — when ${WORKER_HOME}/.claude is a
    # docker named volume, the file survives container restart.
    # Claude Code rewrites .credentials.json itself whenever it
    # refreshes the OAuth token chain; overwriting on every boot
    # would destroy the freshly-refreshed credentials.
    #
    # Defaults:
    #   - refreshToken: empty. Without it, no auto-renewal.
    #   - expiresAt: 9999999999999 (far future) so claude doesn't
    #     proactively refresh on a stale-looking timestamp.
    #   - scopes: the full Claude-Code-issued set.
    #   - subscriptionType + rateLimitTier: match Claude Max.
    if [ -f "${CREDS_FILE}" ]; then
      echo "[worker] ${CREDS_FILE} already present — keeping (worker maintains its own OAuth chain)"
    else
      jq -n \
        --arg at   "${ANTHROPIC_ACCESS_TOKEN}" \
        --arg rt   "${ANTHROPIC_REFRESH_TOKEN:-}" \
        --argjson exp "${ANTHROPIC_TOKEN_EXPIRES_AT:-9999999999999}" \
        --arg sub  "${ANTHROPIC_SUBSCRIPTION_TYPE:-max}" \
        --arg tier "${ANTHROPIC_RATE_LIMIT_TIER:-default_claude_max_20x}" \
        '{
          claudeAiOauth: {
            accessToken:      $at,
            refreshToken:     $rt,
            expiresAt:        $exp,
            scopes: [
              "user:file_upload",
              "user:inference",
              "user:mcp_servers",
              "user:profile",
              "user:sessions:claude_code"
            ],
            subscriptionType: $sub,
            rateLimitTier:    $tier
          }
        }' > "${CREDS_FILE}"
      chmod 600 "${CREDS_FILE}"
      echo "[worker] seeded ${CREDS_FILE} from env (claudeAiOauth, subscription=${ANTHROPIC_SUBSCRIPTION_TYPE:-max})"
    fi
  else
    echo "[worker] either ANTHROPIC_API_KEY or ANTHROPIC_ACCESS_TOKEN is required" >&2
    echo "         API key:    set ANTHROPIC_API_KEY=sk-ant-api03-…" >&2
    echo "         OAuth (Max): set ANTHROPIC_ACCESS_TOKEN=sk-ant-oat01-…" >&2
    echo "                      (pull from your local install:" >&2
    echo "                      cat ~/.claude/.credentials.json | jq '.claudeAiOauth.accessToken')" >&2
    exit 1
  fi

  # ─── Pre-seed Claude Code onboarding state (first boot only) ───
  # A headless worker can't answer first-run prompts. Pre-write the
  # global ~/.claude.json with the keys that skip every interactive
  # bootstrap step: welcome flow, theme picker, "trust this folder?",
  # CLAUDE.md external-includes warning, bypass-permissions warning,
  # MCP-server approval. Keys extracted from a known-good local
  # install. First-boot-only because claude itself updates this file
  # over time (recent dirs, per-project state) and we don't want to
  # clobber that on restart.
  NOW_ISO=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
  if [ -f "${GLOBAL_CFG}" ]; then
    echo "[worker] ${GLOBAL_CFG} already present — keeping (claude maintains project state)"
  else
    jq -n \
      --arg now "${NOW_ISO}" \
      '{
        hasCompletedOnboarding:   true,
        firstStartTime:           $now,
        installMethod:            "native",
        autoUpdates:              false,
        projects: {
          "/workspace": {
            hasTrustDialogAccepted:                  true,
            hasClaudeMdExternalIncludesApproved:     true,
            hasClaudeMdExternalIncludesWarningShown: true,
            # enableAllProjectMcpServers + enabledMcpjsonServers
            # pre-resolve the "New MCP server found in .mcp.json"
            # approval prompt. Belt-and-suspenders in case a future
            # CC version checks only one of the two keys.
            enableAllProjectMcpServers:              true,
            enabledMcpjsonServers:                   ["clawborrator"]
          }
        }
      }' > "${GLOBAL_CFG}"
    echo "[worker] seeded ${GLOBAL_CFG}"
  fi

  # settings.json is rewritten on every boot — it's env-driven
  # configuration (CLAUDE_SKIP_PERMISSIONS toggle takes effect on
  # restart), not state. Claude code doesn't mutate this file at
  # runtime, so overwriting is safe.
  SKIP_DANGEROUS=$([ "${CLAUDE_SKIP_PERMISSIONS:-0}" = "1" ] && echo true || echo false)
  jq -n \
    --argjson skipDangerous "${SKIP_DANGEROUS}" \
    '{
      theme:                              "dark",
      editorMode:                         "normal",
      skipAutoPermissionPrompt:           true,
      skipDangerousModePermissionPrompt:  $skipDangerous,
      permissions: {
        defaultMode: "auto"
      }
    }' > "${SETTINGS_FILE}"
  echo "[worker] wrote ${SETTINGS_FILE} (skipDangerous=${SKIP_DANGEROUS})"

  # Fix ownership before dropping privileges. Bind-mounted /workspace
  # may have arrived owned by some other uid (Docker creates the
  # bind-mount target as root if it didn't exist on the host); the
  # worker user needs to own it to write .mcp.json + run claude.
  chown -R "${WORKER_USER}:${WORKER_USER}" "${WORKER_HOME}"
  chown -R "${WORKER_USER}:${WORKER_USER}" /workspace

  # ─── Docker socket access (optional — only if mounted) ─────────
  # If /var/run/docker.sock is mounted in, give the worker user
  # access. The socket arrives with whatever GID the host's docker
  # group uses (varies by platform), which won't match any group
  # the worker user is in by default. Solution: read the socket's
  # GID, create a matching group inside the container (or use any
  # existing group with that GID), add worker to it.
  #
  # The worker is added to the existing group whose GID matches —
  # if no group exists at that GID, we create one called
  # `docker_host`. This is the standard "Docker outside of Docker"
  # permission pattern.
  #
  # Skipping the socket mount entirely (the default for workers
  # that don't need to spawn) means this block silently no-ops.
  if [ -S /var/run/docker.sock ]; then
    SOCK_GID=$(stat -c '%g' /var/run/docker.sock)
    SOCK_GROUP=$(getent group "${SOCK_GID}" | cut -d: -f1 || true)
    if [ -z "${SOCK_GROUP}" ]; then
      groupadd --gid "${SOCK_GID}" docker_host
      SOCK_GROUP=docker_host
    fi
    usermod -aG "${SOCK_GROUP}" "${WORKER_USER}"
    echo "[worker] docker.sock detected (gid=${SOCK_GID}, group=${SOCK_GROUP}) — ${WORKER_USER} added"
  fi

  # Drop privileges via gosu. HOME is set explicitly so claude
  # finds the credentials we just wrote.
  export HOME="${WORKER_HOME}"
  exec gosu "${WORKER_USER}" "$0" "$@"
fi

# ════════════════════════════════════════════════════════════════
# Phase 2 — worker
# ════════════════════════════════════════════════════════════════

cd /workspace

# ─── Git identity ──────────────────────────────────────────────
# Without these, the first commit fails with "Please tell me who you
# are" and claude burns a turn running `git config user.email/name`
# itself. Cheap to set per-boot; lives in ~/.gitconfig (worker's
# HOME, not the persisted ~/.claude volume) so it always reflects
# the current env. Empty env → skip (and claude will see the friendly
# git error on the first commit, no harm).
if [ -n "${GIT_USER_EMAIL:-}" ]; then
  git config --global user.email "${GIT_USER_EMAIL}"
fi
if [ -n "${GIT_USER_NAME:-}" ]; then
  git config --global user.name  "${GIT_USER_NAME}"
fi
if [ -n "${GIT_USER_EMAIL:-}" ] || [ -n "${GIT_USER_NAME:-}" ]; then
  echo "[worker] git identity: ${GIT_USER_NAME:-(unset)} <${GIT_USER_EMAIL:-(unset)}>"
fi

# ─── Model selection ──────────────────────────────────────────
# MODEL accepts the friendly aliases opus | sonnet | haiku and
# translates to the explicit model ID via ANTHROPIC_MODEL. Anything
# else is passed through verbatim, so operators can pin to an
# exact version if they want. Default haiku — cheap fast model
# right for most worker-pool workloads.
#
# Export so claude (the child process) inherits ANTHROPIC_MODEL.
case "${MODEL:-haiku}" in
  opus)
    export ANTHROPIC_MODEL=claude-opus-4-7
    ;;
  sonnet)
    export ANTHROPIC_MODEL=claude-sonnet-4-6
    ;;
  haiku)
    export ANTHROPIC_MODEL=claude-haiku-4-5-20251001
    ;;
  "")
    export ANTHROPIC_MODEL=claude-haiku-4-5-20251001
    ;;
  *)
    # Pass through full IDs untouched (e.g., a future
    # `claude-opus-5-0` or a snapshot ID).
    export ANTHROPIC_MODEL="${MODEL}"
    ;;
esac
echo "[worker] model: ${MODEL:-haiku} (ANTHROPIC_MODEL=${ANTHROPIC_MODEL})"

# ─── Optional repo clone ─────────────────────────────────────────
# Claude's cwd is /workspace, NOT the cloned repo. We clone one
# level deeper into /workspace/${REPO_DIR_NAME:-repo} so the repo's
# working tree stays untouched by worker plumbing (.mcp.json, .claude/,
# CLAUDE.md all live at /workspace/, not inside the repo). Trade-off:
# `git status` from claude's cwd fails — operator/claude has to
# `cd repo` or use `git -C repo …`. The /workspace/CLAUDE.md note
# written below orients claude to this layout.
#
# Only clones if REPO_URL is set AND the target dir doesn't already
# have a .git directory. So the second container boot reuses the
# existing checkout — git pull is up to whatever Claude or the
# operator runs.
REPO_DIR="/workspace/${REPO_DIR_NAME:-repo}"
if [ -n "${REPO_URL:-}" ]; then
  if [ -d "${REPO_DIR}/.git" ]; then
    echo "[worker] ${REPO_DIR} already contains a git checkout — skipping clone"
  else
    # Splice PAT into the URL if one was supplied. We rewrite into
    # https://<user>:<pat>@<host>/<path>. The full credentialed URL
    # is what `git clone` actually uses; we only echo the redacted
    # form so the PAT doesn't end up in `docker logs`. It DOES still
    # land in ${REPO_DIR}/.git/config after clone (so subsequent
    # fetch/push from inside CC keep working) — see .env.example
    # for the security caveat.
    EFFECTIVE_REPO_URL="${REPO_URL}"
    if [ -n "${REPO_PAT:-}" ]; then
      case "${REPO_URL}" in
        https://*)
          host_path="${REPO_URL#https://}"
          EFFECTIVE_REPO_URL="https://${REPO_PAT_USER:-x-access-token}:${REPO_PAT}@${host_path}"
          echo "[worker] cloning ${REPO_URL} into ${REPO_DIR} (PAT spliced)"
          ;;
        *)
          echo "[worker] REPO_PAT set but REPO_URL is not https:// — cloning without credentials"
          echo "[worker] cloning ${REPO_URL} into ${REPO_DIR}"
          ;;
      esac
    else
      echo "[worker] cloning ${REPO_URL} into ${REPO_DIR}"
    fi
    # `git clone … <target>` creates the target dir; ensure parent
    # exists and is writable.
    mkdir -p "$(dirname "${REPO_DIR}")"
    # Don't `set -e`-exit on a missing ref — that's a recoverable
    # state (e.g., empty repo with no main yet); just warn.
    if ! git clone "${EFFECTIVE_REPO_URL}" "${REPO_DIR}"; then
      echo "[worker] git clone failed — continuing without a repo (you can clone manually inside the container)"
    elif [ -n "${REPO_REF:-}" ]; then
      echo "[worker] checking out ref ${REPO_REF}"
      git -C "${REPO_DIR}" checkout "${REPO_REF}" || \
        echo "[worker] ref ${REPO_REF} not found — staying on default branch"
    fi
  fi
fi

# ─── Orient claude to the /workspace layout ──────────────────────
# /workspace/CLAUDE.md tells claude "the codebase is in ./repo —
# don't touch .mcp.json or .claude/ here, those are worker plumbing."
# Written on every boot since it's a static reference, but only if
# absent so the operator can override by writing their own.
CLAUDE_MD="/workspace/CLAUDE.md"
if [ ! -f "${CLAUDE_MD}" ]; then
  REPO_DIR_REL="${REPO_DIR_NAME:-repo}"
  cat > "${CLAUDE_MD}" <<EOF
# Worker container layout

You are running inside a clawborrator worker_v1 docker container.
Your current working directory is \`/workspace\`, but **the actual
codebase you are here to work on is in \`./${REPO_DIR_REL}/\`**.

For most operations:

- \`cd ${REPO_DIR_REL}\` first, or use \`git -C ${REPO_DIR_REL} …\`
- Reference repo files as \`${REPO_DIR_REL}/path/to/file\` from
  this cwd, or as relative paths after \`cd\`-ing in.

Files at the \`/workspace/\` level are worker plumbing and should
not be modified or committed anywhere:

- \`.mcp.json\` — clawborrator MCP server config.
- \`.claude/\` — project-level hooks, settings.local, MCP plugin state.
- \`CLAUDE.md\` — this file.

Anything under \`/workspace/${REPO_DIR_REL}/\` is fair game and is
what the operator expects you to read, edit, and commit.

## Spawning sibling workers (swarm pattern)

If \`docker --version\` works in your Bash tool, this container has
the Docker socket mounted and you can spawn sibling worker containers
on the same Docker host. Use the helper scripts (preferred) — they
inherit credentials and config from this worker's env so you don't
have to remember the docker run incantation:

\`\`\`bash
# Spawn one sibling to do a specific subtask:
spawn-worker --role "test-writer-foo" \\
             --initial-prompt "Write a Jest test for ${REPO_DIR_REL}/src/components/Foo.tsx. Commit on branch test-foo. Reply when done."
# → SPAWN_OK container=worker-test-writer-foo-1747059823 routing=@workspace-2626a003

# The child shows up in mcp__clawborrator__list_peers under that routing name
# within ~10–15s. Dispatch work to it with mcp__clawborrator__route_to_peer.

# Clean up when done:
terminate-worker @workspace-2626a003           # by routing name
terminate-worker worker-test-writer-foo-…      # OR by container name
\`\`\`

\`spawn-worker --help\` shows the full flag set. By default each child
inherits the SAME repo, credentials, and hub config as this worker.
Override per-child with \`--repo-url\`, \`--repo-ref\`, \`--no-clone\`,
\`--env KEY=VAL\` (repeatable), \`--wait <seconds>\`.

**When to use the swarm pattern:**
- The task naturally parallelizes (N independent files, N repos, N branches).
- You want a child to operate in a sandboxed copy without polluting your own context.
- A subtask is expensive enough that running it in parallel saves wall-clock time.

**When NOT to use:**
- The task is small enough to do here directly — spawning is ~15s overhead per child + Docker memory cost.
- You're not sure exactly what the children should do — spawn workers with vague prompts and they'll burn quota idling.
- You only need a one-off answer — \`mcp__clawborrator__probe_peers\` against existing peers is cheaper.

**Patterns that work well:**
- Fan-out: \`for f in ./files; do spawn-worker --role "process-\$f" --initial-prompt "do X to \$f"; done\` — then aggregate via peer reports.
- Cap-in-flight: before each new spawn, check \`list_peers\` and only spawn if active children < cap.
- Self-cleanup: instruct each child to commit + push + exit on completion; you watch for the peer report and call \`terminate-worker\`.

If you spawn workers and run out of work, kill them — every running child is consuming Anthropic quota.
EOF
  echo "[worker] wrote ${CLAUDE_MD}"
fi

# ─── Optional clawborrator integration ───────────────────────────
HUB_URL="${CLAWBORRATOR_HUB_URL:-wss://next.clawborrator.com}"
FLAGS=""
if [ -n "${CLAWBORRATOR_TOKEN:-}" ]; then
  echo "[worker] writing .mcp.json — clawborrator hub=${HUB_URL}"
  jq -n \
    --arg hub  "${HUB_URL}" \
    --arg tok  "${CLAWBORRATOR_TOKEN}" \
    '{
      mcpServers: {
        clawborrator: {
          command: "npx",
          args:    ["-y", "clawborrator-mcp"],
          env: {
            CLAWBORRATOR_HUB_URL: $hub,
            CLAWBORRATOR_TOKEN:   $tok
          }
        }
      }
    }' > .mcp.json
  chmod 600 .mcp.json
  # --dangerously-load-development-channels enables in-band channel
  # notifications (`<channel source="..." chat_id="…">` tags showing
  # up inline in Claude's context). The non-dangerous --channels
  # flag connects the WS but doesn't surface inbound prompts to
  # claude, so routed prompts from the hub silently disappear.
  # The dangerously flag triggers a startup prompt; we accept it
  # via the expect wrapper (USE_EXPECT_WRAPPER=1 below).
  FLAGS="${FLAGS} --dangerously-load-development-channels server:clawborrator"
  USE_EXPECT_WRAPPER=1
fi

# ─── Permission mode ─────────────────────────────────────────────
if [ "${CLAUDE_SKIP_PERMISSIONS:-0}" = "1" ]; then
  FLAGS="${FLAGS} --dangerously-skip-permissions"
fi

# When ANTHROPIC_API_KEY is set, claude shows a "Do you want to use
# this API key?" prompt with default = "No (recommended)". A
# headless worker can't answer it, so we use the expect wrapper
# (it handles BOTH the API-key prompt and the dev-channels one).
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  USE_EXPECT_WRAPPER=1
fi

# ─── Launch ──────────────────────────────────────────────────────
# Wrap claude in the expect script when there are startup prompts
# we need to auto-dismiss (dev-channels warning, API-key approval).
# Standalone OAuth runs without clawborrator skip the wrapper since
# there's no prompt to dismiss.
if [ "${USE_EXPECT_WRAPPER:-0}" = "1" ]; then
  LAUNCHER="/usr/local/bin/claude-with-autoenter.expect"
else
  LAUNCHER="claude"
fi

if [ -n "${CLAUDE_INITIAL_PROMPT:-}" ]; then
  echo "[worker] launching ${LAUNCHER} with initial prompt (${#CLAUDE_INITIAL_PROMPT} chars)"
  # shellcheck disable=SC2086  # FLAGS is intentionally word-split
  exec "${LAUNCHER}" ${FLAGS} "$@" "${CLAUDE_INITIAL_PROMPT}"
fi

echo "[worker] launching ${LAUNCHER} in /workspace"
# shellcheck disable=SC2086  # FLAGS is intentionally word-split
exec "${LAUNCHER}" ${FLAGS} "$@"
