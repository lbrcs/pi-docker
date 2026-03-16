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
    echo "https://x-access-token:${GH_TOKEN}@github.com" > /home/piuser/.git-credentials
    git config --file /home/piuser/.gitconfig credential.helper store
    chown piuser:piuser /home/piuser/.git-credentials /home/piuser/.gitconfig
fi

# ── Logout Anthropic session on container stop ────────────────────────────
# Removing the 'anthropic' key from auth.json on EXIT ensures that each new
# pi-docker session starts unauthenticated. This prevents the confusing
# "logged in but session expired" state when restarting containers or
# switching branches.
cleanup_auth() {
    AUTH_FILE="/home/piuser/.pi/agent/auth.json"
    if [ -f "$AUTH_FILE" ]; then
        node -e "
const fs = require('fs');
try {
    const data = JSON.parse(fs.readFileSync('$AUTH_FILE', 'utf8'));
    delete data.anthropic;
    fs.writeFileSync('$AUTH_FILE', JSON.stringify(data, null, 2));
} catch(e) {}
" 2>/dev/null || true
    fi
}

# ── Drop to piuser via gosu ─────────────────────────────────────────────
# Run in background so the EXIT trap fires when the container stops.
gosu piuser bash -c 'cd /workspace && exec "$@"' _ "$@" &
CHILD_PID=$!
trap 'kill -TERM $CHILD_PID 2>/dev/null; wait $CHILD_PID; cleanup_auth' EXIT TERM INT
wait $CHILD_PID
