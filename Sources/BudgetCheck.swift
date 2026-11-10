import Foundation
import SQLite3

/// `One --test-budgets` (preflight, CI only, a test copy): a job's share of the week from a made-up `state.db`
/// (its conversation + sub-helpers, never another's), the meter's calibration, the 80% line, the pause at its
/// budget (orange, the stop mark, three choices) and each choice. No engine, no accounts, no network.
enum BudgetCheck {
    static func main(_ args: [String]) {
        guard args.contains("--test-budgets") else { return }
        TestWorld.enter()
        MainActor.assumeIsolated {
            Task { @MainActor in exit(await run()) }
        }
        RunLoop.main.run()
    }

    static func makeDB(_ url: URL, _ rows: [(String, String?, Double, Double, Double, Double)]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        var db: OpaquePointer?
        sqlite3_open(url.path, &db)
        sqlite3_exec(
            db,
            "CREATE TABLE sessions (id TEXT PRIMARY KEY, parent_session_id TEXT, input_tokens INTEGER, output_tokens INTEGER, "
                + "cache_read_tokens INTEGER, cache_write_tokens INTEGER)", nil, nil, nil)
        for r in rows {
            let p = r.1.map { "'\($0)'" } ?? "NULL"
            sqlite3_exec(db, "INSERT INTO sessions VALUES ('\(r.0)', \(p), \(r.2), \(r.3), \(r.4), \(r.5))", nil, nil, nil)
        }
        sqlite3_close(db)
    }

    @MainActor static func run() async -> Int32 {
        var fails = 0
        func check(_ name: String, _ ok: Bool) {
            print((ok ? "  ✓ " : "  ✗ ") + name)
            if !ok { fails += 1 }
        }
        // The Nov 9 shape: a helper, its sub-helpers (one with a sub-helper of its own), and another helper.
        let db = Env.hermesHome.appendingPathComponent("state.db")
        makeDB(
            db,
            [
                ("local-root", nil, 578, 219_158, 83_653_511, 701_148), ("kid-1", "local-root", 100, 50_000, 10_000_000, 200_000),
                ("kid-2", "local-root", 100, 50_000, 10_000_000, 200_000), ("grand", "kid-1", 0, 1_000, 1_000_000, 0),
                ("local-other", nil, 1_000, 9_000_000, 0, 0),
            ])
        let rootOnly = Usage.units(input: 578, output: 219_158, cacheRead: 83_653_511, cacheWrite: 701_148)
        let kid = Usage.units(input: 100, output: 50_000, cacheRead: 10_000_000, cacheWrite: 200_000)
        let grand = Usage.units(input: 0, output: 1_000, cacheRead: 1_000_000, cacheWrite: 0)
        let tree = Usage.tree("local-root", db: db)
        check("a job's use = its conversation + every sub-helper under it", abs(tree - (rootOnly + 2 * kid + grand)) < 1)
        check("never another helper's", abs(Usage.tree("local-other", db: db) - 45_001_000) < 1)
        check(
            "output, cache writes and cache reads weighted like the price list", Usage.units(input: 1, output: 1, cacheRead: 10, cacheWrite: 4) == 12)

        // The meter: units per 1% of the week, measured from how the week moved.
        var s = Usage.Store()
        check("before any reading: Nov 9's number, marked \"about\"", Usage.perPercent(s) == (Usage.defaultPerPercent, false))
        Usage.add(.init(t: 0, provider: "anthropic", week: 10, reset: nil, units: 1_000_000), to: &s)
        Usage.add(.init(t: 300, provider: "anthropic", week: 12, reset: nil, units: 3_000_000), to: &s)
        check("two readings 2% apart, 2 M units: 1 M units per 1%", Usage.perPercent(s) == (1_000_000, true))
        Usage.add(.init(t: 600, provider: "anthropic", week: 0, reset: nil, units: 3_100_000), to: &s)  // the week reset
        Usage.add(.init(t: 700, provider: "anthropic", week: 0.5, reset: nil, units: 3_200_000), to: &s)  // under 1%
        check("a reset or a move under 1% adds no sample", s.perPercent == [1_000_000])
        check("a share: 8 M units at 1 M per 1% = 8% of the week", abs(Usage.share(units: 8_000_000, s) - 0.08) < 1e-9)
        Usage.save(s)
        check("kept in One's folder", Usage.load() == s)

        // Budgets from the job's words.
        check("\"Budget 10%:\" gives 10%", Budget.parse("Budget 10%: find a flight") == 0.10)
        check(
            "\"Goal (50 turns, 20%):\" gives 20%, and still 50 turns",
            Budget.parse("Goal (50 turns, 20%): x") == 0.20 && Goals.helperGoal("Goal (50 turns, 20%): x")?.turns == 50)
        check("\"Goal (10%):\" is a budget, not 10 turns", Budget.parse("Goal (10%): x") == 0.10 && Goals.helperGoal("Goal (10%): x")?.turns == nil)
        check("nothing said: nil", Budget.parse("Find a flight to Quebec") == nil)
        check("\"up to 10% of the week\" anywhere in the job gives 10%", Budget.parse("Find hotels in Quebec, up to 10% of the week.") == 0.10)
        // Omar, Nov 10: a budget only when named. Full range (a Goal:, "don't stop until it's done") never pauses.
        let full = Helper(title: "Finish NotArc", task: "Goal: finish NotArc parity", sid: "local-full", state: "working", line: "Working…")
        let plainJob = Helper(title: "Lamp", task: "Find a lamp. Don't stop until it's done.", sid: "local-plain", state: "working", line: "")
        check("no budget unless named: a goal, a full-range job, a plain job", Budget.of(full) == nil && Budget.of(plainJob) == nil)
        var h = Helper(
            title: "Finish NotArc", task: "Goal (50 turns, 10%): finish NotArc parity", sid: "local-root", state: "working", line: "Working…")
        check("a named one: 10%", Budget.of(h) == 0.10)
        h.budgetOff = true
        check("No limit: none", Budget.of(h) == nil)
        h.budgetOff = nil

        // Warn at 80%, pause at 100%, then each choice.
        let m = Model.shared
        var resent: [(UUID, String)] = []
        Budget.resend = { id, text in resent.append((id, text)) }
        var switched: String?
        Budget.makeDefault = { _, e in
            switched = e
            return true
        }
        Budget.otherAccount = { _ in ("Forge", "ab12cd") }
        var phone: [String] = []
        Limit.tellPhone = { phone.append($0) }
        Limit.away = { true }
        Limit.account = { _ in "Omar's Claude" }
        m.helpers = [h, full]
        m.applyUsage(full.id, used: 0.40)
        check(
            "a full-range job at 40% of the week: still working, no warning, no pause",
            m.helpers[1].state == "working" && m.helpers[1].budgetWarned == nil)
        m.applyUsage(h.id, used: 0.081)
        m.applyUsage(h.id, used: 0.085)
        check(
            "warned once at 80%, on their phone too (they're away)",
            phone.count == 1 && phone[0].contains("8% of its 10%") && phone[0].contains("pauses only at 10%"))
        var x = m.helpers[0]
        check(
            "at 81% of its share: its line in the trail, still working, arc amber",
            x.budgetWarned == true && x.state == "working" && (Budget.fill(x) ?? 0) >= 0.8)
        check("its card reads \"8% of its 10%\"", Budget.words(x) == "8% of its 10%")
        m.applyUsage(h.id, used: 0.101)
        try? await Task.sleep(for: .milliseconds(300))
        x = m.helpers[0]
        check(
            "at its budget: paused, orange, \"Used its 10% of the week · paused\"",
            x.state == "stopped" && x.pausedForBudget == true && x.viewState == .needsYes && x.line == Budget.pausedLine(0.10))
        check("nothing can wake it while paused (the stop mark)", StopMark.isMarked("local-root"))
        let why =
            (try? Data(contentsOf: StopMark.file("local-root"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["why"]
            as? String
        check("the mark says why (the engine tells it it's paused, never \"they pressed Stop\")", why == "it used its 10% of the week")
        check(
            "its cancelled turn ending isn't a cut-off to pick back up, nor a Stop",
            m.pausedTurnEnded(h.id, stop: "cancelled")
                && m.helpers[0].resumeQueued != true && m.helpers[0].stoppedByYou == nil && m.helpers[0].pausedForBudget == true)
        check("it can't leave the screen before a choice", HelperClose.busy(x))
        check("another signed-in account is offered", x.switchTo == "Forge")
        await m.giveMoreBudget(h.id)
        x = m.helpers[0]
        check(
            "Give it 10% more: 20% now, the mark lifted, a goal resumed",
            x.budget == 0.20 && x.pausedForBudget == nil
                && !StopMark.isMarked("local-root") && resent.last?.1 == "/goal resume")
        m.update(h.id) { $0.state = "working" }
        m.applyUsage(h.id, used: 0.21)
        try? await Task.sleep(for: .milliseconds(300))
        await m.switchBudgetAccount(h.id)
        x = m.helpers[0]
        check(
            "Switch to Forge: that account made the default, a fresh share on it, carries on",
            switched == "ab12cd" && x.pausedForBudget == nil && (x.budget ?? 0) > 0.21 && resent.count == 2)
        m.update(h.id) { $0.state = "working" }
        m.applyUsage(h.id, used: 0.5)
        m.stopHelper(h.id)
        x = m.helpers[0]
        check("Stop it (also by asking): stopped by you, not orange", x.stoppedByYou == true && x.pausedForBudget == nil && x.viewState == .done)
        var plain = Helper(title: "Errand", task: "Find a lamp", sid: "local-other", state: "working", line: "")
        plain.budget = 0.05
        m.helpers.append(plain)
        m.setBudget(plain.id, nil)
        m.applyUsage(plain.id, used: 0.9)
        check("No limit: never paused", m.helpers.last?.state == "working" && m.helpers.last?.budgetOff == true)
        // They write to one paused at its budget ("Direction A"): that's the go-ahead, not a pause 30 s later.
        var named = Helper(title: "Report", task: "Budget 5%: write it", sid: "local-named", state: "working", line: "")
        named.budget = 0.05
        m.helpers.append(named)
        m.applyUsage(named.id, used: 0.06)
        m.carryOnWhenWrittenTo(named.id)
        m.update(named.id) { $0.state = "working" }
        m.applyUsage(named.id, used: 0.07)
        check(
            "written to while paused: it carries on, no limit, not paused again",
            m.helpers.last?.pausedForBudget == nil
                && m.helpers.last?.state == "working" && !StopMark.isMarked("local-named"))

        // The account's limit: pause and ask (never switch by itself), wait for the reset if no answer.
        check(
            "a limit error is a limit, not a failure",
            Limit.hit(stop: "error: 429 rate limit reached for this account", reply: "")
                && Limit.hit(stop: "end_turn", reply: "API Error: You've hit your usage limit · resets 3pm")
                && !Limit.hit(stop: "end_turn", reply: "done"))
        check(
            "a window at 100% is the limit",
            Limit.full(.init(week: 40, reset: nil, session: 100, sessionReset: Date(timeIntervalSince1970: 9)))
                == .some(Date(timeIntervalSince1970: 9))
                && Limit.full(.init(week: 99, reset: nil, session: 20, sessionReset: nil)) == nil)
        let reset = Date().addingTimeInterval(3600)
        let job = Helper(title: "Quebec trip", task: "Goal: plan it", sid: "local-trip", state: "working", line: "")
        m.helpers = [job]
        phone = []
        switched = nil
        m.pauseForLimit(job.id, reset: reset)
        try? await Task.sleep(for: .milliseconds(300))
        var j = m.helpers[0]
        check(
            "paused at the limit, not stopped by them, nothing switched",
            j.pausedForLimit == true && j.stoppedByYou == nil && switched == nil
                && j.viewState == .needsYes && StopMark.isMarked("local-trip"))
        check(
            "the question, on their phone: \(phone.first?.prefix(90) ?? "none")",
            phone.count == 1
                && phone[0].hasPrefix("Quebec trip hit the limit on Omar's Claude. Switch to Forge, or wait for the reset at "))
        check("its turn ending isn't picked back up", m.pausedTurnEnded(job.id, stop: "cancelled") && m.helpers[0].resumeQueued != true)
        let cliOK = Limit.cli(["One", "--limit-answer", "wait", "quebec"]) == 0
        m.tendLimits()
        try? await Task.sleep(for: .milliseconds(300))
        j = m.helpers[0]
        check(
            "\"wait\" from the phone chat (One --limit-answer): kept for this job, still paused",
            cliOK && j.limitChoice == "wait" && j.pausedForLimit == true)
        resent = []
        m.tendLimits(now: reset.addingTimeInterval(120))
        try? await Task.sleep(for: .milliseconds(300))
        check(
            "at the reset it carries on by itself, told nobody pressed Stop",
            m.helpers[0].pausedForLimit == nil && !StopMark.isMarked("local-trip")
                && resent.last?.1 == "/goal resume")
        phone = []
        m.update(job.id) { $0.state = "working" }
        m.pauseForLimit(job.id, reset: reset)
        try? await Task.sleep(for: .milliseconds(300))
        check("next limit for the same job: it waits quietly (their answer), no question", phone.isEmpty && m.helpers[0].pausedForLimit == true)
        let other = Helper(title: "Lamp", task: "Find a lamp", sid: "local-lamp", state: "working", line: "")
        m.helpers.append(other)
        m.pauseForLimit(other.id, reset: nil)
        try? await Task.sleep(for: .milliseconds(300))
        check("another job is asked again (an answer counts for its own job only)", phone.count == 1 && m.helpers[1].limitChoice == nil)
        await m.answerLimit(other.id, switchAccount: true)
        check("Switch, tapped: that account made the default, and it carries on", switched == "ab12cd" && m.helpers[1].pausedForLimit == nil)
        check("the week line", WeekMeter(used: 62, reset: nil).words == "This week: 62% used")

        print(fails == 0 ? "budgets ok" : "budgets: \(fails) failed")
        return fails == 0 ? 0 : 1
    }
}
