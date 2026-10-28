import AppKit

/// `One --test-progress` (preflight, from a test copy): helpers show their real progress. The engine's step events
/// for a working helper's own conversation move its pulse (a step opens and closes, words count once a second, the main
/// conversation and finished helpers are left alone); the line under its orb names the step, adds its time past 30 s,
/// says "Waiting on a slow command" for a vague long one, "No progress for 6 min" after six quiet minutes, and never
/// stops it; the plan line keeps only plain sentences; building, testing and pushing read in plain words; a build that
/// started while another held the lock reads "Waiting for another build…".
enum ProgressCheck {
    static func launch() -> Bool {
        guard CommandLine.arguments.contains("--test-progress") else { return false }
        TestWorld.enter()  // in-memory helpers only; run with ONE_SUPPORT_DIR set to an empty folder
        MainActor.assumeIsolated { exit(run()) }
    }

    @MainActor
    static func run() -> Int32 {
        var fails = 0
        func check(_ name: String, _ ok: Bool, _ got: String = "") {
            print("  \(ok ? "✓" : "✗") \(name)\(ok || got.isEmpty ? "" : "  (got: \(got))")")
            fflush(stdout)
            if !ok { fails += 1 }
        }
        let t0 = Date()
        func p(_ step: String, ran: TimeInterval, quiet: TimeInterval, open: Bool = true) -> HelperPulse {
            HelperPulse(step: step, stepAt: t0.addingTimeInterval(-ran), open: open ? ["x"] : [], lastAt: t0.addingTimeInterval(-quiet))
        }
        func line(_ x: HelperPulse, short: Bool = false, building: Bool = false) -> String {
            HelperProgress.line(x, fallback: "Working on it…", now: t0, building: building, short: short)
        }

        print("1. the line under the orb")
        let l1 = line(p("Reading Helpers.swift…", ran: 5, quiet: 2))
        check("a short step: its plain words", l1 == "Reading Helpers.swift…", l1)
        let l2 = line(p("Running tests…", ran: 130, quiet: 40))
        check("a step past 30 s shows its time", l2 == "Running tests (2 min)…", l2)
        let l3 = line(p("Working on your Mac…", ran: 300, quiet: 300 - 1))
        check("a vague long step: waiting on a slow command", l3 == "Waiting on a slow command (5 min)", l3)
        let l3s = line(p("Working on your Mac…", ran: 300, quiet: 299), short: true)
        check("…and short enough under the orb", l3s == "Slow step (5 min)" && l3s.count <= 24, l3s)
        let l4 = line(p("Reading Model.swift…", ran: 50, quiet: 45, open: false))
        check("between steps: when it last did anything", l4 == "Thinking it over · last step 45s ago", l4)
        let l5 = line(p("Working on your Mac…", ran: 430, quiet: 430))
        check("six quiet minutes: no progress (calm, never stopped)", l5 == "No progress for 7 min", l5)
        check("not stuck at 5 min 59 s", !HelperProgress.stuck(p("x", ran: 359, quiet: 359), now: t0))
        check("stuck at 6 min", HelperProgress.stuck(p("x", ran: 360, quiet: 360), now: t0))
        let l6 = line(p("Building One…", ran: 40, quiet: 40), building: true)
        check("a build behind another one waits its turn", l6 == "Waiting for another build…", l6)
        // The real lock build.sh holds, in a scratch place.
        let lock = Env.support.appendingPathComponent("build.lock").path
        setenv("ONE_BUILD_LOCK", lock, 1)
        try? FileManager.default.createDirectory(atPath: lock, withIntermediateDirectories: true)
        let pid = lock + "/pid"
        FileManager.default.createFile(atPath: pid, contents: Data("1\n".utf8))
        let mine = p("Building One…", ran: 10, quiet: 10)
        try? FileManager.default.setAttributes([.modificationDate: t0.addingTimeInterval(-60)], ofItemAtPath: pid)
        check("another build held the lock first: this one waits", HelperProgress.waitingForBuild(mine, now: t0.addingTimeInterval(10)))
        try? FileManager.default.setAttributes([.modificationDate: t0.addingTimeInterval(-5)], ofItemAtPath: pid)
        check("it took the lock itself: building", !HelperProgress.waitingForBuild(mine, now: t0.addingTimeInterval(20)))
        try? FileManager.default.removeItem(atPath: lock)
        check("no lock: building", !HelperProgress.waitingForBuild(mine, now: t0.addingTimeInterval(30)))
        check("only a build step waits", !HelperProgress.waitingForBuild(p("Running tests…", ran: 10, quiet: 10), now: t0.addingTimeInterval(40)))
        check("no pulse yet: its old line", HelperProgress.line(nil, fallback: "Getting started…", now: t0) == "Getting started…")
        check(
            "durations read plainly", HelperProgress.dur(45) == "45s" && HelperProgress.dur(125) == "2 min" && HelperProgress.dur(3900) == "1 h 5 min"
        )

        print("2. plain words for building, testing, pushing")
        let cases: [(String, String)] = [
            ("terminal: cd ~/Repos/one-progress && ./build.sh 2>&1 | grep error", "Building One…"),
            ("terminal: cd ~/Repos/one-progress && make check", "Running tests…"),
            ("terminal: cd ~/Repos/one-progress && tools/helpers-check.sh --no-build", "Running tests…"),
            ("terminal: cd ~/Repos/one-progress && git push -u origin helper-progress", "Pushing to GitHub…"),
            ("terminal: gh release create v0.9.56 build/One.dmg", "Publishing a release…"),
            ("terminal: gh pr merge 42 --squash", "Merging on GitHub…"),
            ("terminal: cd ~/Repos/one-progress && ./build.sh --package", "Packaging One…"),
            ("terminal: npm run build", "Building the app…"),
            ("terminal: ls -la", "Looking through your files…"),
            ("read_file: /Users/x/Repos/one/Sources/Helpers.swift", "Reading Helpers.swift…"),
        ]
        for (title, want) in cases {
            let got = Plain.step(title)
            check("\(title.prefix(60)) → \(want)", got == want, got)
        }

        print("3. its plan line")
        let plan1 = HelperProgress.plan("Good, the build passed.\n\nNow I'll run the tests, then push the branch.")
        check("the last plain sentence", plan1 == "Now I'll run the tests, then push the branch.", plan1 ?? "nil")
        check("no code or paths", HelperProgress.plan("Let me look at `Sources/Model.swift`") == nil)
        check("no error dumps", HelperProgress.plan("Traceback (most recent call last): error in line 3") == nil)
        check("no tags", HelperProgress.plan("[choices: Yes | No]") == nil)
        check("too short says nothing", HelperProgress.plan("OK.") == nil)
        let plan2 = HelperProgress.plan("**Next:** I'll render the three states and look at each one:")
        check("markdown taken out", plan2 == "Next: I'll render the three states and look at each one.", plan2 ?? "nil")

        print("4. step events move the pulse of a working helper only")
        let m = Model.shared
        var a = Helper(title: "Helper progress", task: "x", sid: "s-a", state: "working", line: "Working on it…")
        a.seen = nil
        let done = Helper(title: "Old one", task: "x", sid: "s-d", state: "done", line: "Done")
        m.helpers = [a, done]
        m.pulseStart(a.id)
        m.pulseText(a.id, "The tests passed. Now I'll push the branch and open a pull request.")
        m.pulse(sid: "s-a", kind: "tool_call", call: "c1", status: nil)
        m.pulseStep(a.id, "Pushing to GitHub…")
        check("a step opens", m.pulses[a.id]?.stepOpen == true && m.pulses[a.id]?.step == "Pushing to GitHub…")
        check(
            "what it said just before is its plan", m.pulses[a.id]?.plan == "Now I'll push the branch and open a pull request.",
            m.pulses[a.id]?.plan ?? "nil")
        m.pulse(sid: "s-a", kind: "tool_call_update", call: "c1", status: "in_progress")
        check("an in-progress update keeps it open", m.pulses[a.id]?.stepOpen == true)
        m.pulse(sid: "s-a", kind: "tool_call_update", call: "c1", status: "completed")
        check("a finished step closes", m.pulses[a.id]?.stepOpen == false)
        m.pulses[a.id]?.lastAt = Date().addingTimeInterval(-400)
        check("quiet for 6+ min: seems stuck", m.seemsStuck(m.helpers[0], now: Date()))
        check("and the assistant is told", m.helperNews().contains("no progress for a while"))
        m.pulse(sid: "s-a", kind: "agent_thought_chunk", call: nil, status: nil)
        check("any activity clears it", !m.seemsStuck(m.helpers[0], now: Date()))
        m.pulse(sid: "s-d", kind: "tool_call", call: "c9", status: nil)
        check("a finished helper gets no pulse", m.pulses[done.id] == nil)
        m.pulse(sid: "s-unknown", kind: "tool_call", call: "c9", status: nil)
        check("an unknown conversation is ignored", m.pulses.count == 1)
        check("a stuck helper keeps working (never stopped on its own)", m.helpers[0].state == "working")
        m.pulseEnd(a.id)
        check("its turn ends: the pulse goes", m.pulses[a.id] == nil)
        check("finished helpers keep their usual line", m.progressLine(done, now: Date()) == "Done")

        print("5. many helpers at once")
        var many: [Helper] = []
        for i in 0..<100 { many.append(Helper(title: "H\(i)", task: "x", sid: "m\(i)", state: "working", line: "")) }
        m.helpers = many
        for h in many { m.pulseStart(h.id) }
        for i in 0..<100 {
            m.pulse(sid: "m\(i)", kind: "tool_call", call: "c", status: nil)
            m.pulseStep(many[i].id, "Building One…")
        }
        for i in stride(from: 0, to: 100, by: 2) { m.pulse(sid: "m\(i)", kind: "tool_call_update", call: "c", status: "failed") }
        let openN = many.filter { m.pulses[$0.id]?.stepOpen == true }.count
        check(
            "100 helpers: each its own pulse, steps close only on their own conversation", m.pulses.count == 100 && openN == 50,
            "\(m.pulses.count)/\(openN)")
        m.helpers = []
        m.pulses = [:]

        print(fails == 0 ? "progress ok" : "progress FAILED (\(fails))")
        return fails == 0 ? 0 : 1
    }
}
