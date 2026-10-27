import AppKit
import Foundation

/// `One --test-helper-self` (tools/helper-self-check.sh, `make helperself`): a helper someone opens and talks to
/// does the work itself. Real engine in the throwaway home, driven through the same `Model.send` the Send button
/// uses. A helper goes out, is opened, and gets a follow-up that used to tempt it into a "[helper: …]" line
/// (which only the main assistant can start, so nothing ran and the raw line showed). Checks: the poem file is
/// made, no "[helper:" text is shown, no new helper started, and a stray line is dropped and logged.
/// Must run from a copy with its own bundle id (the script does that), so the person's chat is never touched.
enum HelperSelfCheck {
    @MainActor
    static func run() async -> Int32 {
        var fails = 0
        func check(_ name: String, _ ok: Bool) {
            print("  \(ok ? "✓" : "✗") \(name)")
            fflush(stdout)
            if !ok { fails += 1 }
        }
        guard Env.selfTest, Bundle.main.bundleIdentifier != "ai.forjado.one", Env.hermesHome.path.contains("selftest-hermes") else {
            print("refusing: run tools/helper-self-check.sh (a copy with its own settings, throwaway home)")
            return 2
        }
        _ = NSApplication.shared
        let fm = FileManager.default

        // 1. The safety net, without the engine.
        print("1. a stray helper line is dropped, logged and never started")
        let log = Env.hermesHome.appendingPathComponent("logs/one-helpers.log")
        try? fm.removeItem(at: log)
        let stray = "On it.\n[helper: One promo v3 | Make the promo video again]\nI'll be back."
        let kept = Helpers.dropStrayLines(stray, helper: "Promo video v2")
        check("the line is gone from what's shown", !kept.contains("[helper") && kept.contains("On it.") && kept.contains("I'll be back."))
        check("it's logged", (try? String(contentsOf: log, encoding: .utf8))?.contains("Promo video v2") == true)
        check("a half-written line is hidden while it streams", !Helpers.strip("Sure\n[helper: Promo v3 sam").contains("[helper"))
        check(
            "the brief carries the helper note",
            Helpers.brief(assistant: "Ava", user: "Omar", task: "x").contains("You are a helper working on one job"))
        check(
            "the note isn't added twice",
            Helpers.forHelper(Helpers.brief(assistant: "Ava", user: "Omar", task: "x")).components(separatedBy: "You are a helper working").count == 2
        )
        check(
            "the main assistant's note is unchanged (still sends helpers)",
            Helpers.note.contains("[helper: Short title |") && !Helpers.note.contains("You are a helper"))

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
        _ = Brain.build(owner: "Omar", ai: "Ava", rooms: [])
        Access.override = []
        Persona.write(assistant: "Ava", user: "Omar", connections: [], passwords: "ask each time")
        let soul = (try? String(contentsOf: Env.hermesHome.appendingPathComponent("SOUL.md"), encoding: .utf8)) ?? ""
        check("SOUL says the helper rules are for the main assistant only", soul.contains("for you, the main assistant, only, not for helpers"))
        Engine.shared.onPermission = { _, opts, ans in ans(opts.first { $0.0.hasPrefix("allow") }?.0) }
        if let e = await Engine.shared.start() {
            print("FAIL engine didn't start: \(e)")
            return 1
        }
        let m = Model.shared
        m.assistantName = "Ava"
        m.userName = "Omar"
        m.bubbles = []
        m.helpers = []
        m.shelf = []
        func wait(_ s: Double, until: () -> Bool) async {
            let end = Date().addingTimeInterval(s)
            while Date() < end, !until() { try? await Task.sleep(for: .milliseconds(300)) }
        }
        let dir = Env.support.appendingPathComponent("selftest-scratch/poem-\(UUID().uuidString.prefix(8))")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        print("2. a helper goes out, is opened, and is asked for more work")
        m.spawnHelper(title: "Promo video v2", task: "Reply with only: Ready for the next step.")
        guard let id = m.helpers.first?.id else {
            print("FAIL no helper")
            return 1
        }
        await wait(120) { m.helpers.first { $0.id == id }?.state != "working" }
        check("the helper finished its first job", m.helpers.first { $0.id == id }?.state == "done")
        m.focusHelper(id)
        let chats = m.bubbles.count
        await m.send("Make a short 3-line poem file in a scratch folder: save it as \(dir.path)/poem.txt")
        await wait(180) { m.helpers.first { $0.id == id }?.state != "working" }
        let h = m.helpers.first { $0.id == id }
        let reply = h?.reply ?? ""
        print("   helper said: \(reply.replacingOccurrences(of: "\n", with: " ").prefix(300))")
        let poem = (try? String(contentsOf: dir.appendingPathComponent("poem.txt"), encoding: .utf8)) ?? ""
        let lines = poem.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        print("   poem.txt: \(lines.count) lines")
        check("it made the poem file itself", lines.count == 3)
        check("no [helper: …] text shown in the helper's chat", !reply.lowercased().contains("[helper"))
        check("no [helper: …] text in its card summary", !Choices.split(Helpers.strip(reply)).body.lowercased().contains("[helper"))
        check("no new helper started", m.helpers.count == 1)
        check("nothing went into the main chat", m.bubbles.count == chats)
        let logged = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        print(
            "   stray helper lines logged during the real run: \(logged.components(separatedBy: "\n").filter { $0.contains("wrote a helper line") }.count - 1)"
        )
        m.openHelper = nil
        print(fails == 0 ? "PASS helper-self" : "FAIL helper-self (\(fails))")
        return fails == 0 ? 0 : 1
    }
}
