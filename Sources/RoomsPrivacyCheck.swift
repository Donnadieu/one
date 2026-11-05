import Foundation

/// `One --test-rooms-privacy` (preflight, CI only): room.yaml decides privacy; private rooms are never offered for
/// sharing and never in the engine's recipe list; brains made before room.yaml get one; `assistant/` is made and never
/// overwritten. Pure files in a scratch brain (ONE_SUPPORT_DIR) and a scratch iCloud (ONE_CLOUD_DIR).
enum RoomsPrivacyCheck {
    static func run() -> Int32 {
        var fails = 0
        func check(_ name: String, _ ok: Bool) {
            print("  \(ok ? "✓" : "✗") \(name)")
            if !ok { fails += 1 }
        }
        guard ProcessInfo.processInfo.environment["ONE_SUPPORT_DIR"] != nil, ProcessInfo.processInfo.environment["ONE_CLOUD_DIR"] != nil else {
            print("refusing: set ONE_SUPPORT_DIR and ONE_CLOUD_DIR to empty folders")
            return 2
        }
        let d = UserDefaults.standard
        let saved = d.object(forKey: "sharedRooms")
        defer { if let saved { d.set(saved, forKey: "sharedRooms") } else { d.removeObject(forKey: "sharedRooms") } }
        let fm = FileManager.default
        let brain = Brain.root
        let write = StorageCheck.write
        StorageCheck.plant(brain)
        func room(_ n: String) -> URL { brain.appendingPathComponent(n, isDirectory: true) }
        let (personal, nyx, work) = (room("personal-room"), room("nyx-room"), room("work-room"))
        for (r, n, tier) in [
            (work, "setup", "tier: workhorse\n"), (work, "learned/pitch", ""), (work, "price-list", ""), (nyx, "setup", "tier: light\n"),
        ] {
            let name = (n as NSString).lastPathComponent
            write("---\nname: \(name)\ndescription: Use when testing.\n\(tier)---\n\n# Steps\n", r.appendingPathComponent("skills/\(n)/SKILL.md"))
        }
        let biz = Shared.base.appendingPathComponent("Biz", isDirectory: true)
        write(#"{"title":"Biz","createdBy":"Omar","created":"2026-11-04","members":["Omar","Sam"]}"#, biz.appendingPathComponent("one-room.json"))
        d.set([biz.path], forKey: "sharedRooms")

        print("who is private")
        func names(_ u: [URL]) -> [String] { u.map(\.lastPathComponent) }  // the folder list may spell /var as /private/var
        check("share candidates == [work-room] (Nyx and the personal room are never offered)", names(RoomPrivacy.shareable()) == ["work-room"])
        check("nyx-room is private (room.yaml), personal-room too (no room.yaml yet)", RoomPrivacy.isPrivate(nyx) && RoomPrivacy.isPrivate(personal))
        check("work-room isn't (private: false)", !RoomPrivacy.isPrivate(work))
        check(
            "a shared room is never private, and never offered as a new share", !RoomPrivacy.isPrivate(biz) && !RoomPrivacy.shareable().contains(biz))
        check("privateRooms() lists both", names(RoomPrivacy.privateRooms()) == ["personal-room", "nyx-room"])
        if case .failure = Shared.make(title: "Nyx", moving: nyx) {
            check("sharing a private room is refused and it stays put", fm.fileExists(atPath: nyx.appendingPathComponent("room.yaml").path))
        } else {
            check("sharing a private room is refused", false)
        }
        check(
            "room.yaml is read: quotes, comments, yes/no, nested keys ignored",
            RoomYaml.parse("title: \"A # b\"\nai: Nyx # her\nprivate: yes\n  private: false\n# private: false\n")
                == RoomYaml(title: "A # b", ai: "Nyx", isPrivate: true))
        let y = RoomYaml(title: "Garden Room", ai: "Flora", isPrivate: false)
        check("what One writes, it reads back", RoomYaml.parse(y.text) == y)

        print("the engine's recipe list")
        let want = LearnedDirs.wanted()
        check(
            "wanted == assistant/skills + work-room/skills",
            want.count == 2 && want[0] == BrainLayout.skills(brain).path && want[1].hasSuffix("/selftest-brain/work-room/skills"))
        check(
            "no private room's recipes, never a shared room's",
            !want.contains { $0.contains("nyx-room") || $0.contains("personal-room") || $0.hasPrefix(biz.path) })
        let merged = LearnedDirs.merged(
            current: ["/keep/me", personal.path + "/skills/learned", nyx.path + "/skills", biz.path + "/skills", "/old/skills/learned"], wanted: want)
        check("old entries for private and shared rooms are taken out, other folders kept", merged == ["/keep/me"] + want)
        check("a room's starter skills (tier:) are switched off, never its recipes", LearnedDirs.frameworkNames(want) == ["setup"])
        check(
            "the switched-off list keeps the person's own entries",
            LearnedDirs.disabledList(current: ["godmode", "old-one"], off: ["setup"], mine: ["old-one"]) == ["godmode", "setup"])
        check(
            "tier: only counts in the frontmatter",
            LearnedDirs.isFramework("---\nname: setup\ntier: workhorse\n---\n") && !LearnedDirs.isFramework("---\nname: x\n---\ntier: no\n"))

        print("what the assistant is told")
        RoomPrivacy.refresh()
        let nyxNote = RoomPrivacy.recipesNote(RoomPrivacy.named(in: "Nyx, I want to tell you something"))
        check("working with Nyx points at nyx-room/skills", nyxNote.contains("/selftest-brain/nyx-room/skills"))
        check(
            "a work-room job gets no line (its recipes are in the list)",
            RoomPrivacy.recipesNote(RoomPrivacy.named(in: "Ajax, update my jobs")).isEmpty)
        check(
            "a shared room's recipes are pointed at when it's named",
            RoomPrivacy.recipesNote(RoomPrivacy.named(in: "add this to Biz")).contains(biz.path + "/skills"))
        check(
            "a job the router puts in the personal room",
            RoomPrivacy.recipesNote(RoomPrivacy.claimed("personal")).contains("/selftest-brain/personal-room/skills")
        )
        check("nothing named, nothing said", RoomPrivacy.recipesNote(RoomPrivacy.named(in: "what's the weather")).isEmpty)
        let cross = RoomPrivacy.crossRoomNote
        check(
            "private rooms stay out of cross-room answers unless named",
            cross.contains("Nyx") && cross.contains("Personal room") && !cross.contains("Work Room"))

        print("brains made before room.yaml")
        write("# Secret\n\nAn intimate journal.\n", room("secret-room").appendingPathComponent("AGENTS.md"))
        write(
            "# Biz\n\n## Private things\n\nWhat goes in confidential/: other people's private information.\n",
            room("biz2-room").appendingPathComponent("AGENTS.md"))
        let garden = room("garden-room").appendingPathComponent("room.yaml")
        write("title: \"Mine\"\nprivate: false\n# my own words\n", garden)
        let gardenBefore = try? Data(contentsOf: garden)
        let nyxBefore = try? Data(contentsOf: nyx.appendingPathComponent("room.yaml"))
        let wrote = RoomPrivacy.migrate()
        check("room.yaml written only where missing", Set(wrote) == ["personal-room", "secret-room", "biz2-room"])
        check(
            "rooms that had one are untouched",
            (try? Data(contentsOf: garden)) == gardenBefore && (try? Data(contentsOf: nyx.appendingPathComponent("room.yaml"))) == nyxBefore)
        check(
            "personal-room: private, title and AI from the brain's table",
            RoomYaml.read(personal) == RoomYaml(title: "Personal Room", ai: "Hestia", isPrivate: true))
        check("a room whose notes say intimate: private", RoomYaml.read(room("secret-room"))?.isPrivate == true)
        check("a starter room with nothing private about it: private: false", RoomYaml.read(room("biz2-room"))?.isPrivate == false)
        check("a shared room never gets one", !fm.fileExists(atPath: biz.appendingPathComponent("room.yaml").path))
        check("a second launch writes nothing", RoomPrivacy.migrate().isEmpty)

        print("assistant/")
        let made = BrainLayout.ensure()
        let a = BrainLayout.assistant(brain)
        check(
            "made: notes/, skills/, how-to-work-with-me.md, this-mac.md, routines.md",
            Set(made) == ["notes/", "skills/", "how-to-work-with-me.md", "this-mac.md", "routines.md"])
        let mac = (try? String(contentsOf: a.appendingPathComponent("this-mac.md"), encoding: .utf8)) ?? ""
        check("this-mac.md has # This Mac and ## Always on", mac.contains("# This Mac") && mac.contains("## Always on"))
        let rules = a.appendingPathComponent("how-to-work-with-me.md")
        let own = "# Mine\n\nNever use em-dashes.\n"
        write(own, rules)
        check(
            "a second run makes nothing and overwrites nothing",
            BrainLayout.ensure().isEmpty && (try? String(contentsOf: rules, encoding: .utf8)) == own)
        var t = "### 2. Go into the room\n- **Write only into that room:** its memory.\n- **Say which room you're in**\n"
        _ = BrainLayout.addException(&t)
        var t2 = t
        _ = BrainLayout.addException(&t2)
        check(
            "a new brain's AGENTS.md lets the assistant write in assistant/, once",
            t.contains("memory.\n" + BrainLayout.exception + "\n- **Say") && t2 == t)

        print(fails == 0 ? "rooms privacy ok" : "rooms privacy failed: \(fails)")
        return fails == 0 ? 0 : 1
    }
}
