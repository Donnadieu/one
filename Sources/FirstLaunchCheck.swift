import Foundation

/// `One --test-first-launch` (CI only, the fresh-install workflow, after `--install-test` put an engine into the same
/// empty ONE_SUPPORT_DIR): what a brand-new person gets with no questions asked and no git (storage design 3c).
/// Runs the same steps One's first launch runs, in order, on an empty test brain, then checks each item:
/// the brain with `assistant/` and a `room.yaml` per room, One's own recipes in the engine, a search index,
/// the first instant copy, the "Nightly review" routine at 3:30 AM, the front page, the shortcut guard, and the
/// locked iCloud copy NOT switched on. `ONE_GIT_LOG` names the file a stand-in `git` writes to: it must stay empty
/// until the engine steps begin.
enum FirstLaunchCheck {
    /// From `main()`, before any window (StorageCLI.swift).
    static func main(_ args: [String]) {
        guard args.contains("--test-first-launch") else { return }
        TestWorld.enter()  // scratch One folder (ONE_SUPPORT_DIR), own settings; CI only
        Entry.runHeadless { exit(await run()) }
    }

    static func run() async -> Int32 {
        var fails = 0
        func check(_ name: String, _ ok: Bool) {
            print((ok ? "  ✓ " : "  ✗ ") + name)
            if !ok { fails += 1 }
        }
        let fm = FileManager.default
        let gitLog = ProcessInfo.processInfo.environment["ONE_GIT_LOG"].map { URL(fileURLWithPath: $0) }
        try? fm.removeItem(at: Brain.root)
        check("the test brain starts empty", !Brain.exists)

        // What first launch does, in order: setup builds the brain, then (before the engine starts) the guard,
        // the front page, One's recipes; in the background the index and the first copy.
        let built = Brain.build(owner: "Sam", ai: "Nova", rooms: [.work])
        let loop = Env.hermesHome.appendingPathComponent("skills/skills")
        try? fm.createDirectory(at: loop.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.createSymbolicLink(atPath: loop.path, withDestinationPath: loop.deletingLastPathComponent().path)
        await LinkGuard.atLaunch()
        Persona.write(assistant: "Nova", user: "Sam", connections: [], passwords: "ask each time")
        FrontPage.atLaunch()
        BundledSkills.sync()
        for r in BrainRooms.all() { BrainIndex.refresh(r) }
        let copy = History.take()
        let brainSteps = gitLog.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""

        // 1. The brain.
        check("the brain is built from the starter with no questions", built == nil && Brain.exists)
        let a = Brain.root.appendingPathComponent("assistant")
        check(
            "assistant/ with its notes and an empty recipes folder",
            ["how-to-work-with-me.md", "this-mac.md", "notes", "skills", "routines.md"].allSatisfy {
                fm.fileExists(atPath: a.appendingPathComponent($0).path)
            })
        let personal = Brain.root.appendingPathComponent("personal-room")
        let work = Brain.root.appendingPathComponent("work-room")
        check("personal room: room.yaml says private", RoomYaml.read(personal)?.isPrivate == true)
        check("work room: room.yaml says not private", RoomYaml.read(work)?.isPrivate == false)
        // 2. One's own recipes in the engine.
        let bundled = BundledSkills.source.map { BundledSkills.list(in: $0) } ?? []
        check(
            "One's own recipes are in the engine (\(bundled.count) files)",
            !bundled.isEmpty && bundled.allSatisfy { fm.fileExists(atPath: BundledSkills.target.appendingPathComponent($0).path) })
        // 3. The search index.
        let idx = Env.support.appendingPathComponent("index")
        let dbs = ((try? fm.contentsOfDirectory(atPath: idx.path)) ?? []).filter { $0.hasSuffix(".sqlite") }
        check(
            "a search index per room (\(dbs.sorted().joined(separator: ", ")))",
            dbs.contains("personal-room.sqlite") && dbs.contains("work-room.sqlite"))
        // 4. The first instant copy.
        if case .success(let t) = copy {
            check("the first instant copy of the brain", fm.fileExists(atPath: t.url.appendingPathComponent("snapshot.json").path))
        } else {
            check("the first instant copy of the brain", false)
        }
        // 5. The front page.
        let mem = Env.hermesHome.appendingPathComponent("memories")
        let user = (try? String(contentsOf: mem.appendingPathComponent("USER.md"), encoding: .utf8)) ?? ""
        check("USER.md written (name, assistant)", user.contains("Sam") && user.contains("Nova"))
        check("MEMORY.md built from assistant/this-mac.md", fm.fileExists(atPath: mem.appendingPathComponent("MEMORY.md").path))
        // 6. The shortcut guard.
        check("a shortcut pointing at its own folder is removed at launch", (try? fm.destinationOfSymbolicLink(atPath: loop.path)) == nil)
        // 7. The locked iCloud copy is off until they say yes.
        check("the locked iCloud copy is NOT on by itself", !Offsite.on)
        check("nothing was put in iCloud", !fm.fileExists(atPath: Offsite.folder.path))
        // 8. No git so far.
        check("no git was needed for any of this", gitLog == nil || brainSteps.isEmpty)
        if !brainSteps.isEmpty { print("    git was called: \(brainSteps.prefix(300))") }

        // 9. The engine steps: the learning cap and the nightly review routine, through the freshly installed engine.
        if let gitLog { try? "--- engine steps (the engine itself may use git) ---\n".write(to: gitLog, atomically: true, encoding: .utf8) }
        await LearningCap.sync()
        let made = await NightlyRoutine.ensure()
        let job = NightlyRoutine.jobs().first { ($0["name"] as? String) == NightlyRoutine.name }
        let expr = (job?["schedule"] as? [String: Any])?["expr"] as? String
        check("the Nightly review routine is made (\(made))", job != nil && made == "made")
        check("it runs at 3:30 AM every night (\(expr ?? "no schedule"))", expr == NightlyRoutine.schedule)
        check(
            "its pre-run script is in place",
            (job?["script"] as? String) == NightlyRoutine.scriptName && fm.isExecutableFile(atPath: NightlyRoutine.scriptFile.path))
        check("its first week is suggestions only", Improve.settings().mode == "suggest")
        check("a second launch doesn't make a second one", await NightlyRoutine.ensure() == "already there")
        let cfg = (try? String(contentsOf: Env.hermesHome.appendingPathComponent("config.yaml"), encoding: .utf8)) ?? ""
        check(
            "the engine's learning cap is installed and on",
            fm.fileExists(atPath: LearningCap.pluginDir.appendingPathComponent("__init__.py").path)
                && BrowserGuard.enabledPlugins(cfg).contains(LearningCap.plugin))

        print(fails == 0 ? "first launch ok" : "first launch failed: \(fails)")
        return fails == 0 ? 0 : 1
    }
}
