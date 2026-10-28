import AppKit

// MARK: - Check: home's glass (`One --test-glass`). The design (Claude Design "Home Transparency", smoked glass) is
// blur(40px) saturate(1.4) under a 70% #1C1C20 tint. AppKit's material adds its own grey on top of the blur, which
// made the desktop nearly vanish; this opens a real window with the glass and checks only the blur is left, also
// after the window gains and loses focus and changes size.

@MainActor enum GlassCheck {
    nonisolated static func main(_ args: [String]) {
        guard args.contains("--test-glass") else { return }
        TestWorld.enter()  // a test copy only: one small window, nothing saved
        let ok = MainActor.assumeIsolated { run() }
        print(ok ? "glass ok" : "glass FAILED")
        exit(ok ? 0 : 1)
    }

    /// What the material's layers say: only the blur visible, blur 40, saturation 1.4.
    static func state(_ v: NSView) -> (shown: [String], blur: Double?, sat: Double?) {
        let variant = v.layer?.sublayers?.first { ($0.sublayers ?? []).contains { $0.name == "backdrop" } }
        let shown = (variant?.sublayers ?? []).filter { !$0.isHidden }.map { $0.name ?? "?" }
        var blur: Double?
        var sat: Double?
        for case let f as NSObject in variant?.sublayers?.first(where: { $0.name == "backdrop" })?.filters ?? [] {
            switch f.value(forKey: "name") as? String {
            case "gaussianBlur": blur = (f.value(forKey: "inputRadius") as? NSNumber)?.doubleValue
            case "colorSaturate": sat = (f.value(forKey: "inputAmount") as? NSNumber)?.doubleValue
            default: break
            }
        }
        return (shown, blur, sat)
    }

    static func run() -> Bool {
        NSApplication.shared.setActivationPolicy(.accessory)
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 300), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let host = WindowGlass.host()
        host.frame = w.contentView?.bounds ?? .zero
        host.autoresizingMask = [.width, .height]
        w.contentView?.addSubview(host)
        w.orderFront(nil)
        var ok = true
        func look(_ step: String) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            let s = state(host)
            let good = s.shown == ["backdrop"] && s.blur == Glass.blur && s.sat == Glass.saturation && !w.isOpaque
            print(
                "\(good ? "ok  " : "FAIL") \(step): visible \(s.shown), blur \(s.blur ?? -1), saturation \(s.sat ?? -1), window clear \(!w.isOpaque)")
            ok = ok && good
        }
        look("opened")
        w.makeKeyAndOrderFront(nil)
        look("focused")
        w.resignKey()
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: w)
        look("lost focus")
        w.setContentSize(NSSize(width: 700, height: 500))
        look("resized")
        host.appearance = NSAppearance(named: .aqua)
        host.appearance = NSAppearance(named: .darkAqua)
        look("appearance changed")
        w.orderOut(nil)
        return ok
    }
}
