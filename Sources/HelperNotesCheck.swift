import AppKit
import Foundation

/// `One --test-helper-notes` (tools/helper-notes-check.sh, `make helpernotes`): a helper started on an OLD One keeps
/// that version's instructions after an update (the engine reuses a reloaded conversation's stored system prompt),
/// yet must still know what's built and where things are. Real engine in a throwaway home: a helper starts under an
/// old SOUL that says Chrome isn't built and sends people to "Settings → Passwords & Logins" (what EK's Monarch helper
/// said), the SOUL is then updated as an update would, and a FORK of that helper's conversation is asked, as follow-ups
/// through the same `Model.send` the Send button uses, "can you use my Chrome?" and "where do I save a password?".
/// Both answers must name Connections › Browser and Connections › Passwords, and neither may point to Settings.
/// Must run from a copy with its own bundle id (the script does that), so the person's chat is never touched.
enum HelperNotesCheck {
    /// What an old One told its helpers (frozen into their conversation), worst case.
    static let oldSoul = """
        Logins: using their own Chrome isn't built and would need a brand new capability. To save a password, tell them \
        to open Settings → Passwords & Logins in this app, or run `hermes vault add`.
        """

    /// `--test-helper-notes`: throwaway Hermes home and brain, from a copy with its own settings.
    static func launch() -> Bool {
        guard CommandLine.arguments.contains("--test-helper-notes") else { return false }
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
            print("refusing: run tools/helper-notes-check.sh (a copy with its own settings, throwaway home)")
            return 2
        }
        _ = NSApplication.shared
        let fm = FileManager.default

        print("1. every helper turn carries the same notes as the main chat")
        let h = SessionNotes.helper
        check("their screen and no Settings screen", h.contains("There is no Settings") && h.contains("Connections"))
        check("their own Chrome is built: Connections › Browser", h.contains("then Browser, pick Chrome and tap Connect"))
        check("passwords: Connections › Passwords", h.contains("click Connections at the top, then Passwords"))
        check("the engine's own screen names are called out", h.contains("Passwords & Logins") && h.contains("Credential Vault"))
        check(
            "the hidden browser / their Chrome note",
            h.contains("(One app note, not from the user: their own browser") || h.contains("hidden browser on port"))
        check("which One runs", h.contains("THIS MAC RUNS ONE"))
        check(
            "the main chat gets the same, plus the browser rule", SessionNotes.main.hasPrefix(h) && SessionNotes.main.contains("NO VISIBLE BROWSER"))
        check("the helper note carries the browser rule", Helpers.forHelper("x").contains("NO VISIBLE BROWSER"))

        // 2. The real thing.
        let real = TestWorld.realSupport.appendingPathComponent("hermes/auth.json")
        let dst = Env.hermesHome.appendingPathComponent("auth.json")
        try? fm.removeItem(at: dst)
        try? fm.copyItem(at: real, to: dst)
        let tools = Env.hermesHome.appendingPathComponent("tools")
        if (try? fm.destinationOfSymbolicLink(atPath: tools.path)) == nil {
            try? fm.removeItem(at: tools)
            try? fm.createSymbolicLink(at: tools, withDestinationURL: TestWorld.realSupport.appendingPathComponent("hermes/tools"))
        }
        await SignIn.makeDefault(.claude, model: Provider.claude.tiers[1].1)
        _ = await hermesRun(["config", "set", "auth.adopt_external_logins", "false"])
        try? fm.removeItem(at: Brain.root)
        _ = Brain.build(owner: "EK", ai: "Juan", rooms: [])
        Access.override = []
        Persona.write(assistant: "Juan", user: "EK", connections: [], passwords: "ask each time")
        let soulFile = Env.hermesHome.appendingPathComponent("SOUL.md")
        var old = Persona.soul(assistant: "Juan", user: "EK")
        old = old.replacingOccurrences(of: SessionNotes.screen, with: "This app (One) is what they see.")
        old = old.replacingOccurrences(of: SessionNotes.logins, with: oldSoul)
        try? old.write(to: soulFile, atomically: true, encoding: .utf8)
        check("the old SOUL is in place for the helper's start", !old.contains("There is no Settings") && old.contains("Settings → Passwords"))
        Engine.shared.onPermission = { _, opts, ans in ans(opts.first { $0.0.hasPrefix("allow") }?.0) }
        if let e = await Engine.shared.start() {
            print("FAIL engine didn't start: \(e)")
            return 1
        }
        let m = Model.shared
        m.assistantName = "Juan"
        m.userName = "EK"
        m.bubbles = []
        m.helpers = []
        m.shelf = []
        func wait(_ s: Double, until: () -> Bool) async {
            let end = Date().addingTimeInterval(s)
            while Date() < end, !until() { try? await Task.sleep(for: .milliseconds(300)) }
        }

        print("2. a helper starts on the old One, then One updates")
        m.spawnHelper(title: "Reconcile Amazon transactions", task: "Reply with only: Ready for the next step.")
        guard let id = m.helpers.first?.id else {
            print("FAIL no helper")
            return 1
        }
        await wait(150) { m.helpers.first { $0.id == id }?.state != "working" }
        check("the helper finished its first turn", m.helpers.first { $0.id == id }?.state == "done")
        Persona.refreshSoul(assistant: "Juan", user: "EK")  // what an update does at launch
        check("SOUL updated on disk", ((try? String(contentsOf: soulFile, encoding: .utf8)) ?? "").contains("There is no Settings"))
        guard let orig = m.helpers.first(where: { $0.id == id })?.sid, let fork = await Engine.shared.forkSession(orig) else {
            print("FAIL couldn't fork the helper's conversation")
            return 1
        }
        check("talking to a fork, not the helper itself", fork != orig)
        m.update(id) { $0.sid = fork }
        m.focusHelper(id)

        func ask(_ q: String) async -> String {
            await m.send(q)
            await wait(180) { m.helpers.first { $0.id == id }?.state != "working" }
            let r = m.helpers.first { $0.id == id }?.reply ?? ""
            print("   asked \"\(q)\" → \(r.replacingOccurrences(of: "\n", with: " ").prefix(320))")
            return r
        }
        print("3. the old helper is asked what EK asked")
        let chrome = await ask("Can you use my Chrome? I'm signed in to Amazon and Monarch there.")
        let lc = chrome.lowercased()
        check("Chrome: names Connections › Browser", lc.contains("connections") && lc.contains("browser"))
        check(
            "Chrome: doesn't say it isn't built",
            !lc.contains("isn't built") && !lc.contains("new capability") && !lc.contains("not built") && !lc.contains("can't use your"))
        check("Chrome: no Settings screen", !chrome.contains("Settings →") && !lc.contains("passwords & logins"))
        let pw = await ask("Where do I save a password?")
        let lp = pw.lowercased()
        check("password: names Connections › Passwords", lp.contains("connections") && lp.contains("passwords"))
        check(
            "password: no Settings screen and no terminal",
            !pw.contains("Settings →") && !lp.contains("passwords & logins") && !lp.contains("hermes vault"))
        m.openHelper = nil
        print(fails == 0 ? "PASS helper-notes" : "FAIL helper-notes (\(fails))")
        return fails == 0 ? 0 : 1
    }
}
