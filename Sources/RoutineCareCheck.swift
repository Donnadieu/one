import Foundation

/// `One --test-routine-care` (preflight, from a test copy): routines that fix themselves, and ask once when only the
/// person can (Omar, Nov 19 2026: "We had a routine fail three times today and you didn't do anything about it").
/// Replays that day on made-up jobs: the three X replies routines and X signed out of the hidden browser.
///  1. A routine failing on a sign-in raises exactly one "needs you" item (one hand-off request) and one phone ping;
///     the routines that need the same sign-in are paused; a fixer helper starts for the one that failed.
///  2. A failure with no sign-in cause starts one fixer helper (its brief: every fix that needs nobody, never
///     `One --connect-chrome`, hand an only-you step to One), never a second one for the same routine.
///  3. A pre-flight an hour before a run catches a missing cookie and raises the same item early.
///  4. While a blocker is open, later failures of affected routines are swallowed (no new item, ping or fixer).
///  5. Reminders at sensible times, never at night; a fix clears the item and catches the missed runs up, one
///     routine at a time, today's missed runs only.
///  6. The weekly routine health line for a good morning or status report.
///  7. A helper already on that same failed run (working or finished, that day) means no fixer: one helper per run.
enum RoutineCareCheck {
    static func cli(_ args: [String]) {
        guard args.contains("--test-routine-care") else { return RoutinesCheck.cli(args) }
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
        let noon = cal.date(bySettingHour: 13, minute: 6, second: 0, of: Date(timeIntervalSince1970: 1_795_600_000)) ?? Date()
        let iso = ISO8601DateFormatter()
        func at(_ h: Double) -> String { iso.string(from: noon.addingTimeInterval(h * 3600)) }
        func job(_ id: String, _ name: String, last: Double, next: Double, failed: String? = nil) -> [String: Any] {
            var j: [String: Any] = [
                "id": id, "name": name, "enabled": true, "state": "scheduled", "schedule": ["kind": "cron", "expr": "0 13 * * *"],
                "last_status": failed == nil ? "ok" : "error", "last_run_at": at(last), "next_run_at": at(next),
                "failure_streak": failed == nil ? 0 : 1,
            ]
            if let failed { j["last_error"] = failed }
            return j
        }
        let x = RoutineCare.Need(site: "x.com", port: 9224, cookies: ["auth_token", "ct0", "twid"], login: "https://x.com/i/flow/login")
        let needs: [String: [RoutineCare.Need]] = ["xam": [x], "xpm": [x], "xev": [x]]
        let signedOut = "Not done: X is signed out in the hidden browser, so I skipped the afternoon run."
        func jobs(_ list: [[String: Any]]) -> [RoutineCare.Job] { list.compactMap { RoutineCare.Job($0, out: nil) } }
        func count(_ e: [RoutineCare.Effect], _ k: String) -> Int { e.filter { $0.kind == k }.count }

        // 1. The afternoon run fails because X is signed out.
        print("1. a routine fails on a sign-in")
        var s = RoutineCare.State()
        s.handled = ["xam": at(-4), "xpm": at(-24), "xev": at(-19)]  // runs One already looked at
        var day = [
            job("xam", "Forge X replies (morning)", last: -4, next: 20),
            job("xpm", "Forge X replies (afternoon)", last: -0.03, next: 24, failed: signedOut),
            job("xev", "Forge X replies (evening)", last: -19, next: 4.9),
        ]
        var e = RoutineCare.step(&s, jobs: jobs(day), needs: needs, signedIn: [x.key: false], now: noon)
        check("exactly one needs-you item", s.open.count == 1 && count(e, "ask") == 1)
        check("exactly one phone ping", count(e, "ping") == 1)
        check("the item says what's blocked and what they do", s.open.first.map { RoutineCare.title($0).contains("X") } ?? false)
        check(
            "every routine that needs the X sign-in is paused, once each",
            Set(e.compactMap { $0.kind == "pause" ? $0.job : nil }) == ["xam", "xpm", "xev"] && count(e, "pause") == 3)
        check("a fixer helper starts for the routine that failed", e.contains { $0.kind == "fixer" && $0.job == "xpm" } && count(e, "fixer") == 1)
        check("the failed run is counted as missed", s.open.first?.missed["xpm"]?.count == 1)
        // Carry the effects out the way One does: one hand-off request on disk, one message to the phone chat.
        var phone: [String] = []
        Messenger.standIn = { _, text, _ in phone.append(text) }
        var cron: [[String]] = []
        var helpers: [(String, String)] = []
        let doer = RoutineCare.Doer(
            cron: { cron.append($0) }, fixer: { helpers.append(($0, $1)) }, say: { _ in }, target: { _ in "tab-1" })
        RoutineCare.perform(e, state: s, doer: doer, now: noon)
        let asks = HumanStep.pending().filter { RoutineCare.isAsk($0.id) }
        check("one hand-off request written, kind sign in on port 9224", asks.count == 1 && asks.first?.kind == "sign_in" && asks.first?.port == 9224)
        check("one message went to the phone chat", phone.count == 1 && phone.first?.contains("X") == true)
        check("the engine was asked to pause the three", cron.filter { $0.first == "cron" && $0.dropFirst().first == "pause" }.count == 3)
        check("the fixer helper got the job", helpers.count == 1)

        // A minute later, nothing new: no second item, no second ping.
        e = RoutineCare.step(&s, jobs: jobs(day), needs: needs, signedIn: [x.key: false], now: noon.addingTimeInterval(60))
        check("a minute later: no second item and no second ping", s.open.count == 1 && count(e, "ask") == 0 && count(e, "ping") == 0)

        // 2. A failure with no sign-in cause: one fixer helper, with every fix that needs nobody.
        print("2. a failure only a fixer can look at")
        var r = RoutineCare.State()
        r.handled = ["rl": at(-24)]
        let rate = job("rl", "Daily post", last: -0.02, next: 23, failed: "Not done: X said \"rate limit\" on the first reply.")
        e = RoutineCare.step(&r, jobs: jobs([rate]), needs: [:], signedIn: [:], now: noon)
        let brief = e.first { $0.kind == "fixer" }?.text ?? ""
        check("one fixer helper", count(e, "fixer") == 1 && count(e, "ask") == 0 && count(e, "ping") == 0)
        check("its brief tries find_session and a retry with backoff", brief.contains("find_session") && brief.contains("backoff"))
        check(
            "its brief never copies Chrome and hands only-you steps to One",
            brief.contains("never run `One --connect-chrome`") && brief.contains("One --routine-care block"))
        check("its brief re-runs the missed run if fixed", brief.contains("hermes cron run rl"))
        var later = rate
        later["last_run_at"] = at(1)
        e = RoutineCare.step(&r, jobs: jobs([later]), needs: [:], signedIn: [:], now: noon.addingTimeInterval(3700))
        check("the same routine failing again an hour later starts no second fixer", count(e, "fixer") == 0)
        // The fixer finds it's only theirs to do: its `One --routine-care block` raises the same one item.
        RoutineCare.inbox(["block", "rl", "--site", "x.com", "--kind", "sign_in", "--why", "X wants a code"])
        e = RoutineCare.step(&s, jobs: jobs(day), needs: needs, signedIn: [x.key: false], now: noon.addingTimeInterval(120))
        check("a fixer's block on the same sign-in adds to the one item, no new ask or ping", s.open.count == 1 && count(e, "ask") == 0)

        // 3. Pre-flight: an hour before a run, a missing cookie raises the item early.
        print("3. pre-flight")
        var p = RoutineCare.State()
        p.handled = ["pf": at(-20)]
        let pf = job("pf", "Forge X replies (evening)", last: -20, next: 0.83)
        let far = job("pf", "Forge X replies (evening)", last: -20, next: 3)
        check("a run 3 hours away isn't checked yet", RoutineCare.wanted(p, jobs: jobs([far]), needs: ["pf": [x]], now: noon).isEmpty)
        check("a run 50 minutes away is", RoutineCare.wanted(p, jobs: jobs([pf]), needs: ["pf": [x]], now: noon) == [x])
        var ok = p
        e = RoutineCare.step(&ok, jobs: jobs([pf]), needs: ["pf": [x]], signedIn: [x.key: true], now: noon)
        check("signed in: no item, checked once for that run", ok.open.isEmpty && e.isEmpty && ok.preflighted["pf"] == at(0.83))
        e = RoutineCare.step(&p, jobs: jobs([pf]), needs: ["pf": [x]], signedIn: [x.key: false], now: noon)
        check("a missing cookie raises the item early, before any failure", p.open.count == 1 && p.open.first?.source == "preflight")
        check("with a ping and the routine paused before it runs", count(e, "ping") == 1 && count(e, "ask") == 1 && e.contains { $0.kind == "pause" })
        check(
            "the cookie check reads all three X cookies",
            RoutineCare.hasAll(["auth_token": "a", "ct0": "b", "twid": "c"], x) && !RoutineCare.hasAll(["auth_token": "a", "ct0": "b"], x))

        // 4. Same blocker, no repeat noise.
        print("4. later failures while it's open")
        day[2] = job("xev", "Forge X replies (evening)", last: 0.1, next: 24, failed: signedOut)  // ran before it was paused
        day.append(job("post", "Daily build post on X", last: 0.12, next: 23, failed: "Not done: X is signed out (x.com login page)."))
        s.handled["post"] = at(-24)
        e = RoutineCare.step(&s, jobs: jobs(day), needs: needs, signedIn: [x.key: false], now: noon.addingTimeInterval(600))
        check("no new item, ping or fixer", count(e, "ask") == 0 && count(e, "ping") == 0 && count(e, "fixer") == 0)
        check("both reports kept out of the chat", Set(e.compactMap { $0.kind == "swallow" ? $0.job : nil }) == ["xev", "post"])
        check("a routine that never said it needs X but failed on it joins the item", s.open.first?.routines.contains("post") == true)
        check("and is paused too", e.contains { $0.kind == "pause" && $0.job == "post" })

        // 5. Reminders: sensible times, never at night.
        print("5. reminders")
        e = RoutineCare.step(&s, jobs: jobs(day), needs: needs, signedIn: [x.key: false], now: noon.addingTimeInterval(31 * 60))
        check("after 30 minutes: one reminder to the phone and the item raised again", count(e, "ping") == 1 && count(e, "ask") == 1)
        e = RoutineCare.step(&s, jobs: jobs(day), needs: needs, signedIn: [x.key: false], now: noon.addingTimeInterval(33 * 60))
        check("not again two minutes later", count(e, "ping") == 0)
        e = RoutineCare.step(&s, jobs: jobs(day), needs: needs, signedIn: [x.key: false], now: noon.addingTimeInterval(2.1 * 3600), quiet: true)
        check("never at night", count(e, "ping") == 0 && count(e, "ask") == 0)
        check("the item stays on screen at night", s.open.count == 1)

        // 6. A fix clears the item and catches up, one routine at a time.
        print("6. a fix catches up")
        let fixedAt = noon.addingTimeInterval(3 * 3600)
        e = RoutineCare.step(&s, jobs: jobs(day), needs: needs, signedIn: [x.key: true], now: fixedAt)
        check("signed in again: the item is gone", s.open.isEmpty)
        check("it says so, in the chat and on the phone", count(e, "say") == 1 && count(e, "ping") == 1)
        check("the first routine is turned back on, only one at a time", count(e, "resume") == 1)
        let first = e.first { $0.kind == "resume" }?.job ?? ""
        let missedToday = ["xpm", "xev", "post"]
        check("a routine with a missed run today goes first", missedToday.contains(first))
        e = RoutineCare.step(&s, jobs: jobs(day), needs: needs, signedIn: [x.key: true], now: fixedAt.addingTimeInterval(6 * 60))
        check("its missed run didn't come up by itself: run once now", count(e, "run") == 1 && e.first { $0.kind == "run" }?.job == first)
        e = RoutineCare.step(&s, jobs: jobs(day), needs: needs, signedIn: [x.key: true], now: fixedAt.addingTimeInterval(7 * 60))
        check("never twice", count(e, "run") == 0)
        if let k = day.firstIndex(where: { $0["id"] as? String == first }) {
            day[k]["last_run_at"] = iso.string(from: fixedAt.addingTimeInterval(8 * 60))
            day[k]["last_status"] = "ok"
            day[k]["last_error"] = NSNull()
            day[k]["failure_streak"] = 0
        }
        var seen: [String] = [first]
        var ran: [String] = [first]
        for m in 0..<40 {
            e = RoutineCare.step(&s, jobs: jobs(day), needs: needs, signedIn: [x.key: true], now: fixedAt.addingTimeInterval(Double(9 + m) * 60))
            seen += e.compactMap { $0.kind == "resume" ? $0.job : nil }
            ran += e.compactMap { $0.kind == "run" ? $0.job : nil }
            for j in e.compactMap({ $0.kind == "run" ? $0.job : nil }) {
                if let k = day.firstIndex(where: { $0["id"] as? String == j }) {
                    day[k]["last_run_at"] = iso.string(from: fixedAt.addingTimeInterval(Double(10 + m) * 60))
                    day[k]["last_status"] = "ok"
                    day[k]["last_error"] = NSNull()
                    day[k]["failure_streak"] = 0
                }
            }
        }
        check("every routine it paused is turned back on, each once", seen.sorted() == ["post", "xam", "xev", "xpm"])
        check("each missed run today is made up once", ran.sorted() == ["post", "xev", "xpm"])
        check("the morning routine (no missed run today) is never run early", !ran.contains("xam"))
        check("caught up and logged", RoutineCare.events().contains { $0.kind == "caught_up" })

        // 7. The weekly health line.
        print("7. the weekly routine health line")
        let wk = RoutineCare.weekLine(RoutineCare.events(), now: fixedAt.addingTimeInterval(3600))
        check("says the failures and their cause", wk.contains("failed") && wk.contains("X signed out"))
        check("and the time to fix", wk.contains("3 h"))
        let old = RoutineCare.Event(at: noon.addingTimeInterval(-9 * 86400), job: "old", kind: "failed", cause: "other")
        check("last week's don't count", !RoutineCare.weekLine([old], now: noon).contains("failed"))
        check("a good morning gets it", RoutineCare.weekNote("Good morning!", now: fixedAt.addingTimeInterval(3600)).contains(wk))
        check("anything else doesn't", RoutineCare.weekNote("Find me a flight", now: fixedAt.addingTimeInterval(3600)).isEmpty)

        // 8. Routines say which sign-ins they need.
        print("8. declared sign-ins")
        _ = RoutineCare.cli(["One", "--routine-care", "need", "abc", "x.com", "9224", "auth_token,ct0,twid", "https://x.com/i/flow/login"])
        check("`One --routine-care need` writes the declaration", RoutineCare.needs()["abc"] == [x])
        check("the assistant is told to declare them", RoutineCare.note.contains("--routine-care need"))
        // 9. Nov 20 2026: "Resume vaccines upload" finished the long video's upload at 8:22, then a fixer started for
        //    the same failed run anyway ("Fix Then It Clicked:"). Two helpers on one run; there must be one.
        print("9. a helper already on the same failed run")
        let long = "Then It Clicked: long video (Tue/Fri)"
        var v = RoutineCare.State()
        v.handled = ["tic": at(-96)]
        let upload = job("tic", long, last: -0.7, next: 90, failed: "Partly done: the video is made but never finished uploading.")
        let run = noon.addingTimeInterval(-0.7 * 3600)
        let resume = RoutineCare.HelperRef(
            title: "Resume vaccines upload", task: "Resume the interrupted YouTube upload. The Friday long-video routine tic made it.",
            started: run.addingTimeInterval(15 * 60), state: "done")
        var onRun: [String] = [resume.title]  // the helpers on that run: the one already there
        let d9 = RoutineCare.Doer(cron: { _ in }, fixer: { t, _ in onRun.append(t) }, say: { _ in }, target: { _ in nil })
        e = RoutineCare.step(&v, jobs: jobs([upload]), needs: [:], signedIn: [:], now: noon, helpers: [resume])
        RoutineCare.perform(e, state: v, doer: d9, now: noon)
        check("one helper on the failed run: no fixer starts when one already took it on", onRun.count == 1 && count(e, "fixer") == 0)
        e = RoutineCare.step(&v, jobs: jobs([upload]), needs: [:], signedIn: [:], now: noon.addingTimeInterval(60), helpers: [resume])
        RoutineCare.perform(e, state: v, doer: d9, now: noon)
        check("nor a minute later", onRun.count == 1)
        let line = RoutineCare.onItLine(v, job: "tic", run: at(-0.7)) ?? ""
        check("the routine's report names the helper already on it", line.contains("Resume vaccines upload") && line.contains("no fixer"))
        check("and the log says the fixer was skipped", RoutineCare.events().contains { $0.kind == "fixer_skipped" && $0.job == "tic" })
        RoutineCare.save(v)
        let card = Routines.routine(upload, dir: Routines.cron, now: noon)
        check("the routine's card on the dial says who's on it", card?.onIt?.contains("Resume vaccines upload") == true)
        check("the next run's card doesn't", RoutineCare.onItLine(v, job: "tic", run: at(90)) == nil)
        // Not the same run: another routine's helper, one from the day before, or one they stopped. The fixer starts.
        let others = [
            RoutineCare.HelperRef(title: "Daily post", task: "Post today's build on X.", started: run.addingTimeInterval(600), state: "working"),
            RoutineCare.HelperRef(title: resume.title, task: resume.task, started: run.addingTimeInterval(-86400), state: "done"),
            RoutineCare.HelperRef(title: resume.title, task: resume.task, started: run.addingTimeInterval(600), state: "stopped"),
        ]
        var w = RoutineCare.State()
        w.handled = ["tic": at(-96)]
        e = RoutineCare.step(&w, jobs: jobs([upload]), needs: [:], signedIn: [:], now: noon, helpers: others)
        check("a helper on another routine, an earlier day, or stopped doesn't count: one fixer", count(e, "fixer") == 1)
        let named = RoutineCare.HelperRef(
            title: "Upload fix", task: "The “\(long)” run failed; finish it.", started: run.addingTimeInterval(60), state: "working")
        var n9 = RoutineCare.State()
        n9.handled = ["tic": at(-96)]
        e = RoutineCare.step(&n9, jobs: jobs([upload]), needs: [:], signedIn: [:], now: noon, helpers: [named])
        check("a helper naming the routine (not its id) and still working counts too", count(e, "fixer") == 0)

        Messenger.standIn = nil
        print(fails == 0 ? "routine care ok" : "routine care: \(fails) failed")
        return fails == 0 ? 0 : 1
    }
}
