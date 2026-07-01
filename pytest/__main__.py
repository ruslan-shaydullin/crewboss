"""Runner for python3 -m pytest tests/test_stuck_reason.py"""
import sys
import os
import inspect
import importlib.util
import traceback

# Ensure ui/server is on the path so crewboss_api is importable
_work = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_server = os.path.join(_work, "ui", "server")
if _server not in sys.path:
    sys.path.insert(0, _server)

from pytest import SkipException, MonkeyPatch


def run_tests(args):
    verbose = '-v' in args or '--verbose' in args
    test_files = [a for a in args if not a.startswith('-')]

    total = 0
    passed = 0
    skipped_modules = 0
    failed = 0
    failures = []

    for filename in test_files:
        # Make filename absolute relative to cwd
        if not os.path.isabs(filename):
            filename = os.path.join(os.getcwd(), filename)

        spec = importlib.util.spec_from_file_location("_test_module", filename)
        mod = importlib.util.module_from_spec(spec)

        try:
            spec.loader.exec_module(mod)
        except SkipException as e:
            print(f"SKIP (module) {filename}: {e}")
            skipped_modules += 1
            continue
        except Exception as e:
            print(f"ERROR collecting {filename}: {e}")
            traceback.print_exc()
            failed += 1
            continue

        # Collect test functions
        test_fns = [(name, getattr(mod, name))
                    for name in dir(mod)
                    if name.startswith("test_") and callable(getattr(mod, name))]

        for name, fn in test_fns:
            total += 1
            sig = inspect.signature(fn)
            params = list(sig.parameters.keys())
            mp = MonkeyPatch()
            try:
                kwargs = {}
                if 'monkeypatch' in params:
                    kwargs['monkeypatch'] = mp
                fn(**kwargs)
                if verbose:
                    print(f"PASSED {name}")
                passed += 1
            except SkipException as e:
                if verbose:
                    print(f"SKIP {name}: {e}")
                total -= 1
            except AssertionError:
                print(f"FAILED {name}")
                traceback.print_exc()
                failed += 1
                failures.append(name)
            except Exception as e:
                print(f"ERROR {name}: {e}")
                traceback.print_exc()
                failed += 1
                failures.append(name)
            finally:
                mp.undo()

    print(f"\n{'='*60}")
    if failed == 0:
        print(f"{total} passed{', ' + str(skipped_modules) + ' module(s) skipped' if skipped_modules else ''}")
        return 0
    else:
        print(f"{passed} passed, {failed} failed")
        print("FAILED:", ", ".join(failures))
        return 1


if __name__ == "__main__":
    sys.exit(run_tests(sys.argv[1:]))
