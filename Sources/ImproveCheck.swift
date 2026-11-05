import Foundation
import SQLite3

/// `One --test-improve` (preflight, CI only): the score on made-up records. A small state.db with known
/// corrections, cut-offs, walls, slow jobs, a Nyx conversation, a locked-drawer file and a shared-room file, plus
/// One's own logs and files; then collect, score and moments, checking every count, the week %, "not enough jobs",
/// the incident rule and that no private text ever reaches a moment.
enum ImproveCheck {
    static func launch() -> Bool {
        guard CommandLine.arguments.contains("--test-improve") else { return false }
        TestWorld.enter()  // scratch One folder (ONE_SUPPORT_DIR), own settings; CI only
        exit(run())
    }

    static func t(_ day: String, _ h: Double, _ m: Double = 0) -> Double {
        (Improve.day(day)?.timeIntervalSince1970 ?? 0) + h * 3600 + m * 60
    }
    static func utc(_ ts: Double) -> String { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: ts)) }
    static let helperFirst =
        "You're one of Juno's helpers, sent to do one job in the background while Omar keep talking. Don't send helpers yourself; do the job.\n\nThe job: "
    static let long = String(repeating: "Here is the whole result, with every detail you asked for. ", count: 5)
    static let cut = "Gateway shutting down: this turn was interrupted. Ask again once it's back."
    static func call(_ name: String, _ args: String) -> String {
        let a = args.replacingOccurrences(of: "\"", with: "\\\"")
        return "[{\"id\": \"c\", \"type\": \"function\", \"function\": {\"name\": \"\(name)\", \"arguments\": \"\(a)\"}}]"
    }

    /// A fixture state.db with the real columns the collector reads.
    final class Fixture {
        var db: OpaquePointer?
        var next = 1
        init(_ path: String) {
            try? FileManager.default.removeItem(atPath: path)
            sqlite3_open(path, &db)
            sqlite3_exec(
                db,
                "CREATE TABLE sessions (id TEXT PRIMARY KEY, source TEXT NOT NULL, started_at REAL NOT NULL, title TEXT, tool_call_count INTEGER DEFAULT 0);"
                    + "CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL, role TEXT NOT NULL, content TEXT, tool_calls TEXT, timestamp REAL NOT NULL);",
                nil, nil, nil)
        }
        func run(_ sql: String, _ args: [Any?]) {
            var st: OpaquePointer?
            sqlite3_prepare_v2(db, sql, -1, &st, nil)
            let keep = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (i, a) in args.enumerated() {
                switch a {
                case let s as String: sqlite3_bind_text(st, Int32(i + 1), s, -1, keep)
                case let d as Double: sqlite3_bind_double(st, Int32(i + 1), d)
                case let n as Int: sqlite3_bind_int64(st, Int32(i + 1), Int64(n))
                default: sqlite3_bind_null(st, Int32(i + 1))
                }
            }
            sqlite3_step(st)
            sqlite3_finalize(st)
        }
        /// rows: (role, content, tool_calls, minutes after start)
        func session(_ id: String, _ source: String, _ start: Double, _ rows: [(String, String, String?, Double)]) {
            run(
                "INSERT INTO sessions (id, source, started_at, title, tool_call_count) VALUES (?, ?, ?, ?, ?)",
                [id, source, start, nil, rows.filter { $0.0 == "tool" }.count])
            for r in rows {
                run(
                    "INSERT INTO messages (session_id, role, content, tool_calls, timestamp) VALUES (?, ?, ?, ?, ?)",
                    [id, r.0, r.1, r.2, start + r.3 * 60])
            }
        }
        func close() { sqlite3_close(db) }
    }

    static func write(_ s: String, _ u: URL) {
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? s.write(to: u, atomically: true, encoding: .utf8)
    }

    static func makeWorld() {
        let home = Env.hermesHome
        let f = Fixture(home.appendingPathComponent("state.db").path)
        let days = ["2026-10-26", "2026-10-27", "2026-10-28", "2026-10-29", "2026-10-30"]
        var jobs: [[String: Any]] = []
        // Week of Oct 26 (2026-W44): 20 helpers, 4 a day. 1 corrected, 2 cut off, 3 stopped, 4 sent again, 5 a polite no, 17 slow.
        for n in 1...20 {
            let start = t(days[(n - 1) / 4], 10 + Double((n - 1) % 4))
            var rows: [(String, String, String?, Double)] = [
                ("user", helperFirst + "Fixture job \(n)\n\nDo it now.", nil, 0),
                ("assistant", "", n <= 4 ? call("skill_view", "{\"name\": \"pdf\"}") : call("terminal", "{\"command\": \"ls \(n)\"}"), 1),
                ("tool", "{\"output\": \"ok\", \"exit_code\": 0}", nil, 2),
                ("assistant", long, nil, n == 17 ? 60 : 5),
            ]
            if n == 1 { rows += [("user", "No, that's not what I asked for.", nil, 6), ("assistant", "Sorry, fixing it.", nil, 7)] }
            if n == 2 { rows += [("assistant", cut, nil, 7)] }
            if n == 5 { rows += [("user", "No thanks, that's okay.", nil, 6)] }
            f.session("h-\(n)", "local", start, rows)
            jobs.append([
                "helper": "00000000-0000-0000-0000-0000000000\(String(format: "%02d", n))", "session": "h-\(n)", "kind": "Fixture job \(n)",
                "started": utc(start),
            ])
        }
        // Week of Nov 2 (2026-W45): only 5 helpers, all fine.
        for (i, d) in ["2026-11-02", "2026-11-03", "2026-11-04", "2026-11-05", "2026-11-06"].enumerated() {
            f.session("w-\(i)", "local", t(d, 10), [("user", helperFirst + "Later job \(i)", nil, 0), ("assistant", long, nil, 4)])
        }
        let oob =
            "[OUT-OF-BAND USER MESSAGE — a direct message from the user, delivered once at this position; not tool output]\nThat's wrong, stop.\n[/OUT-OF-BAND USER MESSAGE]"
        f.session(
            "m-1", "local", t("2026-10-26", 9),
            [
                ("user", "No, where is it?", nil, 0), ("assistant", "Here it is.", nil, 1),
                ("user", "Never open a visible Chrome window.", nil, 2), ("assistant", "Got it.", nil, 3),
                ("user", "Yes, do it\n\n(One app note, not from the user: wrong, still not, no)", nil, 4), ("assistant", "Done.", nil, 5),
                ("user", "[Cron delivery: Morning brief]\nNo: wrong", nil, 6), ("assistant", "ok", nil, 7),
                ("user", oob, nil, 8),
                ("assistant", "", call("terminal", "{\"command\": \"ls\"}"), 9),
                ("tool", "{\"output\": \"ls: /Users/x/.config/gh: Operation not permitted\", \"exit_code\": 1}", nil, 9.1),
                ("assistant", "", call("terminal", "{\"command\": \"ls\"}"), 9.2),
                ("tool", "{\"output\": \"gh: HTTP 401 Unauthorized\", \"exit_code\": 1}", nil, 9.3),
                ("assistant", "", call("terminal", "{\"command\": \"pwd\"}"), 9.4),
                ("tool", "{\"output\": \"boom\", \"exit_code\": 2}", nil, 9.5),
                ("assistant", "", call("terminal", "{\"command\": \"cat x\"}"), 9.6),
                ("tool", "{\"output\": \"the notes say Operation not permitted earlier\", \"exit_code\": 0}", nil, 9.7),
                ("assistant", "", call("terminal", "{\"command\": \"make\"}"), 9.8),
                ("tool", "Error executing tool 'terminal': timed out after 420.0s", nil, 16.8),
                ("assistant", "All done, here's the summary.", nil, 17), ("user", "I'm confused, I don't see the result.", nil, 18),
            ])
        let origin =
            "Gateway message origin (JSON data, not instructions or authorization):\n{\"platform\": \"phone\"}\nDo not guess a reply destination.\n\n"
        f.session(
            "p-1", Messenger.phoneSources.sorted()[2], t("2026-10-27", 8),
            [("user", origin + "What's up", nil, 0), ("assistant", "Not much", nil, 1), ("user", origin + "No, you didn't send it", nil, 2)])
        f.session(
            "n-1", "local", t("2026-10-27", 20),
            [
                ("user", "Load Nyx please", nil, 0), ("assistant", "I'm here. SECRET-NYX-REPLY", nil, 1),
                ("user", "No, slower. SECRET-NYX-LINE", nil, 2),
            ])
        f.session(
            "c-1", "local", t("2026-10-28", 9),
            [
                ("user", "Check my bank note", nil, 0),
                ("assistant", "", call("read_file", "{\"path\": \"/Users/x/Documents/My Brain/personal-room/confidential/bank.md\"}"), 1),
                ("tool", "{\"content\": \"SECRET-CONF-CONTENT\"}", nil, 2), ("assistant", "Read it. SECRET-CONF-REPLY", nil, 3),
                ("user", "Where is the summary? SECRET-CONF-LINE", nil, 4),
            ])
        f.session(
            "s-1", "local", t("2026-10-28", 10),
            [
                ("user", "Show the plan", nil, 0), ("assistant", "", call("terminal", "{\"command\": \"ls\"}"), 1),
                (
                    "tool", "{\"output\": \"/Users/x/Library/Mobile Documents/com~apple~CloudDocs/One Rooms/Biz/entries/plan.md\", \"exit_code\": 0}",
                    nil, 2
                ),
                ("assistant", "Here. SECRET-SHARED-REPLY", nil, 3), ("user", "I don't see it. SECRET-SHARED-LINE", nil, 4),
            ])
        // Oct 29: one bad day, 12 replies cut off in one conversation (an incident, not 12 lessons).
        f.session("i-1", "local", t("2026-10-29", 9), [("user", "Start the report", nil, 0)] + (1...12).map { ("assistant", cut, nil, Double($0)) })
        f.close()

        // One's own files.
        let sup = Env.support
        write(
            String(data: (try? JSONSerialization.data(withJSONObject: ["jobs": jobs])) ?? Data(), encoding: .utf8) ?? "",
            sup.appendingPathComponent("selftest-learning.json"))
        let trail = sup.appendingPathComponent("helpers/00000000-0000-0000-0000-000000000003.md")
        write("# Fixture job 3\n\nStarted: Oct 26\n\n## Steps so far\n\n- Reading\n- Stopped by you\n", trail)
        try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: t("2026-10-26", 12, 30))], ofItemAtPath: trail.path)
        let logs = home.appendingPathComponent("logs", isDirectory: true)
        write(
            "\(utc(t("2026-10-26", 13, 30))) redo: \"Fixture job 99\" looks like \"Fixture job 4\" sent again, counted as not worked\n",
            logs.appendingPathComponent("one-routing.log"))
        write(
            "\(utc(t("2026-10-27", 15))) undo pdf create abc: 0 done\n\(utc(t("2026-10-27", 15))) undo pdf patch def: 0 done\n",
            logs.appendingPathComponent("one-learning.log"))
        let sigterm = DateFormatter()
        sigterm.locale = Locale(identifier: "en_US_POSIX")
        sigterm.dateFormat = "yyyy-MM-dd HH:mm:ss"
        write(
            "\(sigterm.string(from: Date(timeIntervalSince1970: t("2026-10-29", 9, 30)))),000 INFO gateway.run: Received SIGTERM — initiating shutdown\n",
            logs.appendingPathComponent("gateway.log"))
        let hand = sup.appendingPathComponent("handoff", isDirectory: true)
        write(
            "{\"id\": \"abc\", \"created\": \(t("2026-10-27", 15)), \"kind\": \"check\", \"site\": \"reddit.com\"}",
            hand.appendingPathComponent("abc.request.json"))
        write("{\"answer\": \"done\"}", hand.appendingPathComponent("abc.answer.json"))
        write(
            "{\"id\": \"def\", \"created\": \(t("2026-11-03", 15)), \"kind\": \"code\", \"site\": \"github.com\"}",
            hand.appendingPathComponent("def.request.json"))
        let cron = home.appendingPathComponent("cron/output/job1", isDirectory: true)
        write(
            "# Cron Job: Outreach drafts\n\n## Prompt\n\nSay Not done: when nothing worked.\n\n## Response\n\nNot done: the browser was signed out.\n",
            cron.appendingPathComponent("2026-10-28_09-00-00.md"))
        write(
            "# Cron Job: Morning brief\n\n## Prompt\n\nSay Not done: when nothing worked.\n\n## Response\n\nAll good today.\n",
            cron.appendingPathComponent("2026-10-28_07-00-00.md"))
    }

    static func run() -> Int32 {
        var fails = 0
        func check(_ name: String, _ ok: Bool) {
            print("  \(ok ? "✓" : "✗") \(name)")
            if !ok { fails += 1 }
        }
        // The correction finder (also FrictionLog's).
        for s in [
            "No, that's not it", "I don't see the helper", "Where is the file?", "I told you twice", "you didn't save it", "Broken again?",
            "that's wrong",
        ] {
            check("a correction: \"\(s)\"", Corrections.matches(s))
        }
        for s in [
            "No that's okay", "no thanks", "No worries!", "Find my receipts", "Yes\n\n(One app note, not from the user: no, wrong)",
            "[Cron delivery: X]\nNot done: no, wrong", "Speaker 1: no\nSpeaker 2: that's wrong\nSpeaker 1: where is it",
        ] { check("not a correction: \"\(s.prefix(30))\"", !Corrections.matches(s)) }
        check("\"always…\" / \"never…\" is their own rule", Corrections.find("Always give me the result in the chat") == .statedRule)

        makeWorld()
        let db = Env.hermesHome.appendingPathComponent("state.db").path
        let before = (try? FileManager.default.attributesOfItem(atPath: db)) ?? [:]
        guard let from = Improve.day("2026-10-26"), let to = Improve.day("2026-11-08") else { return 1 }
        _ = Improve.collect(from: from, to: to)
        let days = Improve.collect(from: from, to: to)  // twice: lines are replaced, never doubled
        let after = (try? FileManager.default.attributesOfItem(atPath: db)) ?? [:]
        check(
            "the engine's history is only read (unchanged, no journal left)",
            before[.modificationDate] as? Date == after[.modificationDate] as? Date && before[.size] as? Int == after[.size] as? Int
                && !FileManager.default.fileExists(atPath: db + "-wal") && !FileManager.default.fileExists(atPath: db + "-journal"))
        check("a day file for each day", days.count == 14 && Improve.dayKeys().count == 14)
        let week = ImproveScore.line("W44", days.filter { Improve.weekKey($0.date) == "2026-W44" }, week: true)
        let c = { (k: String) in days.reduce(0) { $0 + ($1.counts[k] ?? 0) } }
        check("messages from the person: 16 (hidden notes, routine reports and helper jobs left out)", week.said == 16)
        check("corrections: 8 (polite no's, notes, pasted text left out; first message isn't after a reply)", week.corrections == 8)
        check("one of them their own rule", c(ImproveCount.statedRules) == 1)
        check("corrections per 100 messages: 50.0", week.perHundred == 50.0)
        check(
            "right the first time: 16 of 20 = 80% (corrected, cut off, stopped, sent again)",
            week.helpers == 20 && week.right == 16 && week.rightPct == 80)
        check("job kinds kept (pdf: 4 jobs, 0 right)", week.kinds["pdf"] == [4, 0])
        check("cut off: 13", week.cutOff == 13)
        check("walls: a handoff, the folder lock, a 401 (a step that worked doesn't count)", week.walls == 3 && c(ImproveCount.folderLock) == 1)
        check("slow: a helper over 30 min and a command at the time limit", week.slowJobs == 2 && c(ImproveCount.slowHelpers) == 1)
        check("stop, redo and undo found", c(ImproveCount.stops) == 1 && c(ImproveCount.redos) == 1 && c(ImproveCount.undos) == 1)
        check(
            "broke: 3 failed in a row, a repeated step, a routine not done (only in its reply), an engine stop",
            c(ImproveCount.streaks) == 1 && c(ImproveCount.repeats) == 1 && c(ImproveCount.notDone) == 1 && c(ImproveCount.engineStops) == 1)
        let next = ImproveScore.line("W45", days.filter { Improve.weekKey($0.date) == "2026-W45" }, week: true)
        check("under 20 jobs: \"not enough jobs this week\", no %", next.helpers == 5 && next.rightPct == nil && next.note == ImproveScore.notEnough)
        let oct29 = days.first { $0.date == "2026-10-29" }
        check(
            "12 cut-offs in a day: one incident, not 12 events (the count stays)",
            oct29?.incidents.count == 1 && oct29?.incidents.first?.count == 12 && oct29?.events.contains { $0.sub == "cut_off" } == false
                && oct29?.counts[ImproveCount.cutOff] == 12)
        check("a single cut-off stays an event", days.first { $0.date == "2026-10-26" }?.events.contains { $0.sub == "cut_off" } == true)
        let nyx = days.flatMap(\.events).first { $0.session == "n-1" }
        check("a Nyx conversation's correction counts but keeps no words", nyx?.isPrivate == true && nyx?.quote == nil)
        let files = (try? String(contentsOf: Improve.scoreFile, encoding: .utf8)) ?? ""
        let weeks = (try? String(contentsOf: Improve.weeksFile, encoding: .utf8)) ?? ""
        check("score.jsonl: one line a day", files.split(separator: "\n").count == 14 && files.contains("\"period\":\"2026-10-26\""))
        check("weeks.jsonl: one line a week", weeks.split(separator: "\n").count == 2 && weeks.contains("\"right_first_time_pct\":80"))
        let raw = (try? String(contentsOf: Improve.daysDir.appendingPathComponent("2026-10-27.json"), encoding: .utf8)) ?? ""
        check("no private words in the day files", !raw.contains("SECRET") && !files.contains("SECRET"))

        let brief = ImproveScore.brief(lastWeek: false, today: t("2026-11-04", 12).asDate)
        check("morning lines: not enough jobs this week", brief.first == "Right the first time: not enough jobs this week (5 so far).")
        let last = ImproveScore.brief(lastWeek: true, today: t("2026-11-04", 12).asDate)
        check(
            "last week's lines: 80% and 50.0 per 100",
            last.first == "Right the first time: 80% last week." && last.contains("Corrections: 50.0 per 100 messages."))

        var moments = ""
        for d in ["2026-10-26", "2026-10-27", "2026-10-28", "2026-10-29", "2026-10-30"] { moments += ImproveMoments.render(date: d, max: 20) }
        check(
            "moments show the replies around a correction", moments.contains("Never open a visible Chrome window.") && moments.contains("← this one"))
        check("the incident is one moment", moments.contains("Incident: A reply cut off by an engine shutdown, 12 times"))
        check("moments never show Nyx, a locked drawer or a shared room", !moments.contains("SECRET") && moments.contains("left out: private"))
        check("moments stop at --max", ImproveMoments.render(date: "2026-10-26", max: 2).components(separatedBy: "\n## ").count == 3)

        // Settings for the nightly review.
        check("settings start as suggest-only", Improve.settings() == ImproveSettings() && Improve.settings().mode == "suggest")
        check("set mode edit", ImproveCLI.run(["One", "--improve", "settings", "set", "mode", "edit"]) == 0 && Improve.settings().mode == "edit")
        check(
            "a wrong mode is refused",
            ImproveCLI.run(["One", "--improve", "settings", "set", "mode", "wild"]) == 2 && Improve.settings().mode == "edit")
        check("--improve isn't --test-improve", ImproveCLI.run(["One", "--test-improve"]) == nil)

        // Health: notes near full, an oversize skill, a name twice, a link loop, a failing routine.
        let home = Env.hermesHome
        write(String(repeating: "x", count: 2190), home.appendingPathComponent("memories/MEMORY.md"))
        write("---\nname: big\n---\n" + String(repeating: "y", count: 13 * 1024), home.appendingPathComponent("skills/a/big/SKILL.md"))
        write("---\nname: twin\n---\n", home.appendingPathComponent("skills/a/twin/SKILL.md"))
        write("---\nname: twin\n---\n", home.appendingPathComponent("skills/b/twin/SKILL.md"))
        try? FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent("skills/skills"), withDestinationURL: home.appendingPathComponent("skills", isDirectory: true))
        write(
            "{\"jobs\": [{\"name\": \"Ledger\", \"enabled\": true, \"last_status\": \"error\", \"last_error\": \"killed by a restart\"}]}",
            home.appendingPathComponent("cron/jobs.json"))
        let health = Set(ImproveFiles.health(now: Date().timeIntervalSince1970).map(\.sub))
        check(
            "health: notes near full, skill too big, the same name twice, a link loop, a failing routine",
            health.isSuperset(of: ["notes_near_full", "skill_too_big", "skill_twice", "link_loop", "routine_failing"]))

        print(fails == 0 ? "improve ok" : "improve failed: \(fails)")
        return fails == 0 ? 0 : 1
    }
}

extension Double {
    fileprivate var asDate: Date { Date(timeIntervalSince1970: self) }
}
