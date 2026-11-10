import Foundation

/// `One --test-routines` (preflight, from a test copy): which look each routine state gets on the Routines panel.
/// Only a real failure (an error status, a failure streak, an error left on the job, a schedule the engine can't work
/// out, or a report flagged `[CRON_FAILURE]`) gets the alarm, the orange X. A routine that ran all the times it was set
/// to ("Argo P009 check": 15 of 15, no errors, Nov 9 2026) leaves the dial for the quiet Finished list; a paused one,
/// one paused by the engine, a time missed while the Mac was asleep or closed, one still to come, one at work and one
/// never run yet all stay calm. Run again builds the right engine commands and asks first.
enum RoutinesCheck {
    static func cli(_ args: [String]) {
        guard args.contains("--test-routines") else { return }
        TestWorld.enter()  // scratch One folder with made-up jobs; run with ONE_SUPPORT_DIR set to an empty folder
        exit(run())
    }

    static func run() -> Int32 {
        var fails = 0
        func check(_ name: String, _ ok: Bool) {
            print("  \(ok ? "✓" : "✗") \(name)")
            fflush(stdout)
            if !ok { fails += 1 }
        }
        let cal = Calendar.current
        // A fixed clock: 11 PM today, so 9 AM and 6 PM have passed and nothing depends on when the check runs.
        let now = cal.date(bySettingHour: 23, minute: 0, second: 0, of: Date()) ?? Date()
        let iso = ISO8601DateFormatter()
        func ago(_ h: Double) -> String { iso.string(from: now.addingTimeInterval(-h * 3600)) }
        let daily: [String: Any] = ["kind": "cron", "expr": "0 18 * * *"]
        func job(_ id: String, _ more: [String: Any]) -> [String: Any] {
            var j: [String: Any] = [
                "id": id, "name": id, "enabled": true, "state": "scheduled", "schedule": daily, "last_status": "ok",
                "last_run_at": ago(4.9), "next_run_at": iso.string(from: now.addingTimeInterval(19 * 3600)),
                "repeat": ["times": NSNull(), "completed": 3], "failure_streak": 0,
            ]
            for (k, v) in more { j[k] = v }
            return j
        }
        let cron = Routines.cron
        let fm = FileManager.default
        try? fm.createDirectory(at: cron.appendingPathComponent("output/flagged"), withIntermediateDirectories: true)
        try? "# Cron Job: flagged\n\n## Response\n\n[CRON_FAILURE]\nNot done: signed out.\n".write(
            to: cron.appendingPathComponent("output/flagged/2026-11-08_18-00-00.md"), atomically: true, encoding: .utf8)
        try? fm.createDirectory(at: cron.appendingPathComponent("output/argo"), withIntermediateDirectories: true)
        for d in ["2026-11-07_18-11-32", "2026-11-08_18-18-06"] {
            try? "# Cron Job: Argo\n\n## Response\n\nNo new entries.\n".write(
                to: cron.appendingPathComponent("output/argo/\(d).md"), atomically: true, encoding: .utf8)
        }
        let lastNight = cal.date(byAdding: .day, value: -1, to: cal.date(bySettingHour: 18, minute: 18, second: 6, of: now)!)!
        let jobs: [[String: Any]] = [
            // Argo P009 check, as it really was: 15 of 15, switched off by the engine, completed, ok, no next run.
            job(
                "argo",
                [
                    "name": "Argo P009 check", "enabled": false, "state": "completed", "next_run_at": NSNull(),
                    "last_run_at": iso.string(from: lastNight),
                    "repeat": ["times": 15, "completed": 15], "deliver": "origin", "context_from": ["self"], "model": "claude-sonnet-5",
                    "provider": "anthropic", "reasoning_effort": "low", "failure_deliver": "phone:1",
                    "prompt": "Read only. Steps go to cron/steps/argo.jsonl.",
                ]),
            job(
                "oneshot",
                [
                    "enabled": false, "state": "completed", "next_run_at": NSNull(), "schedule": ["kind": "once", "run_at": ago(30)],
                    "repeat": ["times": 1, "completed": 1], "last_run_at": ago(30),
                ]),
            job(
                "finfail",
                [
                    "enabled": false, "state": "completed", "next_run_at": NSNull(), "last_run_at": ago(50), "last_status": "error",
                    "last_error": "No credits left.",
                ]),
            job("error", ["last_status": "error", "last_error": "No credits left.", "failure_streak": 1]),
            job("streak", ["failure_streak": 2]),
            job("blocked", ["last_status": "blocked_config"]),
            job("stuck", ["state": "error", "last_run_at": NSNull(), "next_run_at": NSNull()]),
            job("flagged", [:]),
            job("delivery", ["last_status": "delivery_failed", "last_delivery_error": "chat not found"]),
            job("paused", ["enabled": false, "state": "paused"]),
            job(
                "autopaused",
                [
                    "enabled": false, "state": "paused", "paused_reason": "Cron execution unverified", "last_status": "error",
                    "last_error": "lost its fire claim", "failure_streak": 4,
                ]),
            // Missed: 6 PM passed with no run on record (last ran yesterday, fine): the Mac was asleep or closed.
            job("missed", ["last_run_at": ago(29)]),
            job("worked", [:]),
            job("never", ["last_run_at": NSNull(), "last_status": NSNull()]),
            job("running", ["fire_claim": ["at": iso.string(from: now.addingTimeInterval(-30))]]),
            job("later", ["schedule": ["kind": "cron", "expr": "0 10 * * 0"]]),
        ]
        var withRenewed = jobs
        try? JSONSerialization.data(withJSONObject: ["jobs": jobs]).write(to: cron.appendingPathComponent("jobs.json"))
        let rs = Dictionary(uniqueKeysWithValues: Routines.jobs(at: cron, now: now).map { ($0.id, $0) })
        func look(_ id: String) -> Routine.Look? { rs[id]?.look }

        print("1. finished on purpose: calm, off the dial")
        let argo = rs["argo"]
        check("15 of 15 with no errors is finished", argo?.state == .finished && argo?.look == .finished)
        check("and never needs a look", argo?.needsLook == false)
        check("it reads \"Finished <day> · ran 15 times\"", argo.map { Routines.finishedLine($0).hasSuffix(" · ran 15 times") } ?? false)
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        check("with the day it finished", argo.map { Routines.finishedLine($0) == "Finished \(f.string(from: lastNight)) · ran 15 times" } ?? false)
        check(
            "a one-shot that ran is finished, ran once",
            rs["oneshot"].map { $0.look == .finished && Routines.finishedLine($0).hasSuffix("ran once") } ?? false)
        check(
            "a finished one whose last run failed stays finished, and says so", rs["finfail"].map { $0.look == .finished && $0.lastFailed } ?? false)

        print("2. only real failures get the alarm")
        for id in ["error", "streak", "blocked", "stuck", "flagged"] { check("\(id): alarm", look(id) == .alarm) }
        check("a report that worked but couldn't be delivered isn't a failure", look("delivery") == .calm)
        check("paused by the person: paused look", look("paused") == .paused)
        check("paused by the engine after errors: paused look, not the alarm", look("autopaused") == .paused)
        check("worked: calm", look("worked") == .calm)
        check("never ran yet: waiting", look("never") == .waiting)
        check("at work: running", look("running") == .running)
        check("only the failed mark is an alarm", Dial.Kind.allCases.filter(Dial.alarm) == [.failed])

        print("3. the dial")
        let snap = RoutinesSnapshot(routines: Array(rs.values), skills: [], now: now)
        let L = Dial.layout(snap)
        let onDial = Set(L.marks.map(\.rid) + L.bands.map(\.rid) + L.labels.map(\.rid) + L.later.map(\.id))
        check("finished ones leave the dial", onDial.isDisjoint(with: ["argo", "oneshot", "finfail"]))
        check(
            "and go to the Finished list, newest first",
            L.finished.first?.id == "argo" && Set(L.finished.map(\.id)) == ["argo", "oneshot", "finfail"])
        let kinds = Dictionary(L.marks.map { ("\($0.rid)-\($0.minute)", $0.kind) }) { a, _ in a }
        check("a time missed while the Mac slept is drawn missed", kinds["missed-1080"] == .missed)
        let missedLabel = L.labels.first { $0.rid == "missed" }
        check("and its label isn't orange", missedLabel?.orange == false && missedLabel?.sub.hasSuffix("missed") == true)
        check("a failed run is the alarm mark, orange", kinds["error-1080"] == .failed && L.labels.first { $0.rid == "error" }?.orange == true)
        check("a paused one keeps its own mark", kinds["paused-1080"] == .paused && L.labels.first { $0.rid == "paused" }?.orange == false)
        check("no orange label but real failures", Set(L.labels.filter(\.orange).map(\.rid)) == ["error", "streak", "blocked", "flagged"])
        check("the legend names the calm miss and the failure apart", Dial.legend == "Done · Partly · Missed · Didn't work")

        print("4. Run again")
        let a = Routines.renewSteps(jobs[0])
        check("a finished routine comes back as a new one", Array(a.prefix(3)) == ["cron", "create", "0 18 * * *"])
        func flag(_ k: String) -> String? { a.firstIndex(of: k).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil } }
        check(
            "with its name, its 15 runs and its settings",
            flag("--name") == "Argo P009 check" && flag("--repeat") == "15" && flag("--model") == "claude-sonnet-5"
                && flag("--provider") == "anthropic"
                && flag("--reasoning-effort") == "low" && flag("--failure-deliver") == "phone:1" && a.contains("--continuity"))
        check("its reports still reach the chat", flag("--deliver") == "local")
        check("a one-shot runs once more, now", Routines.renewSteps(jobs[1]) == ["cron", "resume", "oneshot", "--run-now"])
        let oneDay = job("oneday", ["schedule": ["kind": "cron", "expr": "30 7 28 10 *"], "repeat": ["times": 1, "completed": 1]])
        let od = Routines.renewSteps(oneDay, now: now)
        check(
            "one set for a single day runs once more in two minutes, not next year",
            od.count > 3 && od[1] == "create" && Routines.date(od[2]).map { abs($0.timeIntervalSince(now) - 120) < 2 } == true
                && od.firstIndex(of: "--repeat").map { od[$0 + 1] == "1" } == true)
        check(
            "it asks first, in plain words",
            argo.map { Routines.renewQuestion($0).hasPrefix("Run it again? It goes back on your dial, every day at 6:00 PM") } ?? false)
        check(
            "its past reports, newest first",
            Routines.reports("argo").map(\.file.lastPathComponent) == ["2026-11-08_18-18-06.md", "2026-11-07_18-11-32.md"])
        // Once renewed, the active copy is on the dial and the finished one steps aside.
        withRenewed.append(job("new", ["name": "Argo P009 check", "repeat": ["times": 15, "completed": 0]]))
        try? JSONSerialization.data(withJSONObject: ["jobs": withRenewed]).write(to: cron.appendingPathComponent("jobs.json"))
        let L2 = Dial.layout(RoutinesSnapshot(routines: Routines.jobs(at: cron, now: now), skills: [], now: now))
        check("renewed: back on the dial, gone from Finished", L2.marks.contains { $0.rid == "new" } && !L2.finished.contains { $0.id == "argo" })

        print(fails == 0 ? "routines ok" : "routines: \(fails) failed")
        return fails == 0 ? 0 : 1
    }
}
