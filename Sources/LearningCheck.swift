import Foundation

/// `One --test-learning` (run by preflight): the decisions behind "tell me when I learn", on a made-up skill log.
/// Pure: no engine, no Model (its settings are the person's own). Run with ONE_SUPPORT_DIR set to an empty folder.
enum LearningCheck {
    static func run() -> Int32 {
        var fails = 0
        func check(_ name: String, _ ok: Bool) {
            print("  \(ok ? "✓" : "✗") \(name)")
            if !ok { fails += 1 }
        }
        guard Env.selfTest, ProcessInfo.processInfo.environment["ONE_SUPPORT_DIR"] != nil else {
            print("refusing: set ONE_SUPPORT_DIR to an empty folder")
            return 2
        }
        let main = "local-" + String(repeating: "a", count: 64)
        let helper = "local-" + String(repeating: "b", count: 64)
        let other = "local-" + String(repeating: "c", count: 64)
        func line(_ id: String, _ action: String, _ skill: String, _ sid: String, _ at: Date) -> Substring {
            let f = ISO8601DateFormatter()
            let ts = f.string(from: at).replacingOccurrences(of: "Z", with: ".123456+00:00")
            return Substring(
                "{\"id\": \"\(id)\", \"ts\": \"\(ts)\", \"actor\": \"curator\", \"action\": \"\(action)\", \"skill\": \"\(skill)\", "
                    + "\"evidence\": {\"session_id\": \"\(sid)\"}, \"before\": [], \"after\": [{\"path\": \"/x/skills/t/\(skill)/SKILL.md\", \"sha256\": \"0\"}]}"
            )
        }
        let t0 = Date().addingTimeInterval(-600)

        print("the log")
        let p = LedgerLine.parse(line("135433a89150", "create", "movie-showtimes", main, t0))
        check(
            "a log line is read (id, action, skill, chat, file)",
            p?.id == "135433a89150" && p?.action == "create" && p?.session == main
                && p?.paths.first == "/x/skills/t/movie-showtimes/SKILL.md" && abs((p?.ts ?? .distantPast).timeIntervalSince(t0)) < 1.5)
        check("a broken line is skipped", LedgerLine.parse("{not json") == nil)

        var s = LearningState()
        let old = [line("old1", "create", "x", main, t0), line("old2", "patch", "y", main, t0)].compactMap(LedgerLine.parse)
        Learning.take(old, into: &s) { $0 == main ? main : nil }
        check("first launch: everything already there is only marked seen", s.started && s.pending.isEmpty && s.seenLedgerIDs.count == 2)
        let fresh = old + [line("n1", "patch", "y", main, t0), line("n2", "create", "z", other, t0)].compactMap(LedgerLine.parse)
        Learning.take(fresh, into: &s) { $0 == main ? main : nil }
        check("new lines from One's chats wait for their job; other chats (phone, cron) are ignored", s.pending.map(\.id) == ["n1"])
        Learning.take(fresh, into: &s) { $0 == main ? main : nil }
        check("a line is taken once", s.pending.count == 1)

        print("the three branches")
        func job(_ sid: String, kind: String, steps: Int, ended: Date, used: Bool = false, failed: Bool = false) -> LearnJob {
            LearnJob(
                session: sid, helper: nil, kind: kind, started: ended.addingTimeInterval(-60), ended: ended, steps: steps, usedSkill: used,
                failed: failed)
        }
        var a = LearningState()
        a.started = true
        let jA = job(main, kind: "movie times lookup", steps: 4, ended: t0)
        a.jobs = [jA]
        a.pending = [
            line("c1", "create", "movie-showtimes", main, t0.addingTimeInterval(20)),
            line("c2", "write_file", "movie-showtimes", main, t0.addingTimeInterval(21)),
        ]
        .compactMap(LedgerLine.parse)
        let eA = Learning.evaluate(&a, now: t0.addingTimeInterval(25))
        if case .learned(let j, let skills)? = eA.first {
            check("A: a new skill in the job's chat is told right away, before the window ends", skills == ["movie-showtimes"] && j.lines.count == 2)
        } else {
            check("A: a new skill in the job's chat is told right away, before the window ends", false)
        }
        check("A: only once", Learning.evaluate(&a, now: t0.addingTimeInterval(400)).isEmpty)

        var b = LearningState()
        b.started = true
        b.jobs = [job(main, kind: "flight search", steps: 30, ended: t0)]
        b.pending = [line("p1", "patch", "flights", main, t0.addingTimeInterval(30))].compactMap(LedgerLine.parse)
        check("B: a fix says nothing while the window is open", Learning.evaluate(&b, now: t0.addingTimeInterval(60)).isEmpty)
        check(
            "B: and nothing after it either (a long job, but a skill got better)",
            Learning.evaluate(&b, now: t0.addingTimeInterval(200)).isEmpty
                && b.jobs[0].state == "fixed")

        var c = LearningState()
        c.started = true
        c.jobs = [job(main, kind: "tidy downloads", steps: 16, ended: t0)]
        check("C: never before the window closes", Learning.evaluate(&c, now: t0.addingTimeInterval(100)).isEmpty)
        let eC = Learning.evaluate(&c, now: t0.addingTimeInterval(125))
        check("C: a long job (15+ steps) with nothing saved is asked about after ~2 minutes", eC.count == 1 && c.jobs[0].state == "asked")
        check("C: at most once per job", Learning.evaluate(&c, now: t0.addingTimeInterval(300)).isEmpty)
        var c2 = LearningState()
        c2.started = true
        c2.jobs = [
            LearnJob(
                session: main, kind: "write a letter", started: t0.addingTimeInterval(-400), ended: t0, steps: 2, usedSkill: false, failed: false)
        ]
        check("C: a job of 5+ minutes counts as long too", Learning.evaluate(&c2, now: t0.addingTimeInterval(130)).count == 1)
        var c3 = LearningState()
        c3.started = true
        c3.jobs = [
            job(main, kind: "short", steps: 3, ended: t0), job(main, kind: "used one", steps: 20, ended: t0, used: true),
            job(main, kind: "broke", steps: 20, ended: t0, failed: true),
        ]
        check(
            "C: never for a short job, one that used a skill it had, or a failed one", Learning.evaluate(&c3, now: t0.addingTimeInterval(130)).isEmpty
        )
        var c4 = LearningState()
        c4.started = true
        c4.jobs = [
            job(helper, kind: "Movie times", steps: 4, ended: t0.addingTimeInterval(-86400)),
            job(helper, kind: "Movie times tonight", steps: 4, ended: t0),
        ]
        c4.jobs[0].state = "quiet"
        check("C: the same kind of job again is asked about, even when short", Learning.evaluate(&c4, now: t0.addingTimeInterval(130)).count == 1)
        var c5 = LearningState()
        c5.started = true
        c5.declinedKinds = [.init(kind: "tidy downloads folder", date: t0)]
        c5.jobs = [job(main, kind: "tidy downloads", steps: 40, ended: t0)]
        check("C: never again for a kind they said no to", Learning.evaluate(&c5, now: t0.addingTimeInterval(130)).isEmpty)
        c5.jobs = [job(main, kind: "tidy my downloads", steps: 40, ended: t0)]
        c5.pending = [line("d1", "create", "tidy", main, t0.addingTimeInterval(10))].compactMap(LedgerLine.parse)
        if case .undoQuietly? = Learning.evaluate(&c5, now: t0.addingTimeInterval(20)).first {
            check("a skill the engine saved anyway for a kind they said no to is undone quietly", true)
        } else {
            check("a skill the engine saved anyway for a kind they said no to is undone quietly", false)
        }
        var d = LearningState()
        d.started = true
        d.jobs = [job(main, kind: "one", steps: 20, ended: t0), job(helper, kind: "two", steps: 1, ended: t0)]
        d.pending = [line("h1", "create", "two-skill", helper, t0.addingTimeInterval(9))].compactMap(LedgerLine.parse)
        let eD = Learning.evaluate(&d, now: t0.addingTimeInterval(10))
        check("two jobs at once never get mixed up (lines go by chat)", eD.count == 1 && d.jobs[1].state == "learned" && d.jobs[0].lines.isEmpty)

        print("kinds and tags")
        check(
            "same kind: shared words",
            Learning.sameKind("movie times lookup", "Movie times tonight") && !Learning.sameKind("movie times", "flight search"))
        let tg = Learning.tags("Here you go.\n[job-kind: movie times lookup]\n[choices: More | Done]")
        check(
            "[job-kind:] is read and hidden; choices stay last", tg.kind == "movie times lookup" && tg.clean == "Here you go.\n[choices: More | Done]"
        )
        let tl = Learning.tags("I'll remember it.\n[learned: tea-timer | personal-room]")
        check(
            "[learned:] is read and hidden", tl.learned?.name == "tea-timer" && tl.learned?.room == "personal-room" && tl.clean == "I'll remember it."
        )
        check("[learned: none] means nothing was saved", Learning.tags("Couldn't.\n[learned: none | none]").learned == nil)
        check("a tag half-written while streaming never shows", Helpers.strip("Done.\n[job-kind: movie ti") == "Done.")
        check("plain names", Learning.plain("movie-showtimes") == "Movie showtimes")

        print("shared rooms stay out of the engine's reach")
        let cloud = "/Users/x/Library/Mobile Documents/com~apple~CloudDocs/One Rooms/Co-Founder"
        let rooms = [URL(fileURLWithPath: "/brain/personal-room"), URL(fileURLWithPath: "/brain/nyx-room"), URL(fileURLWithPath: cloud)]
        check(
            "only private rooms' learned folders are wanted, never the shared room's",
            LearnedDirs.wanted(rooms: rooms, shared: [cloud]) == ["/brain/personal-room/skills/learned", "/brain/nyx-room/skills/learned"])
        let merged = LearnedDirs.merged(
            current: ["/keep/me", cloud + "/skills/learned", cloud + "/skills"], wanted: ["/brain/personal-room/skills/learned"], shared: [cloud])
        check("anything inside a shared room is taken out, other folders kept", merged == ["/keep/me", "/brain/personal-room/skills/learned"])
        check(
            "config list read",
            LearnedDirs.parseList("[]").isEmpty && LearnedDirs.parseList("- /a\n- \"/b c\"\n") == ["/a", "/b c"]
                && LearnedDirs.parseList("  - /Users/x/Library/Application\n    Support/One/brain/personal-room/skills/learned\n  - /k\n")
                    == ["/Users/x/Library/Application Support/One/brain/personal-room/skills/learned", "/k"]
        )

        print(fails == 0 ? "learning ok" : "learning FAIL (\(fails))")
        return fails == 0 ? 0 : 1
    }
}
