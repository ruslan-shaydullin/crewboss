.PHONY: help setup check check-syntax check-links test-offline test-ui build-ui demo release

help:
	@printf '%s\n' \
	  'make setup         Install locked UI development dependencies' \
	  'make check         Run the contributor checks used in CI' \
	  'make check-syntax  Parse maintained shell and Python source files' \
	  'make check-links   Check local Markdown links in supported guides' \
	  'make test-offline  Run selected offline CLI, API, and runtime contracts' \
	  'make test-ui       Run the UI unit tests once' \
	  'make build-ui      Type-check and build the UI' \
	  'make demo          Start the local credential-free dashboard demo' \
	  'make release       Build a versioned archive and checksums in dist/releases'

setup:
	npm ci --prefix ui/app --no-audit --no-fund

check: check-syntax check-links test-offline test-ui build-ui

check-syntax:
	python3 scripts/check.py syntax

check-links:
	python3 scripts/check.py links

test-offline:
	python3 scripts/check.py offline

test-ui:
	node scripts/test-ui.mjs

build-ui:
	npm run build --prefix ui/app

demo:
	VITE_CREWBOSS_DEMO=1 npm run dev --prefix ui/app -- --host 127.0.0.1

release: build-ui
	python3 scripts/package-release.py --output dist/releases
