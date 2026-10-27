# One: everything an agent or a person runs. `make check` must pass before every commit and release.
.PHONY: build format format-check lint check preflight full release-check hooks jobs followups handoff

build:            ## build build/app.noindex/One.app
	./build.sh
format:           ## rewrite Sources/ with the repo's swift-format rules
	xcrun swift-format format -i -r -p Sources
format-check:     ## fail if anything isn't formatted
	xcrun swift-format lint -r -s -p Sources
lint:             ## One's own rules (tools/lint/one-lint.py) + the baseline may only shrink
	python3 tools/lint/one-lint.py
	tools/lint/check-baseline.sh
check: format-check lint preflight   ## the whole gate
preflight:        ## build + bundle + KeePass + folder lock + updater + renders (~1 min)
	tools/preflight.sh
full:             ## preflight plus a fresh install into an empty folder (~3 min)
	tools/preflight.sh --full
release-check: format-check lint full
jobs:             ## three core jobs end to end with the real engine (OpenRouter, ~10 min, costs a little)
	tools/jobs-check.sh
followups:        ## sending while busy, end to end with the real engine (one or two short Claude turns)
	tools/followups-check.sh
handoff:          ## a code step handed to the person, end to end on a local test page (no real account, no cost)
	tools/handoff-check.sh
hooks:            ## install the git pre-commit hook (fast checks only)
	git config core.hooksPath .githooks
