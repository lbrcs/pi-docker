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

# ── Inject GH_TOKEN into git remote URL ─────────────────────────────────
if [ -n "$GH_TOKEN" ] && [ -d /workspace/.git ]; then
    REMOTE_URL=$(git -C /workspace remote get-url origin 2>/dev/null || true)
    if echo "$REMOTE_URL" | grep -q "github.com"; then
        NEW_URL=$(echo "$REMOTE_URL" | sed "s|https://[^@]*@github.com|https://x-access-token:${GH_TOKEN}@github.com|; s|https://github.com|https://x-access-token:${GH_TOKEN}@github.com|")
        git -C /workspace remote set-url origin "$NEW_URL"
    fi
fi

# ── Drop to piuser via gosu ─────────────────────────────────────────────
exec gosu piuser bash -c 'cd /workspace && exec "$@"' _ "$@"
