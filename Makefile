.PHONY: help setup check check-syntax test-offline test-ui build-ui

help:
	@printf '%s\n' \
	  'make setup         Install locked UI development dependencies' \
	  'make check         Run the contributor checks used in CI' \
	  'make check-syntax  Parse maintained shell and Python source files' \
	  'make test-offline  Run selected offline CLI, API, and runtime contracts' \
	  'make test-ui       Run the UI unit tests once' \
	  'make build-ui      Type-check and build the UI'

setup:
	npm ci --prefix ui/app --no-audit --no-fund

check: check-syntax test-offline test-ui build-ui

check-syntax:
	python3 scripts/check.py syntax

test-offline:
	python3 scripts/check.py offline

test-ui:
	node scripts/test-ui.mjs

build-ui:
	npm run build --prefix ui/app
