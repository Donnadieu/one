import AppKit
import Foundation

/// `One --test-helper-done` (tools/helper-done-check.sh): a real helper with One's real engine in the throwaway
/// home, driven through the same `Model.send` the Send button uses. A helper goes out, then a long reply is asked
/// for while it works. Checks: the reply is never cut off or joined by a hidden note while it runs, exactly one
/// "by the way" line comes after it, the helper's result is never repeated in the main chat, its orb stays orange
/// until it's opened and then shows the check mark, and it can be talked to once opened. Then a good morning with
/// two helpers: one combined report once both are back, and no "by the way" line. Costs a few short Claude turns.
/// Must run from a copy with its own bundle id (the script does that), so the person's chat is never touched.
enum HelperDoneCheck {
    @MainActor
    static func run() async -> Int32 {
        var fails = 0
        func check(_ name: String, _ ok: Bool) {
            print("  \(ok ? "✓" : "✗") \(name)")
            fflush(stdout)
            if !ok { fails += 1 }
        }
        guard Env.selfTest, Bundle.main.bundleIdentifier != "ai.forjado.one", Env.hermesHome.path.contains("selftest-hermes") else {
            print("refusing: run tools/helper-done-check.sh (a copy with its own settings, throwaway home)")
            return 2
        }
        _ = NSApplication.shared  // helpers ask whether One is in front
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
        m.shelf = []
        func wait(_ s: Double, until: () -> Bool) async {
            let end = Date().addingTimeInterval(s)
            while Date() < end, !until() { try? await Task.sleep(for: .milliseconds(200)) }
        }
        let t0 = Date()
        func at() -> String { String(format: "%.0fs", Date().timeIntervalSince(t0)) }

        // 1. A helper goes out.
        print("1. a helper goes out, then a long reply while it works")
        await m.send(
            "Send exactly one helper titled Magic Number with this job: use the terminal to run `sleep 3`, then reply with only: "
                + "The magic number is 4817. Would you like another one? [choices: Yes | No]")
        await wait(120) { !m.thinking }
        check("a helper was sent", m.helpers.count == 1)
        guard let id = m.helpers.first?.id else {
            print("FAIL helper-done (no helper)")
            return 1
        }
        print("   [\(at())] helper sent: \(m.helpers[0].title)")

        // 2. A long reply while it works. Watch for anything hidden going into it while it runs.
        let before = m.bubbles.count
        Task {
            await m.send(
                "Without sending any helper, write me a calm story about a lighthouse keeper, about 900 words, in plain paragraphs.")
        }
        await wait(20) { m.thinking }
        var finishedDuringReply = false
        var hiddenDuringReply = 0
        var bubblesDuringReply = Set<Int>()
        var storyWhenNextBegan: String?
        while m.thinking {
            // The "by the way" turn can begin within a moment of the story ending; note the story as it was then.
            if m.bubbles.count > before + 2 {
                storyWhenNextBegan = m.bubbles[before + 1].text
                break
            }
            if m.helpers.first(where: { $0.id == id })?.state != "working" && !finishedDuringReply {
                finishedDuringReply = true
                print("   [\(at())] helper finished while the story was still being written")
            }
            hiddenDuringReply = max(hiddenDuringReply, m.followUps.filter(\.hidden).count)
            bubblesDuringReply.insert(m.bubbles.count)
            try? await Task.sleep(for: .milliseconds(200))
        }
        print("   [\(at())] story finished")
        let storyIdx = before + 1
        let story = storyIdx < m.bubbles.count ? m.bubbles[storyIdx].text : ""
        check("the helper finished during the story (so this proves the wait)", finishedDuringReply)
        check("nothing hidden went into the story while it ran", hiddenDuringReply == 0)
        print("   messages on screen during the story: \(bubblesDuringReply.sorted().map { $0 - before }) (from \(before))")
        check("no extra reply started during the story", (bubblesDuringReply.max() ?? 0) <= before + 2)
        await wait(90) { !m.thinking || m.bubbles.count > before + 2 }
        if storyWhenNextBegan == nil, m.bubbles.count > before + 2 { storyWhenNextBegan = m.bubbles[before + 1].text }
        check("the next reply began only after the story was complete", storyWhenNextBegan == nil || storyWhenNextBegan == m.bubbles[before + 1].text)
        check("the story wasn't cut off (long, ends cleanly)", story.split(separator: " ").count > 500)
        check("the story doesn't carry the helper's result", !story.contains("4817"))

        // 3. After the story: one "by the way" line, no result, no question.
        await wait(30) { m.bubbles.count > before + 2 }
        await wait(90) { !m.thinking && m.bubbles.count > before + 2 }
        try? await Task.sleep(for: .seconds(2))
        let after = m.bubbles.dropFirst(before + 2).filter { !$0.fromMe }.map(\.text)
        print("   [\(at())] after the story: \(after.map { $0.replacingOccurrences(of: "\n", with: " ") })")
        check("exactly one line came after the story", after.count == 1)
        let line = after.first ?? ""
        check("it's a by-the-way line naming the helper", line.lowercased().contains("by the way") && line.contains("Magic Number"))
        check("it doesn't repeat the result", !line.contains("4817"))
        check("it doesn't ask the helper's question", !line.contains("another one") && Choices.split(line).choices.isEmpty)
        check("no hidden prompt shown as a message from Omar", m.bubbles.filter(\.fromMe).count == 2)

        // 4. Its orb: orange until opened, then the check mark; and it can be talked to there.
        let h = m.helpers.first { $0.id == id }
        print("   helper state: \(h?.state ?? "?"), seen: \(String(describing: h?.seen)), shown as \(String(describing: h?.viewState))")
        check("its orb is orange (same as needs your yes) while not opened", h?.viewState == .needsYes && h?.seen == false)
        check("it holds the result", h?.reply.contains("4817") == true)
        let saved = (try? JSONDecoder().decode([Helper].self, from: UserDefaults.standard.data(forKey: "helpers") ?? Data())) ?? []
        check("not opened is saved (survives a restart)", saved.first { $0.id == id }?.seen == false)
        m.focusHelper(id)
        let opened = m.helpers.first { $0.id == id }
        check("opened: the check mark, if it was done", opened?.seen == true && (opened?.state != "done" || opened?.viewState == .done))
        let saved2 = (try? JSONDecoder().decode([Helper].self, from: UserDefaults.standard.data(forKey: "helpers") ?? Data())) ?? []
        check("opened is saved too", saved2.first { $0.id == id }?.seen == true)
        let chats = m.bubbles.count
        await m.send("What was the number again? Reply with only the number.")
        await wait(90) { m.helpers.first { $0.id == id }?.state != "working" }
        check("talking to it there goes to the helper", m.helpers.first { $0.id == id }?.reply.contains("4817") == true)
        check("and not into the main chat", m.bubbles.count == chats)
        try? await Task.sleep(for: .seconds(3))
        check("no by-the-way for a helper they're looking at", m.bubbles.count == chats && !m.thinking)
        m.openHelper = nil

        // 5. A good morning: one combined report once both helpers are back, no by-the-way lines.
        print("2. good morning with two helpers")
        m.helpers = []
        let gm = m.bubbles.count
        await m.send(
            "Good morning! Send exactly two helpers. Helper Weather: run `sleep 5` in the terminal, then reply with only: Weather: sunny, 21C. "
                + "Helper Calendar: run `sleep 20` in the terminal, then reply with only: Calendar: dentist at 3pm.")
        await wait(120) { !m.thinking }
        check("two helpers went out together", m.helpers.count == 2 && Set(m.helpers.compactMap(\.routine)).count == 1)
        await wait(180) { m.helpers.allSatisfy { $0.state != "working" } }
        print("   [\(at())] both helpers back")
        await wait(30) { m.bubbles.count > gm + 2 }
        await wait(120) { !m.thinking }
        try? await Task.sleep(for: .seconds(3))
        let report = m.bubbles.dropFirst(gm + 2).filter { !$0.fromMe }.map(\.text)
        print("   report: \(report.map { $0.replacingOccurrences(of: "\n", with: " ").prefix(300) })")
        check("one combined report", report.count == 1)
        let r = report.joined(separator: " ").lowercased()
        check("with both results", r.contains("sunny") && r.contains("dentist"))
        check("no by-the-way line for a routine", !r.contains("by the way"))
        check("routine helpers show the check mark", m.helpers.allSatisfy { $0.state != "done" || $0.viewState == .done })

        let previous = Engine.shared.enginePID
        Engine.shared.stop()
        Engine.stopStrayGateway(previousEngine: previous, caller: "test-helper-done")
        print(fails == 0 ? "PASS finished helpers" : "FAIL finished helpers (\(fails))")
        return fails == 0 ? 0 : 1
    }
}
