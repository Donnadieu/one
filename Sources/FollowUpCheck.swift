import Foundation

/// `One --test-followups` (tools/followups-check.sh): a real turn with One's real engine in the throwaway
/// home, driven through the same `Model.send` the Send button and push to talk use. While it runs, four
/// messages are sent (one before the turn has started answering, three in a burst while it works),
/// then two while One is stopped (one changed, one taken back). Checks: the running turn is never cut into
/// (the four wait Next up in the one line, SayQueue.swift) and goes on to its end, then they go together as
/// the next turn, once each and in order, and the assistant acts on them; the changed one goes in with its
/// new words and the taken-back one never goes. Costs two or three short Claude turns.
/// Must run from a copy with its own bundle id (the script does that), so the person's chat is never touched.
enum FollowUpCheck {
    @MainActor
    static func run() async -> Int32 {
        var fails = 0
        func check(_ name: String, _ ok: Bool) {
            print("  \(ok ? "✓" : "✗") \(name)")
            fflush(stdout)
            if !ok { fails += 1 }
        }
        guard Env.selfTest, Bundle.main.bundleIdentifier != "ai.forjado.one", Env.hermesHome.path.contains("selftest-hermes") else {
            print("refusing: run tools/followups-check.sh (a copy with its own settings, throwaway home)")
            return 2
        }
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
        await SignIn.makeDefault(.claude, model: Provider.claude.tiers[1].1)
        _ = await hermesRun(["config", "set", "auth.adopt_external_logins", "false"])
        try? fm.removeItem(at: Brain.root)
        _ = Brain.build(owner: "Omar", ai: "Ava", rooms: [])
        Access.override = []
        Persona.write(assistant: "Ava", user: "Omar", connections: [], passwords: "ask each time")
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
        var prompts = 0
        func ask(_ s: String) {
            prompts += 1
            Task { await m.send(s) }
        }
        func wait(_ s: Double, until: () -> Bool) async {
            let end = Date().addingTimeInterval(s)
            while Date() < end, !until() { try? await Task.sleep(for: .milliseconds(200)) }
        }

        // 1. A long turn, with messages sent while it runs.
        print("1. a long turn, four messages sent during it")
        ask(
            "Do this yourself, right here, never with a helper: run these terminal commands one at a time, each in its own "
                + "separate tool call: `sleep 5; echo one`, then `sleep 5; echo two`, then `sleep 5; echo three`, then `sleep 5; echo four`. "
                + "Then reply with one line: STEPS DONE. After that, whenever I send you extra words, reply with one line that starts with "
                + "WORDS: and lists them, in the order they came.")
        await wait(10) { m.thinking }
        await m.send("Extra word: ZERO")  // before it has started answering: waits next up
        check("sent before the turn got going: shown at once as Next up", m.followUps.map(\.state) == [.next])
        await wait(60) { m.turnStarted }
        try? await Task.sleep(for: .seconds(2))
        for w in ["APPLE", "BANANA", "CHERRY"] { await m.send("Extra word: \(w)") }  // a burst, no pause
        check("the burst shows at once, nothing dropped", m.followUps.count == 4)
        check("still the same turn (no second one started)", m.bubbles.filter(\.fromMe).count == 1 && m.thinking)
        check("none went into the running turn: all four wait Next up", m.followUps.count == 4 && m.followUps.allSatisfy { $0.state == .next })
        await wait(180) { m.bubbles.filter(\.fromMe).count == 2 }
        let first = m.bubbles.count > 1 ? m.bubbles[1].text : ""
        print("   first reply: \(first.replacingOccurrences(of: "\n", with: " ").prefix(200))")
        check("the running turn went to its end (all four steps, not cut)", first.uppercased().contains("STEPS DONE"))
        check(
            "then the four went as the next turn, in one go, in order",
            m.bubbles.last { $0.fromMe }?.text == "Extra word: ZERO\nExtra word: APPLE\nExtra word: BANANA\nExtra word: CHERRY")
        await wait(120) { !m.thinking && m.outbox.isEmpty }
        try? await Task.sleep(for: .seconds(1))
        let reply = m.bubbles.last?.text ?? ""
        print("   reply: \(reply.replacingOccurrences(of: "\n", with: " ").prefix(300))")
        let pos = ["ZERO", "APPLE", "BANANA", "CHERRY"].map { reply.range(of: $0)?.lowerBound }
        check("the assistant heard all four", pos.allSatisfy { $0 != nil })
        check("in the order they were sent", pos.compactMap { $0 } == pos.compactMap { $0 }.sorted())
        check("two turns: two asks, two replies", m.bubbles.filter(\.fromMe).count == 2 && m.bubbles.filter { !$0.fromMe }.count == 2)
        check("nothing left waiting", m.followUps.isEmpty)
        check("no helper was started", m.helpers.isEmpty)

        // 2. Stopped: messages wait Next up, one is changed, one taken back; turning back on sends the rest as the next turn.
        print("2. sent while stopped, one changed, one taken back")
        m.paused = true
        for w in ["DATE", "WRONG", "FIG"] { await m.send("Extra word: \(w)") }
        check("all three wait as Next up", m.followUps.count == 3 && m.followUps.allSatisfy { $0.state == .next })
        if m.followUps.count == 3 {
            let wrong = m.followUps[1].id
            let fig = m.followUps[2].id
            m.editingFollowUp = wrong
            m.editFollowUp(wrong, to: "Extra word: ELDER")
            m.editFollowUp(fig, to: nil)
        }
        check(
            "the changed one has its new words; the taken-back one is gone", m.followUps.map(\.display) == ["Extra word: DATE", "Extra word: ELDER"])
        m.toggleStop()  // back on
        await wait(20) { m.bubbles.filter(\.fromMe).count == 3 }  // the ask is shown once the engine is ready
        check("turning back on sends them as the next turn, in one go", m.bubbles.last { $0.fromMe }?.text == "Extra word: DATE\nExtra word: ELDER")
        await wait(120) { !m.thinking }
        try? await Task.sleep(for: .seconds(1))
        let r2 = (m.bubbles.last?.text ?? "").uppercased()
        print("   reply: \(r2.replacingOccurrences(of: "\n", with: " ").prefix(200))")
        check("the assistant got DATE and ELDER", r2.contains("DATE") && r2.contains("ELDER"))
        check("never WRONG or FIG", !r2.contains("WRONG") && !r2.contains("FIG"))
        check("nothing left waiting", m.followUps.isEmpty)

        let previous = Engine.shared.enginePID
        Engine.shared.stop()
        Engine.stopStrayGateway(previousEngine: previous, caller: "test-followups")
        print(fails == 0 ? "PASS sending while busy" : "FAIL sending while busy (\(fails))")
        return fails == 0 ? 0 : 1
    }
}
