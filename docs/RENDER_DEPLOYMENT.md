# Deploying Hermes Agent to Render (free account)

This repo ships a ready-to-deploy Docker setup for Render's free tier. The
image can run in two modes (env `HERMES_RENDER_MODE`, set in `render.yaml`):

- **`dashboard` (default)** — the full web UI plus in-browser chat served at
  `https://<service>.onrender.com/`, protected by a username/password login
  (the bundled basic-auth dashboard provider).
- **`api`** — the OpenAI-compatible HTTP API (`api_server` platform) at
  `/v1/*`, authenticated with a bearer key. Point any OpenAI-compatible
  client at `https://<service>.onrender.com/v1`.

A **404 at `/` is expected in `api` mode** — that mode only serves `/health`
and `/v1/*`. For a web UI use `dashboard` mode (the default).

## What works on Render free — and what doesn't

| Render free constraint | Consequence for Hermes |
|---|---|
| Web services **sleep after ~15 min without inbound traffic**; cold start ~20–90 s | Fine for a request-driven dashboard/API (visits and requests wake it). **Not fine for Telegram/Discord/Slack bots using long-polling** — outbound polling doesn't keep it awake, so the bot goes offline and misses messages. |
| **No free background workers** | Only the web-service shape works on free. |
| **512 MB RAM, shared CPU** | The idle dashboard uses ~155 MB; each open Chat tab adds a ~120 MB Node TUI process. One–two concurrent chats fit; browser/Playwright tools and voice may OOM. |
| **Ephemeral filesystem** (wiped on every deploy & restart) | SQLite sessions, learned skills and memory under `/data` don't survive restarts. Treat free as **stateless**; persistent disks are a paid feature. |
| 750 free instance-hours/month per account | One service can essentially run month-round (it stops accruing hours while asleep). |

For an always-on messaging bot or persistent memory, use Render's **Starter
plan (~$7/mo)** with a persistent disk mounted at `/data`, a $5 VPS, or
Modal/Daytona (see the main README).

## Files in this repo

- `render.yaml` — Render Blueprint: free Docker web service + env vars.
- `render/Dockerfile` — 3-stage image: Node compiles **both** frontends (web
  UI → `hermes_cli/web_dist`, TUI bundle → `hermes_cli/tui_dist/entry.js`),
  uv installs locked Python deps + aiohttp, `python:3.11-slim` runtime with a
  copied `node` binary for the Chat-tab PTY. No Playwright/s6 bloat.
- `render/start.sh` — mode switch (`HERMES_RENDER_MODE`), config seeding,
  port binding, boot banner with the deployed commit SHA.
- `render/healthcheck.py` — works in both modes (`/api/health`, `/health`).
- `render/config.yaml` — minimal headless model config (provider + model);
  keys always come from Render environment variables.
- `render/trimmed-plugins/` — created during image build; contains only the
  bundled basic-auth plugin so dashboard mode loads no heavy plugins.

## Option A — Deploy with the Blueprint (easiest)

1. Push the repo to GitHub (Render deploys from GitHub/GitLab).
2. Sign up at <https://dashboard.render.com> (free, no card required).
3. **New + → Blueprint**, connect the repo and the branch
   (`arena/01a090db-hermes-agent` until merged). Render reads `render.yaml`
   and builds `render/Dockerfile`.
   > An earlier service created with the old (native Python) settings cannot
   > be converted in place — delete it first, or let the new service get a
   > fresh name.
4. When prompted fill the secrets (or set them afterwards under
   **Environment**):
   - **Dashboard login** — username defaults to `admin`;
     `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD` is auto-generated; copy it from
     the Environment tab after creation.
   - **Model key** — the seeded `render/config.yaml` defaults to OpenRouter,
     so set `OPENROUTER_API_KEY` (<https://openrouter.ai/keys>, free `:free`
     models work). For NVIDIA NIM set `NVIDIA_API_KEY` instead and switch the
     model block in `render/config.yaml` — see
     [Adding providers](#adding-providers-nvidia-nim-openai-groq-others).
5. Click **Apply**. First image build takes ~5–10 min (Node + Python layers);
   later builds are cached per layer.
6. Open `https://<service>.onrender.com/` → sign in with
   `admin` / the generated password. The dashboard's Chat tab runs the agent
   in the container.

## Option B — Manual Docker web service

**New + → Web Service** → connect repo/branch:

| Field | Value |
|---|---|
| Runtime/Language | **Docker** |
| Dockerfile Path | `render/Dockerfile` |
| Docker Build Context | `.` (repo root) |
| Instance type | **Free** |
| Health check path | `/api/health` (dashboard) or `/health` (api mode) |

Environment variables:

| Key | Value | Dashboard | API |
|---|---|---|---|
| `HERMES_RENDER_MODE` | `dashboard` or `api` | required | required |
| `HERMES_DASHBOARD_BASIC_AUTH_USERNAME` | e.g. `admin` | required | — |
| `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD` | a strong password | required | — |
| `HERMES_DASHBOARD_BASIC_AUTH_SECRET` | `openssl rand -hex 32` | recommended | — |
| `API_SERVER_KEY` | `openssl rand -hex 32` | optional (cookie-secret fallback) | required (bearer token) |
| `OPENROUTER_API_KEY` / `NVIDIA_API_KEY` / … | your provider key | required for chat | required for completions |

No start/build commands needed — the image CMD runs `render/start.sh`, which
binds `0.0.0.0:$PORT` (Render injects `$PORT`; `RENDER_EXTERNAL_HOSTNAME` is
used to derive `HERMES_DASHBOARD_PUBLIC_URL` for secure cookies and Host
validation behind Render's HTTPS proxy).

## Adding providers (NVIDIA NIM, OpenAI, Groq, others)

Hermes reads **which** model to use from `$HERMES_HOME/config.yaml` (seeded
from `render/config.yaml`) and **keys** from environment variables:

1. Edit `render/config.yaml` — OpenRouter is active; every other provider is
   there in a commented block. Swap the active `model:` block, commit, push.
2. Add that provider's key env var in Render → **Environment**.

| Provider | `model.provider` | Key env var | Base URL | Free option |
|---|---|---|---|---|
| OpenRouter (default) | `openrouter` | `OPENROUTER_API_KEY` | `https://openrouter.ai/api/v1` | `:free` models |
| **NVIDIA NIM** | `nvidia` | `NVIDIA_API_KEY` | `https://integrate.api.nvidia.com/v1` | free credits at <https://build.nvidia.com> |
| OpenAI | `openai-api` | `OPENAI_API_KEY` | `https://api.openai.com/v1` | no |
| Anthropic | `anthropic` | `ANTHROPIC_API_KEY` | `https://api.anthropic.com` | no |
| Google (Gemini) | `gemini` | `GOOGLE_API_KEY` / `GEMINI_API_KEY` | `https://generativelanguage.googleapis.com/v1beta` | free tier |
| Groq | `groq` | `GROQ_API_KEY` | `https://api.groq.com/openai/v1` | free tier |
| DeepSeek | `deepseek` | `DEEPSEEK_API_KEY` | `https://api.deepseek.com/v1` | cheap |
| xAI | `xai` | `XAI_API_KEY` | `https://api.x.ai/v1` | no |
| z.ai (GLM) | `zai` | `GLM_API_KEY` | `https://api.z.ai/api/paas/v4` | some free |
| Kimi | `kimi-coding` | `KIMI_API_KEY` | `https://api.moonshot.ai/v1` | some free |
| Hugging Face | `huggingface` | `HF_TOKEN` | `https://router.huggingface.co/v1` | free tier |
| Any OpenAI-compatible endpoint (vLLM, Together, self-hosted NIM…) | `custom` | per endpoint | your URL | — |

Full list: `cli-config.yaml.example` and `hermes_cli/auth.py` (`_REGISTRY_ROWS`).

### Serve SEVERAL providers in `api` mode (model routes)

```yaml
platforms:
  api_server:
    enabled: true
    extra:
      model_routes:
        nim:       { model: "nvidia/nemotron-3.5-lightning-30b-a3b", provider: "nvidia" }
        groq-fast: { model: "llama-3.3-70b-versatile", provider: "groq" }
        free:      { model: "meta-llama/llama-3.3-70b-instruct:free", provider: "openrouter" }
```

Set every referenced provider's key in Render; the gateway resolves them from
the environment. Aliases appear in `GET /v1/models`.

## Trying it out

### Dashboard mode

Browse to `https://<service>.onrender.com/` → log in (`admin` + the generated
password) → use the **Chat** tab. Public health probe (pre-login):

```bash
curl https://<service>.onrender.com/api/health
# {"ok":true,"version":"0.21.1","auth_required":true}
```

### API mode

```bash
# Health (also wakes a sleeping service — first hit may take 30–90 s)
curl https://<service>.onrender.com/health

# Models (use API_SERVER_KEY from Render's Environment tab)
curl https://<service>.onrender.com/v1/models \
  -H "Authorization: Bearer $API_SERVER_KEY"

# Chat completion
curl https://<service>.onrender.com/v1/chat/completions \
  -H "Authorization: Bearer $API_SERVER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
        "model": "meta-llama/llama-3.3-70b-instruct:free",
        "messages": [{"role": "user", "content": "Say hello in one sentence."}],
        "stream": false
      }'
```

## Operations & troubleshooting

- **Verifying the deployed commit / mode:** every boot prints
  `== render/start.sh (commit <sha>, mode <dashboard|api>) ==`. If the SHA
  doesn't match the latest push, do **Manual Deploy → Clear build cache &
  deploy** and check the tracked branch.
- **`/` shows 404:** you're in `api` mode (only `/v1/*` + `/health`); set
  `HERMES_RENDER_MODE=dashboard` and redeploy for the web UI.
- **Dashboard login fails / "Configure a provider" in logs:** the auth gate
  on a public bind is mandatory. Set `HERMES_DASHBOARD_BASIC_AUTH_USERNAME`
  and `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD`; the image loads the bundled
  basic-auth plugin from `render/trimmed-plugins`.
- **Build fails with `libatomic.so.1: cannot open shared object file`:** old
  cached image — the runtime stage now installs `libatomic1 libstdc++6` for
  the copied Node binary; **Clear build cache & deploy**.
- **Chat tab: "Chat connection interrupted (code 1006)":** the in-browser
  chat spawns the Node-based TUI over `/api/pty` + `/api/ws`. The image must
  (1) ship the prebuilt TUI bundle `hermes_cli/tui_dist/entry.js` and (2) have
  `node` + `npm` on PATH (`HERMES_SKIP_NODE_BOOTSTRAP=1` prevents cold-start
  downloads). The current `render/Dockerfile` builds and ships all of it;
  seeing 1006 means the running image predates that — rebuild with
  **Manual Deploy → Clear build cache & deploy**. One open chat adds ~120 MB
  (Node TUI) on top of the ~155 MB dashboard — a single chat fits the free
  512 MB tier comfortably; keep concurrent chats low.
- **`aiohttp not installed` / "no open ports detected":** only possible on
  the native Python runtime (Option C, below) — the Docker image bakes
  aiohttp in.
- **First hit after idle is slow:** the free instance is waking; retry after
  ~30–90 s. Don't run uptime-pingers — they burn the 750 free hours.
- **Model errors / 401 / 402 / rate limits:** missing or exhausted provider
  key — set the env var matching `render/config.yaml`; `:free` OpenRouter
  models and NVIDIA trial credits are rate/capacity-limited.
- **SQLite 3.40 WAL-reset warnings:** safe to ignore; Hermes falls back to
  `journal_mode=DELETE` on the slim image's older SQLite.
- **Sessions/memory disappear:** expected on the ephemeral free disk; mount
  a persistent disk at `/data` on a paid plan.
- **Slack/browser/TTS plugin warnings:** shouldn't appear in dashboard mode
  (trimmed plugin tree) or api mode (`HERMES_SAFE_MODE=1`); if they do, the
  deploy is on an old commit.

## Option C — Native Python runtime (no Docker; not recommended)

Python 3 runtime; build command
`pip install -U uv && uv sync --frozen --no-dev --extra sms`, start
`bash render/start.sh`. Dashboard mode additionally needs the web UI built
on the host (`npm install --workspace web && npm run build --workspace web`,
Node ≥ 22.22) — the Docker path handles all of this, which is why it's
recommended.

## Cost recap

- Dashboard/API for intermittent/demo use: **$0** (this guide).
- Always-on bot, persistent state, no cold starts: ~$7/mo Starter + disk.
