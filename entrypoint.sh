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
  if [ -z "${ANTHROPIC_ACCESS_TOKEN:-}" ]; then
    echo "[worker] ANTHROPIC_ACCESS_TOKEN is required — Claude Code reads it from" >&2
    echo "         ~/.claude/.credentials.json to call the model API." >&2
    echo "         Pull yours from your local Claude Code install:" >&2
    echo "           cat ~/.claude/.credentials.json | jq '.claudeAiOauth.accessToken'" >&2
    exit 1
  fi

  # ─── Write OAuth credentials file ──────────────────────────────
  # Schema mirrors what `claude` writes after an interactive OAuth
  # login: a single `claudeAiOauth` block. We use jq (apt-installed)
  # to bind secrets as parameters rather than splicing them into a
  # heredoc — no risk of malformed JSON if a token has an odd char.
  #
  # Defaults:
  #   - refreshToken: empty. Without it, no auto-renewal; long-
  #     running workers fail when the access token expires (~14d).
  #   - expiresAt: 9999999999999 (far future) so claude doesn't
  #     proactively refresh on a stale-looking timestamp.
  #   - scopes: the full Claude-Code-issued set.
  #   - subscriptionType + rateLimitTier: match Claude Max.
  CREDS_DIR="${WORKER_HOME}/.claude"
  CREDS_FILE="${CREDS_DIR}/.credentials.json"
  mkdir -p "${CREDS_DIR}"

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
  echo "[worker] wrote ${CREDS_FILE} (claudeAiOauth, subscription=${ANTHROPIC_SUBSCRIPTION_TYPE:-max})"

  # ─── Pre-seed Claude Code onboarding state ─────────────────────
  # A headless worker can't answer first-run prompts. Pre-write the
  # global ~/.claude.json and ~/.claude/settings.json with the keys
  # that skip every interactive bootstrap step: welcome flow, theme
  # picker, "trust this folder?", CLAUDE.md external-includes
  # warning, bypass-permissions warning, MCP-server approval. Keys
  # extracted from a known-good local install.
  NOW_ISO=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
  GLOBAL_CFG="${WORKER_HOME}/.claude.json"

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

  SETTINGS_FILE="${CREDS_DIR}/settings.json"
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

  echo "[worker] seeded onboarding state in ${GLOBAL_CFG} + ${SETTINGS_FILE}"

  # Fix ownership before dropping privileges. Bind-mounted /workspace
  # may have arrived owned by some other uid (Docker creates the
  # bind-mount target as root if it didn't exist on the host); the
  # worker user needs to own it to write .mcp.json + run claude.
  chown -R "${WORKER_USER}:${WORKER_USER}" "${WORKER_HOME}"
  chown -R "${WORKER_USER}:${WORKER_USER}" /workspace

  # Drop privileges via gosu. HOME is set explicitly so claude
  # finds the credentials we just wrote.
  export HOME="${WORKER_HOME}"
  exec gosu "${WORKER_USER}" "$0" "$@"
fi

# ════════════════════════════════════════════════════════════════
# Phase 2 — worker
# ════════════════════════════════════════════════════════════════

cd /workspace

# ─── Optional repo clone ─────────────────────────────────────────
# Only clones if REPO_URL is set AND /workspace doesn't already
# have a .git directory. So the second container boot reuses the
# existing checkout — git pull is up to whatever Claude or the
# operator runs.
if [ -n "${REPO_URL:-}" ]; then
  if [ -d /workspace/.git ]; then
    echo "[worker] /workspace already contains a git checkout — skipping clone"
  else
    echo "[worker] cloning ${REPO_URL} into /workspace"
    git clone "${REPO_URL}" /workspace
    if [ -n "${REPO_REF:-}" ]; then
      echo "[worker] checking out ref ${REPO_REF}"
      git -C /workspace checkout "${REPO_REF}"
    fi
  fi
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

# ─── Launch ──────────────────────────────────────────────────────
# When the dangerously-load-development-channels flag is on (the
# clawborrator path), wrap claude in an expect script that
# auto-accepts the dev-channels warning prompt. Standalone runs
# skip the wrapper since there's no prompt to dismiss.
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
