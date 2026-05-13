#!/bin/sh
# terminate-worker — companion to spawn-worker. Kills a spawned
# sibling container. Accepts either:
#   - a container name (worker-test-writer-1747059823), or
#   - a routing name (@workspace-2626a003)
#
# When given a routing name, looks up the container whose
# /workspace/.claude/clawborrator/identity.json matches.
#
# Output: TERMINATE_OK container=<name>
#         (or TERMINATE_NOT_FOUND on miss)

set -e

err() { echo "terminate-worker: $*" >&2; exit 1; }

[ $# -ne 1 ] && { echo "usage: terminate-worker <container-name | @routing-name>" >&2; exit 2; }
TARGET="$1"

# ─── Resolve to container name ─────────────────────────────────
if [ "${TARGET#@}" != "${TARGET}" ]; then
  # Starts with `@` — treat as routing name. Iterate worker-*
  # containers; for each, exec a quick cat on its identity.json
  # and grep for the routing name. First match wins.
  ROUTING="${TARGET}"
  CONTAINER_NAME=""
  for c in $(docker ps --filter "name=worker-" --format '{{.Names}}'); do
    IDENT=$(docker exec "${c}" sh -c 'cat /workspace/.claude/clawborrator/identity.json 2>/dev/null' 2>/dev/null || true)
    [ -z "${IDENT}" ] && continue
    THIS=$(echo "${IDENT}" | sed -n 's/.*"routingName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    if [ "${THIS}" = "${ROUTING}" ]; then
      CONTAINER_NAME="${c}"
      break
    fi
  done
  if [ -z "${CONTAINER_NAME}" ]; then
    echo "TERMINATE_NOT_FOUND routing=${ROUTING}"
    exit 0
  fi
else
  CONTAINER_NAME="${TARGET}"
fi

# ─── Kill it ───────────────────────────────────────────────────
if ! docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1; then
  echo "TERMINATE_NOT_FOUND container=${CONTAINER_NAME}"
  exit 0
fi

echo "TERMINATE_OK container=${CONTAINER_NAME}"
