# worker_v1 — headless Claude Code in Docker

A single-container Claude Code worker. Optional clawborrator
integration so operators can drive the worker remotely from a
browser / CLI without sshing into the box.

Process model: ONE Claude Code per container, foregrounded. Container
exits when `claude` exits. For multi-CC-per-host you want the
[`desktop_v1`](../desktop_v1) supervisor pattern instead — this image
is the "ephemeral worker / CI agent / one-off task runner" shape.

```
┌──────────────────────────────── DOCKER HOST ────────────────────────────────┐
│  ┌─────────────── CONTAINER (clawborrator-worker:latest) ────────────────┐  │
│  │                                                                       │  │
│  │  /workspace  (bind mount or volume — persists across restarts)        │  │
│  │     └── (optional) `git clone ${REPO_URL}` on first run               │  │
│  │     └── .mcp.json  ← written at entrypoint w/ ${CLAWBORRATOR_TOKEN}   │  │
│  │     └── …project files…                                               │  │
│  │                                                                       │  │
│  │  $ claude --dangerously-load-development-channels server:clawborrator │  │
│  │     │                                                                 │  │
│  │     └─► spawns `npx -y clawborrator-mcp`                              │  │
│  │           └─► dials wss://next.clawborrator.com/channel               │  │
│  │                                                                       │  │
│  └──────────────────────────────────┬────────────────────────────────────┘  │
└─────────────────────────────────────┼───────────────────────────────────────┘
                                      │
                                      ▼
                            HUB (next.clawborrator.com)
                                      │
                                      ▼
                  operator's orchard-chat / `claw session attach`
```

---

## Quick start

### 1. Build the image

```bash
cd worker_v1
docker build -t clawborrator-worker:latest .
```

### 2. Configure

Copy the env template and fill it in:

```bash
cp .env.example .env
# edit .env — at minimum, set ANTHROPIC_ACCESS_TOKEN.
# Pull yours from your local Claude Code install:
#   cat ~/.claude/.credentials.json | jq '.claudeAiOauth'
# Worth also setting ANTHROPIC_REFRESH_TOKEN so long-running
# workers can auto-renew.
```

### 3. Run

```bash
# easiest path — docker compose reads .env automatically
docker compose up

# or with plain docker:
docker run --rm -it --env-file .env -v "$(pwd)/workspace:/workspace" \
  clawborrator-worker:latest
```

---

## Authentication

This image uses **OAuth credentials** (Claude Max subscription
flow), NOT a raw API key. The entrypoint writes a standard
`~/.claude/.credentials.json` file at startup from your env vars,
matching the shape Claude Code creates locally after an interactive
`claude` login.

Minimum: `ANTHROPIC_ACCESS_TOKEN`. Strongly recommended:
`ANTHROPIC_REFRESH_TOKEN` too — without it, the worker can't
auto-renew when the access token expires (~14 days), and you'll
get auth failures.

Optional fine-tuning: `ANTHROPIC_TOKEN_EXPIRES_AT` (unix ms),
`ANTHROPIC_SUBSCRIPTION_TYPE` (default `max`),
`ANTHROPIC_RATE_LIMIT_TIER` (default `default_claude_max_20x`).

The materialized credentials file lives at
`/root/.claude/.credentials.json` inside the container with mode
`0600`. Anyone with shell access to the container can read it;
treat container access as token-equivalent.

## Modes

### Standalone Claude Code

Just OAuth env vars set (no `CLAWBORRATOR_TOKEN`). Claude Code
runs locally inside the container — interactive in the terminal,
no remote driver. Useful for sandboxed CI / batch use where you
exec into the container or pre-supply a prompt via
`CLAUDE_INITIAL_PROMPT`.

### clawborrator-driven worker

Set `CLAWBORRATOR_TOKEN` (mint with `claw token mint --kind=channel
--name=worker-N --mcp-snippet` on a machine where you're signed
into the hub). On boot, the worker writes `.mcp.json` with the
token and starts Claude with the channel flag. Within seconds the
session appears in your hub session list, addressable from
orchard-chat / `claw session attach` / your own app via the
clawborrator API.

This is the recommended path for any longer-running container —
operator drives the worker remotely; permission gates resolve
through the hub instead of needing a local human.

### Auto-clone

Set `REPO_URL` (and optionally `REPO_REF`). Entrypoint git-clones
into `/workspace` on first run, then starts Claude in that
checkout. Subsequent boots skip the clone (whatever's already in
`/workspace` is treated as authoritative — operator can `git pull`
from inside CC).

### Batch / one-shot

Set `CLAUDE_INITIAL_PROMPT="summarize this repo in three bullets and exit"`.
Claude starts with that prompt instead of an empty buffer. Pair
with no `CLAWBORRATOR_TOKEN` for a fully headless one-shot.

---

## Environment variables

See [`.env.example`](.env.example) for the canonical doc — copy + edit
that file rather than memorizing the table below.

| Var | Required? | Default | Notes |
|---|---|---|---|
| `ANTHROPIC_ACCESS_TOKEN` | yes | — | OAuth access token (`sk-ant-oat01-…`); written into `~/.claude/.credentials.json`. |
| `ANTHROPIC_REFRESH_TOKEN` | recommended | empty | Refresh token (`sk-ant-ort01-…`). Without it, no auto-renewal — long-lived workers will fail when the access token expires. |
| `ANTHROPIC_TOKEN_EXPIRES_AT` | no | far-future | Unix ms expiry. |
| `ANTHROPIC_SUBSCRIPTION_TYPE` | no | `max` | Subscription label. |
| `ANTHROPIC_RATE_LIMIT_TIER` | no | `default_claude_max_20x` | Rate-limit tier label. |
| `CLAWBORRATOR_TOKEN` | no | unset | `ck_live_…` channel token. If unset, no hub integration. |
| `CLAWBORRATOR_HUB_URL` | no | `wss://next.clawborrator.com` | Override for self-hosted hubs. |
| `REPO_URL` | no | unset | Git URL; cloned into /workspace on first run only. |
| `REPO_REF` | no | unset | Branch/tag/sha to check out after clone. |
| `CLAUDE_SKIP_PERMISSIONS` | no | `0` | `"1"` adds `--dangerously-skip-permissions`. See safety note below. |
| `CLAUDE_INITIAL_PROMPT` | no | unset | One-shot prompt at startup. |

---

## Volumes

`/workspace` is the working directory Claude operates in. Two patterns:

- **Bind mount** (`-v "$(pwd)/workspace:/workspace"`) — host-side
  access, survives `docker compose down`, easy to inspect via local
  tools. Default in `docker-compose.yml`.
- **Named volume** (`-v worker-workspace:/workspace`) — Docker-managed,
  no host-side path leak, slightly more portable.

If `/workspace` is empty AND `REPO_URL` is set, the entrypoint
clones for you. If it's non-empty, the existing contents win.

---

## Networking

Outbound only — no ports exposed. The container needs to reach:

- `https://api.anthropic.com` — Claude Code's model API.
- `wss://next.clawborrator.com` — hub WS (if `CLAWBORRATOR_TOKEN` is set).
  Substitute your own hub URL via `CLAWBORRATOR_HUB_URL`.
- Whatever Claude itself needs while working (your repos, npm
  registry, GitHub, etc.).

If you're running behind a strict egress firewall, allow at minimum
`api.anthropic.com` + your hub hostname.

---

## Safety notes

- **`CLAUDE_SKIP_PERMISSIONS=1`** disables Claude Code's permission
  gates. Every tool call (Bash, Edit, Write, MCP) runs without
  asking. Only safe in a genuinely throwaway / sandboxed container
  with restricted egress AND no important credentials on disk.
- The recommended pattern is: keep permission prompts enabled,
  pair with `CLAWBORRATOR_TOKEN`, and let operators resolve gates
  remotely from orchard-chat. That gives you full Claude Code
  capability without bypassing the safety net.
- `.mcp.json` contains a live `ck_live_…` token. The entrypoint
  writes it at runtime so it's not baked into the image, but it
  IS on disk inside the container — anyone with shell access to
  the container can read it. Treat container access as
  token-equivalent.

---

## Operating mid-flight

### Attach to the running Claude Code TUI

`docker attach` hooks your terminal up to the foreground `claude`
process (running under the expect wrapper). You see whatever
the worker sees and type directly into the prompt:

```bash
docker attach --detach-keys="ctrl-p,ctrl-q" worker_v1-worker-1
```

- **`--detach-keys`** lets you leave without killing claude — press
  `Ctrl-P` then `Ctrl-Q`. Pick something you won't fat-finger.
  Without it, the default detach combo is the same but it's worth
  passing explicitly so you remember.
- **`Ctrl-C` kills claude** (and exits the container) — `attach` is
  a real TTY hookup, not a viewer. Use the detach keys.
- Multiple attaches share one input stream. Two people typing at
  once will fight. For multi-operator drive, route through the hub
  (`@workspace`, etc.) instead — that's the whole point of the
  clawborrator integration.

### Side shell (doesn't touch the TUI)

```bash
docker exec -it worker_v1-worker-1 bash
```

Opens a fresh bash in the container without disturbing the running
`claude` process. The `claw` CLI is available globally:

```bash
# inside the running worker
claw whoami
claw session ls
claw session info <id>
```

### Drive from outside the host

The worker's session shows up in orchard-chat under your hub
session list (once you're signed into the same hub the channel
token was minted on). This is the recommended path — no SSH, no
`docker attach`, multi-operator-safe.

---

## Image internals

- Base: `node:22-bookworm-slim`. Picked Debian (not Alpine) because
  Claude Code's bash environment expects glibc and a few
  Debian-default tools.
- Globally installed: `@anthropic-ai/claude-code`, `clawborrator-cli`.
- Apt extras: `git`, `ca-certificates`, `curl`, `jq`. `git` is
  load-bearing for the optional clone; the rest are convenience for
  the operator running Bash via Claude.
- No `clawborrator-supervisor` — that's a multi-CC orchestrator that
  doesn't fit the one-container-one-CC shape. Use `desktop_v1` for
  that.
- No baked tokens / keys — everything sensitive arrives via env.

---

## Not included (yet)

- Multi-arch images (currently amd64 only — bookworm-slim has arm64
  but the build hasn't been tested there).
- Image registry pushes — assemble locally for now.
- Healthcheck — the foreground `claude` exit IS the health signal;
  add one if your orchestrator needs it.
