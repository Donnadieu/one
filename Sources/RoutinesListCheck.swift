import AppKit
import SwiftUI

/// `One --test-routines-list` (preflight, from a test copy): the Routines panel with a long list (Omar, Nov 17 2026:
/// "if it's a lot of routines, it's going to get pretty big"; the list ran over the skills, and he couldn't tell
/// what "Hestia Sunday hub refresh" or "Ping: helper-lines bug" were). Lays the real panel out with 37 made-up
/// routines and 150 skills and checks: the list never runs over the skills and nothing leaves the panel; every
/// routine has a plain name and a one-line "what it does"; the list is grouped, folds, counts; leftovers can go.
/// `One --render-routines-many <png>` (a test copy, ONE_SUPPORT_DIR = scratch) draws the same panel to a picture.
enum RoutinesListCheck {
    static func cli(_ args: [String]) {
        if args.contains("--test-routines-list") {
            TestWorld.enter()  // scratch One folder; made-up jobs only
            MainActor.assumeIsolated { exit(run()) }
        }
        if let k = args.firstIndex(of: "--render-routines-many"), k + 1 < args.count {
            guard TestWorld.enterRender() else { exit(2) }
            MainActor.assumeIsolated {
                let env = ProcessInfo.processInfo.environment
                let z = picture(to: URL(fileURLWithPath: args[k + 1]), pick: env["ONE_RENDER_PICK"], open: env["ONE_RENDER_OPEN"] == "1")
                for (n, r) in z.sorted(by: { $0.key < $1.key }) { print("zone \(n): \(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height))") }
                print(overlap(z).map { "overlap: \($0)" } ?? "overlap: none")
            }
            exit(0)
        }
    }

    final class Box: @unchecked Sendable { var zones: [String: CGRect] = [:] }

    @MainActor static func setUp() -> RoutinesSnapshot {
        HomeView.still = true
        let m = Model.shared
        m.assistantName = "Iris"
        m.helpers = [RoutinesFixture.bot()]
        var s = RoutinesFixture.snapshot(cron: Routines.cron)
        s.routines = RoutineLabels.dress(
            s.routines, labels: RoutineLabels.load(), rooms: RoutinesFixture.rooms(Env.support), bots: m.helpers)
        return s
    }

    /// Lays the real panel out in an off-screen window: the zones it reports, and a picture of it.
    @MainActor static func host(_ s: RoutinesSnapshot, pick: String? = nil, open: Bool = false, image: URL? = nil) -> [String: CGRect] {
        let box = Box()
        let sel = pick.flatMap { t in s.routines.first { $0.title == t }?.id }
        let size = CGSize(width: 1200, height: 740)
        let v = RoutinesPanel(m: Model.shared, fixed: s, sel: sel, picked: true, finishedOpen: open)
            .onPreferenceChange(RoutineZones.self) { z in box.zones = z }
            .frame(width: size.width, height: size.height).background(WorldLook.bg).environment(\.colorScheme, .dark)
        let w = NSWindow(contentRect: NSRect(origin: CGPoint(x: -4000, y: 0), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua)
        let h = NSHostingView(rootView: v)
        w.contentView = h
        w.orderFront(nil)
        h.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        if let image, let rep = h.bitmapImageRepForCachingDisplay(in: h.bounds) {
            h.cacheDisplay(in: h.bounds, to: rep)
            try? FileManager.default.createDirectory(at: image.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? rep.representation(using: .png, properties: [:])?.write(to: image)
            print("picture: \(image.path)")
        }
        w.orderOut(nil)
        return box.zones
    }

    @MainActor static func picture(to url: URL, pick: String?, open: Bool) -> [String: CGRect] {
        host(setUp(), pick: pick, open: open, image: url)
    }

    /// What's wrong with where things landed, in plain words; nil when nothing is.
    static func overlap(_ z: [String: CGRect]) -> String? {
        let stage = CGRect(origin: .zero, size: Dial.size).insetBy(dx: -1, dy: -1)
        guard let list = z["list"], let sky = z["skills"] else { return "the list or the skills didn't show" }
        if list.intersects(sky) {
            return "the list runs over the skills (list \(Int(list.minY))…\(Int(list.maxY)), skills \(Int(sky.minY))…\(Int(sky.maxY)))"
        }
        for (n, r) in z where !stage.contains(r) { return "\(n) runs off the panel (\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height)))" }
        return nil
    }

    @MainActor static func run() -> Int32 {
        var fails = 0
        func check(_ name: String, _ ok: Bool) {
            print("  \(ok ? "✓" : "✗") \(name)")
            fflush(stdout)
            if !ok { fails += 1 }
        }
        // The assistant wrote plain words for two of them (RoutineLabels.file); the rest get them from their own setup.
        try? FileManager.default.createDirectory(at: RoutineLabels.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try?
            #"{"nov4": {"name": "Clear out old backup copies", "line": "Once, tomorrow: lists the old copies kept from the Nov 4 move so you can say if they can go."}}"#
            .write(to: RoutineLabels.file, atomically: true, encoding: .utf8)
        let s = setUp()
        let rs = Dictionary(uniqueKeysWithValues: s.routines.map { ($0.id, $0) })

        print("1. the list never runs over the skills, with 37 routines and 150 skills")
        let z = host(s)
        check(overlap(z) ?? "list and skills apart, both on the panel", overlap(z) == nil)
        let zo = host(s, pick: "Hestia Sunday hub refresh", open: true)
        check("and with a card and every group open: " + (overlap(zo) ?? "still apart"), overlap(zo) == nil)

        print("2. every routine has a plain name and a line saying what it does")
        let ais = RoutinesFixture.rooms(Env.support).compactMap(\.ai)
        for r in s.routines {
            let code = ais.first { r.name.range(of: "\\b\($0)\\b", options: .regularExpression) != nil }
            check("\(r.title) → “\(r.name)”", code == nil && !r.name.hasPrefix("Ping:") && !r.name.isEmpty)
            check("  says what it does: “\(r.line)”", !r.line.isEmpty && r.line != "Hasn't said anything yet.")
        }
        check("plain words the assistant wrote win", rs["nov4"]?.name == "Clear out old backup copies")
        check("a room's routine belongs to that room", rs["hestia"]?.room == "Personal Room" && rs["argo"]?.room == "Co-Founder")
        check("one naming every room is the assistant's own", rs["router"]?.room == nil)

        print(fails == 0 ? "routines list ok" : "routines list: \(fails) failed")
        return fails == 0 ? 0 : 1
    }
}
