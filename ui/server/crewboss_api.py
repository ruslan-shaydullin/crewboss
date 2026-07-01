#!/usr/bin/env python3
"""crewboss_api.py — import shim for test discovery (charter #485 / issue #1212).

Python's normal import system cannot load 'crewboss-api.py' (hyphens are not
valid in module identifiers).  This shim bridges the gap:

  • When imported as a module  → loads crewboss-api.py via importlib and
                                  re-exports the public symbols tests need.
  • When run as __main__       → delegates to crewboss-api.py's real server
                                  (smoke-runner.sh starts it via 'python3 crewboss_api.py <port>').

Smoke-runner note: this file matches the '*api.py' detector pattern.  When
smoke-runner.sh starts it, the __main__ block below delegates to the real
server, so health + state assertions pass identically to crewboss-api.py.
"""
import importlib.util
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_IMPL = os.path.join(_HERE, "crewboss-api.py")

_spec = importlib.util.spec_from_file_location("_crewboss_api_impl", _IMPL)
_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_mod)

# ── Public re-exports (add here as needed by tests) ──────────────────────────
_compute_stuck = _mod._compute_stuck
build_state    = _mod.build_state

if __name__ == "__main__":
    # Run the real API server so smoke-runner.sh's detect_api() passes.
    # runpy re-executes the file as __main__, which hits the
    #   if __name__ == "__main__": ... ThreadingHTTPServer(...).serve_forever()
    # block in crewboss-api.py.  CB_API_PORT / CB_API_TOKEN / CB_REPO are
    # already set by the smoke runner before exec.
    import runpy
    runpy.run_path(_IMPL, run_name="__main__")
