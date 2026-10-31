# One: everything an agent or a person runs. `make check` must pass before every commit and release.
.PHONY: identity build format format-check lint docdrift check preflight full release-check hooks jobs followups handoff helperdone helperself helpernotes helperstop helpercut helpers-check learning

build:            ## build build/app.noindex/One.app
	./build.sh
format:           ## rewrite Sources/ with the repo's swift-format rules
	xcrun swift-format format -i -r -p Sources
format-check:     ## fail if anything isn't formatted
	xcrun swift-format lint -r -s -p Sources
lint:             ## One's own rules (tools/lint/one-lint.py) + the baseline may only shrink
	python3 tools/lint/one-lint.py
	tools/lint/check-baseline.sh
docdrift:         ## sensitive code changed without its matching doc (docs/SECURITY.md etc) touched
	git fetch -q origin main 2>/dev/null || true
	python3 tools/doc-drift-check.py origin/main
identity:         ## commits here are only Donnadieu <donnadieu.86@gmail.com>, signed ABAFD67086BDA7E0 (never donnadieu-andela)
	tools/check-identity.sh
	git fetch -q origin main 2>/dev/null || true
	tools/check-identity.sh --range origin/main..HEAD
check: identity format-check lint docdrift preflight   ## the whole gate
preflight:        ## build + bundle + KeePass + folder lock + updater + renders (~1 min)
	tools/preflight.sh
full:             ## preflight plus a fresh install into an empty folder (~3 min)
	tools/preflight.sh --full
release-check: format-check lint full
jobs:             ## three core jobs end to end with the real engine (OpenRouter, ~10 min, costs a little)
	tools/jobs-check.sh
followups:        ## sending while busy, end to end with the real engine (one or two short Claude turns)
	tools/followups-check.sh
helperdone:       ## finished helpers: orange until opened, one "by the way" line, routines report together (real engine)
	tools/helper-done-check.sh
helperself:       ## a helper you talk to does the work itself, never a [helper: …] line (real engine)
	tools/helper-self-check.sh
helpernotes:      ## a helper from an older One still names Connections › Browser / Passwords after an update (real engine, a fork)
	tools/helper-notes-check.sh
helperstop:       ## stop a helper (button, by asking), it stays stopped; an update with a helper at work resumes it (real engine)
	tools/helper-stop-check.sh
helpercut:        ## helpers cut off by an engine restart show stopped, pick back up, are done only with their answer (real engine)
	tools/helper-cut-check.sh
helpers-check:    ## 100 helpers at once, engine killed, One killed, an update, all mid-run: none lost, doubled or falsely done (stand-in engine, free, ~1 min; in preflight)
	tools/helpers-check.sh
handoff:          ## a code step handed to the person, end to end on a local test page (no real account, no cost)
	tools/handoff-check.sh
learning:         ## tell me when I learn: new skill line + Undo, fixes silent, the remember question (real engine, ~10 min)
	tools/learning-check.sh
hooks:            ## install the git hooks (pre-commit fast checks, pre-push identity) and pin this clone to Donnadieu
	git config core.hooksPath .githooks
	git config --local user.name Donnadieu
	git config --local user.email donnadieu.86@gmail.com
	git config --local user.signingkey ABAFD67086BDA7E0
	git config --local gpg.format openpgp
	git config --local commit.gpgsign true
	git config --local tag.gpgsign true
