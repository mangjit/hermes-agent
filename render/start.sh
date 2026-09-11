#!/usr/bin/env bash
# Render free-tier startup for the Hermes Agent gateway in HTTP "api_server"
# mode (OpenAI-compatible API). See docs/RENDER_DEPLOYMENT.md.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

# ── Diagnostics: prove which commit + deps this deploy is actually running ───
# Render passes SOURCE_COMMIT as a Docker build arg/ENV; native checkouts fall
# back to git.
COMMIT="${SOURCE_COMMIT:-$(git rev-parse --short HEAD 2>/dev/null || echo unknown)}"
echo "== render/start.sh (commit ${COMMIT:0:9}) =="
echo "   PORT=${PORT:-<unset>}  HERMES_HOME=${HERMES_HOME:-<unset>}"

# ── Dependency self-heal ─────────────────────────────────────────────────────
# The api_server adapter REQUIRES aiohttp (it lives in an optional extra, so a
# plain `uv sync --no-dev` misses it). If the Render Build Command wasn't
# updated (manually-created services ignore render.yaml changes), install it
# HERE at startup so the port always binds. Pinned to the lockfile version.
if ! .venv/bin/python -c "import aiohttp" 2>/dev/null; then
  echo "!! aiohttp missing from .venv — installing at runtime (fix the Build"
  echo "   Command to 'uv sync --frozen --no-dev --extra sms' to skip this)."
  if command -v uv >/dev/null 2>&1; then
    uv sync --frozen --no-dev --extra sms
  else
    .venv/bin/python -m pip install 'aiohttp==3.14.3' 2>/dev/null \
      || { .venv/bin/python -m ensurepip && .venv/bin/python -m pip install 'aiohttp==3.14.3'; }
  fi
fi
.venv/bin/python - <<'PY'
import aiohttp, sys
print(f"   aiohttp {aiohttp.__version__} OK on {sys.version.split()[0]}")
PY

# All Hermes state (config.yaml, session SQLite DB, skills, logs) lives under
# HERMES_HOME. On Render free this is EPHEMERAL — it is reset on every deploy
# and every cold start. Set HERMES_HOME explicitly so the app and this script
# agree on the path.
export HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
mkdir -p "$HERMES_HOME"

# Seed a minimal headless config (model/provider) on first boot.
# Render discards the disk on deploy, so this re-seeds automatically.
# Secrets are NEVER put in this file — they come from Render environment vars.
if [ ! -f "$HERMES_HOME/config.yaml" ]; then
  cp "$REPO_ROOT/render/config.yaml" "$HERMES_HOME/config.yaml"
fi

# Render routes traffic to the port it assigns via $PORT and expects the app
# to bind 0.0.0.0. Setting API_SERVER_KEY also auto-enables the api_server
# platform (gateway/config_env.py) — no platforms block needed in config.yaml.
export API_SERVER_HOST="0.0.0.0"
export API_SERVER_PORT="${PORT:-8642}"
export PYTHONUNBUFFERED="1"

# ── Fast boot on the free tier (512 MB / shared 0.1 CPU) ─────────────────────
# The port must open before Render's deploy port-scan times out. These knobs
# move every non-essential boot cost AFTER the socket binds (or remove it):
#
# HERMES_SAFE_MODE=1        skip bundled-plugin discovery/import, MCP servers,
#                           shell hooks and outbound webhooks (none of which a
#                           headless API server needs; also removes the
#                           "Failed to load plugin …" warnings).
# HERMES_STARTUP_WARMUP_TIMEOUT=0
#                           don't pre-build the tool registry / system prompt
#                           during boot (the ~20-60s of "check_fn … False"
#                           scans). The first API request initializes lazily;
#                           /health is available immediately.
# HERMES_STARTUP_RESTORE_DRAIN_TIMEOUT=1
#                           ephemeral disk has no previous sessions to resume.
export HERMES_SAFE_MODE="${HERMES_SAFE_MODE:-1}"
export HERMES_STARTUP_WARMUP_TIMEOUT="${HERMES_STARTUP_WARMUP_TIMEOUT:-0}"
export HERMES_STARTUP_RESTORE_DRAIN_TIMEOUT="${HERMES_STARTUP_RESTORE_DRAIN_TIMEOUT:-1}"
echo "   SAFE_MODE=$HERMES_SAFE_MODE WARMUP_TIMEOUT=$HERMES_STARTUP_WARMUP_TIMEOUT RESTORE_DRAIN=$HERMES_STARTUP_RESTORE_DRAIN_TIMEOUT"

# uv created .venv at build time. --no-supervise = run in the foreground
# (Render manages the process; s6/systemd supervision does not exist here).
# Success marker in the logs:
#   "API server listening on http://0.0.0.0:$PORT (model: …)"
exec .venv/bin/hermes gateway run --no-supervise
