FROM node:22-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    gh \
    gosu \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install pi globally and record version for update checks
RUN npm install -g @mariozechner/pi-coding-agent && \
    node -e "process.stdout.write(require('/usr/local/lib/node_modules/@mariozechner/pi-coding-agent/package.json').version)" \
    > /etc/pi-agent-version

# Patch OAuth callback to bind to 0.0.0.0 instead of 127.0.0.1
# so Docker port mapping can reach it (needed for pi-docker-auth on macOS)
RUN sed -i 's/const CALLBACK_HOST = "127.0.0.1"/const CALLBACK_HOST = "0.0.0.0"/' \
    /usr/local/lib/node_modules/@mariozechner/pi-coding-agent/node_modules/@mariozechner/pi-ai/dist/utils/oauth/anthropic.js

# Git identity for commits made inside the container
# (credential.helper is configured per-session by entrypoint.sh)
RUN git config --global user.email "pi-agent@local" \
 && git config --global user.name "pi-agent"

# Non-root user for running pi
RUN useradd -m -s /bin/bash piuser
RUN mkdir -p /home/piuser/.pi/agent /workspace \
 && chown -R piuser:piuser /home/piuser/.pi /workspace

# entrypoint.sh is bind-mounted from the host at runtime (see docker-compose.yml),
# keeping the image generic so it doesn't need a rebuild when the script changes.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["pi"]
