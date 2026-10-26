#!/usr/bin/env bash
set -euo pipefail

# tailscaled state lives on the Fly volume so the node keeps its identity
# (and doesn't consume a new auth key / create a new tailnet device) on redeploys.
TS_STATE_DIR="${TAILSCALE_STATE_DIR:-/app/backend/data/tailscale}"
TS_SOCKET=/var/run/tailscale/tailscaled.sock

mkdir -p "$TS_STATE_DIR" /var/run/tailscale

# Userspace networking avoids needing /dev/net/tun or NET_ADMIN in the Fly VM.
# Inbound tailnet connections are forwarded to localhost automatically; the
# SOCKS5/HTTP proxies on :1055 let the app reach other tailnet services.
tailscaled \
  --tun=userspace-networking \
  --statedir="$TS_STATE_DIR" \
  --socket="$TS_SOCKET" \
  --socks5-server=localhost:1055 \
  --outbound-http-proxy-listen=localhost:1055 \
  >"$TS_STATE_DIR/tailscaled.log" 2>&1 &

for _ in $(seq 1 40); do
  [ -S "$TS_SOCKET" ] && break
  sleep 0.5
done

if [ -n "${TAILSCALE_AUTHKEY:-}" ]; then
  tailscale up \
    --auth-key="$TAILSCALE_AUTHKEY" \
    --hostname="${TAILSCALE_HOSTNAME:-openwebui}" \
    --accept-routes \
    ${TAILSCALE_TAGS:+--advertise-tags="$TAILSCALE_TAGS"} \
    --reset
else
  echo "[start.sh] TAILSCALE_AUTHKEY not set — relying on saved tailscale state (if any)." >&2
fi

# Optional: serve HTTPS on the tailnet at https://<hostname>.<tailnet>.ts.net
if [ "${TAILSCALE_SERVE:-false}" = "true" ]; then
  tailscale serve --bg 8080
fi

# Chain into Open WebUI's own startup (migrations, then uvicorn on :8080).
cd /app/backend
exec bash start.sh "$@"
