#!/usr/bin/env bash
# Deploy Open WebUI + Tailscale to Fly.io.
#
# Usage:
#   export TAILSCALE_AUTHKEY=tskey-auth-XXXX   # reusable key from
#                                              # https://login.tailscale.com/admin/settings/keys
#   ./deploy.sh
#
# You can also put TAILSCALE_AUTHKEY (and optionally OPENAI_API_KEY,
# WEBUI_SECRET_KEY, FLY_APP, FLY_REGION) in a .env file next to this script.
set -euo pipefail
cd "$(dirname "$0")"

# ----- config -------------------------------------------------------------
if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

APP="${FLY_APP:-$(sed -n 's/^app *= *"\(.*\)"/\1/p' fly.toml | head -1)}"
REGION="${FLY_REGION:-$(sed -n 's/^primary_region *= *"\(.*\)"/\1/p' fly.toml | head -1)}"
VOLUME_NAME="openwebui_data"
VOLUME_SIZE="${FLY_VOLUME_SIZE:-3}"

# ----- preflight ----------------------------------------------------------
command -v flyctl >/dev/null || { echo "flyctl not found — install with: brew install flyctl" >&2; exit 1; }
flyctl auth whoami >/dev/null 2>&1 || { echo "not logged in — run: flyctl auth login" >&2; exit 1; }
[ -n "${TAILSCALE_AUTHKEY:-}" ] || { echo "TAILSCALE_AUTHKEY is not set. Export it or put it in .env" >&2; exit 1; }

echo "==> Deploying app '$APP' (region: $REGION)"

# ----- app ----------------------------------------------------------------
if flyctl status -a "$APP" >/dev/null 2>&1; then
  echo "==> App '$APP' already exists"
else
  echo "==> Creating app '$APP'"
  flyctl apps create "$APP"
fi

# ----- volume -------------------------------------------------------------
if flyctl volumes list -a "$APP" 2>/dev/null | grep -q "$VOLUME_NAME"; then
  echo "==> Volume '$VOLUME_NAME' already exists"
else
  echo "==> Creating $VOLUME_SIZE GB volume '$VOLUME_NAME' in $REGION"
  flyctl volumes create "$VOLUME_NAME" --region "$REGION" --size "$VOLUME_SIZE" -a "$APP" --yes
fi

# ----- secrets ------------------------------------------------------------
SECRETS=("TAILSCALE_AUTHKEY=$TAILSCALE_AUTHKEY")

# Generate a WEBUI_SECRET_KEY once, if not provided and not already on the app.
if [ -z "${WEBUI_SECRET_KEY:-}" ] && ! flyctl secrets list -a "$APP" 2>/dev/null | grep -q "^WEBUI_SECRET_KEY"; then
  WEBUI_SECRET_KEY="$(openssl rand -hex 32)"
  echo "==> Generated a random WEBUI_SECRET_KEY"
fi
[ -n "${WEBUI_SECRET_KEY:-}" ] && SECRETS+=("WEBUI_SECRET_KEY=$WEBUI_SECRET_KEY")
[ -n "${OPENAI_API_KEY:-}" ]   && SECRETS+=("OPENAI_API_KEY=$OPENAI_API_KEY")

echo "==> Setting secrets"
flyctl secrets set -a "$APP" "${SECRETS[@]}"

# ----- deploy -------------------------------------------------------------
echo "==> Deploying"
flyctl deploy -a "$APP"

cat <<EOF

Done.
  Public:   https://$APP.fly.dev
  Tailnet:  http://${TAILSCALE_HOSTNAME:-openwebui}:8080
            (or https://${TAILSCALE_HOSTNAME:-openwebui}.<tailnet>.ts.net with TAILSCALE_SERVE=true)
EOF
