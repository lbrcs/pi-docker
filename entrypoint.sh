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

# ── Drop to piuser via gosu ─────────────────────────────────────────────
exec gosu piuser bash -c 'cd /workspace && exec "$@"' _ "$@"
