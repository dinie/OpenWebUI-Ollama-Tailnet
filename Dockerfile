# Open WebUI + Tailscale, deployable on Fly.io.
# For reproducible deploys, pin a release tag instead of :main.
FROM ghcr.io/open-webui/open-webui:main

USER root

# Install the Tailscale client (tailscaled + tailscale CLI).
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates \
 && curl -fsSL https://tailscale.com/install.sh | sh \
 && rm -rf /var/lib/apt/lists/*

COPY start.sh /start.sh
RUN chmod +x /start.sh

# The base image has no ENTRYPOINT of its own (it runs /app/backend/start.sh);
# our wrapper brings tailscaled up first, then chains into that script.
ENTRYPOINT []
CMD ["/start.sh"]
