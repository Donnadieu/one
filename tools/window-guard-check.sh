#!/bin/bash
# Proves the top row (name pill, Voice, Rooms, Connections, Routines, Push to talk, Folders, Switch AI, Stop —
# all living in the window's titlebar/toolbar, Sources/HomeChrome.swift HomeTitleRow) stays reachable after a
# bad restored window frame (Sources/WindowGuard.swift, Sources/WindowGuardCheck.swift). Real NSWindows only;
# touches no settings, brain or engine.
#   tools/window-guard-check.sh <built One binary>
set -u
BIN="${1:-build/app.noindex/One.app/Contents/MacOS/One}"
[ -x "$BIN" ] || { echo "refusing: build One first (./build.sh), then pass its binary path"; exit 2; }
"$BIN" --test-window-guard
exit $?
