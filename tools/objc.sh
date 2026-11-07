#!/bin/bash
# Compiles One's only Objective-C (Sources/ObjC: catching Apple's audio exceptions, see OneCatch.h) into <dir> and
# prints the extra swiftc arguments, one per line. Every script that compiles One reads them:
#   OBJC=(); while IFS= read -r l; do OBJC+=("$l"); done < <(tools/objc.sh "$DIR" [extra clang flags…])
set -euo pipefail
cd "$(dirname "$0")/.."
DIR="$1"; shift
mkdir -p "$DIR"
clang -c -fobjc-arc -O2 -target arm64-apple-macosx14.0 "$@" Sources/ObjC/OneCatch.m -o "$DIR/OneCatch.o"
printf '%s\n' -import-objc-header "$PWD/Sources/ObjC/OneCatch.h" "$DIR/OneCatch.o"
