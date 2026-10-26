# Open WebUI + Tailscale, deployable on Fly.io / Render.
# For reproducible deploys, pin a release tag instead of :main.
FROM ghcr.io/open-webui/open-webui:main

USER root

# Copy the client from the official image rather than apt/curl-installing it:
# this build must not do any network installs. Render exposes the service's env
# vars to Docker builds (HTTP(S)_PROXY=localhost:1055 broke apt/curl here), and
# `curl ... | sh` silently no-ops on network failure, yielding an image with no
# tailscale binaries that only fails at container start.
COPY --from=tailscale/tailscale:stable /usr/local/bin/tailscale /usr/local/bin/tailscale
COPY --from=tailscale/tailscale:stable /usr/local/bin/tailscaled /usr/local/bin/tailscaled
RUN tailscale version

COPY start.sh /start.sh
RUN chmod +x /start.sh

# The base image has no ENTRYPOINT of its own (it runs /app/backend/start.sh);
# our wrapper brings tailscaled up first, then chains into that script.
ENTRYPOINT []
CMD ["/start.sh"]
