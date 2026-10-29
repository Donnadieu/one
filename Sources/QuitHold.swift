import AppKit
import Foundation

// MARK: - Quitting never cuts a routine off. Quitting One stops its engine, and with it any scheduled job mid-run
// (Oct 28: a 7:15 PM run lost its last rounds when One quit at 8:19 PM and opened again). So a quit (⌘Q, Dock › Quit)
// while a routine is at work waits for it: the window tucks into the orb, a line says so, and One quits by itself the
// moment the routine finishes (at most `limit`). Quitting again while it waits quits right away. Logging out,
// restarting or shutting down the Mac never waits, and an update's own quit (it already waited) goes straight through.

@MainActor
enum QuitHold {
    static var waiting = false
    /// Set just before a quit that has already waited (an update), so it isn't held a second time.
    static var bypass = false
    static var limit: TimeInterval = 2 * 3600

    /// The quit reasons macOS sends when the Mac logs out, restarts or shuts down ('why?' = kAEQuitReason).
    static let systemReasons: Set<OSType> = ["logo", "rlgo", "rrst", "rest", "rsdn", "shut"].map(fourCC).reduce(into: []) { $0.insert($1) }
    static func fourCC(_ s: String) -> OSType { s.utf8.reduce(0) { ($0 << 8) | OSType($1) } }

    static var systemQuit: Bool {
        guard let ev = NSAppleEventManager.shared().currentAppleEvent,
            let why = ev.attributeDescriptor(forKeyword: fourCC("why?"))
        else { return false }
        return systemReasons.contains(why.typeCodeValue)
    }

    /// The line shown while One waits to quit.
    static func line(_ busy: [String]) -> String {
        let who = busy.count == 1 ? "\(busy[0]) is" : Routines.list(busy) + " are"
        return "\(who) still working. I'll quit as soon as it's done. Quit again to stop it now."
    }

    /// Hold the quit? Pure, so the check can prove every case.
    static func shouldHold(busy: [String], waiting: Bool, bypass: Bool, system: Bool, testCopy: Bool) -> Bool {
        !(busy.isEmpty || waiting || bypass || system || testCopy)
    }

    /// `applicationShouldTerminate`: quit now, or tuck away and quit once the routines at work are done.
    static func reply() -> NSApplication.TerminateReply {
        let testCopy = Env.commandLine || Env.selfTest || Bundle.main.bundleIdentifier != TestWorld.productionID
        let busy = testCopy || bypass || waiting ? [] : Routines.inFlight()
        guard shouldHold(busy: busy, waiting: waiting, bypass: bypass, system: systemQuit, testCopy: testCopy) else { return .terminateNow }
        waiting = true
        let text = line(busy)
        GatewayGuard.log("quit waits for routines at work: \(busy.joined(separator: ", "))")
        Floater.shared.tuckAway(nil)
        Floater.shared.note(text)
        Task {
            _ = await Speaker.shared.sayNow(text)
            let until = Date().addingTimeInterval(limit)
            var left = busy
            while !left.isEmpty && Date() < until && waiting {
                try? await Task.sleep(for: .seconds(15))
                left = await Task.detached { Routines.inFlight() }.value
            }
            guard waiting else { return }
            GatewayGuard.log(left.isEmpty ? "routines done: quitting now" : "quit waited \(Int(limit / 60)) min: quitting now")
            bypass = true
            NSApp.terminate(nil)
        }
        return .terminateCancel
    }
}
