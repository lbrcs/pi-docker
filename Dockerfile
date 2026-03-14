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
