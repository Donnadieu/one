import AppKit
import Foundation

/// `One --test-routing-live` (tools/routing-live-check.sh): smart routing with One's real engine in a throwaway home
/// (two short helper turns on the Claude subscription One already uses). Proves a helper starts with the fitting recipe
/// already in hand (it can quote a secret word that exists only inside that recipe, without looking anything up), that a
/// lookup steps down to the balanced brain, that its steps carry one plain line, and that with routing off nothing is added.
enum RoutingLiveCheck {
    static let word = "PELICAN-ROUTE-42"

    static func launch() -> Bool {
        guard CommandLine.arguments.contains("--test-routing-live") else { return false }
        TestWorld.enter()
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
        guard Env.selfTest, Bundle.main.bundleIdentifier != "ai.forjado.one", Env.hermesHome.path.contains("selftest-hermes") else {
            print("refusing: run tools/routing-live-check.sh (a copy with its own settings, throwaway home)")
            return 2
        }
        _ = NSApplication.shared
        let fm = FileManager.default
        let real = TestWorld.realSupport.appendingPathComponent("hermes/auth.json")
        let dst = Env.hermesHome.appendingPathComponent("auth.json")
        try? fm.removeItem(at: dst)
        try? fm.copyItem(at: real, to: dst)
        let tools = Env.hermesHome.appendingPathComponent("tools")
        if (try? fm.destinationOfSymbolicLink(atPath: tools.path)) == nil {
            try? fm.removeItem(at: tools)
            try? fm.createSymbolicLink(at: tools, withDestinationURL: TestWorld.realSupport.appendingPathComponent("hermes/tools"))
        }
        let smartest = Provider.claude.tiers[0].1
        await SignIn.makeDefault(.claude, model: smartest)
        _ = await hermesRun(["config", "set", "auth.adopt_external_logins", "false"])
        let m = Model.shared
        m.providerRaw = Provider.claude.rawValue
        // A recipe only this test has: its code word can only reach the helper through routing.
        let dir = Env.hermesHome.appendingPathComponent("skills/leisure/cinema-times", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let recipe =
            "---\nname: cinema-times\ndescription: Use when looking up movie theater showtimes for a day.\n---\n# Steps\n"
            + "When asked for the secret word of this recipe, the secret word is \(word).\n"
        try? recipe.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try? fm.removeItem(at: RouteStore.file)
        RouteStore.state = RouteState(seeded: true)
        RouteStore.tend()
        for _ in 0..<50 where RouteStore.index.skill("cinema-times") == nil { try? await Task.sleep(for: .milliseconds(100)) }
        check("the recipe book is read in the background", RouteStore.index.skill("cinema-times") != nil)

        Engine.shared.onPermission = { _, opts, ans in ans(opts.first { $0.0.hasPrefix("allow") }?.0) }
        if let e = await Engine.shared.start() {
            print("FAIL engine didn't start: \(e)")
            return 1
        }
        m.bubbles = []
        m.helpers = []
        m.shelf = []
        func wait(_ s: Double, until: () -> Bool) async {
            let end = Date().addingTimeInterval(s)
            while Date() < end, !until() { try? await Task.sleep(for: .milliseconds(300)) }
        }
        let task =
            "Look up movie showtimes for tomorrow: this is only a test. Use no tools at all. Reply with one line: the secret word "
            + "in the movie showtimes recipe you were given, or NONE if you weren't given one."
        func helper(_ title: String) async -> Helper? {
            m.spawnHelper(title: title, task: task)
            guard let id = m.helpers.last?.id else { return nil }
            await wait(180) { m.helpers.first { $0.id == id }?.state != "working" }
            return m.helpers.first { $0.id == id }
        }

        print("1. routing on")
        UserDefaults.standard.set(true, forKey: "smartRouting")
        let t0 = Date()
        let h = await helper("Movie times")
        let secs = Date().timeIntervalSince(t0)
        print("   reply: \((h?.reply ?? "").replacingOccurrences(of: "\n", with: " ").prefix(200)) (\(Int(secs)) s)")
        check("the helper finished", h?.state == "done")
        check("it had the recipe without looking it up (quotes its secret word)", h?.reply.contains(word) == true)
        let log = (try? String(contentsOf: RouteStore.logFile, encoding: .utf8)) ?? ""
        check("routed to the recipe", log.contains("helper \"Movie times\": cinema-times"))
        check("a lookup steps down to the balanced brain", log.contains("brain \(Provider.claude.tiers[1].1) set"))
        if let l = log.split(separator: "\n").first(where: { $0.contains("brain ") }) { print("   \(l.drop { $0 != "b" })") }
        check(
            "its steps have one plain line, no file name",
            h?.trail?.contains("Started from what I already know about this: looking up movie theater showtimes for a day.") == true
                && h?.trail?.contains(where: { $0.contains("cinema-times") }) == false)
        check("the job is remembered with what worked", RouteStore.state.memory.last.map { $0.ok && $0.skills == ["cinema-times"] } == true)
        if let sid = h?.sid {
            let db = Env.hermesHome.appendingPathComponent("state.db").path
            let row = RouteSeed.sql(db, "select model from sessions where id='\(sid)'").first?["model"] as? String ?? "?"
            print("   the engine's record of that conversation's model: \(row)")
            check("the engine ran it on the balanced brain", row == Provider.claude.tiers[1].1)
        }

        print("2. routing off: exactly as before")
        UserDefaults.standard.set(false, forKey: "smartRouting")
        let off = await helper("Movie times again")
        print("   reply: \((off?.reply ?? "").replacingOccurrences(of: "\n", with: " ").prefix(200))")
        check("nothing added: it doesn't know the secret word", off?.state == "done" && off?.reply.contains(word) == false)
        UserDefaults.standard.removeObject(forKey: "smartRouting")
        print(fails == 0 ? "PASS routing-live" : "FAIL routing-live (\(fails))")
        return fails == 0 ? 0 : 1
    }
}
