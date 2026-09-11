#!/usr/bin/env bash
# Render free-tier startup for the Hermes Agent gateway in HTTP "api_server"
# mode (OpenAI-compatible API). See docs/RENDER_DEPLOYMENT.md.
set -euo pipefail

# All Hermes state (config.yaml, session SQLite DB, skills, logs) lives under
# HERMES_HOME. On Render free this is EPHEMERAL — it is reset on every deploy
# and every cold start. Set HERMES_HOME explicitly so it is the same path the
# app and this script agree on.
export HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
mkdir -p "$HERMES_HOME"

# Seed a minimal headless config (model/provider) on first boot.
# Render discarts the disk on deploy, so this re-seeds automatically.
# Secrets are NEVER put in this file — they come from Render environment vars.
if [ ! -f "$HERMES_HOME/config.yaml" ]; then
  cp "$(dirname "$0")/config.yaml" "$HERMES_HOME/config.yaml"
fi

# Render routes traffic to the port it assigns via $PORT and expects the app
# to bind 0.0.0.0. Setting API_SERVER_KEY also auto-enables the api_server
# platform (gateway/config_env.py) — no platforms block needed in config.yaml.
export API_SERVER_HOST="0.0.0.0"
export API_SERVER_PORT="${PORT:-8642}"
export PYTHONUNBUFFERED="1"

# uv created .venv at build time. --no-supervise = run in the foreground
# (Render manages the process; s6/systemd supervision does not exist here).
exec .venv/bin/hermes gateway run --no-supervise
