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

Two auth paths are supported; pick whichever fits your billing model.

### Path A — `ANTHROPIC_API_KEY`

Set `ANTHROPIC_API_KEY=sk-ant-api03-…` and you're done. Claude Code
reads the key directly from env; the entrypoint skips the
`.credentials.json` materialization entirely. No rotation, no
refresh-token chain, no host/container sharing problem. Bills
against your Anthropic API account (per-token metered).

Get a key from <https://console.anthropic.com/settings/keys>.

> ⚠ **API key + clawborrator channels don't work together.** Claude
> Code treats API-key sessions as "Not logged in" for purposes of
> the channels feature. When `ANTHROPIC_API_KEY` is set, the
> `--dangerously-load-development-channels server:clawborrator`
> flag is silently ignored:
>
> ```
> Channels are not currently available
> --dangerously-load-development-channels ignored (server:clawborrator)
> ```
>
> The clawborrator MCP server still loads — the worker registers
> with the hub and shows up in `list_peers` — but inbound prompts
> routed to this worker via `route_to_peer` won't render as
> `<channel source="…">` user-turn notifications, so the worker
> can't be driven remotely. It can still actively call clawborrator
> tools from inside (`list_peers`, `dispatch_to_agent`, etc.) and
> be attached to via `docker attach`, but it's a one-way fleet
> member.
>
> If you need both API-key billing AND routed-prompt reception,
> see *Hybrid: API key billing + OAuth-logged-in for channels*
> below.

### Path B — Claude Max OAuth (subscription billing)

Set `ANTHROPIC_ACCESS_TOKEN=sk-ant-oat01-…` and (recommended)
`ANTHROPIC_REFRESH_TOKEN=sk-ant-ort01-…`. The entrypoint seeds a
standard `~/.claude/.credentials.json` file on **first boot only**,
matching the shape Claude Code creates after an interactive `claude`
login. Claude refreshes the token chain itself thereafter (the
`claude-home` named volume persists the chain across restarts).

Optional fine-tuning: `ANTHROPIC_TOKEN_EXPIRES_AT` (unix ms),
`ANTHROPIC_SUBSCRIPTION_TYPE` (default `max`),
`ANTHROPIC_RATE_LIMIT_TIER` (default `default_claude_max_20x`).

The materialized credentials file lives at
`/home/worker/.claude/.credentials.json` inside the container with
mode `0600`. Anyone with shell access to the container can read it;
treat container access as token-equivalent.

**Warning about Path B**: Anthropic's refresh tokens are single-use.
When either side (host or worker) refreshes, the other's copy of
the refresh token is invalidated. Don't share host tokens with a
long-running worker; mint a worker-dedicated credential (see
*Credentials persistence* below) or use Path A instead.

### Picking between them

Set ANTHROPIC_API_KEY for Path A, leave it blank and set
ANTHROPIC_ACCESS_TOKEN for Path B. **Exactly one must be set**;
the entrypoint exits with a clear error if neither is provided.

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

### Minting a worker-dedicated OAuth credential

This is the *correct* way to put OAuth tokens in the worker's `.env`
— get a fresh token chain by running `claude /login` inside a
throwaway worker container. Tokens you mint this way are unrelated
to your host's chain, so neither side's refreshes affect the other.

It's also the workaround for the **API key + channels** limitation:
seed the worker's persisted volume with these OAuth credentials,
keep `ANTHROPIC_ACCESS_TOKEN` in `.env`, and the worker satisfies
the "logged in" gate that the channels feature requires.

**Step-by-step:**

1. **Start a throwaway worker** with autoenter off + a placeholder
   for the required-env check:
   ```bash
   docker run -d -it --name worker-bootstrap \
     -e ANTHROPIC_ACCESS_TOKEN="placeholder" \
     -e DISABLE_AUTOENTER=1 \
     -e CLAWBORRATOR_TOKEN= \
     -v worker-bootstrap-home:/home/worker/.claude \
     clawborrator-worker:latest
   ```
   `DISABLE_AUTOENTER=1` keeps the expect wrapper out of the way so
   you can drive prompts manually. `CLAWBORRATOR_TOKEN=""` skips
   the .mcp.json setup so claude doesn't try to register with the
   hub during the bootstrap. The placeholder OAuth token is just
   to satisfy the entrypoint's required-env check; it'll be
   overwritten when you log in.

2. **Attach and answer the API-key prompt with "No"** so claude
   falls back to OAuth:
   ```bash
   docker attach --detach-keys="ctrl-p,ctrl-q" worker-bootstrap
   ```
   When the API-key prompt appears (it will, because the
   placeholder ACCESS_TOKEN is bogus and claude tries env-API-key
   next), pick **"No (recommended)"** — the default. Claude will
   then drop into its main UI in a "Not logged in" state.

3. **Run `/login`** from within the claude TUI. It prints an
   OAuth URL. Open it in your browser, approve the connection,
   paste the resulting code back into the TUI. Claude writes the
   token chain to `~/.claude/.credentials.json`.

4. **Detach** with `Ctrl-P, Ctrl-Q`.

5. **Extract the tokens** and put them in `.env`:
   ```bash
   docker exec worker-bootstrap sh -c \
     'jq -r "[.claudeAiOauth.accessToken, .claudeAiOauth.refreshToken, .claudeAiOauth.expiresAt] | @tsv" \
       /home/worker/.claude/.credentials.json'
   ```
   Output is `<accessToken>\t<refreshToken>\t<expiresAt>`. Paste
   into `.env`:
   ```
   ANTHROPIC_ACCESS_TOKEN=sk-ant-oat01-...
   ANTHROPIC_REFRESH_TOKEN=sk-ant-ort01-...
   ANTHROPIC_TOKEN_EXPIRES_AT=<unix-ms>
   ```

6. **Tear down the throwaway:**
   ```bash
   docker rm -f worker-bootstrap
   docker volume rm worker-bootstrap-home
   ```

7. **Boot the real worker** with the new `.env`. The first-boot
   seed materializes `.credentials.json` from the env values; from
   then on the worker maintains its own chain in the `claude-home`
   volume.

The host's CC and this worker now have independent token chains.
You can re-run the recipe per worker if you want multiple
independently-refreshing identities.

### Hybrid: API-key billing + OAuth-logged-in for channels

If you specifically want to bill against your API account but
still need clawborrator channels to route prompts in, set BOTH
in `.env`:

```
ANTHROPIC_API_KEY=sk-ant-api03-...     # for inference billing
ANTHROPIC_ACCESS_TOKEN=sk-ant-oat01-... # for the "logged in" gate
ANTHROPIC_REFRESH_TOKEN=sk-ant-ort01-...
```

The OAuth credentials only need to be valid enough for claude to
consider the session "logged in"; the API key takes precedence for
actual model calls. Mint the OAuth tokens via the recipe above.

The entrypoint accepts both being set — it materializes
`.credentials.json` from the OAuth values (which flips claude's
"logged in" state to true) and lets `ANTHROPIC_API_KEY` flow
through to the model API for billing.

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
| `ANTHROPIC_API_KEY` | one of two | — | Raw API key (`sk-ant-api03-…`); used directly by claude, no `.credentials.json`. Bills against API account. Set this OR `ANTHROPIC_ACCESS_TOKEN`. |
| `ANTHROPIC_ACCESS_TOKEN` | one of two | — | Claude Max OAuth access token (`sk-ant-oat01-…`); seeded into `~/.claude/.credentials.json` on first boot. Bills against Max subscription. |
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
