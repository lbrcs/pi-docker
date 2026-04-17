#!/bin/bash
set -e

# ── Inject default .pi/ config if repo doesn't have its own ──────────────
# Global defaults are mounted to /defaults/ by docker-compose.yml.
# We copy them into /workspace/.pi/ only if the repo hasn't provided its own.
mkdir -p /workspace/.pi/extensions

if [ -f /defaults/AGENTS.md ] && [ ! -f /workspace/.pi/AGENTS.md ]; then
    cp /defaults/AGENTS.md /workspace/.pi/AGENTS.md
    echo "[setup] Injected default AGENTS.md (repo has none)"
fi

if [ -d /defaults/extensions ] && [ -z "$(ls -A /workspace/.pi/extensions/ 2>/dev/null)" ]; then
    cp /defaults/extensions/* /workspace/.pi/extensions/ 2>/dev/null || true
    echo "[setup] Injected default extensions (repo has none)"
fi

# Ensure piuser owns the .pi directory inside the workspace
chown -R piuser:piuser /workspace/.pi 2>/dev/null || true

# ── Configure git credentials for piuser (container-local, never touches repo) ──
if [ -n "$GH_TOKEN" ]; then
    # Write credentials to /tmp (tmpfs) so they never touch persistent storage
    echo "https://x-access-token:${GH_TOKEN}@github.com" > /tmp/.git-credentials
    chmod 600 /tmp/.git-credentials
    git config --file /home/piuser/.gitconfig credential.helper "store --file /tmp/.git-credentials"
    chown piuser:piuser /tmp/.git-credentials /home/piuser/.gitconfig
fi

# ── Logout Anthropic session on container stop ────────────────────────────
# Removing the 'anthropic' key from auth.json on EXIT ensures that each new
# pi-docker session starts unauthenticated. This prevents the confusing
# "logged in but session expired" state when restarting containers or
# switching branches.
cleanup_auth() {
    # Skip cleanup in auth-only containers — their entire purpose is to persist tokens.
    [ "${PI_AUTH_MODE:-0}" = "1" ] && return 0
    AUTH_FILE="/home/piuser/.pi/agent/auth.json"
    if [ -f "$AUTH_FILE" ]; then
        node -e "
const fs = require('fs');
try {
    fs.writeFileSync('$AUTH_FILE', JSON.stringify({}, null, 2));
} catch(e) {}
" 2>/dev/null || true
    fi
}

# ── Auth-mode: watch for login completion and prompt the user to exit ────
if [ "${PI_AUTH_MODE:-0}" = "1" ]; then
    AUTH_FILE="/home/piuser/.pi/agent/auth.json"
    INITIAL_MTIME=$(node -e "try{process.stdout.write(String(require('fs').statSync('$AUTH_FILE').mtimeMs))}catch(e){process.stdout.write('0')}" 2>/dev/null || echo "0")
    (
        while true; do
            sleep 1
            CURRENT_MTIME=$(node -e "try{process.stdout.write(String(require('fs').statSync('$AUTH_FILE').mtimeMs))}catch(e){process.stdout.write('0')}" 2>/dev/null || echo "0")
            if [ "$CURRENT_MTIME" != "$INITIAL_MTIME" ] && \
               node -e "try{const d=JSON.parse(require('fs').readFileSync('$AUTH_FILE','utf8'));process.exit(Object.keys(d).length>0?0:1)}catch(e){process.exit(1)}" 2>/dev/null; then
                echo ""
                echo "────────────────────────────────────────────────────────────────────"
                echo "│  ✓  Type /quit to exit, then run pi-docker!"
                echo "────────────────────────────────────────────────────────────────────"
                break
            fi
        done
    ) &
fi

# ── Drop to piuser via gosu ─────────────────────────────────────────────
# `init: true` in docker-compose.yml runs tini as PID 1, which properly
# forwards SIGTERM to this script. Since we're no longer PID 1, bash
# handles SIGTERM normally → the EXIT trap fires → cleanup_auth runs.
# Foreground execution preserves stdin (Enter key works for pi input).
trap 'cleanup_auth' EXIT
gosu piuser bash -c 'cd /workspace && exec "$@"' _ "$@"
