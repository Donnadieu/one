import Foundation

/// The recipe filer part of `One --test-front-page` (FrontPageCheck.swift): a made-up skill log on a scratch engine home
/// and brain; where each new recipe goes, what never moves, and undo.
enum SkillFilerCheck {
    static func run(_ check: (String, Bool) -> Void) {
        let fm = FileManager.default
        let d = UserDefaults.standard
        let skills = SkillFiler.engineSkills
        let brain = Brain.root
        let work = brain.appendingPathComponent("work-room", isDirectory: true)
        let personal = brain.appendingPathComponent("personal-room", isDirectory: true)
        let shared = Shared.cloud.appendingPathComponent("One Rooms/Co-Founder", isDirectory: true)
        for r in [work, personal, shared] {
            try? fm.createDirectory(at: r.appendingPathComponent("skills/learned"), withIntermediateDirectories: true)
        }
        Shared.paths = [shared.path]
        print("recipe filer")
        d.removeObject(forKey: SkillFiler.key)
        SkillFiler.settleDefault(fresh: false)
        check("an install set up before the filer: off until turned on", d.object(forKey: SkillFiler.key) != nil && !SkillFiler.on)
        d.removeObject(forKey: SkillFiler.key)
        SkillFiler.settleDefault(fresh: true)
        SkillFiler.settleDefault(fresh: false)
        check("a new install: on (and a later launch doesn't change it)", SkillFiler.on)

        var ledger = ""
        func add(_ id: String, _ rel: String, _ sid: String, actor: String = "agent") {
            let f = skills.appendingPathComponent("\(rel)/SKILL.md")
            let name = f.deletingLastPathComponent().lastPathComponent
            FrontPageCheck.write("---\nname: \(name)\ndescription: Use when testing.\n---\n\nSteps.\n", f)
            ledger += "{\"id\": \"\(id)\", \"ts\": \"2026-11-05T03:33:56.212511+00:00\", \"actor\": \"\(actor)\", \"action\": \"create\", "
            ledger +=
                "\"skill\": \"\(name)\", \"evidence\": {\"session_id\": \"\(sid)\"}, \"before\": [], \"after\": [{\"path\": \"\(f.path)\", \"sha256\": \"0\"}]}\n"
            FrontPageCheck.write(ledger, Learning.ledger)
        }
        let jobs = [
            "s-work": "Check the ConstructEase Basecamp board", "s-none": "Fix the Mac's printer queue",
            "s-shared": "Draft the co-founder room's pitch with Argo", "s-personal": "Plan a family vacation trip to Maine",
        ]
        let text: (LedgerLine) -> String? = { jobs[$0.session] }
        add("old1", "general/old-recipe", "s-none")
        _ = SkillFiler.run(jobText: text, busy: false)
        check(
            "first look: recipes saved before the filer stay put",
            fm.fileExists(atPath: skills.appendingPathComponent("general/old-recipe/SKILL.md").path))

        FrontPageCheck.write("builtin-skill:abc123\n", skills.appendingPathComponent(".bundled_manifest"))
        FrontPageCheck.write("---\nname: clash-one\n---\n", SkillFiler.assistantSkills.appendingPathComponent("clash-one/SKILL.md"))
        add("n1", "productivity/work-board", "s-work")
        add("n2", "general/mac-trick", "s-none")
        add("n3", "biz/pitch-deck", "s-shared")
        add("n4", "x/builtin-skill", "s-none")
        add("n5", "y/clash-one", "s-none")
        add("n6", "my-connections/feedly", "s-none")
        add("n7", "home/tea-timer", "s-personal")
        add("n8", "general/hand-made", "s-none", actor: "user")
        let wanted = LearnedDirs.wanted()
        check(
            "assistant/skills is a folder the engine reads; the shared room's isn't",
            wanted.contains(SkillFiler.std(SkillFiler.assistantSkills)) && !wanted.contains { $0.hasPrefix(shared.path) })
        _ = SkillFiler.run(jobText: text, busy: true)
        check("while something is working, nothing moves", fm.fileExists(atPath: skills.appendingPathComponent("productivity/work-board").path))
        let moved = SkillFiler.run(jobText: text, busy: false)
        // storage-guards makes the engine read <room>/skills; before it, <room>/skills/learned. Either way: a folder it reads.
        let workHome = wanted.contains(SkillFiler.std(work.appendingPathComponent("skills"))) ? "skills" : "skills/learned"
        let wb = work.appendingPathComponent("\(workHome)/work-board/SKILL.md")
        check(
            "a work-room job's recipe → work-room/\(workHome)/work-board (a folder the engine reads)",
            fm.fileExists(atPath: wb.path) && wanted.contains(SkillFiler.std(wb.deletingLastPathComponent().deletingLastPathComponent())))
        check(
            "…and no copy left in the engine's folder (its emptied category folder gone too)",
            !fm.fileExists(atPath: skills.appendingPathComponent("productivity/work-board").path)
                && !fm.fileExists(atPath: skills.appendingPathComponent("productivity").path))
        check(
            "a job with no room → assistant/skills/mac-trick",
            fm.fileExists(atPath: SkillFiler.assistantSkills.appendingPathComponent("mac-trick/SKILL.md").path))
        check(
            "a private room's job → personal-room/skills/tea-timer",
            fm.fileExists(atPath: personal.appendingPathComponent("skills/tea-timer/SKILL.md").path))
        for s in ["biz/pitch-deck", "x/builtin-skill", "y/clash-one", "my-connections/feedly", "general/hand-made"] {
            check("not moved: \(s)", fm.fileExists(atPath: skills.appendingPathComponent("\(s)/SKILL.md").path))
        }
        check(
            "nothing went into the shared room",
            !fm.fileExists(atPath: shared.appendingPathComponent("skills/pitch-deck").path)
                && !fm.fileExists(atPath: shared.appendingPathComponent("skills/learned/pitch-deck").path))
        let log = FrontPageCheck.read(SkillFiler.logFile)
        check(
            "three moves, each logged from → to",
            moved.count == 3 && ["work-board", "mac-trick", "tea-timer"].allSatisfy { log.contains("moved \($0): ") })
        check("the shared-room and name-clash ones are logged", log.contains("shared room") && log.contains("already used"))
        let r = SkillFiler.undo("mac-trick")
        check(
            "undo moves it back",
            r.ok && fm.fileExists(atPath: skills.appendingPathComponent("general/mac-trick/SKILL.md").path)
                && !fm.fileExists(atPath: SkillFiler.assistantSkills.appendingPathComponent("mac-trick").path))
        add("n9", "general/after-undo", "s-none")
        _ = SkillFiler.run(jobText: text, busy: false)
        check(
            "an undone recipe isn't moved again; a newer one still is",
            fm.fileExists(atPath: skills.appendingPathComponent("general/mac-trick/SKILL.md").path)
                && fm.fileExists(atPath: SkillFiler.assistantSkills.appendingPathComponent("after-undo/SKILL.md").path))
        check("moves are recorded for undo", SkillFiler.load().filed.map(\.name).sorted() == ["after-undo", "tea-timer", "work-board"])
    }
}
