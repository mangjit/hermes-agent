#!/usr/bin/env python3
"""Container health check used by the render/Dockerfile HEALTHCHECK.

Works in both deployment modes (see render/start.sh):
  dashboard -> GET /api/health (public, pre-login)
  api       -> GET /health
"""
import os
import sys
import urllib.request

port = os.environ.get("PORT", "10000")
for path in ("/api/health", "/health"):
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=4) as resp:
            if resp.status == 200:
                sys.exit(0)
    except Exception:
        continue
sys.exit(1)
