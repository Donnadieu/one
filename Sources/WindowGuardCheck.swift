import AppKit

/// `One --test-window-guard` (tools/window-guard-check.sh): proves the top row (name pill plus Voice, Rooms,
/// Connections, Routines, Push to talk, Folders, Switch AI, Stop — all living in the titlebar/toolbar) stays
/// reachable after a bad restored frame, the exact shape of the 0.9.74-and-restart regression: body content
/// (orb, greeting, chat) still on screen, titlebar/toolbar pushed off it. Real `NSWindow`s, no engine, no
/// settings, no brain; nothing here touches Omar's real state.
enum WindowGuardCheck {
    @MainActor static func launch() -> Bool {
        guard CommandLine.arguments.contains("--test-window-guard") else { return false }
        exit(run())
    }

    @MainActor static func run() -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        guard let screen = NSScreen.main else {
            print("refusing: no screen available to test against")
            return 2
        }
        let visible = screen.visibleFrame
        var ok = true
        func check(_ name: String, _ cond: Bool) {
            print((cond ? "ok " : "FAIL ") + name)
            if !cond { ok = false }
        }
        func window(_ rect: NSRect) -> NSWindow {
            let w = NSWindow(contentRect: rect, styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
            w.setFrame(rect, display: false)
            return w
        }

        // Case 1: titlebar pushed above the top of the visible screen (a display change, or a restart that
        // landed the window taller than the screen can show from where it last was) — the reported symptom.
        let offTop = NSRect(x: visible.midX - 250, y: visible.maxY + 400, width: 500, height: 500)
        let w1 = window(offTop)
        check("reproduced: titlebar starts off the top of the screen", w1.frame.maxY > visible.maxY)
        WindowGuard.ensureOnScreen(w1)
        check(
            "titlebar back on screen after the guard",
            w1.frame.maxY <= visible.maxY && w1.frame.maxY >= visible.minY + WindowGuard.titlebarStrip)
        check("window kept a sane size", w1.frame.width > 1 && w1.frame.height > 1)

        // Case 2: a perfectly normal on-screen frame must be left exactly as the person put it.
        let normal = NSRect(x: visible.minX + 40, y: visible.minY + 40, width: 500, height: 500)
        let w2 = window(normal)
        WindowGuard.ensureOnScreen(w2)
        check("a normal on-screen frame is left untouched", w2.frame == normal)

        // Case 3: parked far to the side (e.g. a second monitor that's since been unplugged).
        let offSide = NSRect(x: visible.maxX + 2000, y: visible.midY - 250, width: 500, height: 500)
        let w3 = window(offSide)
        WindowGuard.ensureOnScreen(w3)
        check("off-side frame brought back on screen", w3.frame.minX < visible.maxX && w3.frame.maxX > visible.minX)

        print(ok ? "window guard ok: top row stays reachable" : "window guard FAILED")
        return ok ? 0 : 1
    }
}
