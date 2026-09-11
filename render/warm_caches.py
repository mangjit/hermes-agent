#!/usr/bin/env python3
"""Pre-warm model catalog caches for the Render deployment.

The dashboard model picker (web UI and the Chat tab's ``model.options`` RPC)
synchronously fetches multi-MB model catalogs on a COLD cache:

  * models.dev ``api.json`` (capability/pricing metadata),
  * the curated provider manifest (Nous/OpenRouter),
  * OpenRouter ``/v1/models`` (live reasoning capabilities),
  * per-provider model lists / pricing (key-gated).

On the free tier's shared 0.1 CPU this can take minutes, and the picker just
shows an endless spinner ("models are not loading"). ``/data`` is also wiped
on every cold start, so the pain repeats daily.

Runs in two places, always best-effort (never blocks a deploy/boot):

  * IMAGE BUILD  — ``HERMES_HOME=/app/render/home-seed``; public catalogs are
    fetched on fast build network and baked into the image.
  * CONTAINER START (backgrounded by render/start.sh) — fills the key-gated
    caches using the runtime provider key(s) in the environment.
"""
import os
import sys
import time

HOME = os.environ.setdefault("HERMES_HOME", "/data")
os.makedirs(HOME, exist_ok=True)


def _step(name, fn) -> bool:
    t = time.time()
    try:
        fn()
        print(f"[warm-caches] {name}: ok ({time.time() - t:.1f}s)", flush=True)
        return True
    except Exception as exc:  # never fatal
        print(f"[warm-caches] {name}: skipped ({type(exc).__name__}: {exc})", flush=True)
        return False


def warm_models_dev() -> None:
    from agent.models_dev import fetch_models_dev
    data = fetch_models_dev(force_refresh=True)
    if not data:
        raise RuntimeError("empty models.dev registry")


def warm_curated() -> None:
    from hermes_cli.model_catalog import refresh_catalogs
    if not refresh_catalogs():
        raise RuntimeError("curated manifest refresh returned False")


def warm_reasoning() -> None:
    from hermes_cli.models_reasoning_caps import _fetch_reasoning_caps_catalog
    caps = _fetch_reasoning_caps_catalog("https://openrouter.ai/api/v1/models", 30)
    if not caps:
        raise RuntimeError("openrouter reasoning catalog empty")


def warm_picker() -> None:
    """Populate provider_models_cache / pricing for whatever keys exist in env."""
    from hermes_cli.inventory import build_model_options_payload, load_picker_context
    payload = build_model_options_payload(load_picker_context())
    providers = payload.get("providers", [])
    n_models = sum(len(r.get("models") or []) for r in providers)
    print(f"[warm-caches] picker payload: {len(providers)} providers / {n_models} models", flush=True)


def main() -> int:
    # --public-only: image-build mode. Fetch only the keyless public catalogs;
    # skip the picker payload (which reads provider keys from the environment
    # and writes auth/session state — that belongs to the runtime home).
    public_only = "--public-only" in sys.argv[1:]
    print(f"[warm-caches] HERMES_HOME={HOME} public_only={public_only}", flush=True)
    _step("models.dev", warm_models_dev)
    _step("curated manifests", warm_curated)
    _step("openrouter reasoning caps", warm_reasoning)
    if not public_only:
        _step("picker payload", warm_picker)
    return 0  # best effort


if __name__ == "__main__":
    sys.exit(main())
