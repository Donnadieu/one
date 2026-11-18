import Foundation

// MARK: - A long, made-up list of routines and skills (test and render data only, never the person's own).
// Shaped like a real busy Mac (Nov 17 2026): 37 routines across three rooms, a bot, the assistant itself and a Hermes
// outside One, with the kinds of names a person can't read ("Hestia Sunday hub refresh", "Ping: helper-lines bug",
// "Then It Clicked: Short of the day"), plus 150 skills. Everything is written into the test world's own cron folder.

enum RoutinesFixture {
    /// Tuesday Nov 17 2026, 11 PM, on this Mac's clock: every check sees the same day.
    static var now: Date {
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour) = (2026, 11, 17, 23)
        return Calendar.current.date(from: c) ?? Date()
    }
    static let botSID = "fixture-ads-bot"

    /// The rooms the made-up routines mention (folder, title, its AI's name).
    static func rooms(_ base: URL) -> [RoomFacts] {
        [
            RoomFacts(url: base.appendingPathComponent("personal-room"), title: "Personal Room", ai: "Hestia", isPrivate: true, isShared: false),
            RoomFacts(url: base.appendingPathComponent("work-room"), title: "Work Room", ai: "Ajax", isPrivate: true, isShared: false),
            RoomFacts(url: base.appendingPathComponent("Co-Founder"), title: "Co-Founder", ai: "Argo", isPrivate: false, isShared: true),
            RoomFacts(url: base.appendingPathComponent("nyx-room"), title: "Nyx", ai: "Nyx", isPrivate: true, isShared: false),
        ]
    }

    /// The bot that owns "Ad test daily check".
    static func bot() -> Helper {
        var h = Helper(title: "Ads bot", task: "Run the ad test", sid: botSID, state: "done", line: "")
        h.bot = BotInfo(name: "Ads bot", color: "amber", room: "Co-Founder", roomPath: "/fixture/Co-Founder", job: "Run the ad test")
        return h
    }

    static func skills() -> [SkillStar] {
        (0..<150).map { i in
            SkillStar(
                name: "fixture-skill-\(i)", about: "Made-up skill \(i).", room: i % 9 == 0 ? "Work Room" : nil, made: nil, mine: i < 20,
                path: "/fixture/skills/fixture-skill-\(i)/SKILL.md")
        }
    }

    /// Writes jobs.json and a few reports into `cron`, then reads them the way the panel does.
    static func snapshot(cron: URL) -> RoutinesSnapshot {
        let fm = FileManager.default
        try? fm.createDirectory(at: cron, withIntermediateDirectories: true)
        let list = jobs()
        try? JSONSerialization.data(withJSONObject: ["jobs": list]).write(to: cron.appendingPathComponent("jobs.json"))
        // The three "Ping:" jobs already said their one thing; every run since has been silent.
        for id in ["ping3", "ping4", "ping5"] {
            let out = cron.appendingPathComponent("output/\(id)")
            try? fm.createDirectory(at: out, withIntermediateDirectories: true)
            for k in 0..<6 {
                let body = "# Cron Job: \(id)\n\n**Job ID:** \(id)\n**Mode:** no_agent (script)\n**Status:** silent (empty output)\n"
                try? body.write(to: out.appendingPathComponent(String(format: "2026-11-17_22-%02d-00.md", k * 5)), atomically: true, encoding: .utf8)
            }
        }
        let said = cron.appendingPathComponent("output/brief")
        try? fm.createDirectory(at: said, withIntermediateDirectories: true)
        try? "# Cron Job: Morning brief\n\n## Response\n\nGood morning. Two meetings today and one bill due Friday.\n".write(
            to: said.appendingPathComponent("2026-11-17_07-00-00.md"), atomically: true, encoding: .utf8)
        var s = RoutinesSnapshot(now: now)
        s.routines = Routines.jobs(at: cron, now: now)
        // Two jobs a Hermes outside One runs (the panel reads those from that Hermes's own folder).
        for (id, name) in [("out1", "Skills sync to One"), ("out2", "Remote control health check")] {
            var r = Routine(
                id: id, title: name, what: "Works quietly.", often: "Every hour", today: [], every: 60, lastRun: now.addingTimeInterval(-1800),
                next: now.addingTimeInterval(1800), state: .worked, reason: nil)
            r.outside = true
            s.routines.append(r)
        }
        s.skills = skills()
        return s
    }

    static func jobs() -> [[String: Any]] {
        let iso = ISO8601DateFormatter()
        let n = now
        func at(_ h: Double) -> String { iso.string(from: n.addingTimeInterval(h * 3600)) }
        func cron(_ e: String) -> [String: Any] { ["kind": "cron", "expr": e] }
        func every(_ m: Int) -> [String: Any] { ["kind": "interval", "minutes": m] }
        func job(_ id: String, _ name: String, _ sched: [String: Any], _ prompt: String = "", _ more: [String: Any] = [:]) -> [String: Any] {
            var j: [String: Any] = [
                "id": id, "name": name, "enabled": true, "state": "scheduled", "schedule": sched, "prompt": prompt, "last_status": "ok",
                "last_run_at": at(-3), "next_run_at": at(10), "repeat": ["times": NSNull(), "completed": 4], "failure_streak": 0,
                "origin": ["chat_id": "local-main"],
            ]
            for (k, v) in more { j[k] = v }
            return j
        }
        let done: [String: Any] = ["enabled": false, "state": "completed", "next_run_at": NSNull()]
        func finished(_ times: Int, _ lastH: Double) -> [String: Any] {
            var d = done
            d["repeat"] = ["times": times, "completed": times]
            d["last_run_at"] = at(lastH)
            return d
        }
        let ping: [String: Any] = [
            "repeat": ["times": 288, "completed": 140], "last_run_at": at(-0.05), "next_run_at": at(0.05), "script": "ping.py",
        ]
        return [
            job("brief", "Morning brief", cron("0 7 * * 1-5"), "Give Sam the morning brief.", ["last_run_at": at(-16)]),
            job("work", "Nightly work room update", cron("5 0 * * *"), "Update the work room with the day's work. Read only outside the brain."),
            job("cosync", "Co-Founder room sync", every(5), "Run the co-founder room sync script.", ["no_agent": true]),
            job("rsync", "Rooms GitHub sync", every(5), "Run the rooms GitHub sync script (personal, work, nyx rooms).", ["no_agent": true]),
            job("mail1", "Email triage (morning)", cron("30 6 * * *"), "Sort the inbox and draft replies for Sam's yes."),
            job("mail2", "Email triage (4 PM + 8 PM)", cron("0 16,20 * * *"), "Sort the inbox and draft replies for Sam's yes."),
            job("p009", "Argo P009 check", cron("0 18 * * *"), "You are Argo. Check the P009 problem for new entries.", finished(15, -220)),
            job("chk", "Check: brief + nightly fix", cron("30 7 28 10 *"), "Check-only job.", finished(1, -500)),
            job("token", "Basecamp token refresh", every(30), "", ["script": "refresh.py", "no_agent": true]),
            job(
                "hestia", "Hestia Sunday hub refresh", cron("0 10 * * 0"),
                "You are Hestia, the AI of Sam's personal room, running the Sunday hub refresh. Follow the agents/weekly-hub-refresh.md section.",
                ["last_run_at": at(-61), "next_run_at": at(107)]),
            job(
                "ajax", "Ajax Sunday hub refresh", cron("15 10 * * 0"), "You are Ajax, the AI of Sam's work room, running the Sunday hub refresh.",
                ["last_run_at": at(-61), "next_run_at": at(107.25)]),
            job(
                "argo", "Argo Sunday hub refresh", cron("30 10 * * 0"),
                "You are Argo, the AI of the Co-Founder room, running the Sunday hub refresh.",
                ["last_run_at": at(-60.5), "next_run_at": at(107.5)]),
            job(
                "safe", "Turn on safe edits", ["kind": "once", "run_at": at(-130)], "The Script Output above already did the switch.",
                finished(1, -130)),
            job(
                "nov4", "Old copies from the Nov 4 move", ["kind": "once", "run_at": at(10)],
                "You are Sam's assistant, running a one-time reminder Sam approved on Nov 4 2026 (storage move: keep old note files as .bak for 2 weeks).",
                ["last_run_at": NSNull(), "last_status": NSNull(), "repeat": ["times": 1, "completed": 0]]),
            job("night", "Nightly review", cron("30 3 * * *"), "One's nightly review."),
            job("jobs", "Morning job shortlist", cron("0 7 * * *"), "DRAFT MODE: you read freelance job-alert emails and write a shortlist."),
            job("build", "Daily build post", cron("30 8 * * 1-5"), "DRAFT MODE: you write one post about something you really built."),
            job(
                "bets", "Friday bets scorecard", cron("0 16 * * 5"), "You run Sam's Friday bets scorecard routine.",
                ["enabled": false, "state": "paused", "last_run_at": NSNull(), "next_run_at": at(65)]),
            job(
                "week", "One bug-free week", cron("0 18 * * 0"), "You run Sam's One bug-free week routine. It is the cloud readiness gate.",
                ["last_run_at": at(-53), "next_run_at": at(115)]),
            job(
                "x1", "Forge X replies (morning)", cron("0 9 * * *"), "Reply to posts about Forge on X.",
                ["last_status": "error", "last_error": "X signed out."]),
            job("x2", "Forge X replies (afternoon)", cron("0 13 * * *"), "Reply to posts about Forge on X."),
            job("x3", "Forge X replies (evening)", cron("0 18 * * *"), "Reply to posts about Forge on X."),
            job("rel", "Forge release", cron("0 13,18 * * *"), "Forge release (runs 1 PM and 6 PM ET)."),
            job("router", "Nightly room router", cron("0 23 * * *"), "It files the day's new material into the Personal, Work and Co-Founder rooms."),
            job("ping1", "Ping: Ledger accounts deleted", every(5), "", finished(144, -40).merging(["script": "ping.py"]) { $1 }),
            job("ping2", "Ping: phone helper bug fix", every(5), "", finished(288, -12).merging(["script": "ping.py"]) { $1 }),
            job(
                "tic1", "Then It Clicked: long video (Tue/Fri)", cron("0 7 * * 2,5"),
                "Then It Clicked (YouTube explainer channel): make and publish one long video.",
                ["last_run_at": at(-16), "next_run_at": at(56)]),
            job(
                "tic2", "Then It Clicked: Short of the day", cron("0 12 * * 0,1,3,4,6"),
                "Then It Clicked (YouTube explainer channel): post today's Short.",
                ["last_run_at": at(-35), "next_run_at": at(13), "last_status": "error", "last_error": "Upload stopped."]),
            job(
                "tic3", "Then It Clicked: Sunday report", cron("0 18 * * 0"), "Then It Clicked (YouTube explainer channel): Sunday report for Sam.",
                ["last_run_at": NSNull(), "last_status": NSNull(), "next_run_at": at(115)]),
            job(
                "ledger", "Ledger: deactivate X account", cron("0 10 18 11 *"), "Ledger: deactivate X account @example. ATTEMPT 1 of 3.",
                ["last_run_at": NSNull(), "last_status": NSNull(), "next_run_at": at(11), "repeat": ["times": 1, "completed": 0]]),
            job(
                "tic4", "Then It Clicked: reply to comments", cron("0 19 * * *"),
                "Then It Clicked (YouTube explainer channel): reply to new viewer comments."),
            job("ping3", "Ping: helper-lines bug", every(5), "", ping),
            job("ping4", "Ping: ClickFunnels + doc comments", every(5), "", ping),
            job("ping5", "Ping: channel style upgrade", every(5), "", ping),
            job(
                "ads", "Ad test daily check", cron("0 9 * * *"), "Daily check of Sam's lead-ad test. Look only: read and report.",
                ["origin": ["chat_id": botSID], "repeat": ["times": 8, "completed": 1]]),
        ]
    }
}
