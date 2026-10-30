import AppKit
import ApplicationServices
import SwiftUI

// MARK: - Real click test: `One --test-message-click` (not a unit test — an actual on-screen window,
// a real mouse-down/mouse-up NSEvent routed through NSApplication's own event dispatch, same path a
// real click takes). Finds the Copy and "Ask again" buttons by their real screen position (via the
// Accessibility API, which performs the same hit-testing geometry AppKit uses), clicks each one for
// real, and checks the real pasteboard / real `m.draftSeed` changed. Proves (or disproves) that clicks
// land, not just that the view compiles.

@MainActor
enum MessageHistoryClickCheck {
    static func launch() -> Bool {
        guard CommandLine.arguments.contains("--test-message-click") else { return false }
        TestWorld.enter()
        guard ProcessInfo.processInfo.environment["ONE_SUPPORT_DIR"] != nil else {
            print("refusing: set ONE_SUPPORT_DIR to an empty folder first")
            exit(2)
        }
        run()
        return true
    }

    /// Finds every AXButton under `window`'s AX element, recursively.
    static func buttons(in el: AXUIElement) -> [AXUIElement] {
        var out: [AXUIElement] = []
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
        if (role as? String) == kAXButtonRole { out.append(el) }
        var kids: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids)
        for c in (kids as? [AXUIElement]) ?? [] { out.append(contentsOf: buttons(in: c)) }
        return out
    }

    static func help(_ el: AXUIElement) -> String {
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXHelpAttribute as CFString, &v)
        return (v as? String) ?? ""
    }

    /// Screen point (top-left-origin, as AX reports) at the centre of `el`'s frame.
    static func screenCenter(_ el: AXUIElement) -> CGPoint? {
        var posV: CFTypeRef?
        var sizeV: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posV)
        AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeV)
        guard let posV, let sizeV else { return nil }
        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posV as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeV as! AXValue, .cgSize, &size)
        return CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)
    }

    /// A real left click: two real NSEvents (down, up) sent through NSApplication.sendEvent, the same
    /// dispatch path a genuine mouse click takes (not a direct call into the button's action).
    static func click(window: NSWindow, screenPointTopLeft p: CGPoint) {
        // The CG/AX global coordinate origin (0,0) is the top-left of the screen that holds the menu bar
        // (NSScreen.screens[0] in multi-display or headless setups), NOT necessarily `NSScreen.main`
        // (which tracks the key window's screen). Using the wrong screen's height here put clicks off
        // the bottom of the window entirely (silently missed) — found by printing winLocal.y < 0.
        let screenH = (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first)?.frame.height ?? 0
        let cocoaScreen = CGPoint(x: p.x, y: screenH - p.y)  // AX is top-left origin; AppKit screen coords are bottom-left.
        let winLocal = CGPoint(x: cocoaScreen.x - window.frame.origin.x, y: cocoaScreen.y - window.frame.origin.y)
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            if let e = NSEvent.mouseEvent(
                with: type, location: winLocal, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            {
                NSApp.sendEvent(e)
            }
        }
    }

    static func pump(_ seconds: Double) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    static func run() {
        var fails = 0
        func check(_ name: String, _ ok: Bool) {
            print("  \(ok ? "✓" : "✗") \(name)")
            if !ok { fails += 1 }
        }

        let m = Model.shared
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        let sample: [Bubble] = [
            Bubble(fromMe: true, text: "What's my flight time on the 20th?", date: yesterday),
            Bubble(fromMe: false, text: "7:40 AM out of EWR, lands in Quebec City at 10:05.", date: yesterday),
            Bubble(fromMe: true, text: "And the hotel address?"),
            Bubble(fromMe: false, text: "Auberge Saint-Antoine, 8 Rue Saint-Antoine, old town, 2 nights."),
        ]
        m.draftSeed = nil

        // Mirrors production: HistoryStrip inside an outer vertical page ScrollView — the same shape as
        // HomeView's own page ScrollView around HistoryStrip (a little real content above it, like the
        // greeting row, kept short here so the target row stays inside the window's starting viewport —
        // scrolling itself isn't what's under test, clickability once visible is).
        // `HistoryStrip.still = true` forces the icons to full opacity (bypassing the separate, working
        // hover-to-reveal mechanism) so this test isolates the actual question: once an icon is visible,
        // does a real click on it land? (Hover-to-reveal itself is unchanged by this fix and is a SwiftUI
        // onHover + opacity mechanism, not a hit-testing one.)
        HistoryStrip.still = true
        let strip = HistoryStrip(m: m, turns: sample, open: .constant(true))
        let host = ScrollView {
            VStack(spacing: 12) {
                Color.clear.frame(height: 40)  // a little real content above, like the greeting row.
                strip
            }
            .padding(.horizontal, 28)
        }
        .frame(width: 760, height: 620)
        .background(Color.black)
        .environment(\.colorScheme, .dark)

        let window = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 760, height: 620), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: host)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        pump(1.5)  // let SwiftUI lay out and the AX tree populate.

        let axApp = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        var axWindows: [AXUIElement] = []
        var allButtons: [AXUIElement] = []
        // The AX bridge populates asynchronously; retry a few times rather than trusting one snapshot.
        for _ in 0..<10 {
            var winsV: CFTypeRef?
            AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winsV)
            axWindows = (winsV as? [AXUIElement]) ?? []
            allButtons = axWindows.flatMap { buttons(in: $0) }
            if allButtons.contains(where: { help($0) == "Copy" }) { break }
            pump(0.3)
        }
        check("found the test window in the Accessibility tree", !axWindows.isEmpty)
        let copyBtn = allButtons.first { help($0) == "Copy" }
        let resendBtn = allButtons.first { help($0) == "Ask again" }
        check("Copy button exists and is reachable by real hit-test geometry", copyBtn != nil)
        check("Ask again button exists and is reachable by real hit-test geometry", resendBtn != nil)

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("unrelated — must be replaced by a real click", forType: .string)
        // `.first` in AX document order is the first row rendered (oldest turn, sample[0]); click that one.
        if let copyBtn, let p = screenCenter(copyBtn) {
            click(window: window, screenPointTopLeft: p)
            pump(0.2)
        }
        check(
            "a REAL click on Copy set the real pasteboard to the message text",
            NSPasteboard.general.string(forType: .string) == sample[0].text)

        m.draftSeed = nil
        if let resendBtn, let p = screenCenter(resendBtn) {
            click(window: window, screenPointTopLeft: p)
            pump(0.2)
        }
        check("a REAL click on Ask again set draftSeed to the exact earlier message", m.draftSeed == sample[0].text)

        window.close()
        HistoryStrip.still = false
        print(fails == 0 ? "message history click test: all checks passed" : "message history click test: \(fails) check(s) failed")
        exit(fails == 0 ? 0 : 1)
    }
}
