import Foundation

/// `One --test-helper-work` (preflight, from a test copy, ONE_SUPPORT_DIR set to an empty folder): the four Nov 4 2026
/// helper features. Look-only helpers are marked for the engine's guard and lifted only by the person; a helper whose
/// repo another helper is working in gets its own git worktree, removed afterwards (unsaved work kept); a new helper
/// is told about today's related results; long turns aren't cut off while they still do something, a saved
/// conversation is waited for through a slow restart, and restarts wait for helpers to finish their current step.
/// The engine side of look-only is checked on real commands by tools/look-only-check.py.
enum HelperWorkCheck {
    static func launch() -> Bool {
        guard CommandLine.arguments.contains("--test-helper-work") else { return false }
        TestWorld.enter()  // scratch One folder, in-memory helpers, a throwaway git repo inside it
        Task { @MainActor in exit(await run()) }
        return true
    }

    @MainActor
    static func run() async -> Int32 {
        var fails = 0
        func check(_ name: String, _ ok: Bool, _ got: String = "") {
            print("  \(ok ? "✓" : "✗") \(name)\(ok || got.isEmpty ? "" : "  (got: \(got))")")
            fflush(stdout)
            if !ok { fails += 1 }
        }
        let m = Model.shared
        m.helpers = []

        print("1. look-only helpers")
        check("\"Look only:\" marks a job", LookOnly.marked("Look only: see why last night's build failed and report back."))
        check(
            "so do \"look-only —\" and \"(Look only) -\"",
            LookOnly.marked("look-only — check the loop") && LookOnly.marked("(Look only) - read the logs"))
        check(
            "a build job that says \"don't push during the wait\" is not look-only",
            !LookOnly.marked("Build it. Don't commit, push or tag during that wait. Change nothing else."))
        check("\"look at the logs only\" is not the tag", !LookOnly.marked("Look at the logs only"))
        let sid = "local-test-look-\(getpid())"
        LookOnly.mark(sid, title: "Check Forge compound loop")
        check("the mark is a file in One's guard folder", FileManager.default.fileExists(atPath: LookOnly.dir.path + "/\(sid).json"))
        check("the engine can't write that folder (folder lock)", BrowserGuard.lockedPaths.contains(LookOnly.dir.path))
        check(
            "the main assistant is told how (SOUL and every prompt)",
            Persona.soul(assistant: "Ava", user: "Sam").contains("Look only:") && Helpers.note.contains("Look only:"))
        LookOnly.lift(sid)
        check("lifting removes it", !LookOnly.isMarked(sid))

        var h = Helper(title: "Check loop", task: "Look only: check the loop", sid: "local-look-a", state: "working", line: "")
        h.lookOnly = true
        m.helpers = [h]
        m.syncLookOnly(h.id)
        check("a look-only helper's conversation gets its mark on each turn", LookOnly.isMarked("local-look-a"))
        m.update(h.id) { $0.sid = "local-look-b" }  // started again: a new conversation
        m.syncLookOnly(h.id)
        check("…its new conversation too", LookOnly.isMarked("local-look-b"))
        m.liftLookOnly(h.id)
        check(
            "their own message in its thread lifts it", !LookOnly.isMarked("local-look-b") && m.helpers.first?.lookOnly == false)
        let notes = await m.helperStartNotes(h.id, title: "Check loop", task: "Look only: check the loop")
        check(
            "a new look-only helper is told what it can't do and to ask instead",
            notes.contains("LOOK ONLY") && notes.contains("[choices: Do it | Not now]"))
        check("…and its steps say so in plain words", m.helpers.first?.trail?.contains(LookOnly.trailLine) == true)
        m.helpers = []

        print("2. each helper gets its own copy of a repo")
        let repo = Env.support.appendingPathComponent("work/proj").path
        try? FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        for a in [
            ["init", "-q", "-b", "main"], ["config", "user.name", "Test"], ["config", "user.email", "t@example.com"],
            ["config", "commit.gpgsign", "false"],
        ] {
            _ = HelperRepos.run(["-C", repo] + a)
        }
        try? "hi\n".write(toFile: repo + "/README.md", atomically: true, encoding: .utf8)
        _ = HelperRepos.run(["-C", repo, "add", "."])
        let made = HelperRepos.run(["-C", repo, "commit", "-q", "-m", "first"])
        check("a throwaway repo to work on", made.ok, made.err)
        check(
            "a job naming a file in it names the repo", HelperRepos.repos(in: "Fix the typo in \(repo)/README.md.") == [repo],
            "\(HelperRepos.repos(in: "Fix \(repo)/README.md"))")
        check("a quoted path works too", HelperRepos.repos(in: "Repo: \"\(repo)\" (GitHub x/y)") == [repo])
        check("the brain is never copied", !HelperRepos.allowed(Brain.root.path + "/personal-room"))
        check("nor One's own data outside work/", !HelperRepos.allowed(Env.support.path + "/hermes"))

        var a = Helper(title: "Forge triage moves", task: "Move cards in \(repo).", sid: "s-a", state: "working", line: "")
        a.repos = [repo]
        let b = Helper(title: "README fix", task: "Fix \(repo)/README.md", sid: "s-b", state: "working", line: "")
        m.helpers = [a, b]
        let nb = await m.helperStartNotes(b.id, title: b.title, task: b.task)
        let copies = HelperRepos.load()
        let copy = copies.first
        check(
            "the second helper gets its own copy",
            copies.count == 1 && copy.map { FileManager.default.fileExists(atPath: $0.path + "/README.md") } == true)
        check(
            "…next to the repo, on its own branch", copy?.path == repo + "-readme-fix" && copy?.branch.hasPrefix("helper/readme-fix-") == true,
            copy?.path ?? "none")
        check("…and is told to work only there", nb.contains("YOUR OWN COPY") && nb.contains("readme-fix") && nb.contains("Forge triage moves"))
        check("…while the first keeps the repo itself", m.helpers.first { $0.id == b.id }?.repos == [])
        let c = Helper(title: "Other repo job", task: "Look at /tmp/nothing-here", sid: "s-c", state: "working", line: "")
        m.helpers.append(c)
        _ = await m.helperStartNotes(c.id, title: c.title, task: c.task)
        check("a job no other helper's repo is in gets no copy", HelperRepos.load().count == 1)
        if let copy {
            try? "edit\n".write(toFile: copy.path + "/README.md", atomically: true, encoding: .utf8)
            HelperRepos.release(helper: b.id.uuidString)
            check("a copy with unsaved changes is kept", FileManager.default.fileExists(atPath: copy.path) && HelperRepos.load().count == 1)
            _ = HelperRepos.run(["-C", copy.path, "checkout", "-q", "--", "."])
            HelperRepos.release(helper: b.id.uuidString)
            check(
                "a clean copy is removed when they're done with the helper",
                !FileManager.default.fileExists(atPath: copy.path) && HelperRepos.load().isEmpty)
            check("…with its empty branch", HelperRepos.run(["-C", repo, "branch", "--list", copy.branch]).out?.isEmpty == true)
        }
        let d = Helper(title: "Saver", task: "x", sid: "s-d", state: "working", line: "")
        if let c2 = HelperRepos.make(repo: repo, title: d.title, helper: d.id) {
            try? "saved\n".write(toFile: c2.path + "/NOTE.md", atomically: true, encoding: .utf8)
            _ = HelperRepos.run(["-C", c2.path, "add", "."])
            _ = HelperRepos.run(["-C", c2.path, "commit", "-q", "-m", "saved"])
            HelperRepos.sweep(alive: [])
            check("a helper gone since the last launch: its copy goes at the next start", !FileManager.default.fileExists(atPath: c2.path))
            check("…but work it saved stays on its branch", HelperRepos.run(["-C", repo, "branch", "--list", c2.branch]).out?.isEmpty == false)
        } else {
            check("a second copy can be made", false)
        }
        m.helpers = []

        print("3. helpers see what earlier helpers found")
        let now = Date()
        let dir = Env.support.appendingPathComponent("made")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func item(_ t: String, _ body: String, ago: TimeInterval, from: String? = nil) -> ShelfItem {
            let u = dir.appendingPathComponent("\(t).md")
            try? "# \(t)\n\n\(body)\n".write(to: u, atomically: true, encoding: .utf8)
            return ShelfItem(title: t, detail: body, from: from ?? "\(t) helper", path: u.path, made: now.addingTimeInterval(-ago))
        }
        let readme = item("Fix GitHub README", "Rewrote the README of Donnadieu/one: new intro, install steps, screenshots.", ago: 3 * 3600)
        let quebec = item("Flight to Quebec", "Cheapest flight PHL to YQB is $412.", ago: 3600)
        let old = item("README draft", "An older README draft.", ago: 30 * 3600)
        let mine = item("README notes", "Notes about the README.", ago: 600, from: "Iris")
        let picked = EarlierResults.pick(
            job: "Add project icons to the README of Donnadieu/one.", title: "README project icons", from: [quebec, readme, old, mine], now: now)
        check(
            "the related result from earlier today is picked", picked.map(\.title) == ["Fix GitHub README"],
            picked.map(\.title).joined(separator: ", "))
        check("unrelated, older than a day, or not from a helper: left out", !picked.contains { [quebec.id, old.id, mine.id].contains($0.id) })
        let en = EarlierResults.note(picked)
        check("the note names its title and file", en.contains("\"Fix GitHub README\": \(readme.path)"))
        check(
            "nothing related: no note",
            EarlierResults.pick(job: "Book a table for two", title: "Dinner table", from: [readme, quebec], now: now).isEmpty)
        m.shelf = [readme, quebec]
        let e = Helper(
            title: "README project icons", task: "Add project icons to the README of Donnadieu/one.", sid: "s-e", state: "working", line: "")
        m.helpers = [e]
        let ne = await m.helperStartNotes(e.id, title: e.title, task: e.task)
        check("a new helper's first prompt carries it", ne.contains("EARLIER TODAY") && ne.contains(readme.path))
        m.helpers = []
        m.shelf = []

        print("4. restarts don't cut work off or lose the chat")
        let t0 = Date()
        check(
            "a turn with no sign of life is given up on after its window",
            TurnWait.left(nil, started: t0.addingTimeInterval(-1801), window: 1800, now: t0) <= 0)
        TurnWait.saw("s-long", at: t0.addingTimeInterval(-60))
        check(
            "a helper still doing something at 30 minutes keeps going",
            TurnWait.left("s-long", started: t0.addingTimeInterval(-1900), window: 1800, now: t0) > 1700)
        TurnWait.forget("s-long")
        check(
            "the restart answer that lost the chat on Nov 4 is waited out",
            !Engine.gone("Gateway could not start: Another gateway instance is already running (PID 25647)"))
        check("\"draining\" is waited out too", !Engine.gone("{code = -32603; message = \"Gateway draining: not_ready\"}"))
        check("only \"not found\" means the conversation is gone", Engine.gone("{code = -32603; message = not_found}"))
        check("the wait covers a slow handover (77 s on Nov 4)", Engine.loadPatience >= 180)
        check(
            "a folder restart waits while a helper is mid-step",
            !FolderWatch.due(talking: false, helpersWorking: true, waited: 60, midStep: true))
        check("…and goes once it's between steps", FolderWatch.due(talking: false, helpersWorking: true, waited: 60, midStep: false))
        check(
            "…or after the longest wait, if a step hangs",
            FolderWatch.due(talking: false, helpersWorking: true, waited: FolderWatch.stepWait + 1, midStep: true))
        let w = Helper(title: "Builder", task: "x", sid: "s-w", state: "working", line: "")
        m.helpers = [w]
        m.pulseStart(w.id)
        m.pulse(sid: "s-w", kind: "tool_call", call: "c1", status: nil)
        check("a helper with a command running is mid-step", m.helpersMidStep() == ["Builder"])
        m.pulse(sid: "s-w", kind: "tool_call_update", call: "c1", status: "completed")
        check("…and between steps once it ends", m.helpersMidStep().isEmpty)
        m.helpers = []

        print(fails == 0 ? "helper work ok" : "helper work: \(fails) failed")
        return fails == 0 ? 0 : 1
    }
}
