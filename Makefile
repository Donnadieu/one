# One: everything an agent or a person runs. `make check` must pass before every commit and release.
# Hard rule: a test never runs on this Mac by accident. Preflight and every *-check run in CI; the
# exception is a live check that needs One's installed engine and the owner's own subscription, which
# its target asks for by name with ONE_LIVE_CHECK=<that check> (tools/ci-only.sh). `make check` runs no test.
# Every target, from the recipes themselves: this was a hand-typed list of 30 names, which is the
# kind of list that goes stale the first time somebody adds a target in a hurry.
.PHONY: $(shell grep -oE '^[a-z][a-z-]*:' $(firstword $(MAKEFILE_LIST)) | tr -d :)
# A live check (jobs, learning, the helper ones, routinglive, humanwindow) needs One's installed engine
# and the owner's own subscription, so no runner can have it: its target asks for it by name and sets
# ONE_LIVE_CHECK to that check's own file name (tools/ci-only.sh). The NAME is the point — the old
# ONE_LIVE_CHECK=1 unlocked all twenty scripts that source ci-only.sh, tools/preflight.sh among them,
# so one stale export turned the hard rule off. Every other check runs in CI, and `make check` runs none.
# The script is named once and the variable is derived from it, so the two can't drift:
#   $(call live,jobs-check.sh)  ->  ONE_LIVE_CHECK=jobs-check.sh tools/jobs-check.sh
live = ONE_LIVE_CHECK=$(1) tools/$(1)

help:             ## every target and what it costs
	@grep -hE '^[a-z][a-z-]*:.*##' $(firstword $(MAKEFILE_LIST)) | sed 's/:.*##/ /' | expand -t18
build:            ## build build/app.noindex/One.app
	./build.sh
format:           ## rewrite Sources/ with the repo's swift-format rules
	xcrun swift-format format -i -r -p Sources
format-check:     ## fail if anything isn't formatted
	xcrun swift-format lint -r -s -p Sources
lint:             ## One's own rules + their canaries + ruff/shellcheck; every baseline may only shrink
	git fetch -q origin main 2>/dev/null || true
	python3 tools/lint/one-lint.py
	python3 tools/lint/one-lint.py --prove
	python3 tools/lint/ext-lint.py
	tools/lint/check-baseline.sh --all
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
preflight:        ## every end-to-end check; runs in CI on every pull request, refuses here
	tools/preflight.sh
full: check       ## the release gate: `make check`, then the CI checks that need what this Mac isn't
	@echo
	@echo "check: clean. The rest of the release gate runs in CI, because it needs a machine without One:"
	@echo "  - a fresh install into an empty folder   .github/workflows/fresh-install.yml (push a v* tag)"
	@echo "  - every end-to-end check, 4 parts        .github/workflows/preflight.yml (every pull request)"
	@echo "  - the sanitizer and soak builds          .github/workflows/deep-checks.yml (nightly)"
	@echo "Push the branch and read the checks on the pull request."
release-check: check   ## the release gate, by the name the release notes use
jobs:             ## three core jobs end to end with the real engine (OpenRouter, ~10 min, costs a little)
	$(call live,jobs-check.sh)
followups:        ## sending while busy, end to end with the real engine (one or two short Claude turns)
	$(call live,followups-check.sh)
helperdone:       ## finished helpers: orange until opened, one "by the way" line, routines report together (real engine)
	$(call live,helper-done-check.sh)
helperself:       ## a helper you talk to does the work itself, never a [helper: …] line (real engine)
	$(call live,helper-self-check.sh)
helpernotes:      ## a helper from an older One still names Connections › Browser / Passwords after an update (real engine, a fork)
	$(call live,helper-notes-check.sh)
helperstop:       ## stop a helper (button, by asking), it stays stopped; an update with a helper at work resumes it (real engine)
	$(call live,helper-stop-check.sh)
helpercut:        ## helpers cut off by an engine restart show stopped, pick back up, are done only with their answer (real engine)
	$(call live,helper-cut-check.sh)
routinglive:      ## smart routing with the real engine: the fitting recipe in hand, a lookup steps down, off adds nothing (real engine, a throwaway home)
	$(call live,routing-live-check.sh)
humanwindow:      ## the human-check window on a real robot-check page (opens a real Chrome window; a copy of your own browser profile)
	$(call live,human-window-check.sh)
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
	$(call live,learning-check.sh)
handoffqa:        ## hand a code step to yourself in a real browser window, by hand (QA=<dir> for the scratch)
	QA="$${QA:-$${TMPDIR:-/tmp}/one-handoff-qa}" $(call live,handoff-qa.sh)
hooks:            ## install the git hooks (pre-commit fast checks, pre-push identity) and pin this clone to Donnadieu
	git config core.hooksPath .githooks
	git config --local user.name Donnadieu
	git config --local user.email donnadieu.86@gmail.com
	git config --local user.signingkey ABAFD67086BDA7E0
	git config --local gpg.format openpgp
	git config --local commit.gpgsign true
	git config --local tag.gpgsign true
