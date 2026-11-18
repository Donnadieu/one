#!/bin/bash
# RED PROOF ONLY (throwaway branch red-proof-main-chat, never merged): One 0.9.125 + the Nov 17 corrections scenario.
set -u
cd "$(dirname "$0")/.."
./build.sh > /tmp/build.txt 2>&1 || { tail -30 /tmp/build.txt; echo "FAIL build"; exit 1; }
tools/corrections-check.sh --no-build
