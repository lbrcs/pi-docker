# Pi Coding Agent — Global Docker Setup (macOS)

Run [pi](https://github.com/mariozechner/pi) inside a locked-down Docker container with network filtering, resource limits, and git-worktree-based subagent orchestration — across any of your repos.

> **Platform:** This setup is designed for **macOS** with Docker Desktop. Linux users may need to adjust the OAuth auth container (e.g. `--network=host` works on Linux and is simpler than the `socat` approach used here).

---

## 1. Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│  Host                                                   │
│                                                         │
│   ~/pi-docker/          (this repo — cloned once)       │
│     ├── pi-docker       launcher script                 │
│     ├── entrypoint.sh   container init                  │
│     ├── AGENTS.md       default agent rules             │
│     ├── extensions/     default pi extensions           │
│     ├── Dockerfile      pi agent image                  │
│     ├── Dockerfile.proxy  squid image                   │
│     ├── squid.conf      domain allowlist                │
│     └── docker-compose.yml                              │
│                                                         │
│   ~/my-project/         (any repo you work on)          │
│                                                         │
│                                                         │
│  ┌──────────────── Docker ────────────────────────────┐  │
│  │                                                    │  │
│  │  ┌──────────────┐      ┌──────────────────────┐   │  │
│  │  │  pi-agent     │──────▶  proxy (squid)       │   │  │
│  │  │              │      │  allowlist only:      │   │  │
│  │  │  /workspace  │      │   api.anthropic.com   │   │  │
│  │  │  = your repo │      │   github.com          │   │  │
│  │  │              │      │   api.github.com      │   │  │
│  │  └──────────────┘      └──────────────────────┘   │  │
│  │        pi-net (bridge network)                     │  │
│  └────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

| Layer | What it does |
|---|---|
| **pi-docker launcher** | Detects the repo root, sets env vars, calls `docker compose run` |
| **entrypoint.sh** | Injects default `AGENTS.md` + extensions if the repo has none, drops to non-root user |
| **proxy (squid)** | Allows only `api.anthropic.com`, `github.com`, `api.github.com` — blocks everything else |
| **pi-agent container** | Runs pi with `http_proxy` pointed at the squid sidecar |
| **worktree-subagent extension** | Lets pi spawn autonomous subagents in isolated git worktrees |

---

## 2. Prerequisites

| Tool | Minimum version | Install |
|---|---|---|
| Docker Engine | 24+ | [docs.docker.com/engine/install](https://docs.docker.com/engine/install/) |
| Docker Compose | v2 (bundled with Docker Desktop) | included with Docker Desktop |
| Git | 2.20+ | your package manager |
| A GitHub fine-grained PAT | — | [github.com/settings/tokens?type=beta](https://github.com/settings/tokens?type=beta) |

The PAT needs **Contents: Read & write** and **Pull requests: Read & write** on every repo you want pi to work on.

---

## 3. Installation

```bash
# Clone directly to ~/.pi-docker
git clone https://github.com/YOUR_USER/pi-docker.git ~/.pi-docker

# Make the launchers executable
chmod +x ~/.pi-docker/pi-docker ~/.pi-docker/pi-docker-auth ~/.pi-docker/pi-docker-models

# Add to your PATH
echo 'export PATH="$HOME/.pi-docker:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

To update later: `git -C ~/.pi-docker pull`

---

## 4. Authentication

### First-time Anthropic login

Pi uses OAuth to authenticate with your Claude Pro/Max subscription. Because the OAuth flow requires a browser redirect to `localhost`, authentication runs in a separate container with host networking:

```bash
# Run once (or whenever your refresh token expires)
pi-docker-auth
```

This launches pi in a **restricted, auth-only session** — no repo mounted, no GitHub access, no proxy, and no file/bash tools (`--no-tools`). Type `/login`, select **Anthropic**, and complete the browser flow. Tokens are saved to `~/.pi/agent/auth.json` and automatically shared with `pi-docker` via a bind mount.

> ⚠ **Auth-only mode:** The `pi-docker-auth` session deliberately disables all coding tools. Do not use it for coding tasks — use `pi-docker` for normal agent sessions.

> ⏱ **3-minute timeout:** The auth container automatically terminates after 3 minutes. If it times out before you finish, simply run `pi-docker-auth` again.

**Token refresh is automatic.** Inside the sandboxed `pi-docker` container, pi refreshes expired tokens via the Anthropic API (no browser needed). You only need to re-run `pi-docker-auth` if the refresh token itself expires.

**Sessions are cleared on container stop.** When a `pi-docker` container exits, the `anthropic` key is automatically removed from `auth.json`. This means every new `pi-docker` session starts in a logged-out state, so you will never encounter a stale "logged in but expired" situation. Run `pi-docker-auth` once before each working session (or rely on automatic token refresh if your session was recent).

> **Why a separate container?** Pi's OAuth callback server normally binds to `127.0.0.1`, making it unreachable via Docker port mapping. The Docker image patches it to bind to `0.0.0.0` so that `-p 53692:53692` works. No repo is mounted and no proxy is used — the container exists only for login.

---

## 5. Configuration

### 5a. GitHub Token

**Option A: Token file (recommended)**

```bash
# Write your PAT to the token file (created as an empty placeholder during install)
echo "github_pat_..." > ~/.pi-docker/.gh-auth-token
```

**Option B: Environment variable**

```bash
# Set once per shell, or add to ~/.bashrc / ~/.zshrc
export PI_GH_TOKEN="github_pat_..."
```

The env var takes priority over the file. The launcher will warn you if neither is set and ask whether to continue without GitHub access.

### 5b. Network Allowlist (`squid.conf`)

Edit `squid.conf` to add or remove domains. The defaults are:

```
api.anthropic.com      # Claude API
github.com             # git push / PR creation
api.github.com         # gh CLI
objects.githubusercontent.com  # GitHub raw content
```

To allow a new domain:

```
acl allowed_domains dstdomain new-domain.example.com
```

Then restart the proxy: `docker compose restart proxy`

### 5c. Agent Defaults (`AGENTS.md` + `extensions/`)

These files are injected into `/workspace/.pi/` at startup **only if the repo doesn't already have its own**. This lets you set global defaults while allowing per-repo overrides.

### 5d. Resource Limits

Edit `docker-compose.yml` under `deploy.resources.limits`:

```yaml
limits:
  memory: 4g     # max RAM
  cpus: "2.0"    # max CPU cores
```

---

## 6. Usage

```bash
# cd into any git repo
cd ~/my-project

# Launch pi inside Docker
pi-docker

# Pass arguments through to pi
pi-docker "refactor the auth module"

# Or run with a specific prompt
pi-docker -p "add unit tests for utils.ts"

# Force rebuild of Docker images (e.g. after updating pi-docker)
pi-docker --rebuild
```

What happens:

1. The launcher detects the repo root and current branch.
2. It checks for `PI_GH_TOKEN`.
3. It ensures `.worktrees/` is in the repo's `.gitignore`.
4. It runs `docker compose run --rm pi` with the repo mounted at `/workspace`.

---

## 7. Subagent Orchestration

The `worktree-subagent` extension gives pi a `spawn_subagent` tool that:

1. Creates a git worktree under `/workspace/.worktrees/<task-name>/`
2. Spawns a new pi process in that worktree with full instructions
3. The subagent works autonomously — commits, pushes, opens a PR
4. Returns the PR URL to the orchestrator

### Example conversation

```
You: "Add input validation to the API and write tests for it"

Pi:  I'll split this into two parallel tasks.

     [spawn_subagent: add-validation]
     [spawn_subagent: add-validation-tests]

     Both subagents are working. I'll report back when they finish.

     ✓ add-validation completed → PR #42
     ✓ add-validation-tests completed → PR #43
```

### Slash commands

| Command | Description |
|---|---|
| `/worktrees` | List all active subagent worktrees |
| `/cleanup-worktree <name>` | Remove a specific worktree |
| `/cleanup-all` | Remove all worktrees under `.worktrees/` |

---

## 8. Local Model Fallback (Ollama)

Use local models via [Ollama](https://ollama.com) alongside (or instead of) Claude. Ollama runs on your host machine; the pi-docker container talks to it over HTTP.

### Prerequisites

1. Install Ollama: [ollama.com/download](https://ollama.com/download)
2. Start the server: `ollama serve`
3. Pull a model: `ollama pull qwen2.5-coder:32b`

### Enable Ollama integration

```bash
# One command — auto-detects platform, syncs all installed models
pi-docker-models ollama enable
```

This generates three files (all gitignored):
- `docker-compose.override.yml` — adds Ollama env var + volume mount
- `squid-local.conf` — extends the allowlist to permit Ollama traffic
- `models.json` — registers installed Ollama models with pi

The next time you run `pi-docker`, local models will appear in pi's model picker alongside Anthropic models.

### Manage models

```bash
# Show installed Ollama models and which are configured
pi-docker-models ollama list

# Re-sync after pulling new models in Ollama
pi-docker-models ollama sync

# Add/remove individual models
pi-docker-models ollama add codellama:34b
pi-docker-models ollama remove codellama:34b

# Check current status
pi-docker-models status
```

### Disable Ollama integration

```bash
pi-docker-models ollama disable
```

This removes the generated files. The base `docker-compose.yml` and `squid.conf` are never modified.

### Custom Ollama host

If Ollama runs on a different machine:

```bash
pi-docker-models ollama enable --host 192.168.1.100
```

<details>
<summary>Manual setup (advanced)</summary>

If you prefer not to use the script, see the comments in `docker-compose.yml` and `squid.conf` for the three manual steps: uncomment the Ollama ACL in squid, uncomment the `OLLAMA_HOST` env var and `models.json` volume mount in compose, and create a `models.json` file following [pi's models.json docs](https://github.com/mariozechner/pi/blob/main/docs/models.md).

</details>

---

## 9. Troubleshooting

| Problem | Fix |
|---|---|
| `Error: not inside a git repository` | `cd` into a git repo before running `pi-docker` |
| `No GitHub token found` | Write your PAT to `~/.pi-docker/.gh-auth-token` or export `PI_GH_TOKEN` |
| Subagent can't push | Check that your PAT has **Contents: Read & write** on the repo |
| Subagent can't create PRs | Check that your PAT has **Pull requests: Read & write** on the repo |
| Network timeout | Check `squid.conf` — is the domain in the allowlist? |
| `permission denied` on entrypoint | Run `chmod +x ~/pi-docker/entrypoint.sh` |
| Container OOM killed | Increase `memory` limit in `docker-compose.yml` |
| Worktree conflicts | Run `/cleanup-all` to remove stale worktrees |
| Image out of date after `pi-docker` update | Run `pi-docker --rebuild` to rebuild Docker images |
| `⚠ Anthropic session token is expired` on startup | Run `pi-docker-auth` to re-authenticate; pi will attempt an automatic refresh but may fail if the refresh token is also expired |

### Viewing logs

```bash
# Proxy logs (see what's being allowed/denied)
docker compose -f ~/pi-docker/docker-compose.yml logs proxy

# Pi agent logs
docker compose -f ~/pi-docker/docker-compose.yml logs pi
```

---

## 10. Security Model

| Control | Implementation |
|---|---|
| **Network filtering** | Squid forward proxy — only allowlisted domains can be reached |
| **No root in container** | `gosu` drops to `piuser` before running pi |
| **No privilege escalation** | `no-new-privileges:true` security option |
| **Resource limits** | Memory (4 GB), CPU (2 cores), PIDs (512) |
| **Filesystem isolation** | Only the target repo is mounted (at `/workspace`) |
| **Secret management** | `GH_TOKEN` passed via env var, never written to the image |
| **Worktree isolation** | Each subagent works in its own worktree — no conflicts |
| **Read-only proxy filesystem** | Squid proxy container runs with `read_only: true`; only tmpfs dirs are writable |
| **Credentials on tmpfs** | `.git-credentials` written to `/tmp` (tmpfs) — never touches persistent storage |
| **Container stop clears auth** | Stopping the container wipes tmpfs — credentials don't survive restarts |

### What pi CAN do

- Read and write files in the mounted repo
- Make git commits and push branches
- Open pull requests via `gh`
- Call the Claude API (via the proxy)
- Spawn subagents in worktrees

### What pi CANNOT do

- Access the internet beyond the allowlist
- Read files outside `/workspace`
- Run as root
- Exceed resource limits
- Access other containers or the Docker socket

---

## 11. File Reference

| File | Purpose |
|---|---|
| `pi-docker` | Launcher script — run from any repo |
| `pi-docker-auth` | OAuth login helper — run once for initial auth |
| `pi-docker-models` | Ollama integration manager — enable/disable local models |
| `entrypoint.sh` | Container init — injects defaults, drops to non-root |
| `Dockerfile` | Pi agent image (Node 22, pi, git, gh) |
| `Dockerfile.proxy` | Squid proxy image |
| `docker-compose.yml` | Service definitions, volumes, networking |
| `squid.conf` | Network allowlist configuration |
| `AGENTS.md` | Default agent rules (injected if repo has none) |
| `extensions/worktree-subagent.ts` | Subagent orchestration extension |
| `.gh-auth-token` | _(gitignored)_ GitHub PAT for container access |
| `models.json` | _(optional, gitignored)_ Local model configuration |
