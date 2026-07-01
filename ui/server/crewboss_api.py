"""crewboss_api.py -- importable alias for crewboss-api.py.

Python cannot import a module whose filename contains a hyphen using a normal
`import` statement.  This shim loads crewboss-api.py via importlib and
re-exports all public symbols so that tests (and the acceptance check) can do:

    from crewboss_api import _compute_stuck
"""
import importlib.util
import os
import sys

_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "crewboss-api.py")
_spec = importlib.util.spec_from_file_location("crewboss_api", _path)
_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_mod)

# Re-export all public names into this module's namespace
globals().update({k: v for k, v in vars(_mod).items() if not k.startswith("__")})
