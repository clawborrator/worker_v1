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
│  │  /home/worker/.claude/  (named volume `claude-home`)                  │  │
│  │     ├── .credentials.json   ← seeded from env on first boot;          │  │
│  │     │                         claude refreshes it after — never       │  │
│  │     │                         re-clobbered.                           │  │
│  │     └── …per-user CC state…                                           │  │
│  │                                                                       │  │
│  │  /workspace/  (claude's cwd — bind mount or named volume)             │  │
│  │     ├── .mcp.json    ← written at entrypoint w/ ${CLAWBORRATOR_TOKEN} │  │
│  │     ├── .claude/     ← project-level hooks + settings.local           │  │
│  │     ├── CLAUDE.md    ← orientation note for claude                    │  │
│  │     └── repo/        ← `git clone ${REPO_URL}` lands here             │  │
│  │         └── .git/, src/, …                                            │  │
│  │                                                                       │  │
│  │  $ claude --dangerously-load-development-channels server:clawborrator │  │
│  │     │   (cwd = /workspace, NOT /workspace/repo)                       │  │
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
flow), NOT a raw API key. The entrypoint seeds a standard
`~/.claude/.credentials.json` file on **first boot only** from your
env vars, matching the shape Claude Code creates after an interactive
`claude` login.

Minimum: `ANTHROPIC_ACCESS_TOKEN`. Strongly recommended:
`ANTHROPIC_REFRESH_TOKEN` too — without it, the worker can't
auto-renew when the access token expires (~14 days), and you'll
get auth failures.

Optional fine-tuning: `ANTHROPIC_TOKEN_EXPIRES_AT` (unix ms),
`ANTHROPIC_SUBSCRIPTION_TYPE` (default `max`),
`ANTHROPIC_RATE_LIMIT_TIER` (default `default_claude_max_20x`).

The materialized credentials file lives at
`/home/worker/.claude/.credentials.json` inside the container with
mode `0600`. Anyone with shell access to the container can read it;
treat container access as token-equivalent.

### Credentials persistence (named volume)

`~/.claude/` is mounted as a docker named volume (`claude-home`) so
the credentials file survives across `docker compose down/up`. This
is **load-bearing**: Anthropic's OAuth refresh tokens are single-use,
and Claude Code rewrites `.credentials.json` every time it refreshes.
Without the volume, every container restart would clobber the freshly-
refreshed tokens with the (now-stale) values from `.env`, and the
worker would 401 within hours.

The first boot of a fresh volume seeds from `.env`. From that point
on, the in-container claude maintains the file itself — the
entrypoint detects the existing file and leaves it alone.

To force a re-seed (e.g., after rotating credentials externally):

```bash
docker compose down
docker volume rm worker_v1_claude-home
docker compose up -d   # entrypoint will re-seed from current .env
```

### Why you should NOT share host credentials with the worker

The credential chain in your host's `~/.claude/.credentials.json` is
the one your local `claude` is actively refreshing. The moment either
side (host or worker) refreshes, the other's copy of the refresh
token is invalidated. They cannot coexist long-term on the same
chain.

**Mint a worker-dedicated credential** instead:

1. Run an interactive container once with no creds set:
   ```bash
   docker run --rm -it -v worker-bootstrap:/home/worker/.claude \
     --entrypoint bash clawborrator-worker:latest
   ```
2. Inside, run `claude` and walk the OAuth flow in your browser.
3. `cat ~/.claude/.credentials.json` and copy the `accessToken` +
   `refreshToken` values into your worker's `.env`.
4. Optionally also `docker cp` the volume contents into the
   `claude-home` named volume to skip the first-boot seed entirely.

Now host and worker have independent token chains; neither
refreshing affects the other.

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
| `REPO_URL` | no | unset | Git URL (plain, no embedded creds); cloned into `/workspace/${REPO_DIR_NAME}` on first run only. |
| `REPO_REF` | no | unset | Branch/tag/sha to check out after clone. |
| `REPO_PAT` | no | unset | Personal access token. Spliced into `REPO_URL` at clone time for private repos. **Persists in `.git/config`** — treat container access as PAT-equivalent. |
| `REPO_PAT_USER` | no | `x-access-token` | Username paired with `REPO_PAT`. GitHub: leave default. GitLab: `oauth2`. Self-hosted: your username. |
| `REPO_DIR_NAME` | no | `repo` | Subdir under `/workspace` where the clone lands. Keeps worker plumbing (`.mcp.json`, `.claude/`, `CLAUDE.md`) at `/workspace/` and the repo at `/workspace/<this>/`. |
| `CLAUDE_SKIP_PERMISSIONS` | no | `0` | `"1"` adds `--dangerously-skip-permissions`. See safety note below. |
| `CLAUDE_INITIAL_PROMPT` | no | unset | One-shot prompt at startup. |

---

## Volumes

The image expects two volumes — one for the workspace, one for the
worker's persistent Claude Code state.

**`/workspace`** — claude's working directory. Two patterns:

- **Bind mount** (`-v "$(pwd)/workspace:/workspace"`) — host-side
  access, survives `docker compose down`, easy to inspect via local
  tools. Default in `docker-compose.yml`.
- **Named volume** (`-v worker-workspace:/workspace`) — Docker-managed,
  no host-side path leak, slightly more portable.

If `/workspace/${REPO_DIR_NAME}` is missing AND `REPO_URL` is set,
the entrypoint clones for you. If it's already present, the existing
checkout wins.

### Layout inside `/workspace`

Claude's cwd is `/workspace`, **not** the cloned repo. The repo lives
in a subdir (`./${REPO_DIR_NAME}/`, default `./repo/`). This keeps
worker plumbing fully separate from the repo's working tree:

```
/workspace/
├── .mcp.json     ← worker plumbing (NOT in the repo's git history)
├── .claude/      ← worker plumbing — hooks, settings.local, etc.
├── CLAUDE.md     ← orientation note auto-written by the entrypoint;
│                   tells claude the repo is in ./repo
└── repo/         ← cloned codebase, untouched by worker plumbing
    ├── .git/
    └── …
```

Trade-off: `git status` from `/workspace` fails (it's not a repo).
The auto-written `CLAUDE.md` instructs claude to `cd repo` or use
`git -C repo …` for git operations.

**`/home/worker/.claude`** — claude's per-user state (credentials,
projects, sessions). Mounted as a docker named volume
(`claude-home`) so the OAuth credential chain survives container
restart. See the *Credentials persistence* section above for why
this is load-bearing.

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
- **`/var/run/docker.sock` mount** (see *Spawning sibling workers*
  below) gives the container root-equivalent access to the host's
  Docker daemon. Anyone inside — including a prompt-injection that
  tricks claude into running a malicious `docker run` — can mount
  `/` from the host, run privileged containers, or escape the
  sandbox entirely. The image installs the `docker` CLI but only
  uses it when the socket is actually mounted in. **Mount the
  socket only on workers that need to spawn siblings, never as a
  blanket default.**

---

## Spawning sibling workers

Mount the host's Docker socket into a worker and that worker can
spawn other workers on the same Docker host. The pattern is "Docker
outside of Docker" (DooD) — the in-container `docker` CLI talks to
the *host* daemon over the socket; spawned containers become
siblings of the parent on the same host, not nested children.

**Enable on a worker:**

1. Mount the socket. In `docker-compose.yml`, the line is already
   there commented in by default — leave it active when you want
   the swarm primitive, comment it out otherwise. For plain
   `docker run`, add `-v /var/run/docker.sock:/var/run/docker.sock`.
2. The entrypoint auto-detects the socket on boot. It reads the
   socket's GID, creates a matching group inside the container,
   and adds the `worker` user to it. Look for this line in
   `docker logs`:
   ```
   [worker] docker.sock detected (gid=999, group=docker_host) — worker added
   ```
3. The worker user can now run `docker` directly:
   ```bash
   docker ps      # lists *host* containers (including self)
   docker run …   # spawns a sibling on the host
   ```

**Spawn from inside claude (via its Bash tool):**

```bash
docker run -d --rm \
  --name worker-child-$(date +%s) \
  -e CLAWBORRATOR_TOKEN="$CLAWBORRATOR_TOKEN" \
  -e ANTHROPIC_ACCESS_TOKEN="$ANTHROPIC_ACCESS_TOKEN" \
  -e ANTHROPIC_REFRESH_TOKEN="$ANTHROPIC_REFRESH_TOKEN" \
  -e REPO_URL="https://github.com/your/repo.git" \
  -e REPO_PAT="$REPO_PAT" \
  -e CLAUDE_INITIAL_PROMPT="$WORK_DESCRIPTION" \
  clawborrator-worker:latest
```

The new container's claude registers with the hub within ~10–15s.
It shows up in the parent's `list_peers` as a fresh `@workspace-…`
entry; the parent can then `route_to_peer` to dispatch work.

**Wait-for-ready + dispatch + cleanup** — see the orchestration
guide in `<repo>/hub_v1/docs/SWARM-NOTES.md` (TODO) for end-to-end
swarm patterns.

**Terminate a child:**

```bash
docker rm -f worker-child-<id>
```

The WS closes, the hub marks the session offline, the container
disappears from `docker ps`. No hub-side action needed.

**Caveat reminder:** Mounting docker.sock = root on host. Only do
this when you specifically want the swarm pattern.

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
