# ─────────────────────────────────────────────────────────────────────────────
# Image for Hermes Agent on Render (free tier) — runs in two modes
# (selected with HERMES_RENDER_MODE in render/start.sh):
#
#   dashboard (default)  `hermes dashboard` — web UI + in-browser chat on
#                        $PORT. The Chat tab needs: (1) the prebuilt web UI,
#                        (2) the prebuilt Node TUI bundle, (3) a node binary
#                        at runtime. All three are baked here. Login:
#                        HERMES_DASHBOARD_BASIC_AUTH_USERNAME/PASSWORD.
#   api                  OpenAI-compatible gateway api_server on $PORT.
#
# Node is used at BUILD time (web + TUI bundles) and a ~100 MB node binary is
# kept at RUNTIME for the dashboard Chat PTY. The runtime stays a slim Python
# image — no Playwright, no s6, no npm installs on cold start.
# ─────────────────────────────────────────────────────────────────────────────

# ---- Stage 1: build web UI (Vite) + TUI (esbuild) ---------------------------
FROM node:26-bookworm-slim@sha256:9e6f9357d371591e32ab6f2d8a26d63bdd0d17c29eee3f4f3e7e454d9634bf73 AS web

WORKDIR /build

# Manifests first (with the file: workspace packages' package.json + src), so
# the npm install layer is cached unless dependencies change.
COPY package.json package-lock.json ./
COPY web/package.json web/package.json
COPY ui-tui/package.json ui-tui/package.json
COPY ui-tui/packages/hermes-ink/package.json ui-tui/packages/hermes-ink/package.json
COPY apps/shared/package.json apps/shared/package.json
COPY ui-tui/packages/hermes-ink/src ui-tui/packages/hermes-ink/src
COPY apps/shared/src apps/shared/src
RUN npm install --workspace web --workspace ui-tui --no-audit --fetch-retries=5

# Sources, then both production builds:
#   web  -> /build/hermes_cli/web_dist   (Vite outDir)
#   tui  -> /build/ui-tui/dist/entry.js  (self-contained esbuild bundle,
#                                         "no runtime node_modules needed")
# node_modules is excluded from the build context by .dockerignore.
COPY web/ web/
COPY ui-tui/ ui-tui/
RUN npm run build --workspace web && npm run build --workspace ui-tui

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
    HERMES_WEB_DIST=/app/hermes_cli/web_dist \
    # Never try to download Node on a cold start (it is copied below).
    HERMES_SKIP_NODE_BOOTSTRAP=1

# node + npm at runtime (the Chat PTY checks for both). Copied from the same
# bookworm-based node image used in stage 1, so glibc matches. Pattern mirrors
# the repo's root Dockerfile. Node 26 additionally links libatomic (and wants
# libstdc++6/ca-certificates), none of which python:3.11-slim guarantees.
RUN apt-get update \
 && apt-get install -y --no-install-recommends libatomic1 libstdc++6 ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY --chmod=0755 --from=web /usr/local/bin/node /usr/local/bin/
COPY --from=web /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/npm
RUN ln -sf /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm && \
    ln -sf /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx

WORKDIR /app

# .venv + source tree (editable install points at /app).
COPY --from=builder /app /app
# Compiled frontends at the locations _find_bundled_tui / HERMES_WEB_DIST read.
COPY --from=web /build/hermes_cli/web_dist /app/hermes_cli/web_dist
COPY --from=web /build/ui-tui/dist/entry.js /app/hermes_cli/tui_dist/entry.js
RUN mkdir -p /data && node --version && hermes --version

# Render injects $PORT at runtime (10000 by default); render/start.sh maps it.
EXPOSE 10000

# Works for both modes: dashboard -> /api/health (public, pre-login),
# api -> /health.
HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=3 \
  CMD ["python", "render/healthcheck.py"]

CMD ["bash", "render/start.sh"]
