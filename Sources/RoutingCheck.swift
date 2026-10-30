import Foundation

/// `One --test-routing` (run by preflight): the router's decisions on a made-up recipe book. Pure: no engine, no Model.
/// `ONE_ROUTING_REPLAY=<items.json> ONE_ROUTING_SKILLS=<dirs> One --test-routing` also replays real past jobs against the real recipe book
/// (tools/routing-replay.py writes that file on the Mac it runs on; it never goes in the repo).
enum RoutingCheck {
    /// `--test-routing`: pure decisions on a made-up recipe book; ONE_ROUTING_REPLAY adds a replay of real past jobs.
    static func launch() -> Bool {
        guard CommandLine.arguments.contains("--test-routing") else { return false }
        TestWorld.enter()
        exit(run())
    }

    static func run() -> Int32 {
        var fails = 0
        func check(_ name: String, _ ok: Bool) {
            print("  \(ok ? "✓" : "✗") \(name)")
            if !ok { fails += 1 }
        }
        func md(_ name: String, _ desc: String, _ body: String = "# Steps\n") -> String { "---\nname: \(name)\ndescription: \(desc)\n---\n\(body)" }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("one-routing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let book: [(String, String)] = [
            ("movie-showtimes", "Use when looking up movie theater showtimes for a day."),
            ("hotel-search", "Use when finding or comparing hotels for a trip."),
            ("one-assistant-dev", "Use when building or fixing Omar's One Mac app."),
            ("monarch", "Use when Omar asks about his Monarch money or budget."),
            ("pokemon-player", "Play Pokemon via headless emulator + RAM reads."),
        ]
        for (n, d) in book {
            let f = dir.appendingPathComponent("cat/\(n)/SKILL.md")
            try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? md(n, d).write(to: f, atomically: true, encoding: .utf8)
        }
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent(".archive/old"), withIntermediateDirectories: true)
        try? md("old-thing", "Use when movie showtimes.").write(
            to: dir.appendingPathComponent(".archive/old/SKILL.md"), atomically: true, encoding: .utf8)
        let idx = RouteIndex.build(dirs: [dir])

        print("the recipe book")
        check("every recipe read, hidden folders skipped", idx.skills.count == 5 && idx.skill("old-thing") == nil)
        check("name and description come from the header", idx.skill("monarch")?.desc.hasPrefix("Use when Omar asks") == true)

        print("picking recipes")
        let a = Router.route("Search for movie showtimes in Allentown tomorrow after 12pm", index: idx, memory: [])
        check("words pick the recipe: showtimes → movie-showtimes", a.preload.first == "movie-showtimes")
        let b = Router.route("Fix the orb bug in the One Mac app and ship it", index: idx, memory: [])
        check("building One → one-assistant-dev", b.preload.first == "one-assistant-dev")
        let none = Router.route("zzzz qqqq", index: idx, memory: [])
        check("no matching words: nothing loaded, nothing said", none.preload.isEmpty && Router.helperNote(none, index: idx).isEmpty)
        let empty = Router.route("movie showtimes", index: RouteIndex(), memory: [])
        check("no recipe book yet: nothing loaded", empty.preload.isEmpty)

        print("what worked before")
        let q = "Check how Project Ledger runs went today"
        let worked = RouteMemory(date: Date(), terms: RouteMemory.terms("Check Project Ledger runs today"), skills: ["monarch"], ok: true)
        let r1 = Router.route(q, index: idx, memory: [worked])
        check("a similar job that worked brings its recipe", r1.preload.first == "monarch")
        var bad = worked
        bad.ok = false
        let r2 = Router.route(q, index: idx, memory: [bad])
        check("a similar job that went badly doesn't", !r2.preload.contains("monarch"))
        check("the memory keeps at most 60 words per job", RouteMemory.terms((0..<200).map { "word\($0)" }.joined(separator: " ")).count == 60)

        print("rooms")
        check("Andela job → work", Router.room("Check my Andela PRs") == "work")
        check("EK and the strategy canvas → Co-Founder", Router.room("Draft price options for EK's strategy canvas") == "cofounder")
        check("two rooms named → no claim (ask, as today)", Router.room("Tell EK about my Andela job") == nil)
        check("Nyx is never routed into", Router.room("load nyx and talk about work at Andela") == nil)
        check("building One → no claim", Router.room("Fix a bug in Omar's One Mac app, bundle id ai.forjado.one") == nil)
        check("nothing named → no claim", Router.room("What's the weather?") == nil)
        check("main chat inside Nyx: no room line", !Router.mainNote(Route(room: "work"), inNyx: true).contains("room"))

        print("their yes")
        for t in [
            "Post it", "Reply and merge", "Yes, all 12 (trash them)", "Get a refund for Gaia", "Buy the cheaper flight", "Yes, remove it",
            "approve last email sweep", "Change the Slack bot's profile picture",
        ] {
            check("\"\(t)\" → ask first", Router.needsYes(t))
        }
        check("a plain lookup doesn't", !Router.needsYes("What movies are playing tomorrow?"))
        check("sending a helper doesn't", !Router.needsYes("Can you send a helper to check the orbs? Send me the link."))
        check("the yes line is short", Router.mainNote(Route(needsYes: true), inNyx: false).count < 160)

        print("the brain")
        check("a showtimes lookup → balanced", Router.tier("Search for movie showtimes tomorrow") == 1)
        check("building → their own pick", Router.tier("Build and ship the orb fix") == 0)
        check("steps down from Smartest only", Router.model(Route(tier: 1), provider: .claude, current: "claude-opus-5-5") == "claude-sonnet-5")
        check("never from Balanced or Fastest", Router.model(Route(tier: 1), provider: .claude, current: "claude-sonnet-5") == nil)
        check("never on a pay-per-use account", Router.model(Route(tier: 1), provider: .openrouter, current: "anthropic/claude-opus-5.5") == nil)

        print("what the helper gets")
        let note = Router.helperNote(b, index: idx)
        check("the recipe is loaded in full", note.contains("<skill name=\"one-assistant-dev\">") && note.contains("Use when building"))
        check(
            "its one plain line names no file",
            Router.plainLine(b, index: idx) == "Started from what I already know about this: building or fixing Omar's One Mac app.")
        check("a looked-up recipe is read from the step title", Router.viewed("skill_view: monarch → references/x.md") == "monarch")
        check("other steps aren't", Router.viewed("terminal: ls") == nil)
        var big = b
        big.preload = []
        check("nothing to add: nothing said", Router.helperNote(big, index: idx).isEmpty)

        print("the first memory")
        let j = RouteSeed.job("You're one of Elias's helpers.\n\nThe job: Find hotels in Quebec\n\nDo it now. Finish …")
        check("a helper's job is read from its first prompt", j == "Find hotels in Quebec")
        check("other conversations aren't", RouteSeed.job("Hello") == nil)

        if let replay = ProcessInfo.processInfo.environment["ONE_ROUTING_REPLAY"] { fails += Self.replay(replay) }
        print(fails == 0 ? "routing ok" : "routing: \(fails) failed")
        return fails == 0 ? 0 : 1
    }

    /// Real jobs in time order against the real recipe book: each job is routed with only the memory of the jobs before it.
    static func replay(_ path: String) -> Int {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)), let all = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
            let items = all["items"] as? [[String: Any]]
        else {
            print("  ✗ replay file unreadable")
            return 1
        }
        let turns = all["turns"] as? [[String: Any]] ?? []
        let t0 = Date()
        // A test never reads the real home by itself: the recipe folders come in ONE_ROUTING_SKILLS (colon-separated), read only.
        let dirs = (ProcessInfo.processInfo.environment["ONE_ROUTING_SKILLS"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        let idx = RouteIndex.build(dirs: dirs)
        let buildMs = Date().timeIntervalSince(t0) * 1000
        var mem: [RouteMemory] = []
        var n = 0
        var top3 = 0
        var top1 = 0
        var pre = 0
        var preHit = 0
        var ms: [Double] = []
        var rooms = 0
        var claims = 0
        var wrongRoom: [String] = []
        var gates = 0
        var gateMiss: [String] = []
        var noGate = 0
        var flagged = 0
        for it in items {
            let q = it["q"] as? String ?? ""
            let gt = (it["gt"] as? [String] ?? []).filter { idx.skill($0) != nil }
            let r = Router.route(q, index: idx, memory: mem)
            ms.append(r.ms)
            if !gt.isEmpty {
                n += 1
                if r.ranked.contains(where: { gt.contains($0.name) }) { top3 += 1 }
                if let f = r.ranked.first, gt.contains(f.name) { top1 += 1 }
                pre += r.preload.count
                preHit += r.preload.filter { gt.contains($0) }.count
            }
            let raw = it["raw"] as? String ?? q
            if let room = it["room"] as? String, !room.isEmpty {
                rooms += 1
                if let c = Router.room(raw) {
                    claims += 1
                    if c != room { wrongRoom.append("\(c)≠\(room): \(raw.prefix(60))") }
                }
            }
            if it["gate"] as? Bool == true {
                gates += 1
                if !Router.needsYes(raw) { gateMiss.append(String(raw.prefix(60))) }
            } else {
                noGate += 1
                if Router.needsYes(raw) { flagged += 1 }
            }
            mem.append(RouteMemory(date: Date(), terms: RouteMemory.terms(q), skills: gt, ok: true))
        }
        var mGates = 0
        var mMiss: [String] = []
        var mNo = 0
        var mFlagged = 0
        var nyx = 0
        var nyxRouted = 0
        for t in turns {
            let user = t["user"] as? String ?? ""
            let text = user + "\n" + (user.count < 60 ? t["prev"] as? String ?? "" : "")
            let t0 = Date()
            let yes = Router.needsYes(text)
            let room = Router.room(user)
            ms.append(Date().timeIntervalSince(t0) * 1000)
            if t["gate"] as? Bool == true {
                mGates += 1
                if !yes { mMiss.append(String(user.prefix(60))) }
            } else {
                mNo += 1
                if yes { mFlagged += 1 }
            }
            if user.range(of: #"\bnyx\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
                nyx += 1
                if room != nil { nyxRouted += 1 }
            }
        }
        ms.sort()
        print("replay: rooms: \(rooms) jobs wrote into exactly one room; the router claimed a room for \(claims), wrong \(wrongRoom.count)")
        for w in wrongRoom { print("    wrong room: \(w)") }
        print("replay: helpers that needed a yes: \(gates), missed \(gateMiss.count); others flagged anyway \(flagged) of \(noGate)")
        print(
            "replay: main-chat turns that needed a yes: \(mGates) of \(turns.count), missed \(mMiss.count); others flagged anyway \(mFlagged) of \(mNo)"
        )
        for g in gateMiss + mMiss { print("    missed yes: \(g)") }
        print("replay: turns naming Nyx: \(nyx), routed into a room: \(nyxRouted)")
        func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "-" : "\(Int((Double(a) / Double(b) * 100).rounded()))%" }
        print("replay: \(items.count) jobs, \(n) with recipes, \(idx.skills.count) recipes indexed in \(Int(buildMs)) ms")
        print("replay: right recipe in top 3 \(pct(top3, n)), first pick right \(pct(top1, n)), loaded up front that were used \(pct(preHit, pre))")
        print(
            String(
                format: "replay: route time p50 %.2f ms, p95 %.2f ms, max %.2f ms", ms[ms.count / 2], ms[Int(Double(ms.count) * 0.95)], ms.last ?? 0))
        return 0
    }
}
