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
4. When prompted, fill the `OPENROUTER_API_KEY` environment variable
   (get one at <https://openrouter.ai/keys>; free `:free` models work).
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
| `OPENROUTER_API_KEY` | your OpenRouter key (or the key for your provider) |
| `API_SERVER_HOST` | `0.0.0.0` |

`API_SERVER_PORT` is set to Render's `$PORT` automatically by `render/start.sh`.

> Using a different provider (OpenAI, Anthropic, Gemini, a self-hosted endpoint)?
> Edit `render/config.yaml` (`model.provider`, `model.default`, `model.base_url`)
> and set that provider's standard key env var (`OPENAI_API_KEY`,
> `ANTHROPIC_API_KEY`, `GOOGLE_API_KEY`, …). The full provider list is in
> `cli-config.yaml.example`.

## Trying it out

```bash
# Health (also wakes a sleeping service — expect a slow first response)
curl https://<your-service>.onrender.com/health

# List models (use the API_SERVER_KEY value from Render's env tab)
curl https://<your-service>.onrender.com/v1/models \
  -H "Authorization: Bearer $API_SERVER_KEY"

# Chat completion (OpenAI-compatible)
curl https://<your-service>.onrender.com/v1/chat/completions \
  -H "Authorization: Bearer $API_SERVER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
        "model": "meta-llama/llama-3.3-70b-instruct:free",
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
- **Model errors / 402 / rate limits:** the `:free` OpenRouter models are
  rate-limited and change over time — edit `render/config.yaml` to a current
  model id from <https://openrouter.ai/models?max_price=0>, or add credits.
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
