# Open WebUI on Fly.io + Tailscale

Runs [Open WebUI](https://github.com/open-webui/open-webui) as a private application on
[Fly.io](https://fly.io), with a [Tailscale](https://tailscale.com) client baked into the
container so the instance is also reachable directly on your tailnet.

## How it works

- The container image extends `ghcr.io/open-webui/open-webui` and installs the
  Tailscale client (`tailscaled` + `tailscale` CLI).
- At container start, `start.sh` brings up `tailscaled` in **userspace networking**
  mode (no `/dev/net/tun` or `NET_ADMIN` required on Fly machines), authenticates with
  `TAILSCALE_AUTHKEY`, then chains into Open WebUI's own startup script
  (`/app/backend/start.sh`).
- A Fly volume mounted at `/app/backend/data` persists Open WebUI's SQLite database and
  uploads **and** the tailscaled state, so the node keeps its tailnet identity across
  redeploys (no new device / auth key consumption per deploy).
- The app listens on port `8080`, handled publicly by the Fly proxy, and privately on
  the tailnet via tailscaled.

## Files

| File         | Purpose                                                        |
|--------------|----------------------------------------------------------------|
| `Dockerfile` | Open WebUI base image + Tailscale client + entrypoint wiring   |
| `start.sh`   | Starts `tailscaled`, runs `tailscale up`, then starts Open WebUI |
| `fly.toml`   | Fly app config: region, volume mount, health check, VM size    |
| `deploy.sh`  | Idempotent deploy to Fly.io: creates app/volume/secrets, then deploys |
| `render.yaml` | Render Blueprint: free-plan web service + env vars (Render's `fly.toml`) |
| `deploy-render.sh` | Triggers a Render deploy via the Render API           |
| `docker-compose.yml` | Local Ollama + Tailscale sidecar published on the tailnet |
| `tailscale/serve.json` | `tailscale serve` config: tailnet HTTPS :443 → `ollama:11434` |
| `.env`       | (gitignored) Local secrets, sourced by `deploy.sh` / compose   |

## Prerequisites

- [`flyctl`](https://fly.io/docs/flyctl/install/) installed and authenticated
  (`flyctl auth login`)
- A Tailscale account, and a **reusable** auth key created at
  <https://login.tailscale.com/admin/settings/keys>
  - Recommended: pre-approved and tagged (e.g. `tag:openwebui`); set
    `TAILSCALE_TAGS=tag:openwebui` in `fly.toml` to match.
  - The key is injected as a **runtime** secret. It is consumed by `tailscale up`
    when the container starts, so there is no reason (and it is unsafe — it ends up
    in image layers) to bake it in at build time.

## Deploy

The same container image (`Dockerfile` + `start.sh`) runs on both platforms — you
can deploy to either or both; they'll be two distinct tailnet nodes
(`openwebui` and `openwebui-render`).

### Fly.io

```bash
# 1. Configure
cp .env.example .env   # or just export the variable
#    put TAILSCALE_AUTHKEY=tskey-auth-XXXX in .env (or export it)

# 2. Deploy (idempotent — same command for first deploy and updates)
./deploy.sh
```

`deploy.sh` will: source `.env`, create the Fly app if missing, create a 3 GB
`openwebui_data` volume if missing, set secrets (`TAILSCALE_AUTHKEY`, a generated
`WEBUI_SECRET_KEY`, and `OPENAI_API_KEY` if exported), then run `flyctl deploy`.

App name and region come from `fly.toml`; override with `FLY_APP` / `FLY_REGION`
environment variables. The app name must be globally unique on Fly.io.

### Render

Render deploys from a Git repo, so push this directory to GitHub/GitLab first, then:

1. In the [Render dashboard](https://dashboard.render.com): **New → Blueprint**,
   select the repo. Render reads `render.yaml` and creates the free-plan web
   service, health check, and environment variables (no disk — persistence comes
   from PostgreSQL, see below).
2. When prompted, set `TAILSCALE_AUTHKEY` and `DATABASE_URL` (`OLLAMA_BASE_URL`
   is hardcoded in `render.yaml` to the local Ollama node's tailnet address).
3. Render builds `Dockerfile` and starts it. The app is live at
   `https://<service-name>.onrender.com` and joins the tailnet as
   `openwebui-render`.

Subsequent updates deploy automatically when you push to the repo. To trigger a
redeploy manually:

```bash
export RENDER_API_KEY=rnd_XXXX     # dashboard.render.com/u/settings#api-keys
export RENDER_SERVICE_ID=srv-XXXX  # from the service URL in the dashboard
./deploy-render.sh
```

Render vs Fly.io notes:

- Runs on the **free plan** (no disk) — persistence comes from PostgreSQL
  instead. Free services sleep after ~15 min idle and the tailnet node drops
  offline until the next public request; switch `plan: free` to `plan: starter`
  in `render.yaml` if you need 24/7 tailnet reachability.
- Render injects its own `PORT`, which Open WebUI honours — `PORT` is deliberately
  not set in `render.yaml`.
- Render exposes service env vars to the Docker **build**, so `HTTP(S)_PROXY` is
  exported by `start.sh` at container start instead — a localhost proxy visible
  at build time breaks `apt`/`curl` install steps (observed as failed builds).
  If you previously synced proxy vars onto the service, delete them manually in
  the **Environment** tab — removing them from `render.yaml` doesn't always
  clean up values already stored on the service.
- `region: singapore` is the closest Render region to Australia.

### Memory footprint (Render 512MB cap)

Render's free **and** Starter plans both cap instances at 512MB — upgrading to
Starter would NOT help. The stock Open WebUI config loads
sentence-transformers + PyTorch for local RAG embeddings, which (with Python and
tailscaled) OOMs the instance at boot. `render.yaml` therefore offloads
embeddings to the tailnet Ollama (`RAG_EMBEDDING_ENGINE=ollama`):

```bash
docker compose exec ollama ollama pull nomic-embed-text   # needed once, locally
```

This keeps the Render instance in the ~350–450MB range. Note the trade-off:
RAG ingestion/retrieval on Render now round-trips to your Mac, and won't work
while it's offline. The Fly deployment is untouched — its 2GB VM runs the
default local embeddings fine.

If memory still spikes (many concurrent users), the options are Render Standard
(2GB, paid) or just using the Fly deployment.

### PostgreSQL persistence (Render)

Open WebUI reads `DATABASE_URL` natively (SQLAlchemy/Peewee) and runs its
migrations at boot, so no code changes are needed — persistence replaces the disk:

```text
postgresql://<user>:<password>@<host>:5432/<database>
```

**Survives restarts/redeploys:** chat history, users, settings, model configs.

**Ephemeral without a disk** (reset on every restart): uploaded files, the RAG
vector store (re-upload knowledge-base docs), and the tailscaled state — which is
why you should use an **[ephemeral](https://tailscale.com/kb/1111/ephemeral-nodes)**
reusable auth key for the Render node: departed devices delete themselves and
`openwebui-render` keeps its name instead of accumulating `-1`, `-2` clones.

Where to get the database:

- Any external Postgres works — the free tiers of Neon or Supabase don't expire
  and are good fits.
- Render's own free Postgres **expires after 30 days**; `render.yaml` has a
  commented-out `databases:` block that provisions one and wires `DATABASE_URL`
  via `fromDatabase` if you want it anyway.
- After Blueprint creation, `DATABASE_URL` can be rotated from the service's
  **Environment** tab (it's a `sync: false` secret, never committed to the repo).

## Access

- **Public:** `https://<app-name>.fly.dev` on Fly.io, or
  `https://<service-name>.onrender.com` on Render — both still behind Open WebUI's
  own login (the first account created becomes admin)
- **Tailnet:** `http://openwebui:8080` (Fly node) or `http://openwebui-render:8080`
  (Render node) from any device on your tailnet
- **Tailnet HTTPS:** set `TAILSCALE_SERVE=true` in `fly.toml` to publish
  `https://openwebui.<tailnet>.ts.net` via `tailscale serve`

## Configuration

Set non-secret values under `[env]` in `fly.toml`:

| Variable            | Default     | Purpose                                             |
|---------------------|-------------|-----------------------------------------------------|
| `PORT`              | `8080`      | Port Open WebUI listens on                          |
| `TAILSCALE_HOSTNAME`| `openwebui` | Node name on the tailnet                            |
| `TAILSCALE_TAGS`    | —           | ACL tags, e.g. `tag:openwebui`                      |
| `TAILSCALE_SERVE`   | `false`     | `true` → serve HTTPS on the tailnet via MagicDNS    |
| `DATABASE_URL`      | SQLite      | Postgres connection string (Render: required)       |
| `OLLAMA_BASE_URL`   | —           | Point at an Ollama instance (tailnet or otherwise)  |
| `HTTP(S)_PROXY`     | (runtime)   | Exported by `start.sh` — never set as platform env vars |

Set secrets with `fly secrets set` (or export them before running `deploy.sh`):
`TAILSCALE_AUTHKEY`, `WEBUI_SECRET_KEY`, `OPENAI_API_KEY`.

### Local Ollama on the tailnet

`docker-compose.yml` runs [Ollama](https://ollama.com) locally in Docker with a
Tailscale sidecar that publishes it on the tailnet as
`https://ollama.<tailnet>.ts.net` (`tailscale serve` proxies tailnet 443 →
`ollama:11434`; the Ollama port is never exposed anywhere else). The sidecar reuses
the `TAILSCALE_AUTHKEY` from `.env` — a reusable key can authenticate multiple nodes.

Prerequisites: Docker Desktop running; HTTPS certificates + MagicDNS enabled on the
tailnet (both on by default).

```bash
# 1. Bring it up and pull models (chat + embeddings used by the Render instance)
docker compose up -d
docker compose exec ollama ollama pull llama3.2
docker compose exec ollama ollama pull nomic-embed-text

# 2. Check the node registered on the tailnet
docker compose exec tailscale tailscale status

# 3. Verify from any tailnet device
curl https://ollama.<tailnet>.ts.net/api/tags
```

Then point the app(s) at it: set `OLLAMA_BASE_URL=https://ollama.<tailnet>.ts.net`
(hint in `fly.toml`; hardcoded in `render.yaml`) and redeploy. `start.sh` exports
`HTTP(S)_PROXY` itself at runtime — deliberately not a platform env var, since
Render (and builds generally) would see an unusable localhost proxy during the
Docker build. Open WebUI's outbound traffic then flows through tailscaled's
userspace proxy (`localhost:1055` inside the container), straight to your Mac.

Notes:

- Ollama in Docker Desktop on a Mac uses **CPU only** (containers get no Apple-GPU
  access) — fine for small models. For Metal acceleration, install Ollama natively
  instead, delete the `ollama` service from `docker-compose.yml`, and change the
  proxy target in `tailscale/serve.json` to `http://host.docker.internal:11434`.
- Ollama itself has no authentication; it is protected only by being reachable
  exclusively on your tailnet. Tighten with
  [ACLs](https://tailscale.com/kb/1018/acls) if you share the tailnet.
- State lives in named volumes: `ollama_data` (models) and `ts_state` (node
  identity). `docker compose down` keeps both; `down -v` deletes models and the
  tailnet identity.

### Tailnet-only (no public URL)

Remove the entire `[http_service]` block from `fly.toml` and redeploy. The app will
have no public address; access it via `http://openwebui:8080` on the tailnet, or set
`TAILSCALE_SERVE=true` for HTTPS.

## Operations

```bash
fly logs -a openwebui                 # app logs
fly status -a openwebui               # machines/status
fly ssh console -a openwebui          # shell into the machine
tailscale status                      # (inside the machine) tailnet state
```

tailscaled writes its own log to `/app/backend/data/tailscale/tailscaled.log` on the
volume. If the node stops appearing on the tailnet, check that file and confirm
`TAILSCALE_AUTHKEY` is still valid (auth keys can expire; the volume-stored state
normally keeps the node authenticated without the key).

## Costs / scaling notes

- `fly.toml` keeps **one machine always running** (`min_machines_running = 1`,
  `auto_stop_machines = "off"`) so the node stays on the tailnet. To save money,
  allow auto-stop — but the tailnet endpoint will be unreachable while stopped.
- The volume is attached to a single machine; don't scale above 1 without moving to
  an external database and object storage.

## Teardown

```bash
fly apps destroy openwebui   # removes app, machines, and the volume (data is lost)
```

On Render: delete the web service in the dashboard (there is no disk — the data
lives in your Postgres instance; drop the database there if you want it gone).

Also delete the `openwebui` / `openwebui-render` devices from the
[Tailscale admin console](https://login.tailscale.com/admin/machines).
