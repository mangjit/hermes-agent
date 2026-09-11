#!/usr/bin/env bash
# Render startup for Hermes Agent.
#
# HERMES_RENDER_MODE selects what runs on Render's $PORT:
#   dashboard (default)  web UI + in-browser chat (`hermes dashboard`),
#                        login = HERMES_DASHBOARD_BASIC_AUTH_USERNAME/PASSWORD
#   api                  OpenAI-compatible gateway api_server (`hermes gateway`)
#
# See docs/RENDER_DEPLOYMENT.md.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

# Render passes SOURCE_COMMIT as a Docker build arg/ENV; native checkouts fall
# back to git.
COMMIT="${SOURCE_COMMIT:-$(git rev-parse --short HEAD 2>/dev/null || echo unknown)}"
MODE="${HERMES_RENDER_MODE:-dashboard}"
echo "== render/start.sh (commit ${COMMIT:0:9}, mode ${MODE}) =="
echo "   PORT=${PORT:-<unset>}  HERMES_HOME=${HERMES_HOME:-<unset>}"

# All Hermes state (config.yaml, session SQLite DB, skills, logs) lives under
# HERMES_HOME. On Render free this is EPHEMERAL — reset on every deploy and
# cold start.
export HERMES_HOME="${HERMES_HOME:-/data}"
mkdir -p "$HERMES_HOME"

# Seed a minimal headless config (model/provider) on first boot.
# Secrets are NEVER put in this file — they come from Render environment vars.
if [ ! -f "$HERMES_HOME/config.yaml" ]; then
  cp "$REPO_ROOT/render/config.yaml" "$HERMES_HOME/config.yaml"
fi

# Restore catalogs baked at image build (models.dev api.json, curated manifests,
# OpenRouter reasoning caps) so the model picker never synchronously downloads
# multi-MB JSON on a cold 0.1-CPU instance (endless "loading models" spinner).
if [ -d "$REPO_ROOT/render/home-seed" ]; then
  cp -rn "$REPO_ROOT/render/home-seed/." "$HERMES_HOME/" 2>/dev/null || true
fi

# Render routes traffic to the port it assigns via $PORT and expects the app
# to bind 0.0.0.0.
export PYTHONUNBUFFERED="1"

# Locate the hermes entrypoint + interpreter: PATH on the Docker image,
# .venv on native runtimes, finally the system python.
if command -v hermes >/dev/null 2>&1; then
  HERMES_BIN=(hermes)
  PYTHON_BIN="$(command -v python)"
elif [ -x "$REPO_ROOT/.venv/bin/hermes" ]; then
  HERMES_BIN=("$REPO_ROOT/.venv/bin/hermes")
  PYTHON_BIN="$REPO_ROOT/.venv/bin/python"
else
  HERMES_BIN=(python -m hermes_cli.main)
  PYTHON_BIN="python"
fi

# Background-warm key-gated catalog caches (provider model lists/pricing) with
# the runtime provider key. Public catalogs are already baked via home-seed.
# Best effort — must never block the port bind. Logs: $HERMES_HOME/warm-caches.log
if [ "${HERMES_SKIP_WARM:-0}" != "1" ] && [ -f "$REPO_ROOT/render/warm_caches.py" ]; then
  setsid "$PYTHON_BIN" "$REPO_ROOT/render/warm_caches.py" \
    >>"$HERMES_HOME/warm-caches.log" 2>&1 < /dev/null &
  echo "   catalog warm-up running in background (warm-caches.log)"
fi

case "$MODE" in
  dashboard)
    # The web UI is prebuilt into /app/hermes_cli/web_dist at image build time
    # (or locally in hermes_cli/web_dist for native runtimes).
    if [ -z "${HERMES_WEB_DIST:-}" ] && [ -d "$REPO_ROOT/hermes_cli/web_dist" ]; then
      export HERMES_WEB_DIST="$REPO_ROOT/hermes_cli/web_dist"
    fi
    if [ ! -f "${HERMES_WEB_DIST:-/nonexistent}/index.html" ]; then
      echo "!! Web UI dist missing (HERMES_WEB_DIST=${HERMES_WEB_DIST:-unset})." >&2
      echo "   Use the Docker image (render/Dockerfile builds it), or run"   >&2
      echo "   'npm run build --workspace web' on the host."                 >&2
      exit 1
    fi

    # A non-loopback bind ALWAYS requires an auth provider (June-2026
    # hardening — unauthenticated public dashboards were exploited). Use the
    # bundled username/password plugin; fail early with an actionable message
    # instead of letting the server SystemExit.
    : "${HERMES_DASHBOARD_BASIC_AUTH_USERNAME:?set HERMES_DASHBOARD_BASIC_AUTH_USERNAME (e.g. admin)}"
    : "${HERMES_DASHBOARD_BASIC_AUTH_PASSWORD:?set HERMES_DASHBOARD_BASIC_AUTH_PASSWORD (generateValue in render.yaml)}"
    export HERMES_DASHBOARD_BASIC_AUTH_USERNAME HERMES_DASHBOARD_BASIC_AUTH_PASSWORD
    export HERMES_DASHBOARD_BASIC_AUTH_SECRET="${HERMES_DASHBOARD_BASIC_AUTH_SECRET:-$API_SERVER_KEY}"

    # Only the bundled auth plugin should be discovered (trimmed tree baked in
    # render/Dockerfile). Native runtimes fall back to the full plugins/ tree.
    if [ -d "$REPO_ROOT/render/trimmed-plugins" ]; then
      export HERMES_BUNDLED_PLUGINS="$REPO_ROOT/render/trimmed-plugins"
    fi

    # Trust the public Render hostname (used for Host/Origin validation,
    # secure cookies and OAuth redirects). Render sets RENDER_EXTERNAL_HOSTNAME.
    if [ -z "${HERMES_DASHBOARD_PUBLIC_URL:-}" ] && [ -n "${RENDER_EXTERNAL_HOSTNAME:-}" ]; then
      export HERMES_DASHBOARD_PUBLIC_URL="https://$RENDER_EXTERNAL_HOSTNAME"
    fi
    echo "   public URL: ${HERMES_DASHBOARD_PUBLIC_URL:-<unset; set HERMES_DASHBOARD_PUBLIC_URL>}"

    # Success markers: "HERMES_DASHBOARD_READY port=$PORT", then browse to /
    exec "${HERMES_BIN[@]}" dashboard --host 0.0.0.0 --port "${PORT:-9119}" --no-open --skip-build
    ;;

  api)
    # ── Dependency self-heal (native runtime only; Docker has it baked in) ──
    if ! "$PYTHON_BIN" -c "import aiohttp" 2>/dev/null; then
      echo "!! aiohttp missing — installing at runtime (fix Build Command to"
      echo "   'uv sync --frozen --no-dev --extra sms' to skip this step)."
      if command -v uv >/dev/null 2>&1; then
        UV_PROJECT_ENVIRONMENT="$(dirname "$(dirname "$PYTHON_BIN")")" \
          uv sync --frozen --no-dev --extra sms
      else
        "$PYTHON_BIN" -m pip install 'aiohttp==3.14.3' \
          || { "$PYTHON_BIN" -m ensurepip && "$PYTHON_BIN" -m pip install 'aiohttp==3.14.3'; }
      fi
    fi
    "$PYTHON_BIN" -c "import aiohttp,sys; print(f'   aiohttp {aiohttp.__version__} OK on {sys.version.split()[0]}')"

    # Setting API_SERVER_KEY also auto-enables the api_server platform
    # (gateway/config_env.py).
    export API_SERVER_HOST="0.0.0.0"
    export API_SERVER_PORT="${PORT:-8642}"

    # ── Fast boot on the free tier (512 MB / shared 0.1 CPU) ────────────────
    export HERMES_SAFE_MODE="${HERMES_SAFE_MODE:-1}"
    export HERMES_STARTUP_WARMUP_TIMEOUT="${HERMES_STARTUP_WARMUP_TIMEOUT:-0}"
    export HERMES_STARTUP_RESTORE_DRAIN_TIMEOUT="${HERMES_STARTUP_RESTORE_DRAIN_TIMEOUT:-1}"
    echo "   SAFE_MODE=$HERMES_SAFE_MODE WARMUP_TIMEOUT=$HERMES_STARTUP_WARMUP_TIMEOUT"

    # Success marker: "API server listening on http://0.0.0.0:$PORT (model: …)"
    exec "${HERMES_BIN[@]}" gateway run --no-supervise
    ;;

  *)
    echo "Unknown HERMES_RENDER_MODE='$MODE' (use 'dashboard' or 'api')." >&2
    exit 1
    ;;
esac
