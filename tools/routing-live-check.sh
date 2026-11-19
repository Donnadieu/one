#!/bin/bash
# runs: owner-only (make routinglive) — One's real engine on the owner's own Claude subscription; no CI runner has it
# Smart routing with One's real engine in a throwaway home (two short helper turns on the Claude subscription One
# already uses): a helper starts with the fitting recipe in hand, a lookup steps down to the balanced brain, and
# with routing off nothing is added. A copy of the app with its own bundle id runs it, so the person's chat,
# settings and running One are never touched. See Sources/RoutingLiveCheck.swift.
exec env ONE_CALLER="$(basename "$0")" "$(dirname "$0")/engine-check.sh" --mode --test-routing-live --timeout 420 \
  --name routing-test --test-engine "$@"
