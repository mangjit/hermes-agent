# ─────────────────────────────────────────────────────────────────────────────
# Image for Hermes Agent on Render (free tier) — can run in two modes
# (selected with HERMES_RENDER_MODE in render/start.sh):
#
#   dashboard (default)  `hermes dashboard` — the web UI + in-browser chat
#                        served on $PORT, protected by username/password.
#   api                  the gateway's OpenAI-compatible api_server on $PORT.
#
# This is NOT the repo's full-fat Dockerfile (that bundles Playwright, s6 and
# a Node runtime). Here Node is used ONLY at build time to compile the web UI;
# the runtime is a slim Python image.
# ─────────────────────────────────────────────────────────────────────────────

# ---- Stage 1: build the web dashboard (Vite -> hermes_cli/web_dist) ----------
FROM node:26-bookworm-slim AS web

WORKDIR /build

# Install only the web workspace's dependency tree (the file: dependency on
# apps/shared is resolved from the copied manifests).
COPY package.json package-lock.json ./
COPY web/package.json web/package.json
COPY apps/shared/package.json apps/shared/package.json
RUN npm install --workspace web --no-audit --fetch-retries=5

# Sources, then the production build (outDir: ../hermes_cli/web_dist).
COPY web/ web/
COPY apps/shared/ apps/shared/
RUN npm run build --workspace web

# ---- Stage 2: Python dependencies -------------------------------------------
FROM python:3.11-slim-bookworm AS builder

COPY --from=ghcr.io/astral-sh/uv:0.11.6 /uv /usr/local/bin/uv

ENV UV_LINK_MODE=copy \
    UV_COMPILE_BYTECODE=1 \
    UV_PROJECT_ENVIRONMENT=/app/.venv \
    UV_PYTHON_DOWNLOADS=never

WORKDIR /app

# Dependency layer, cached unless pyproject.toml / uv.lock change.
# pyproject references README.md, which .dockerignore excludes, so `touch`
# a placeholder for resolution; the editable install below is --no-deps.
# --extra sms pulls aiohttp (needed by the gateway api_server in api mode).
COPY pyproject.toml uv.lock setup.py ./
RUN touch ./README.md \
 && uv sync --frozen --no-dev --no-install-project --extra sms

# Project source (contains render/start.sh, render/config.yaml, plugins/...).
COPY . .

# Trimmed bundled-plugin TREE for dashboard mode: the dashboard's auth gate
# (engaged on every non-loopback bind) needs a DashboardAuthProvider. The
# bundled username/password provider lives in plugins/dashboard_auth/basic;
# pointing HERMES_BUNDLED_PLUGINS at this trimmed tree means the browser,
# image-gen, slack, ... plugins are never discovered (fast boot, low RAM,
# no missing-dependency warnings on the slim image).
RUN mkdir -p render/trimmed-plugins/dashboard_auth \
 && cp -r plugins/dashboard_auth/basic render/trimmed-plugins/dashboard_auth/ \
 && cp plugins/dashboard_auth/_shared.py render/trimmed-plugins/dashboard_auth/ \
 && uv pip install --python /app/.venv/bin/python --no-cache-dir --no-deps -e "."

# ---- Stage 3: runtime --------------------------------------------------------
FROM python:3.11-slim-bookworm AS runtime

# Render passes the deployed commit SHA as an automatic build arg.
ARG SOURCE_COMMIT=unknown
ENV SOURCE_COMMIT=${SOURCE_COMMIT} \
    PYTHONUNBUFFERED=1 \
    PATH=/app/.venv/bin:$PATH \
    HERMES_HOME=/data \
    HERMES_WEB_DIST=/app/hermes_cli/web_dist

WORKDIR /app

# .venv + source tree (editable install points at /app) + compiled web UI.
COPY --from=builder /app /app
COPY --from=web /build/hermes_cli/web_dist /app/hermes_cli/web_dist
RUN mkdir -p /data

# Render injects $PORT at runtime (10000 by default); render/start.sh maps it
# to the dashboard/api port. EXPOSE is documentation only.
EXPOSE 10000

# Works for both modes: dashboard -> /api/health (public, pre-login),
# api -> /health.
HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=3 \
  CMD ["python", "render/healthcheck.py"]

CMD ["bash", "render/start.sh"]
