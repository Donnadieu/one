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
            s.routines, labels: RoutineLabels.load(), rooms: RoutinesFixture.rooms(Env.support), bots: m.helpers, owner: "Sam")
        return s
    }

    /// Lays the real panel out in an off-screen window: the zones it reports, and a picture of it.
    @MainActor static func host(_ s: RoutinesSnapshot, pick: String? = nil, open: Bool = false, remove: Bool = false, image: URL? = nil) -> [String:
        CGRect]
    {
        let box = Box()
        let sel = pick.flatMap { t in s.routines.first { $0.title == t }?.id }
        let size = CGSize(width: 1200, height: 740)
        let v = RoutinesPanel(m: Model.shared, fixed: s, sel: sel, picked: true, finishedOpen: open, removeAsk: remove ? sel : nil)
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
        let env = ProcessInfo.processInfo.environment
        let s = setUp()
        let n = env["ONE_RENDER_MANY"].flatMap(Int.init) ?? 0
        return host(n > s.routines.count ? many(s, to: n) : s, pick: pick, open: open, remove: env["ONE_RENDER_REMOVE"] == "1", image: url)
    }

    /// The fixture filled up to `n` routines: copies of the working ones under new ids and names.
    static func many(_ s: RoutinesSnapshot, to n: Int) -> RoutinesSnapshot {
        var t = s
        let base = s.routines.filter { !$0.outside && $0.state != .finished && $0.leftover == nil }
        var k = 0
        while t.routines.count < n, !base.isEmpty {
            let o = base[k % base.count]
            var r = Routine(
                id: o.id + "-\(k)", title: o.title + " \(k + 2)", what: o.what, often: o.often, today: o.today, every: o.every, lastRun: o.lastRun,
                next: o.next, state: o.state, reason: o.reason)
            (r.owner, r.miss, r.notes, r.runs, r.once, r.prompt, r.times) = (o.owner, o.miss, o.notes, o.runs, o.once, o.prompt, o.times)
            (r.shownName, r.shownLine, r.room) = (o.name + " \(k + 2)", o.line, o.room)
            t.routines.append(r)
            k += 1
        }
        return t
    }

    /// What's wrong with where things landed, in plain words; nil when nothing is.
    static func overlap(_ z: [String: CGRect]) -> String? {
        let stage = CGRect(origin: .zero, size: Dial.size).insetBy(dx: -1, dy: -1)
        guard let groups = z["sky-groups"], let open = z["sky-open"], let sky = z["skills"] else {
            return "the routines' constellations or the skills didn't show"
        }
        let list = groups.union(open)
        if let d = z["dial"], d.intersects(list) {
            return "a dial label runs into the list (labels end at \(Int(d.maxX)), list starts at \(Int(list.minX)))"
        }
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
        check("so is one listing \"personal, work, nyx rooms\" (an AI named like its room)", rs["rsync"]?.room == nil)

        print("3. grouped by who it's for, or how often; groups fold and count")
        let me = Model.shared.name
        let bot = Model.shared.helpers[0]
        let who = RoutineList.groups(s.routines, by: .who, me: me) { r in
            BotStore.owns(bot, r) ? (bot.id.uuidString, "Ads bot", 0xE9B26B) : nil
        }
        func g(_ gs: [RoutineList.Group], _ id: String) -> Set<String> { Set(gs.first { $0.id == id }?.rows.map(\.id) ?? []) }
        check(
            "every routine shows once", who.flatMap(\.rows).count == s.routines.count && Set(who.flatMap(\.rows).map(\.id)).count == s.routines.count)
        check("the assistant's own first, under its name", who.first?.id == "me" && who.first?.title == me)
        check("each room's own under the room", g(who, "room:Personal Room") == ["hestia"] && g(who, "room:Work Room") == ["work", "ajax"])
        check("a bot's under the bot", g(who, "bot:" + bot.id.uuidString) == ["ads"])
        check("jobs run outside One apart", g(who, "outside") == ["out1", "out2"])
        check("the ones that look done together at the end", g(who, RoutineList.leftoverID) == ["ping3", "ping4", "ping5"])
        check(
            "then the finished ones",
            who.last?.id == RoutineList.finishedID && g(who, RoutineList.finishedID) == ["p009", "chk", "safe", "ping1", "ping2"])
        let often = RoutineList.groups(s.routines, by: .often, me: me) { _ in nil }
        check(
            "or by how often, most often first",
            often.prefix(5).map(\.title) == ["Every hour or more", "Every day", "Some days of the week", "Once", "Paused"])
        check("weekly ones together", g(often, "often:weekly").isSuperset(of: ["hestia", "ajax", "argo", "week", "tic1"]))
        check("paused ones together", g(often, "often:paused") == ["bets"])
        let shut = RoutineList.folded(who)
        check("a long list starts folded, but for a group with something that needs a look", Set(who.map(\.id)).subtracting(shut) == ["me"])
        let few = RoutineList.groups(Array(s.routines.prefix(6)), by: .who, me: me) { _ in nil }
        check("a short list starts open, but for the quiet groups", RoutineList.folded(few) == Set(few.filter(\.clearable).map(\.id)))
        check("needs a look comes first in its group", who.first?.rows.first?.needsLook == true)

        print("4. each row says its next run, its last result, or that it's paused")
        func st(_ id: String) -> String { rs[id].map { RoutineList.status($0, now: s.now) } ?? "" }
        check("paused: \(st("bets"))", st("bets").hasPrefix("Paused"))
        check("next and last: \(st("x2"))", st("x2").hasPrefix("Next ") && st("x2").hasSuffix("last done"))
        check("didn't work: \(st("x1"))", st("x1").hasSuffix("last didn't work"))
        check("never ran: \(st("tic3"))", st("tic3").hasSuffix("never ran yet"))
        check("every few minutes: \(st("cosync"))", st("cosync") == "Every 5 minutes · last done")
        check("finished: \(st("p009"))", st("p009").hasPrefix("Finished"))

        print("5. clean-up: leftovers can go, after a yes")
        check("a check-until-done job that already said its thing looks done", ["ping3", "ping4", "ping5"].allSatisfy { rs[$0]?.leftover != nil })
        check("a sync that runs for good never does", rs["cosync"]?.leftover == nil && rs["token"]?.leftover == nil)
        check(
            "leftovers, paused and finished ones can be removed; working ones and outside ones can't from here",
            ["ping3", "bets", "p009"].allSatisfy { rs[$0].map(RoutinesPanel.canRemove) == true }
                && ["x2", "brief", "out1"].allSatisfy { rs[$0].map(RoutinesPanel.canRemove) == false })
        check("Remove is the engine's own remove", rs["ping3"].map(RoutineList.removeSteps) == ["cron", "remove", "ping3"])

        print("6. the list is part of the sky: constellations, no box, no pop-up card (Claude Design, Omar Nov 18 2026)")
        // Omar: "It feels like it's just popping out at me … square, rectangle, rectangle." Each group is a small star
        // figure with a count; one opens at a time, its routines in one column on a thread; a picked one opens in place.
        check("no list box any more", z["list"] == nil)
        check("each group is a star figure, the open one's routines below them", z["sky-groups"] != nil && z["sky-open"] != nil)
        if let g = z["sky-groups"], let o = z["sky-open"] { check("figures above the open group, apart", g.maxY <= o.minY + 1) }
        let zp = host(s, pick: "Forge X replies (morning)")
        check("a picked routine shows no pop-up card", zp["card"] == nil)
        if let row = zp["picked"], let det = zp["details"], let open = zp["sky-open"] {
            check("its details open in place, right under its own row", det.minY >= row.maxY - 2 && det.minY - row.maxY < 14)
            check("inside the open group's own place", open.insetBy(dx: -2, dy: -2).contains(CGPoint(x: det.minX, y: det.minY)))
        } else {
            check("a picked routine has its row and its details in the open group", false)
        }
        check("a thread joins its mark on the dial to its star in the list", zp["thread"] != nil)
        check("and still nothing overlaps: " + (overlap(zp) ?? "apart"), overlap(zp) == nil)
        let zr = host(s, pick: "Friday bets scorecard", remove: true)
        if let ask = zr["remove-ask"], let det = zr["details"] {
            check("Remove asks first, in place, no card", det.insetBy(dx: -2, dy: -2).contains(ask) && zr["card"] == nil)
        } else {
            check("Remove asks first, in place", false)
        }
        let big = many(s, to: 55)
        let zb = host(big)
        check("55 routines: \(overlap(zb) ?? "constellations and skills apart, all on the panel")", overlap(zb) == nil)
        check("55 routines: still one open group, the rest are figures", zb["sky-groups"] != nil && zb["sky-open"] != nil)
        let pts = (0..<6).map { CGPoint(x: Sky.starX($0, "r\($0)"), y: Sky.rowTops(6, picked: 2, details: 90)[$0] + Sky.starY) }
        let l0 = Sky.light(pts, t: 0)
        let l1 = Sky.light(pts, t: 1.5)
        check("it flows: a light travels down the open group's thread", l0 != nil && l1 != nil && l0 != l1 && (l1?.y ?? 0) > (l0?.y ?? 0))
        check("one column: every star sits on the thread (within 8 pt)", (pts.map(\.x).max() ?? 0) - (pts.map(\.x).min() ?? 0) <= 8)
        check("the picked one's details push the stars under it down", pts[3].y - pts[2].y >= Sky.rowH + 90 - 0.5)
        check("one group open at a time: the picked routine's own", Sky.open(who, sel: "ads", chosen: "me") == "bot:" + bot.id.uuidString)

        print(fails == 0 ? "routines list ok" : "routines list: \(fails) failed")
        return fails == 0 ? 0 : 1
    }
}
