# ─────────────────────────────────────────────────────────────────────────────
# Lightweight image for the Hermes Agent HTTP API on Render (free tier).
#
# This is NOT the repo's full-fat Dockerfile (that one bundles Node, the web
# dashboard, Playwright browsers and s6 supervision). It runs just the
# gateway's OpenAI-compatible api_server — Python 3.11 + core deps + aiohttp.
#
# Render (bluepinint): render.yaml points dockerfilePath at this file.
# Render (manual):    New Web Service -> Docker -> Dockerfile Path:
#                     render/Dockerfile
# ─────────────────────────────────────────────────────────────────────────────

# ---- builder: compile/install deps (build-essential as a safety net) --------
FROM python:3.11-slim-bookworm AS builder

COPY --from=ghcr.io/astral-sh/uv:0.11.6 /uv /usr/local/bin/uv

ENV UV_LINK_MODE=copy \
    UV_COMPILE_BYTECODE=1 \
    UV_PROJECT_ENVIRONMENT=/app/.venv \
    UV_PYTHON_DOWNLOADS=never

WORKDIR /app

# Dependency layer, cached unless pyproject.toml / uv.lock change.
# Same trick as the main Dockerfile: pyproject references README.md, which
# .dockerignore excludes, so `touch` an empty placeholder for resolution.
COPY pyproject.toml uv.lock setup.py ./
RUN touch ./README.md \
 && uv sync --frozen --no-dev --no-install-project --extra sms

# Project source, then the fast editable egg-link (deps are already present).
COPY . .
RUN uv pip install --python /app/.venv/bin/python --no-cache-dir --no-deps -e "."

# ---- runtime ----------------------------------------------------------------
FROM python:3.11-slim-bookworm AS runtime

# Render passes the deployed commit SHA as an automatic build arg.
ARG SOURCE_COMMIT=unknown
ENV SOURCE_COMMIT=${SOURCE_COMMIT} \
    PYTHONUNBUFFERED=1 \
    PATH=/app/.venv/bin:$PATH \
    HERMES_HOME=/data

WORKDIR /app

# .venv (builder) + source tree (editable install points here).
COPY --from=builder /app /app
RUN mkdir -p /data

# Render injects $PORT at runtime (10000 by default); render/start.sh maps it
# to API_SERVER_PORT. EXPOSE is documentation; Render detects the real bind.
EXPOSE 10000

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD python -c "import os,urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:%s/health' % os.environ.get('PORT','10000'), timeout=4).status == 200 else 1)" || exit 1

CMD ["bash", "render/start.sh"]
