import AppKit

/// `One --test-blocked` (preflight): a helper or the assistant blocked on a step only the person can do asks,
/// never substitutes. Checks the rule is in SOUL and in every helper turn (first, follow-up, picked back up), and
/// One's own catch: a stand-in hidden browser (a local `/json/list`, never port 9223) shows a Cloudflare page,
/// One asks "Can I show you the window?" with Yes, show it / Not now, turns the browsing helper orange, never
/// shows a window by itself, and a helper reply that skipped the ask still ends on it.
enum BlockedAskCheck {
    static func launch() -> Bool {
        guard CommandLine.arguments.contains("--test-blocked") else { return false }
        TestWorld.enter()  // scratch folder and a stand-in browser list; run with ONE_SUPPORT_DIR set to an empty folder
        Task { @MainActor in exit(await run()) }
        return true
    }
    @MainActor
    static func run() async -> Int32 {
        var fails = 0
        func check(_ name: String, _ ok: Bool) {
            print("  \(ok ? "✓" : "✗") \(name)")
            fflush(stdout)
            if !ok { fails += 1 }
        }
        guard Env.selfTest, ProcessInfo.processInfo.environment["ONE_SUPPORT_DIR"] != nil else {
            print("refusing: run with ONE_SUPPORT_DIR set to an empty folder, from a test copy")
            return 2
        }
        let fm = FileManager.default

        print("1. the rule is written where it can't be lost")
        let soul = Persona.soul(assistant: "Ava", user: "Omar")
        check("SOUL (rewritten at every update) carries it", soul.contains(BlockedAsk.soul))
        check(
            "with the plain ask and its two answers",
            soul.contains("Can I show you the window?") && soul.contains("[choices: Yes, show it | Not now]"))
        check("and says never swap in another method", soul.contains("never swap in another way of doing the job"))
        check("the main assistant is told every turn", Helpers.note.contains(BlockedAsk.marker))
        let brief = Helpers.forHelper(Helpers.brief(assistant: "Ava", user: "Omar", task: "Make 3 designs in Claude Design."))
        check("a helper's first turn carries it once", brief.components(separatedBy: BlockedAsk.marker).count == 2)
        check("a follow-up turn carries it", Helpers.forHelper("Use the blue one").contains(BlockedAsk.marker))
        let resumed =
            "You were interrupted by a restart.\n\nYour original job: x\n\n(One app note, not from the user: You are a helper working on one job. Do the work yourself.)"
        check("a helper picked back up after a restart or an update carries it", Helpers.forHelper(resumed).contains(BlockedAsk.marker))
        check("never twice", Helpers.forHelper(Helpers.forHelper("x")).components(separatedBy: BlockedAsk.marker).count == 2)

        print("2. spotting a robot check")
        check("Cloudflare's \"Just a moment...\"", BlockedAsk.isChallenge(title: "Just a moment...", url: "https://claude.ai/design"))
        check("a challenge address", BlockedAsk.isChallenge(title: "", url: "https://claude.ai/?__cf_chl_rt_tk=abc"))
        check("\"Verify you are human\"", BlockedAsk.isChallenge(title: "Verify you are human", url: "https://x.com"))
        check("a normal page isn't one", !BlockedAsk.isChallenge(title: "Claude", url: "https://claude.ai/design/p/123"))
        check("nor a Google search", !BlockedAsk.isChallenge(title: "flights to Quebec - Google Search", url: "https://www.google.com/search?q=x"))

        print("3. One asks by itself (stand-in hidden browser)")
        let port = 29000 + Int(getpid() % 900)
        let root = Env.support.appendingPathComponent("blocked-browser")
        try? fm.createDirectory(at: root.appendingPathComponent("json"), withIntermediateDirectories: true)
        let tabs: [[String: Any]] = [
            ["type": "page", "id": "TAB1", "title": "Just a moment...", "url": "https://claude.ai/design"],
            ["type": "page", "id": "TAB2", "title": "Google", "url": "https://www.google.com/"],
        ]
        try? JSONSerialization.data(withJSONObject: tabs).write(to: root.appendingPathComponent("json/list"))
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-m", "http.server", String(port), "--bind", "127.0.0.1", "-d", root.path]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try? server.run()
        defer { server.terminate() }
        var pages: [BlockedAsk.Page] = []
        for _ in 0..<40 where pages.isEmpty {
            try? await Task.sleep(for: .milliseconds(250))
            pages = await BlockedAsk.pages(port: port)
        }
        check("reads the browser's tabs", pages.count == 2)

        let m = Model.shared
        var h = Helper(title: "Notification designs", task: "Make 3 designs in Claude Design.", sid: nil, state: "working", line: "Working on it…")
        h.started = Date()
        let other = Helper(title: "Flight prices", task: "x", sid: nil, state: "working", line: "Working on it…")
        m.helpers = [h, other]
        BlockedAsk.saw("browser_exec: # Opening Claude Design", by: h.id.uuidString)
        BlockedAsk.saw("web_search: flights", by: other.id.uuidString)
        check(
            "the helper that was browsing is the one stuck", BlockedAsk.owner(working: [h.id, other.id], lastBrowser: BlockedAsk.lastBrowser) == h.id)

        await m.tendBlocked(port: port, settle: 60)
        check("a check that may clear itself is left a few seconds", HumanStep.pending().isEmpty)
        await m.tendBlocked(port: port, settle: 0)
        let asks = HumanStep.pending()
        check("one that stays up gets One's own ask", asks.count == 1 && asks.first?.target == "TAB1" && asks.first?.ask == true)
        let line = asks.first?.line ?? ""
        check(
            "in plain words: who, what's blocked, the ask",
            line.contains("Notification designs") && line.contains("claude.ai") && line.hasSuffix("Can I show you the window?"))
        check("the helper turns orange (needs your yes)", m.helpers.first { $0.id == h.id }?.viewState == .needsYes)
        check("the other helper keeps working", m.helpers.first { $0.id == other.id }?.state == "working")
        await m.tendBlocked(port: port, settle: 0)
        check("asked once, not again every few seconds", HumanStep.pending().count == 1)
        let shown = NSApp.windows.filter { $0.isVisible && $0.title != "One" }.map { "\(type(of: $0)) \($0.title)" }  // One's own window aside
        if !shown.isEmpty || !HumanStep.windows.isEmpty { print("    visible: \(shown) step windows: \(HumanStep.windows.keys.sorted())") }
        check("no window shows by itself", HumanStep.windows.isEmpty && shown.isEmpty)

        print("4. the yes, and the job carries on as asked")
        m.humanSteps = HumanStep.pending()
        let skipped = BlockedAsk.enforce("I couldn't get past it, so I drew the 3 designs by hand instead.", line: line)
        check(
            "a reply that skipped the ask still ends on it, with its buttons",
            skipped.hasSuffix("Can I show you the window?\n[choices: Yes, show it | Not now]"))
        check(
            "a reply that asked is left alone",
            BlockedAsk.enforce("Blocked.\n[choices: Yes, show it | Not now]", line: line) == "Blocked.\n[choices: Yes, show it | Not now]")
        check("\"Not now\" isn't a yes", m.blockedYes("Not now", helper: h.id).isEmpty)
        check(
            "\"Yes, show it\" tells the helper to wait for them, then carry on",
            m.blockedYes("Yes, show it", helper: h.id).contains("carry on with the job exactly as asked"))
        check("a yes to something else shows nothing", m.blockedYes("Yes", helper: other.id).isEmpty)
        m.answerHumanStep(asks.first?.id ?? "", "away")
        check("Not now closes the ask and starts nothing", m.humanSteps.isEmpty && BlockedAsk.helperFor.isEmpty)

        m.helpers = []
        try? fm.removeItem(at: HumanStep.dir)
        print(fails == 0 ? "blocked ok" : "blocked FAILED (\(fails))")
        return fails == 0 ? 0 : 1
    }
}
