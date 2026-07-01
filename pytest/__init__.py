"""Minimal pytest shim for test_stuck_reason.py compatibility.
Placed in /work/pytest/ so python3 -m pytest finds it from the working directory.
"""
import sys


class SkipException(Exception):
    pass


def skip(reason="", allow_module_level=False):
    raise SkipException(reason)


class MonkeyPatch:
    def __init__(self):
        self._patches = []

    def setattr(self, obj, name, value, raising=True):
        old = getattr(obj, name, None)
        setattr(obj, name, value)
        self._patches.append((obj, name, old))

    def undo(self):
        for obj, name, old in reversed(self._patches):
            setattr(obj, name, old)
        self._patches.clear()


__all__ = ["skip", "MonkeyPatch", "SkipException"]
