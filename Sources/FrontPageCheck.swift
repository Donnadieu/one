import Foundation

/// `One --test-front-page` (preflight, CI only): the generated front page (USER.md, MEMORY.md) and the recipe filer,
/// on a scratch engine home and a scratch brain. Run with ONE_SUPPORT_DIR and ONE_CLOUD_DIR set to empty folders.
enum FrontPageCheck {
    static func launch() -> Bool {
        guard CommandLine.arguments.contains("--test-front-page") else { return false }
        TestWorld.enter()  // scratch One folder, brain and engine home; never the person's own
        exit(run())
    }

    static func write(_ t: String, _ u: URL) {
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? t.write(to: u, atomically: true, encoding: .utf8)
    }
    static func read(_ u: URL) -> String { (try? String(contentsOf: u, encoding: .utf8)) ?? "" }

    static func run() -> Int32 {
        guard Env.selfTest, ProcessInfo.processInfo.environment["ONE_SUPPORT_DIR"] != nil else {
            print("refusing: set ONE_SUPPORT_DIR to an empty folder")
            return 2
        }
        var fails = 0
        func check(_ name: String, _ ok: Bool) {
            print("  \(ok ? "✓" : "✗") \(name)")
            if !ok { fails += 1 }
        }
        let fm = FileManager.default
        let d = UserDefaults.standard
        for k in ["passwordsWith", "sharedRooms", "skillFiler", "folders"] { d.removeObject(forKey: k) }
        let brain = Brain.root
        let hermes = Env.hermesHome
        write("# Brain\n", brain.appendingPathComponent("AGENTS.md"))
        let roomOnly = "Room-only line: the garden plan for the spring."
        write("# Life\n\n\(roomOnly)\n", brain.appendingPathComponent("personal-room/brain/life.md"))
        let cfg = hermes.appendingPathComponent("config.yaml")
        let keepass =
            "memory:\n  memory_enabled: true\n  user_char_limit: 1375\n  memory_char_limit: 2200\nvault:\n  keepass:\n    database: /scratch/logins.kdbx\n"
        write(keepass, cfg)

        print("USER.md")
        let c = FrontPage.config()
        var u = FrontPage.userText(
            assistant: "Ava", user: "Omar", wanted: ["News", "Files", "Passwords", "Gmail"], passwords: "use your Mac's Keychain",
            passwordsWith: nil, live: ["Files", "Web", "Email"], folders: true, cfg: c, declined: nil)
        check(
            "KeePass set in the engine: logins say KeePass is connected",
            u.text.contains("For logins: KeePass is connected (Connections > Passwords)"))
        check("never the setup answer \"Keychain\" when something is connected", !u.text.contains("Keychain"))
        check("only what's still not connected is listed (News)", u.text.contains("They want these connected: News. Not connected yet"))
        u = FrontPage.userText(
            assistant: "Ava", user: "Omar", wanted: ["News", "Files", "Passwords", "Gmail"], passwords: "use your Mac's Keychain",
            passwordsWith: nil, live: ["Web"], folders: false, cfg: "", declined: nil)
        check(
            "nothing connected: the setup answer and the whole wish list",
            u.text.contains("For logins: use your Mac's Keychain.") && u.text.contains("News, Files, Passwords, Email"))
        u = FrontPage.userText(
            assistant: "Ava", user: "Omar", wanted: ["Gmail"], passwords: "", passwordsWith: "1Password", live: ["Email", "Passwords"], folders: true,
            cfg: "", declined: nil)
        check(
            "1Password from Connections; no wish line when all is connected",
            u.text.contains("1Password is connected") && !u.text.contains("want these"))

        write("Old notes: likes short answers.", hermes.appendingPathComponent("owner-notes.md"))
        check("no how-to file yet: the old owner notes", FrontPage.howToText(user: "Omar")?.contains("likes short answers") == true)
        write(
            "# How to work with Omar\n\nIntro for people.\n\n## Always on\n\nHow Omar works: terse and direct. Act after a clear go.\n\n## More\n\n- The back-page rule stays out.\n",
            FrontPage.howTo)
        let how = FrontPage.howToText(user: "Omar") ?? ""
        check("how-to-work-with-me.md: only its Always on part", how == "How Omar works: terse and direct. Act after a clear go.")
        write("# How to work with Omar\n\nShort answers. No menus.\n", FrontPage.howTo)
        check("no Always on heading: the whole file", FrontPage.howToText(user: "Omar") == "How Omar works: Short answers. No menus.")

        var ls = LearningState()
        ls.declinedKinds = (1...12).map { LearningState.Declined(kind: "kind number \($0)", date: Date()) }
        Learning.save(ls)
        let dec = Learning.declinedFact ?? ""
        check(
            "the don't-save list keeps the newest 8",
            dec.contains("kind number 12") && dec.contains("kind number 5") && !dec.contains("kind number 4;"))

        let long = (1...60).map { "Rule \($0) is a full sentence about how he likes things done." }.joined(separator: " ")
        write("# How\n\n## Always on\n\n\(long)\n", FrontPage.howTo)
        FrontPage.writeUser(assistant: "Ava", user: "Omar", wanted: ["News"], passwords: "use your Mac's Keychain", live: ["Files"])
        let ut = read(FrontPage.userFile)
        check(
            "over the engine's limit: cut at a sentence, under 1,375, logged",
            FrontPage.size(ut) <= 1375 && ut.contains("Rule 1 is") && ut.contains("done.\n§\n") && ut.contains("Don't save recipes")
                && read(FrontPage.logFile).contains("cut at a sentence"))
        check(
            "USER.md has KeePass, never Keychain, nothing from a room",
            ut.contains("KeePass is connected") && !ut.contains("Keychain") && !ut.contains(roomOnly))

        print("MEMORY.md")
        let mem = FrontPage.memoryFile
        write("Old line one.\n§\nOld line two.", mem)
        check(
            "a brain without assistant/this-mac.md: left exactly as it is",
            !FrontPage.rebuildMemory() && read(mem) == "Old line one.\n§\nOld line two.")
        let mac = """
            # This Mac

            Facts.

            ## Always on

            - Old line one.
            - python3 is 3.9; use 3.12 for new tools.

            ## More

            - The Basecamp CLI needs XDG_CONFIG_HOME.
            """
        write(mac, FrontPage.thisMac)
        FrontPage.atLaunch()
        var mt = read(mem)
        check("first launch: Old line two (new) filed into this-mac.md", read(FrontPage.thisMac).contains("- Old line two. (added by the assistant "))
        check(
            "MEMORY.md rebuilt from Always on + the pointer",
            FrontPage.entries(mt) == ["Old line one.", "python3 is 3.9; use 3.12 for new tools.", "Old line two.", FrontPage.pointer])
        check(
            "the old MEMORY.md kept as a .bak",
            read(FrontPage.memDir.appendingPathComponent("MEMORY.md.bak-\(FrontPage.today())")).contains("Old line two."))
        write(mt + "\n§\nThe printer is called Brother-7.\n§\nThe Basecamp CLI needs XDG_CONFIG_HOME.", mem)
        FrontPage.atLaunch()
        let macNow = read(FrontPage.thisMac)
        mt = read(mem)
        check(
            "a new line from the day is filed under Always on, dated", macNow.contains("- The printer is called Brother-7. (added by the assistant "))
        let above = (macNow.range(of: "Brother-7")?.lowerBound).flatMap { b in macNow.range(of: "## More").map { b < $0.lowerBound } } ?? false
        check(
            "…above ## More, and a line already in this-mac.md isn't copied again",
            above && macNow.components(separatedBy: "XDG_CONFIG_HOME").count == 2)
        check(
            "nothing lost: every line the day had is in this-mac.md",
            ["Old line one", "Old line two", "Brother-7", "XDG_CONFIG"].allSatisfy(macNow.contains))
        check(
            "rebuilt with the new line, pointer last, under 2,200",
            mt.contains("Brother-7") && mt.hasSuffix(FrontPage.pointer) && FrontPage.size(mt) <= 2200)
        let baks = { ((try? fm.contentsOfDirectory(atPath: FrontPage.memDir.path)) ?? []).filter { $0.hasPrefix("MEMORY.md.bak-") } }
        let before = baks().count
        FrontPage.atLaunch()
        check("unchanged since the last rebuild: launch leaves it alone", baks().count == before && read(FrontPage.thisMac) == macNow)
        check("nothing from a room on the front page", !mt.contains(roomOnly))
        write(keepass.replacingOccurrences(of: "memory_char_limit: 2200", with: "memory_char_limit: 420"), cfg)
        let many = (1...12).map { "- Fact \($0) about this Mac, long enough to take some room on the page." }.joined(separator: "\n")
        write("# This Mac\n\n## Always on\n\n\(many)\n", FrontPage.thisMac)
        for i in 1...20 { write("old \(i)", FrontPage.memDir.appendingPathComponent(String(format: "MEMORY.md.bak-2026-01-%02d", i))) }
        FrontPage.rebuildMemory()
        mt = read(mem)
        check(
            "over the limit: the newest that fit, the rest stay in this-mac.md (logged)",
            FrontPage.size(mt) <= 420 && mt.contains("Fact 12 ") && !mt.contains("Fact 1 ") && mt.hasSuffix(FrontPage.pointer)
                && read(FrontPage.logFile).contains("stay in this-mac.md"))
        check("only the last 14 backups are kept", baks().count == 14)
        write(keepass, cfg)

        SkillFilerCheck.run(check)
        print(fails == 0 ? "front page ok" : "front page: \(fails) failed")
        return fails == 0 ? 0 : 1
    }
}
