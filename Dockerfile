FROM node:22-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    gh \
    gosu \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install pi globally
RUN npm install -g @mariozechner/pi-coding-agent

# Patch OAuth callback to bind to 0.0.0.0 instead of 127.0.0.1
# so Docker port mapping can reach it (needed for pi-docker-auth on macOS)
RUN sed -i 's/const CALLBACK_HOST = "127.0.0.1"/const CALLBACK_HOST = "0.0.0.0"/' \
    /usr/local/lib/node_modules/@mariozechner/pi-coding-agent/node_modules/@mariozechner/pi-ai/dist/utils/oauth/anthropic.js

# Git identity for commits made inside the container
RUN git config --global user.email "pi-agent@local" \
 && git config --global user.name "pi-agent" \
 && git config --global credential.helper store

# Non-root user for running pi
RUN useradd -m -s /bin/bash piuser
RUN mkdir -p /home/piuser/.pi/agent \
 && chown -R piuser:piuser /home/piuser/.pi

# Entrypoint is bind-mounted at runtime from the host (see docker-compose.yml)
# This keeps the image generic and rebuildable without the full repo context.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["pi"]
