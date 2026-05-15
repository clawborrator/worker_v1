#!/bin/sh
# spawn-worker — convenience wrapper around `docker run` that
# spawns a sibling clawborrator-worker container. Designed to be
# called from inside a parent worker (with /var/run/docker.sock
# mounted in) so claude can orchestrate a swarm via its Bash tool
# without having to remember the full docker run incantation.
#
# Required args:
#   --role <name>              becomes the container name suffix
#   --initial-prompt "<text>"  passed as CLAUDE_INITIAL_PROMPT
#
# Optional overrides (default to whatever the parent has in env):
#   --repo-url <url>           override REPO_URL for the child
#   --repo-ref <ref>           override REPO_REF
#   --repo-dir-name <dir>      override REPO_DIR_NAME
#   --no-clone                 force-disable the clone for this child
#   --model <opus|sonnet|haiku|full-id>
#                              override MODEL for this child (default:
#                              whatever the parent has, falling back
#                              to MODEL=haiku at the child's entrypoint)
#   --env KEY=VAL              repeatable; ad-hoc env addition
#   --wait <seconds>           poll the hub until the child appears
#                              (default 30; 0 to skip)
#
# Output (machine-parseable single line on success):
#   SPAWN_OK container=worker-<role>-<ts> routing=@workspace-<8hex>
#
# Inherited from parent env (no flag needed):
#   CLAWBORRATOR_TOKEN, CLAWBORRATOR_HUB_URL,
#   ANTHROPIC_API_KEY, CLAUDE_CODE_OAUTH_TOKEN,
#   ANTHROPIC_ACCESS_TOKEN, ANTHROPIC_REFRESH_TOKEN,
#   ANTHROPIC_TOKEN_EXPIRES_AT, ANTHROPIC_SUBSCRIPTION_TYPE,
#   ANTHROPIC_RATE_LIMIT_TIER, REPO_URL, REPO_REF, REPO_PAT,
#   REPO_PAT_USER, REPO_DIR_NAME, CLAUDE_SKIP_PERMISSIONS,
#   GIT_USER_EMAIL, GIT_USER_NAME, MODEL
#
# Image reference (sibling container's docker image) defaults to
# `ladder99/clawborrator-worker:latest`. Override with WORKER_IMAGE
# for forks / private registries.
#
# All three auth envs are forwarded as-is (empty when unset).
# The child entrypoint's first-match-wins resolution picks the same
# path the parent did:
#   ANTHROPIC_API_KEY  >  CLAUDE_CODE_OAUTH_TOKEN  >  ANTHROPIC_ACCESS_TOKEN
#
# Always set on the child (no opt-out — spawn-worker's identity is
# "ephemeral helper"; if you want a persistent worker, use
# `docker run` directly):
#   CLAWBORRATOR_EPHEMERAL=1   — child's session row is fully
#                                deleted by the hub when its WS
#                                closes (via the new sessions.
#                                delete_on_disconnect flag).

set -e

# ─── Source the parent's spawn-env snapshot ────────────────────
# The parent's entrypoint writes /etc/clawborrator/spawn-env.conf
# at boot with every env var spawn-worker forwards to children.
# We can't rely on `${VAR}` env inheritance here because Claude
# Code redacts ANTHROPIC_* / CLAUDE_CODE_* env vars from Bash-tool
# subprocesses (security feature) — so by the time spawn-worker
# runs from a CC tool call, those vars look empty. Sourcing the
# file restores them locally without leaking back into env.
SPAWN_ENV_FILE="/etc/clawborrator/spawn-env.conf"
if [ -f "${SPAWN_ENV_FILE}" ]; then
  set -a
  # shellcheck disable=SC1090,SC1091
  . "${SPAWN_ENV_FILE}"
  set +a
fi

err() { echo "spawn-worker: $*" >&2; exit 1; }

# ─── Parse args ─────────────────────────────────────────────────
ROLE=""
INITIAL_PROMPT=""
OVERRIDE_REPO_URL=""
OVERRIDE_REPO_REF=""
OVERRIDE_REPO_DIR_NAME=""
OVERRIDE_MODEL=""
NO_CLONE=0
WAIT_SECONDS=30
EXTRA_ENVS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --role)            ROLE="$2"; shift 2 ;;
    --initial-prompt)  INITIAL_PROMPT="$2"; shift 2 ;;
    --repo-url)        OVERRIDE_REPO_URL="$2"; shift 2 ;;
    --repo-ref)        OVERRIDE_REPO_REF="$2"; shift 2 ;;
    --repo-dir-name)   OVERRIDE_REPO_DIR_NAME="$2"; shift 2 ;;
    --model)           OVERRIDE_MODEL="$2"; shift 2 ;;
    --no-clone)        NO_CLONE=1; shift ;;
    --env)             EXTRA_ENVS="${EXTRA_ENVS} -e $2"; shift 2 ;;
    --wait)            WAIT_SECONDS="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) err "unknown flag: $1 (try --help)" ;;
  esac
done

[ -z "${ROLE}" ]            && err "--role is required"
[ -z "${INITIAL_PROMPT}" ]  && err "--initial-prompt is required"

# Sanitize role for use in a docker container name (lowercase
# alphanumeric and dashes only; collapse anything else to '-').
SAFE_ROLE=$(echo "${ROLE}" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9-' '-' | sed 's/--*/-/g; s/^-//; s/-$//')
[ -z "${SAFE_ROLE}" ] && err "--role produced an empty safe name"

CONTAINER_NAME="worker-${SAFE_ROLE}-$(date +%s)"

# ─── Sanity: are we actually able to talk to docker? ───────────
if ! command -v docker >/dev/null 2>&1; then
  err "docker CLI not on PATH — the parent worker image probably wasn't built with the swarm primitive (Dockerfile docker-cli RUN block missing)"
fi
if ! docker info >/dev/null 2>&1; then
  err "docker daemon not reachable — is /var/run/docker.sock mounted into this container? (docker info exit code $?)"
fi

# ─── Resolve repo args (overrides win) ────────────────────────
EFFECTIVE_REPO_URL="${OVERRIDE_REPO_URL:-${REPO_URL:-}}"
EFFECTIVE_REPO_REF="${OVERRIDE_REPO_REF:-${REPO_REF:-}}"
EFFECTIVE_REPO_DIR_NAME="${OVERRIDE_REPO_DIR_NAME:-${REPO_DIR_NAME:-repo}}"
EFFECTIVE_MODEL="${OVERRIDE_MODEL:-${MODEL:-haiku}}"
if [ "${NO_CLONE}" = "1" ]; then
  EFFECTIVE_REPO_URL=""
fi

# ─── Assemble env-flag list ───────────────────────────────────
# Use printf to safely emit each -e flag — values with spaces or
# special chars don't survive a naive shell concatenation, so we
# pass them as separate argv elements via a here-doc parameter
# array.
set -- \
  -e "CLAWBORRATOR_TOKEN=${CLAWBORRATOR_TOKEN:-}" \
  -e "CLAWBORRATOR_HUB_URL=${CLAWBORRATOR_HUB_URL:-wss://next.clawborrator.com}" \
  -e "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}" \
  -e "CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN:-}" \
  -e "ANTHROPIC_ACCESS_TOKEN=${ANTHROPIC_ACCESS_TOKEN:-}" \
  -e "ANTHROPIC_REFRESH_TOKEN=${ANTHROPIC_REFRESH_TOKEN:-}" \
  -e "ANTHROPIC_TOKEN_EXPIRES_AT=${ANTHROPIC_TOKEN_EXPIRES_AT:-}" \
  -e "ANTHROPIC_SUBSCRIPTION_TYPE=${ANTHROPIC_SUBSCRIPTION_TYPE:-max}" \
  -e "ANTHROPIC_RATE_LIMIT_TIER=${ANTHROPIC_RATE_LIMIT_TIER:-default_claude_max_20x}" \
  -e "CLAUDE_SKIP_PERMISSIONS=${CLAUDE_SKIP_PERMISSIONS:-0}" \
  -e "CLAUDE_INITIAL_PROMPT=${INITIAL_PROMPT}" \
  -e "REPO_URL=${EFFECTIVE_REPO_URL}" \
  -e "REPO_REF=${EFFECTIVE_REPO_REF}" \
  -e "REPO_DIR_NAME=${EFFECTIVE_REPO_DIR_NAME}" \
  -e "REPO_PAT=${REPO_PAT:-}" \
  -e "REPO_PAT_USER=${REPO_PAT_USER:-x-access-token}" \
  -e "GIT_USER_EMAIL=${GIT_USER_EMAIL:-}" \
  -e "GIT_USER_NAME=${GIT_USER_NAME:-}" \
  -e "MODEL=${EFFECTIVE_MODEL}" \
  -e "CLAWBORRATOR_EPHEMERAL=1"

# ─── Run ──────────────────────────────────────────────────────
# -d -it: detached + interactive PTY. The expect wrapper inside
# the child needs a TTY to spawn `claude`; without -it, the child
# exits immediately on EOF.
# --rm: container is removed on exit (no lingering stopped rows
# in `docker ps -a`). State that should survive lives in the
# child's own claude-home volume (one per child, created
# implicitly by docker run when not pre-declared).
#
# Image reference defaults to the Docker Hub published name so the
# host doesn't need a local build of worker_v1. Override with
# WORKER_IMAGE if you maintain a fork or have a private registry
# mirror.
WORKER_IMAGE="${WORKER_IMAGE:-ladder99/clawborrator-worker:latest}"
echo "spawn-worker: launching ${CONTAINER_NAME} (role=${ROLE}, image=${WORKER_IMAGE})" >&2
CONTAINER_ID=$(docker run -d -it --rm \
  --name "${CONTAINER_NAME}" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  "$@" \
  ${EXTRA_ENVS} \
  "${WORKER_IMAGE}")

if [ -z "${CONTAINER_ID}" ]; then
  err "docker run returned empty container id"
fi

# ─── Wait for hub registration ─────────────────────────────────
# Poll the child's identity.json inside its container — written by
# clawborrator-mcp on welcome handshake. We can read it via
# `docker exec` because we have the socket. Bail with timeout if
# WAIT_SECONDS > 0 and we never see it.
ROUTING_NAME=""
if [ "${WAIT_SECONDS}" -gt 0 ]; then
  echo "spawn-worker: waiting up to ${WAIT_SECONDS}s for ${CONTAINER_NAME} to register…" >&2
  START=$(date +%s)
  while [ $(($(date +%s) - START)) -lt "${WAIT_SECONDS}" ]; do
    # /workspace/.claude/clawborrator/identity.json appears once
    # the channel WS welcome handshake completes.
    IDENT=$(docker exec "${CONTAINER_ID}" sh -c 'cat /workspace/.claude/clawborrator/identity.json 2>/dev/null' 2>/dev/null || true)
    if [ -n "${IDENT}" ]; then
      ROUTING_NAME=$(echo "${IDENT}" | sed -n 's/.*"routingName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
      [ -n "${ROUTING_NAME}" ] && break
    fi
    sleep 1
  done
  if [ -z "${ROUTING_NAME}" ]; then
    echo "spawn-worker: timeout waiting for registration — container is up but not yet online" >&2
    ROUTING_NAME="(pending)"
  fi
else
  ROUTING_NAME="(skipped)"
fi

echo "SPAWN_OK container=${CONTAINER_NAME} routing=${ROUTING_NAME}"
