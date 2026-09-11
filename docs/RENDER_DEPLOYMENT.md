# Deploying Hermes Agent to Render (free account)

This guide deploys the Hermes **gateway in HTTP API mode** — the OpenAI-compatible
`api_server` platform (`gateway/platforms/api_server.py`, port 8642 by default)
— as a free Render web service. Once deployed you can point any OpenAI client,
the Hermes web dashboard, or other agents at `https://<your-service>.onrender.com/v1`.

## What works on Render free — and what doesn't

Render's free tier has hard constraints that shape *which part* of Hermes you can run:

| Render free constraint | Consequence for Hermes |
|---|---|
| Web services **sleep after ~15 min without inbound traffic**; cold start takes 30–90 s | Fine for a request-driven HTTP API (incoming requests wake it). **Not fine for Telegram/Discord/Slack bots using long-polling** — outbound polling does not keep the service awake, so the bot goes offline and misses messages. |
| **No free background workers / cron jobs** | The gateway as a worker is impossible on free; only the web-service shape works. |
| **512 MB RAM, ~0.1 CPU** | Enough to boot the API and serve small turns. Browser/Playwright tools, voice transcription, and heavy parallel subagents may OOM — keep your toolset lean. |
| **Ephemeral filesystem** (wiped on every deploy & restart) | The SQLite session DB, learned skills, and memory under `$HERMES_HOME` do not survive restarts. Treat a free deployment as **stateless**. Persistent disks and Postgres are paid features. |
| 750 free instance-hours/month per account | One free service can essentially run month-round (it stops accruing hours while asleep). Don't run two free services simultaneously. |

If you need an always-on messaging bot or persistent memory, the fit is Render's
**Starter plan ($7/mo)** with a background worker + persistent disk, or one of the
self-host/serverless options the README recommends (a $5 VPS, Modal, Daytona).

Incoming webhooks (Telegram webhook mode, Slack/Socket mode is polling) *can* wake a
free service, but Hermes' cold start under 512 MB often exceeds Telegram's ~60 s
webhook timeout — expect dropped updates. Use polling bots on a paid plan.

## Option A — Deploy with the Blueprint (easiest)

This repo now contains:

- `render.yaml` — service definition (free Python web service)
- `render/start.sh` — binds `$PORT`, seeds config, runs `hermes gateway run`
- `render/config.yaml` — minimal headless model config (provider + model)

Steps:

1. Push the repo to your GitHub account (Render deploys from GitHub/GitLab).
2. Sign up / log in at <https://dashboard.render.com> (free, no card required).
3. **New + → Blueprint** and connect your repo. Render reads `render.yaml`.
4. When prompted, fill the provider key(s) — the default `render/config.yaml`
   uses **NVIDIA NIM**, so set `NVIDIA_API_KEY` (get it at
   <https://build.nvidia.com> → "Get API Key", starts with `nvapi-`; new
   accounts get free credits). Using another provider? See
   [Adding providers](#adding-providers-nvidia-nim-openai-groq-others).
5. Click **Apply**. Render builds (`uv sync` from `uv.lock`) and starts the service.
6. Watch the **Logs** tab; success looks like the api_server adapter binding
   `0.0.0.0:$PORT` and a `200 OK` on the health check.

Your API base URL is `https://<service-name>.onrender.com/v1`.

## Option B — Manual web service setup

If you don't want the blueprint, create **New + → Web Service** and set:

| Field | Value |
|---|---|
| Runtime | Python 3 |
| Branch | your branch (e.g. `main`) |
| Build command | `pip install -U uv && uv sync --frozen --no-dev` |
| Start command | `bash render/start.sh` |
| Instance type | **Free** |
| Health check path | `/health` |

Then under **Environment** add:

| Key | Value |
|---|---|
| `API_SERVER_KEY` | output of `openssl rand -hex 32` (≥ 16 chars, required) |
| `NVIDIA_API_KEY` | your NVIDIA NIM key (or the key for whatever provider `render/config.yaml` uses) |
| `API_SERVER_HOST` | `0.0.0.0` |

`API_SERVER_PORT` is set to Render's `$PORT` automatically by `render/start.sh`.

## Adding providers (NVIDIA NIM, OpenAI, Groq, others)

Hermes reads **which** model to use from `$HERMES_HOME/config.yaml` (seeded from
`render/config.yaml`) and **keys** from environment variables — so adding a
provider is always the same two steps:

**1. Pick the provider + model in `render/config.yaml`** (the active file ships
with NVIDIA NIM; every other supported provider is there in a commented block —
just swap which `model:` block is uncommented).

**2. Add the provider's key env var in Render** (service → **Environment** →
Add Environment Variable), then redeploy (Manual Deploy → Clear build cache not
needed — just *Deploy latest commit* after committing the config change).

### Common providers cheat-sheet

| Provider | `model.provider` | Key env var | Base URL | Free option |
|---|---|---|---|---|
| **NVIDIA NIM** | `nvidia` | `NVIDIA_API_KEY` | `https://integrate.api.nvidia.com/v1` | Free credits on build.nvidia.com |
| OpenRouter | `openrouter` | `OPENROUTER_API_KEY` | `https://openrouter.ai/api/v1` | `:free` models |
| OpenAI | `openai-api` | `OPENAI_API_KEY` | `https://api.openai.com/v1` | No |
| Anthropic | `anthropic` | `ANTHROPIC_API_KEY` | `https://api.anthropic.com` | No |
| Google AI Studio (Gemini) | `gemini` | `GOOGLE_API_KEY` or `GEMINI_API_KEY` | `https://generativelanguage.googleapis.com/v1beta` | Free tier |
| Groq | `groq` | `GROQ_API_KEY` | `https://api.groq.com/openai/v1` | Free tier |
| DeepSeek | `deepseek` | `DEEPSEEK_API_KEY` | `https://api.deepseek.com/v1` | Cheap |
| xAI (Grok) | `xai` | `XAI_API_KEY` | `https://api.x.ai/v1` | No |
| z.ai (GLM) | `zai` | `GLM_API_KEY` | `https://api.z.ai/api/paas/v4` | Some free |
| Kimi | `kimi-coding` | `KIMI_API_KEY` | `https://api.moonshot.ai/v1` | Some free |
| Hugging Face | `huggingface` | `HF_TOKEN` | `https://router.huggingface.co/v1` | Free tier |
| Ollama Cloud | `ollama-cloud` | `OLLAMA_API_KEY` | (provider default) | No |
| Any OpenAI-compatible endpoint (vLLM, Together, Fireworks, a local NIM…) | `custom` | key per endpoint | your URL | — |

The full always-current list lives in `cli-config.yaml.example` (top of the
`model:` section) and `hermes_cli/auth.py` (`_REGISTRY_ROWS`).

### NVIDIA NIM specifics

1. Create the key at <https://build.nvidia.com> (sign in → **Get API Key**;
   format `nvapi-…`). New accounts receive free inference credits; usage-based
   billing can be added after.
2. Render → Environment: `NVIDIA_API_KEY = nvapi-…`.
3. Pick a model id at <https://build.nvidia.com/models> — NIM ids are
   `vendor/model` (e.g. `nvidia/nemotron-3.5-lightning-30b-a3b`,
   `meta/llama-3.3-70b-instruct`). Hermes' built-in list for `nvidia` also
   appears via `GET /v1/models` once the service is up. Put it in
   `model.default` in `render/config.yaml`.
4. Commit the config change and push (if auto-deploy is on, Render redeploys),
   or edit `config.yaml` directly in the Render shell for a one-off test.

> **Self-hosted/local NIM container:** use `provider: "custom"` with your NIM's
> `base_url` instead — but note a free Render service cannot reach `localhost`
> on your machine; the NIM needs a public/HTTPS URL.

### Serve SEVERAL providers from one deployment (model routes)

The API server supports per-client model routing. In `render/config.yaml`
uncomment and edit:

```yaml
platforms:
  api_server:
    enabled: true
    extra:
      model_routes:
        nim:                       # clients send {"model": "nim"}
          model: "nvidia/nemotron-3.5-lightning-30b-a3b"
          provider: "nvidia"
        groq-fast:                 # clients send {"model": "groq-fast"}
          model: "llama-3.3-70b-versatile"
          provider: "groq"
        free:                      # clients send {"model": "free"}
          model: "meta-llama/llama-3.3-70b-instruct:free"
          provider: "openrouter"
```

Set **every** referenced provider's key env var in Render (`NVIDIA_API_KEY`,
`GROQ_API_KEY`, `OPENROUTER_API_KEY`) — the gateway resolves each route's
credentials from the environment; keys never need to appear in the YAML.
Unmapped model names fall back to the global `model.default`. Aliases show up
in `GET /v1/models` automatically.

### Switching model at runtime (no redeploy)

- An OpenAI client can also send a per-request `provider` field (Hermes
  extension), or use the Hermes session/chat endpoint's `/model` override —
  these need only the relevant key to already exist in the environment.

## Trying it out

```bash
# Health (also wakes a sleeping service — expect a slow first response)
curl https://<your-service>.onrender.com/health

# List models (use the API_SERVER_KEY value from Render's env tab)
curl https://<your-service>.onrender.com/v1/models \
  -H "Authorization: Bearer $API_SERVER_KEY"

# Chat completion (OpenAI-compatible). Model must match what you configured in
# render/config.yaml (NVIDIA NIM example below; use a model_routes alias too).
curl https://<your-service>.onrender.com/v1/chat/completions \
  -H "Authorization: Bearer $API_SERVER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
        "model": "nvidia/nemotron-3.5-lightning-30b-a3b",
        "messages": [{"role": "user", "content": "Say hello in one sentence."}],
        "stream": false
      }'
```

Point any OpenAI-compatible client at the base URL with the bearer key
(e.g. `openai.BaseURL = https://<your-service>.onrender.com/v1`).

## (Optional) Hosting the web dashboard as a free static site

The Vite dashboard in `web/` can build to static files:

1. **New + → Static Site**, connected to the same repo.
2. Build command: `npm install && npm run build --workspace web`
3. Publish directory: `web/dist`
4. Add env `NODE_VERSION=22.22.0` (the repo requires Node ≥ 22.22).
5. On the API web service set `API_SERVER_CORS_ORIGINS=https://<static-site>.onrender.app`.

Note the dashboard is designed to be served by `hermes dashboard` on the same
origin as the gateway; cross-origin static hosting works for the HTTP surfaces
but some websocket features may not. For full functionality, run the dashboard
alongside a paid service instead.

## Operations & troubleshooting

- **First request after idle is slow / times out:** the free instance is waking up
  (cold start). Retry after ~30–60 s. External uptime-pingers will burn your
  750 free hours and are against the spirit of the free tier — don't.
- **`Refusing to start: API_SERVER_KEY is required…`:** set `API_SERVER_KEY`
  (min 16 chars; `openssl rand -hex 32`) in the service's environment.
- **Build failures around Python version:** the repo pins Python via
  `.python-version` (3.11, within the supported `>=3.11,<3.14`).
- **Model errors / 402 / rate limits:** free-tier models (NVIDIA trial credits
  exhausted, OpenRouter `:free`, Groq limits) are rate/capacity-limited —
  check the model id against <https://build.nvidia.com/models> (or your
  provider's catalog), add credits, or switch providers in
  `render/config.yaml`.
- **Sessions/memory disappear:** expected on free (ephemeral disk). Upgrade to a
  paid instance with a persistent disk mounted at `$HERMES_HOME` to keep them.
- **Logs show the first-run setup wizard prompt:** it only appears when
  `$HERMES_HOME/config.yaml` is missing — confirm `render/start.sh` seeded it.
- **Running messaging platforms (Telegram, Discord, …):** do not enable them on a
  free sleeping service. Use a paid background worker (start command
  `.venv/bin/hermes gateway run --no-supervise` with the platform's env vars,
  e.g. `TELEGRAM_BOT_TOKEN`) — Render doesn't route traffic to workers, but
  long-polling needs exactly that always-on process.

## Cost recap

- API server, intermittent/demo use: **$0** (this guide).
- Always-on bot, persistent state, no cold starts: **~$7/mo** Starter worker
  (+ disk), per Render's current pricing.
