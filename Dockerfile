# Open WebUI + Tailscale, deployable on Fly.io / Render.
# For reproducible deploys, pin a release tag instead of :main.
FROM ghcr.io/open-webui/open-webui:main

USER root

# Copy the client from the official image: `curl tailscale.com/install.sh | sh`
# silently no-ops when the build host can't reach pkgs.tailscale.com (the build
# succeeds and the container only fails at startup), while a registry COPY
# fails loudly at build time.
COPY --from=tailscale/tailscale:stable /usr/local/bin/tailscale /usr/local/bin/tailscale
COPY --from=tailscale/tailscale:stable /usr/local/bin/tailscaled /usr/local/bin/tailscaled
RUN tailscale version

COPY start.sh /start.sh
RUN chmod +x /start.sh

# The base image has no ENTRYPOINT of its own (it runs /app/backend/start.sh);
# our wrapper brings tailscaled up first, then chains into that script.
ENTRYPOINT []
CMD ["/start.sh"]
