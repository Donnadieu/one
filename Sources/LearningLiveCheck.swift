import Foundation

/// `One --test-learning-live` (tools/learning-check.sh, `make learning`): "tell me when I learn" end to end with One's
/// real engine in the throwaway home, driven through the same `Model.send` and choice taps the window uses.
/// A: a new skill saved in the main chat → one line with Undo after the reply; Undo removes it and the running engine
/// can't open it any more. B: a fix to a skill → nothing said. C: a long job with nothing saved → asked once after the
/// window, never during the job; No → never again for that kind; Yes → saved into the room, card, Undo to the Trash.
/// Helper: a helper's new skill → its own line + Undo, and one line in the main chat.
/// The background review is turned off in the throwaway home so each case is decided by the job alone.
/// The script shortens the review window (ONE_LEARN_WINDOW); the real one is 2 minutes. Costs several short Claude turns.
enum LearningLiveCheck {
    @MainActor
    static func run() async -> Int32 {
        var fails = 0
        func check(_ name: String, _ ok: Bool) {
            print("  \(ok ? "✓" : "✗") \(name)")
            fflush(stdout)
            if !ok { fails += 1 }
        }
        guard Env.selfTest, Bundle.main.bundleIdentifier != "ai.forjado.one", Env.hermesHome.path.contains("selftest-hermes") else {
            print("refusing: run tools/learning-check.sh (a copy with its own settings, throwaway home)")
            return 2
        }
        let fm = FileManager.default
        let real = Env.support.appendingPathComponent("hermes/auth.json")
        let dst = Env.hermesHome.appendingPathComponent("auth.json")
        try? fm.removeItem(at: dst)
        try? fm.copyItem(at: real, to: dst)
        let tools = Env.hermesHome.appendingPathComponent("tools")
        if (try? fm.destinationOfSymbolicLink(atPath: tools.path)) == nil {
            try? fm.removeItem(at: tools)
            try? fm.createSymbolicLink(at: tools, withDestinationURL: Env.support.appendingPathComponent("hermes/tools"))
        }
        await SignIn.makeDefault(.claude, model: Provider.claude.tiers[1].1)
        _ = await hermesRun(["config", "set", "auth.adopt_external_logins", "false"])
        _ = await hermesRun(["config", "set", "skills.creation_nudge_interval", "0"])  // no background review: each case is the job's own doing
        let skills = Env.hermesHome.appendingPathComponent("skills")
        for n in ["testing", "learned"] { try? fm.removeItem(at: skills.appendingPathComponent(n)) }
        try? fm.removeItem(at: Learning.file)
        try? fm.removeItem(at: Learning.ledger)  // a fresh home: the very first log line must count
        _ = await hermesRun(["config", "set", "skills.external_dirs", "[]", "--force"])
        try? fm.removeItem(at: Brain.root)
        _ = Brain.build(owner: "Omar", ai: "Ava", rooms: [.personal])
        Access.override = []
        Persona.write(assistant: "Ava", user: "Omar", connections: [], passwords: "ask each time")
        await LearnedDirs.sync()
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
        m.learning = Learning.load()
        let window = Double(ProcessInfo.processInfo.environment["ONE_LEARN_WINDOW"] ?? "120") ?? 120
        Task { @MainActor in
            while true {
                m.tendLearning()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        func wait(_ s: Double, until: () -> Bool) async {
            let end = Date().addingTimeInterval(s)
            while Date() < end, !until() { try? await Task.sleep(for: .milliseconds(300)) }
        }
        func turn(_ text: String) async -> String {
            await m.send(text)
            await wait(400) { !m.thinking }
            try? await Task.sleep(for: .seconds(1))
            return m.bubbles.last?.text ?? ""
        }
        func ledger() -> [LedgerLine] { Learning.readLedger(force: true) ?? [] }
        let me = "Do this yourself, right here, never with a helper. "

        // A
        print("A. a new skill saved in the main chat")
        let tea = skills.appendingPathComponent("testing/zz-tea-timer/SKILL.md")
        var r = await turn(
            me + "Use the skill_manage tool to create a new skill named zz-tea-timer in category testing. Its SKILL.md: front matter "
                + "with name: zz-tea-timer and description: Use when timing a cup of tea., then one line: Steep green tea 2 minutes. Then reply with just: Saved."
        )
        print("   reply: \(r.replacingOccurrences(of: "\n", with: " ").prefix(160))")
        check(
            "the engine saved it (its file and a create line in the log)",
            fm.fileExists(atPath: tea.path)
                && ledger().contains { $0.action == "create" && $0.skill == "zz-tea-timer" && $0.session == Engine.shared.mainSession })
        await wait(30) { m.bubbles.last?.text.contains(Learning.learnedLine) == true }
        r = m.bubbles.last?.text ?? ""
        check("one line after the reply: \"\(Learning.learnedLine)\"", r.components(separatedBy: Learning.learnedLine).count == 2)
        check("it goes under the job's own reply, not a new message", m.bubbles.filter { !$0.fromMe }.count == 1)
        check("with an Undo tap", Choices.split(r).choices == [Learning.undo])
        check("the first time, a skill is explained in plain words", r.contains(Learning.explain))
        check("no tag shows", !r.contains("[job-kind") && !r.contains("[learned"))
        check("a Learned card on Ready for you", m.shelf.contains { $0.title == "Learned: Zz tea timer" && $0.path == tea.path })
        var handled = await m.learnPick(Learning.undo)
        await wait(30) { m.bubbles.last?.text.contains(Learning.forgot) == true }
        check("Undo is One's own (never sent to the assistant)", handled && m.bubbles.filter(\.fromMe).count == 1)
        check(
            "Undo: the line says \"\(Learning.forgot)\" and the tap is gone",
            (m.bubbles.last?.text ?? "").contains(Learning.forgot)
                && Choices.split(m.bubbles.last?.text ?? "").choices.isEmpty)
        check("Undo: the skill's files are gone", !fm.fileExists(atPath: tea.path) && !fm.fileExists(atPath: tea.deletingLastPathComponent().path))
        check(
            "Undo: through the engine's own rollback (safety copy kept)",
            ledger().contains { $0.action == "rollback" && $0.skill == "zz-tea-timer" }
                && ledger().contains { $0.action == "pre-rollback" && $0.skill == "zz-tea-timer" })
        check("Undo: the card is gone", !m.shelf.contains { $0.title.hasPrefix("Learned: Zz tea") })
        r = await turn(
            me + "Use the skill_view tool to open the skill named zz-tea-timer. Reply with exactly EXISTS if it opened, or GONE if it isn't there.")
        print("   reply: \(r.replacingOccurrences(of: "\n", with: " ").prefix(160))")
        check("the running engine can't open it any more (no restart needed)", r.uppercased().contains("GONE") && !r.uppercased().contains("EXISTS"))

        // B
        print("B. a fix to an existing skill")
        let notes = skills.appendingPathComponent("testing/zz-notes/SKILL.md")
        try? fm.createDirectory(at: notes.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "---\nname: zz-notes\ndescription: Use when writing test notes.\n---\n\nThis is version one.\n".write(
            to: notes, atomically: true, encoding: .utf8)
        r = await turn(
            me
                + "Use the skill_manage tool with action patch on the skill zz-notes: replace the text 'version one' with 'version two'. Reply with just: Patched."
        )
        let before = r
        print("   reply: \(r.replacingOccurrences(of: "\n", with: " ").prefix(160))")
        check("the engine patched it (a patch line in the log)", ledger().contains { $0.action == "patch" && $0.skill == "zz-notes" })
        try? await Task.sleep(for: .seconds(window + 8))
        check(
            "nothing said in the chat, before or after the window",
            m.bubbles.last?.text == before && !before.contains(Learning.learnedLine)
                && !before.contains(Learning.askLine))
        check("no Undo or question waiting", m.learning.offers.isEmpty)

        // C
        print("C. a long job with nothing saved")
        let count =
            me
            + "Don't save or change any skill. Run 16 separate terminal commands, one per tool call: echo step 1, echo step 2, and so on up to echo step 16. "
            + "Then reply with just: Counted."
        r = await turn(count)
        print("   reply: \(r.replacingOccurrences(of: "\n", with: " ").prefix(160))")
        let job = m.learning.jobs.last
        print("   job: kind \"\(job?.kind ?? "")\", \(job?.steps ?? 0) steps")
        check("its steps were counted (15 or more)", (job?.steps ?? 0) >= 15)
        try? await Task.sleep(for: .seconds(3))
        check("never asked right as the job ends", !(m.bubbles.last?.text ?? "").contains(Learning.askLine))
        await wait(window + 25) { m.bubbles.last?.text.contains(Learning.askLine) == true }
        r = m.bubbles.last?.text ?? ""
        check("asked once after the window: \"Want me to remember how I did this?…\"", r.components(separatedBy: Learning.askLine).count == 2)
        check("with Yes, remember it | No thanks", Choices.split(r).choices == [Learning.yes, Learning.no])
        handled = await m.learnPick(Learning.no)
        check("No: answered by One, the kind is remembered", handled && m.learning.declinedKinds.contains { $0.kind == job?.kind })
        check(
            "No: the memory note says so",
            (try? String(contentsOf: Env.hermesHome.appendingPathComponent("memories/USER.md"), encoding: .utf8))?
                .contains("Don't save recipes") == true)
        r = await turn(count)
        try? await Task.sleep(for: .seconds(window + 12))
        check("the same kind of job again: no question", !(m.bubbles.last?.text ?? "").contains(Learning.askLine))

        print("C. Yes: saved into the room")
        r = await turn(
            me + "Don't save or change any skill. In the folder \(Brain.root.path)/personal-room/notes/tea (make it), write 16 small files "
                + "tea-1.md to tea-16.md, one write_file call per file, each with one line about a kind of tea. Then reply with just: Written.")
        print("   reply: \(r.replacingOccurrences(of: "\n", with: " ").prefix(160)) (kind \"\(m.learning.jobs.last?.kind ?? "")\")")
        await wait(window + 25) { m.bubbles.last?.text.contains(Learning.askLine) == true }
        check("asked about this other kind of job", (m.bubbles.last?.text ?? "").contains(Learning.askLine))
        handled = await m.learnPick(Learning.yes)
        await wait(10) { m.thinking }
        await wait(300) { !m.thinking && m.learnSaving == nil }
        try? await Task.sleep(for: .seconds(2))
        r = m.bubbles.last?.text ?? ""
        print("   reply: \(r.replacingOccurrences(of: "\n", with: " ").prefix(200))")
        let learnedDir = Brain.root.appendingPathComponent("personal-room/skills/learned")
        let saved = (try? fm.contentsOfDirectory(atPath: learnedDir.path))?.filter { !$0.hasPrefix(".") } ?? []
        let skillMD = saved.first.map { learnedDir.appendingPathComponent("\($0)/SKILL.md") }
        check(
            "saved into the personal room: \(saved.joined(separator: ", "))",
            saved.count == 1 && skillMD.map { fm.fileExists(atPath: $0.path) } == true)
        check("a Learned card that opens the recipe", m.shelf.contains { $0.title.hasPrefix("Learned: ") && $0.path == skillMD?.path })
        check("no tag shows, Undo offered", !r.contains("[learned") && Choices.split(r).choices == [Learning.undo])
        let (_, dirs) = await hermesRun(["config", "get", "skills.external_dirs"])
        check("the room's learned folder counts as skills for the engine", LearnedDirs.parseList(dirs).contains(learnedDir.path))
        if let name = saved.first {
            let (_, list) = await hermesRun(["skills", "list"])
            check("the engine lists it (`hermes skills list`)", list.contains(name))
        }
        handled = await m.learnPick(Learning.undo)
        await wait(10) { m.bubbles.last?.text.contains(Learning.forgot) == true }
        check(
            "Undo: a room skill goes to the Trash (or One's forgotten folder if the Trash is closed)",
            handled && skillMD.map { !fm.fileExists(atPath: $0.path) } == true
                && (m.bubbles.last?.text ?? "").contains(Learning.forgot))

        // Helper
        print("Helper: a new skill saved by a helper")
        let htea = skills.appendingPathComponent("testing/zz-helper-tea/SKILL.md")
        let mainBefore = m.bubbles.count
        m.spawnHelper(
            title: "Tea notes",
            task: "Use the skill_manage tool to create a new skill named zz-helper-tea in category testing. Its SKILL.md: front matter with "
                + "name: zz-helper-tea and description: Use when brewing black tea., then one line: Steep 4 minutes. Then reply with just: Saved.")
        await wait(240) { m.helpers.first?.state == "done" || m.helpers.first?.state == "needsYes" }
        await wait(30) { m.helpers.first?.reply.contains(Learning.learnedLine) == true }
        let h = m.helpers.first
        print("   helper: \(h?.reply.replacingOccurrences(of: "\n", with: " ").prefix(200) ?? "none")")
        check(
            "the line goes in the helper's own conversation, with Undo",
            h?.reply.contains(Learning.learnedLine) == true
                && Choices.split(h?.reply ?? "").choices == [Learning.undo])
        await wait(30) { m.bubbles.contains { $0.text.contains("Tea notes learned how to do this") } }
        check("one line in the main chat, never more", m.bubbles.filter { $0.text.contains("Tea notes learned how to do this") }.count == 1)
        check("the main chat never got the Undo or the full line", !m.bubbles.dropFirst(mainBefore).contains { $0.text.contains("[choices: Undo]") })
        if let h { m.openHelper = h.id }
        handled = await m.learnPick(Learning.undo)
        check(
            "Undo in the helper removes it", handled && !fm.fileExists(atPath: htea.path) && m.helpers.first?.reply.contains(Learning.forgot) == true)
        m.openHelper = nil

        let previous = Engine.shared.enginePID
        Engine.shared.stop()
        Engine.stopStrayGateway(previousEngine: previous, caller: "test-learning-live")
        print(fails == 0 ? "PASS tell me when I learn" : "FAIL tell me when I learn (\(fails))")
        return fails == 0 ? 0 : 1
    }
}
