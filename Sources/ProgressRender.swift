import AppKit
import SwiftUI

// MARK: - Render-only (`--render-world <prefix>` → progress-busy, progress-long, progress-stuck): the home screen with
// helpers showing their real steps, a long step with its time, and one gone quiet (amber, Nudge in its thread).
// Never run on the real One: it fills Model.shared with made-up helpers (tools/test-copy.sh gives the copy its own settings).

enum ProgressRender {
    static let names = ["progress-busy", "progress-long", "progress-stuck"]
    static let at = Date(timeIntervalSince1970: 1_793_000_000)

    static func helper(_ title: String, _ state: String = "working", seen: Bool? = true) -> Helper {
        var h = Helper(title: title, task: "", sid: nil, state: state, line: "Working on it…")
        h.seen = seen
        if state == "done" { h.reply = "Shipped. The orbs have no X now." }
        return h
    }
    static func pulse(_ step: String, ran: TimeInterval, quiet: TimeInterval, open: Bool = true, plan: String? = nil) -> HelperPulse {
        HelperPulse(
            step: step, stepAt: at.addingTimeInterval(-ran), open: open ? ["t"] : [], lastAt: at.addingTimeInterval(-quiet), plan: plan)
    }

    @MainActor static func draw(_ name: String, _ out: String) -> Bool {
        guard names.contains(name) else { return false }
        let m = Model.shared
        HelperProgress.stillNow = at
        defer { HelperProgress.stillNow = nil }
        var a = helper("Helper progress")
        var b = helper("Helper line bug")
        var c = helper("Ledger runs check")
        let d = helper("No X on orbs", "done", seen: false)
        switch name {
        case "progress-busy":
            m.pulses = [
                a.id: pulse("Reading Helpers.swift…", ran: 6, quiet: 2, plan: "I'll add the step timer next, then build and run the tests."),
                b.id: pulse("Building One…", ran: 18, quiet: 18),
                c.id: pulse("Pushing to GitHub…", ran: 4, quiet: 4),
            ]
        case "progress-long":
            a.title = "Helper progress"
            m.pulses = [
                a.id: pulse("Running tests…", ran: 130, quiet: 40, plan: "The build passed, so now the whole test run."),
                b.id: pulse("Working on your Mac…", ran: 300, quiet: 300),
                c.id: pulse("Reading Model.swift…", ran: 50, quiet: 45, open: false),
            ]
        default:
            b.title = "Fix human check window"
            m.pulses = [
                b.id: pulse("Working on your Mac…", ran: 430, quiet: 430, plan: "Now I'll run the human check test against the local page."),
                a.id: pulse("Building One…", ran: 40, quiet: 40),
                c.id: pulse("Checking a website…", ran: 3, quiet: 3),
            ]
        }
        m.helpers = [a, b, c, d]
        m.openHelper = name == "progress-stuck" ? b.id : a.id
        HomeRender.closeFirst = false
        HomeRender.png(HomeRender.scene(16, keep: true), "\(out)-\(name).png", height: 1000)  // tall: the opened thread shows whole
        m.openHelper = nil
        m.pulses = [:]
        print("wrote \(out)-\(name).png")
        return true
    }
}
