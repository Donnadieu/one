import AppKit
import Foundation

/// `One --test-link-guard` and `One --test-rooms-privacy` (preflight, CI only; ONE_SUPPORT_DIR and ONE_CLOUD_DIR set
/// to empty folders), and `One --render-share-rooms <prefix>` (a test copy with ONE_SUPPORT_DIR: the share-a-room
/// pop-up over a scratch brain that has a private Nyx room, which must not be listed). Never the real brain.
enum StorageCheck {
    static func main(_ args: [String]) {
        if args.contains("--test-link-guard") {
            TestWorld.enter()  // scratch One folder and brain; run with ONE_SUPPORT_DIR set to an empty folder
            exit(linkGuard())
        }
        if args.contains("--test-rooms-privacy") {
            TestWorld.enter()  // scratch brain; run with ONE_SUPPORT_DIR and ONE_CLOUD_DIR set to empty folders
            exit(RoomsPrivacyCheck.run())
        }
        if let k = args.firstIndex(of: "--render-share-rooms"), k + 1 < args.count {
            guard TestWorld.enterRender() else { exit(2) }
            UserDefaults.standard.set([String](), forKey: "sharedRooms")
            plant(Brain.root)
            MainActor.assumeIsolated { _ = PopupRender.draw("popup-share", args[k + 1]) }
            print("wrote \(args[k + 1])-popup-share.png (rooms: \(RoomMap.roomFolders().map(\.lastPathComponent).joined(separator: ", ")))")
            exit(0)
        }
    }

    static func write(_ text: String, _ u: URL) {
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: u, atomically: true, encoding: .utf8)
    }
    static func exists(_ p: String) -> Bool {
        var st = stat()
        return lstat(p, &st) == 0
    }

    /// personal-room (no room.yaml), nyx-room (`private: true`), work-room (`private: false`), as in the spec.
    static func plant(_ brain: URL) {
        write(
            "# Brain\n\n| Room | Folder | Acts as | Hub file | Holds | Never holds |\n|---|---|---|---|---|---|\n"
                + "| Personal Room | `personal-room/` | Hestia | `brain/life.md` | life | work |\n"
                + "| Work Room | `work-room/` | Ajax | `brain/jobs.md` | jobs | code |\n| Nyx | `nyx-room/` | Nyx | `brain/nyx.md` | feelings | rest |\n",
            brain.appendingPathComponent("AGENTS.md"))
        for r in ["personal-room", "nyx-room", "work-room"] {
            write("# \(r)\n\n## Private things\n\nother people's private information\n", brain.appendingPathComponent("\(r)/AGENTS.md"))
        }
        write(RoomYaml(title: "Nyx", ai: "Nyx", isPrivate: true).text, brain.appendingPathComponent("nyx-room/room.yaml"))
        write(RoomYaml(title: "Work Room", ai: "Ajax", isPrivate: false).text, brain.appendingPathComponent("work-room/room.yaml"))
    }

    // MARK: Shortcut guard

    static func linkGuard() -> Int32 {
        var fails = 0
        func check(_ name: String, _ ok: Bool) {
            print("  \(ok ? "✓" : "✗") \(name)")
            if !ok { fails += 1 }
        }
        guard ProcessInfo.processInfo.environment["ONE_SUPPORT_DIR"] != nil else {
            print("refusing: set ONE_SUPPORT_DIR to an empty folder")
            return 2
        }
        let fm = FileManager.default
        let home = Env.hermesHome
        let brain = Brain.root
        let skills = home.appendingPathComponent("skills", isDirectory: true)
        let skill = skills.appendingPathComponent("tea-timer/SKILL.md")
        write("---\nname: tea-timer\n---\n", skill)
        write("# Brain\n", brain.appendingPathComponent("AGENTS.md"))
        let notes = brain.appendingPathComponent("work-room/notes", isDirectory: true)
        write("# Today\n", notes.appendingPathComponent("today.md"))
        let elsewhere = Env.support.appendingPathComponent("elsewhere", isDirectory: true)
        write("# Kept\n", elsewhere.appendingPathComponent("kept.md"))

        // The three from Nov 4: a folder link to the folder it's in, one to a folder further up, a file pointing at itself.
        let selfLoop = skills.appendingPathComponent("skills").path
        let parentLoop = notes.appendingPathComponent("up").path
        let fileLoop = home.appendingPathComponent("google_client_secret.json").path
        try? fm.createSymbolicLink(atPath: selfLoop, withDestinationPath: skills.path)
        try? fm.createSymbolicLink(atPath: parentLoop, withDestinationPath: "../..")
        try? fm.createSymbolicLink(atPath: fileLoop, withDestinationPath: fileLoop)
        // Harmless: a folder link and a file link to somewhere else.
        let fine = skills.appendingPathComponent("linked").path
        let fineFile = brain.appendingPathComponent("work-room/kept.md").path
        try? fm.createSymbolicLink(atPath: fine, withDestinationPath: elsewhere.path)
        try? fm.createSymbolicLink(atPath: fineFile, withDestinationPath: "../../elsewhere/kept.md")
        let bad = Set([selfLoop, parentLoop, fileLoop])
        check("all five links planted", [selfLoop, parentLoop, fileLoop, fine, fineFile].allSatisfy(exists))

        let dry = LinkGuard.run(roots: [home, brain], dryRun: true)
        check("a dry run finds exactly the three loops", Set(dry.map(\.path)) == bad && dry.count == 3)
        check("a dry run removes nothing and logs nothing", bad.allSatisfy(exists) && !fm.fileExists(atPath: LinkGuard.logFile.path))

        let found = LinkGuard.run(roots: [home, brain])
        check("the guard removes the three loops", Set(found.map(\.path)) == bad && !bad.contains(where: exists))
        check(
            "links to somewhere else stay, pointing where they did",
            (try? fm.destinationOfSymbolicLink(atPath: fine)) == elsewhere.path
                && (try? fm.destinationOfSymbolicLink(atPath: fineFile)) == "../../elsewhere/kept.md")
        check(
            "what they point to is untouched",
            fm.fileExists(atPath: elsewhere.appendingPathComponent("kept.md").path) && fm.fileExists(atPath: skill.path))
        let log = ((try? String(contentsOf: LinkGuard.logFile, encoding: .utf8)) ?? "").split(separator: "\n")
        check("the log has 3 lines", log.count == 3)
        check(
            "each line says what, where it pointed and when", log.allSatisfy { $0.hasPrefix("20") && $0.contains("removed ") && $0.contains(" -> ") })
        check(
            "the file that pointed to itself is logged with a warning",
            log.contains { $0.contains("google_client_secret.json") && $0.contains("Warning:") })
        check("a second run finds nothing", LinkGuard.run(roots: [home, brain]).isEmpty)

        // The engine's two skill walks.
        let loop = SkillWalkFix.targets[0].1
        let py = "import os\n\ndef f(skills_dir):\n    \(loop)\n        pass\n"
        let once = SkillWalkFix.patch(py, loop: loop)
        check("the skill walk patch applies", once?.contains("_one_seen.add(_one_real)") == true)
        check("applying it again changes nothing", once.flatMap { SkillWalkFix.patch($0, loop: loop) } == once)
        check("an engine whose walk changed is left alone", SkillWalkFix.patch("def other():\n    pass\n", loop: loop) == nil)
        write("def other():\n    pass\n", Env.engineDir.appendingPathComponent("agent/skill_utils.py"))
        let r = SkillWalkFix.apply()
        let after = (try? String(contentsOf: Env.engineDir.appendingPathComponent("agent/skill_utils.py"), encoding: .utf8)) ?? ""
        check(
            "…and that's logged, never written",
            r.first?.contains("left as is") == true && after == "def other():\n    pass\n"
                && ((try? String(contentsOf: LinkGuard.logFile, encoding: .utf8)) ?? "").contains("skill walk"))

        print(fails == 0 ? "link guard ok" : "link guard failed: \(fails)")
        return fails == 0 ? 0 : 1
    }
}
