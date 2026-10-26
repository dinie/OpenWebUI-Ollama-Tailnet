#!/usr/bin/env bash
# Trigger a fresh deploy of the Render service via the Render API.
# Initial service creation is done once via the Blueprint flow (render.yaml —
# Dashboard → New → Blueprint); after that, pushes to the repo auto-deploy and
# this script is only for manual re-deploys.
#
#   export RENDER_API_KEY=rnd_XXXX    # https://dashboard.render.com/u/settings#api-keys
#   export RENDER_SERVICE_ID=srv-XXXX # from the service's URL in the dashboard
#   ./deploy-render.sh
set -euo pipefail
cd "$(dirname "$0")"

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

: "${RENDER_API_KEY:?RENDER_API_KEY must be set (see .env.example)}"
: "${RENDER_SERVICE_ID:?RENDER_SERVICE_ID must be set (see .env.example)}"

curl -sSf -X POST \
  "https://api.render.com/v1/services/$RENDER_SERVICE_ID/deploys" \
  -H "Authorization: Bearer $RENDER_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"clearCache":"do_not_clear"}' \
  && printf '\nDeploy triggered.\n'
