# One: everything an agent or a person runs. `make check` must pass before every commit and release.
# Hard rule: a test never runs on this Mac by accident. Preflight and every *-check run in CI; the
# exception is a live check that needs One's installed engine and the owner's own subscription, which
# its target asks for by name with ONE_LIVE_CHECK=1 (tools/ci-only.sh). `make check` runs no test.
.PHONY: corrections identity build format format-check lint prove extlint docdrift knowledgebase hooks-installed check preflight full release-check hooks jobs followups handoff helperdone helperself helpernotes helperstop helpercut helpers-check routinglive humanwindow sanitize soak learning
# A live check (jobs, learning, the helper ones, routinglive, humanwindow) needs One's installed engine
# and the owner's own subscription, so no runner can have it: its target asks for it by name and sets
# ONE_LIVE_CHECK=1 (tools/ci-only.sh). Every other check runs in CI, and `make check` runs none of them.
LIVE = ONE_LIVE_CHECK=1

build:            ## build build/app.noindex/One.app
	./build.sh
format:           ## rewrite Sources/ with the repo's swift-format rules
	xcrun swift-format format -i -r -p Sources
format-check:     ## fail if anything isn't formatted
	xcrun swift-format lint -r -s -p Sources
lint:             ## One's own rules + their canaries + ruff/shellcheck; every baseline may only shrink
	python3 tools/lint/one-lint.py
	python3 tools/lint/one-lint.py --prove
	tools/lint/check-baseline.sh
	python3 tools/lint/ext-lint.py
	tools/lint/check-baseline.sh origin/main tools/lint/ext-baseline.json
prove:            ## just the canaries: each rule in one-lint.py still fires on a snippet that breaks it
	python3 tools/lint/one-lint.py --prove
extlint:          ## just ruff + shellcheck over One's own Python and shell (tools/lint/ext-baseline.json)
	python3 tools/lint/ext-lint.py
hooks-installed:  ## the git hooks are armed, and the hook and `make check` agree on the rules
	tools/hooks-check.sh
docdrift:         ## sensitive code changed without its matching doc (docs/SECURITY.md etc) touched
	git fetch -q origin main 2>/dev/null || true
	python3 tools/doc-drift-check.py origin/main
knowledgebase:    ## mandated docs exist, docs/INDEX.md has no broken/orphaned entries, AGENTS.md stays short
	tools/knowledge-base-check.sh
identity:         ## commits here are only Donnadieu <donnadieu.86@gmail.com>, signed ABAFD67086BDA7E0 (never donnadieu-andela)
	tools/check-identity.sh
	git fetch -q origin main 2>/dev/null || true
	tools/check-identity.sh --range origin/main..HEAD
check: identity format-check lint docdrift knowledgebase hooks-installed   ## the local gate: no tests here; preflight runs in CI on every push
preflight:        ## build + bundle + KeePass + folder lock + updater + renders (~1 min)
	tools/preflight.sh
full:             ## preflight plus a fresh install into an empty folder (~3 min)
	tools/preflight.sh --full
release-check: format-check lint   ## plus the CI check on the release commit
jobs:             ## three core jobs end to end with the real engine (OpenRouter, ~10 min, costs a little)
	$(LIVE) tools/jobs-check.sh
followups:        ## sending while busy, end to end with the real engine (one or two short Claude turns)
	$(LIVE) tools/followups-check.sh
helperdone:       ## finished helpers: orange until opened, one "by the way" line, routines report together (real engine)
	$(LIVE) tools/helper-done-check.sh
helperself:       ## a helper you talk to does the work itself, never a [helper: …] line (real engine)
	$(LIVE) tools/helper-self-check.sh
helpernotes:      ## a helper from an older One still names Connections › Browser / Passwords after an update (real engine, a fork)
	$(LIVE) tools/helper-notes-check.sh
helperstop:       ## stop a helper (button, by asking), it stays stopped; an update with a helper at work resumes it (real engine)
	$(LIVE) tools/helper-stop-check.sh
helpercut:        ## helpers cut off by an engine restart show stopped, pick back up, are done only with their answer (real engine)
	$(LIVE) tools/helper-cut-check.sh
routinglive:      ## smart routing with the real engine: the fitting recipe in hand, a lookup steps down, off adds nothing (real engine, a throwaway home)
	$(LIVE) tools/routing-live-check.sh
humanwindow:      ## the human-check window on a real robot-check page (opens a real Chrome window; a copy of your own browser profile)
	$(LIVE) tools/human-window-check.sh
corrections:      ## Omar's corrections replayed against the stand-in engine (tests/corrections/README.md; free, ~1 min; in preflight)
	tools/corrections-check.sh
helpers-check:    ## 100 helpers at once, engine killed, One killed, an update, all mid-run: none lost, doubled or falsely done (stand-in engine, free, ~1 min; in preflight)
	tools/helpers-check.sh
sanitize:         ## thread + address sanitizer builds drive the real audio line under load (`--test-voice-stress`, ~10 min; runs nightly in deep-checks.yml, refuses here)
	tools/sanitizer-check.sh
soak:             ## the whole app under load, a write to freed memory crashes AT the write (`--test-soak`; MIN=10 MODE=guard|thread|address; runs nightly in deep-checks.yml, refuses here)
	ONE_SOAK_ROUTE=$${ROUTE:-0} tools/soak-check.sh $${MIN:-10} $${MODE:-guard}
handoff:          ## a code step handed to the person, end to end on a local test page (no real account, no cost)
	tools/handoff-check.sh
learning:         ## tell me when I learn: new skill line + Undo, fixes silent, the remember question (real engine, ~10 min)
	$(LIVE) tools/learning-check.sh
hooks:            ## install the git hooks (pre-commit fast checks, pre-push identity) and pin this clone to Donnadieu
	git config core.hooksPath .githooks
	git config --local user.name Donnadieu
	git config --local user.email donnadieu.86@gmail.com
	git config --local user.signingkey ABAFD67086BDA7E0
	git config --local gpg.format openpgp
	git config --local commit.gpgsign true
	git config --local tag.gpgsign true
