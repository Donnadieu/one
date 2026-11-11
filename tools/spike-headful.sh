#!/bin/bash
# Throwaway spike (CI only). Questions:
# 1. A normal Chrome started by the Mac's launcher, hidden (-j) or in the background (-g), with its window off screen:
#    does any window show on screen? Is it in the Dock (ApplicationType Foreground)?
# 2. Can another process turn it into a UI element (no Dock, no Cmd-Tab) with lsappinfo / LaunchServices?
# 3. Can its SAME tab be brought on screen (CDP Browser.setWindowBounds + activate) and sent back, page state kept?
set -u
P=/tmp/spike-prof; rm -rf $P; mkdir -p $P
cat > /tmp/win.swift <<'EOF'
import AppKit
import CoreGraphics
let pid = Int32(CommandLine.arguments[1])!
let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]
let on = Set(((CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []).compactMap { $0[kCGWindowNumber as String] as? Int })
for w in all where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
  let n = w[kCGWindowNumber as String] as? Int ?? 0
  let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
  let layer = w[kCGWindowLayer as String] as? Int ?? -1
  if layer != 0 { continue }
  print("  window \(n) layer \(layer) onscreen=\(on.contains(n)) bounds=\(b["X"] ?? "?"),\(b["Y"] ?? "?") \(b["Width"] ?? "?")x\(b["Height"] ?? "?")")
}
if let a = NSRunningApplication(processIdentifier: pid) { print("  policy=\(a.activationPolicy.rawValue) (0 regular,1 accessory,2 prohibited) hidden=\(a.isHidden) active=\(a.isActive)") }
for s in NSScreen.screens { print("  screen \(s.frame)") }
EOF
cat > /tmp/front.swift <<'EOF'
import AppKit
let pid = Int32(CommandLine.arguments[1])!
let a = NSRunningApplication(processIdentifier: pid)!
if CommandLine.arguments[2] == "show" { a.unhide(); print("activate:", a.activate(options: [.activateAllWindows])) } else { print("hide:", a.hide()) }
EOF
swiftc -O /tmp/win.swift -o /tmp/win 2>&1 | tail -3; swiftc -O /tmp/front.swift -o /tmp/front 2>&1 | tail -3
cat > /tmp/cdp.py <<'EOF'
import json, sys, urllib.request, asyncio
port = int(sys.argv[1]); method = sys.argv[2]; params = json.loads(sys.argv[3]) if len(sys.argv) > 3 else {}
ver = json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/json/version"))
import websocket  # pip websocket-client
ws = websocket.create_connection(ver["webSocketDebuggerUrl"], suppress_origin=True)
ws.send(json.dumps({"id": 1, "method": method, "params": params}))
while True:
    m = json.loads(ws.recv())
    if m.get("id") == 1:
        print(json.dumps(m.get("result") or m.get("error"))[:400]); break
EOF
pip3 install --quiet --break-system-packages websocket-client 2>/dev/null || pip3 install --quiet websocket-client
pid_of() { pgrep -f -- "--user-data-dir=$P" | while read p; do ps -o args= -p $p | grep -q -- '--type=' || echo $p; done | head -1; }
report() { local pid=$(pid_of); echo "== $1 (pid $pid)"; lsappinfo info -only ApplicationType "#$pid" 2>/dev/null | sed 's/^/  /'; lsappinfo visibleProcessList 2>/dev/null | tr ':' '\n' | grep -c Chrome | sed 's/^/  chrome in visibleProcessList: /'; /tmp/win $pid; }

echo "### A: open -g -n (background), window far off screen"
open -g -n -a "Google Chrome" --args --user-data-dir=$P --remote-debugging-port=9400 --no-first-run --no-default-browser-check \
  --window-position=-30000,-30000 --window-size=1000,700 --disable-background-timer-throttling --disable-renderer-backgrounding \
  --disable-backgrounding-occluded-windows "data:text/html,<input id=x value=start><script>window.mark=1</script>"
for i in $(seq 30); do curl -s -m1 127.0.0.1:9400/json/version >/dev/null && break; sleep 0.5; done
sleep 2; report "after start"
PID=$(pid_of)
echo "### hide it"; /tmp/front $PID hide; sleep 1; report "after hide"
echo "### B: try to make it a UI element (no Dock, no Cmd-Tab)"
ASN=$(lsappinfo find pid=$PID 2>/dev/null); echo "  asn=$ASN"
lsappinfo setinfo "$ASN" ApplicationType=UIElement 2>&1 | sed 's/^/  setinfo: /'
lsappinfo setinfo "$ASN" --setinfo ApplicationType=UIElement 2>&1 | head -2 | sed 's/^/  setinfo2: /'
sleep 1; report "after setinfo"
echo "### C: the same tab: type into it while hidden"
T=$(curl -s 127.0.0.1:9400/json/list | python3 -c 'import json,sys; print([t["id"] for t in json.load(sys.stdin) if t["type"]=="page"][0])')
echo "  target $T"
python3 - <<EOF
import json, websocket
ws = websocket.create_connection("ws://127.0.0.1:9400/devtools/page/$T", suppress_origin=True)
ws.send(json.dumps({"id":1,"method":"Runtime.evaluate","params":{"expression":"document.getElementById('x').value='typed while hidden'; [document.visibilityState, window.mark]","returnByValue":True}}))
print("  ", ws.recv()[:200])
EOF
W=$(python3 /tmp/cdp.py 9400 Browser.getWindowForTarget "{\"targetId\":\"$T\"}"); echo "  window: $W"
WID=$(echo "$W" | python3 -c 'import json,sys; print(json.load(sys.stdin)["windowId"])')
echo "### D: bring that same window on screen"
python3 /tmp/cdp.py 9400 Browser.setWindowBounds "{\"windowId\":$WID,\"bounds\":{\"left\":120,\"top\":80,\"width\":1000,\"height\":700,\"windowState\":\"normal\"}}"
/tmp/front $PID show; sleep 1.5; report "after show"
python3 /tmp/cdp.py 9400 Browser.getWindowBounds "{\"windowId\":$WID}"
screencapture -x /tmp/shown.png 2>&1 | head -1; ls -la /tmp/shown.png 2>&1
python3 - <<EOF
import json, websocket
ws = websocket.create_connection("ws://127.0.0.1:9400/devtools/page/$T", suppress_origin=True)
ws.send(json.dumps({"id":1,"method":"Runtime.evaluate","params":{"expression":"[document.getElementById('x').value, window.mark, document.visibilityState]","returnByValue":True}}))
print("  same page after show:", ws.recv()[:200])
EOF
echo "### E: send it back off screen and hide"
python3 /tmp/cdp.py 9400 Browser.setWindowBounds "{\"windowId\":$WID,\"bounds\":{\"left\":-30000,\"top\":-30000}}"
/tmp/front $PID hide; sleep 1; report "after send back"
echo "### F: minimized instead of off screen"
python3 /tmp/cdp.py 9400 Browser.setWindowBounds "{\"windowId\":$WID,\"bounds\":{\"windowState\":\"minimized\"}}"; sleep 1; report "after minimize"
echo "### G: headless + new window? (Target.createTarget newWindow on headless)"
kill $PID; sleep 2
echo done
