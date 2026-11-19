#!/bin/bash
# The same smoothness measurement (`One --test-smooth`) on older releases, to see which version got slower.
#   tools/smooth-compare.sh v0.9.122 v0.9.123 v0.9.134     (CI only: .github/workflows/smooth.yml, by hand)
# For each tag: a worktree at that tag, this branch's Sources/SmoothCheck.swift copied in with the one line that hooks
# it up (Diagnostics.swift), the streaming entry point it calls (`helperStreamed`, the same steps the old code did
# inline), and for releases made before bots a version of the check without bots. Built optimized, measured, printed.
# Never fails the job: a tag that can't build says so and the next one is measured.
source "$(dirname "$0")/ci-only.sh"
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
OUT="${RUNNER_TEMP:-/tmp}/smooth-compare"
mkdir -p "$OUT"
for TAG in "$@"; do
  W="$OUT/$TAG"
  rm -rf "$W"
  git worktree add -f "$W" "$TAG" >/dev/null 2>&1 || { echo "$TAG: no such tag"; continue; }
  cp "$ROOT/Sources/SmoothCheck.swift" "$W/Sources/SmoothCheck.swift"
  /usr/bin/python3 - "$W" <<'PY'
import pathlib, re, sys
w = pathlib.Path(sys.argv[1]) / "Sources"
d = w / "Diagnostics.swift"
s = d.read_text()
if "SmoothCheck.main" not in s:
    s = s.replace("        SoakCheck.main(args)", "        SoakCheck.main(args)\n        SmoothCheck.main(args)", 1)
    d.write_text(s)
src = "".join(p.read_text() for p in w.glob("*.swift"))
if "func helperStreamed(" not in src:
    (w / "SmoothCompat.swift").write_text(
        "import Foundation\n@MainActor extension Model {\n    func helperStreamed(_ id: UUID, _ s: String) {\n"
        "        helperUnderway(id)\n        update(id) { $0.reply += s }\n        pulseText(id, s)\n        saveTrail(id, force: false)\n    }\n}\n")
if "enum Motion" not in src:
    with open(w / "SmoothCompat.swift", "a") as f:
        f.write("\nenum Motion {\n    nonisolated(unsafe) static var every: Double? = nil\n}\n")
if "struct BotInfo" not in src:
    c = w / "SmoothCheck.swift"
    t = c.read_text()
    t = re.sub(r"    // BOTS-START.*?// BOTS-END\n",
               "    static func isBot(_ h: Helper) -> Bool { false }\n    static func bot(_ i: Int, room: URL) -> Helper? { nil }\n", t, flags=re.S)
    c.write_text(t)
PY
  ( cd "$W" && ./build.sh > "$OUT/$TAG-build.txt" 2>&1 )
  # shellcheck disable=SC2012  # release names sorted by version are the point, and find's order is unspecified
  APP_SRC=$(ls -d "$W/build/app.noindex/One.app" "$W/build/One.app" 2>/dev/null | head -1)
  if [ -z "$APP_SRC" ] || ! [ -x "$APP_SRC/Contents/MacOS/One" ]; then
    echo "$TAG: didn't build with the check:"; grep " error:" "$OUT/$TAG-build.txt" | head -5; continue
  fi
  APP=$( cd "$W" && tools/test-copy.sh smoothold "$OUT/$TAG-app.noindex" )
  mkdir -p "$OUT/$TAG-support"
  echo "== $TAG"
  ONE_SUPPORT_DIR="$OUT/$TAG-support" perl -e 'alarm 240; exec @ARGV' "$APP/Contents/MacOS/One" --test-smooth | tee "$OUT/$TAG.txt"
done
exit 0
