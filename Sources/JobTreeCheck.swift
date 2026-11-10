import AppKit
import Foundation

/// `One --test-stop-tree` (preflight, CI only, a test copy): stopping a helper ends its whole tree, with real
/// processes. The Nov 9 case: a program that lost its parent (like the NotArc test app) is still closed, because
/// it was on the helper's record while it ran; another helper's programs and anything not on the record live on.
enum JobTreeCheck {
    static func main(_ args: [String]) {
        guard args.contains("--test-stop-tree") else { return }
        TestWorld.enter()
        MainActor.assumeIsolated {
            Task { @MainActor in exit(await run()) }
        }
        RunLoop.main.run()
    }

    static func spawn(_ cmd: String) -> pid_t {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        try? p.run()
        return p.processIdentifier
    }
    static func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 && ProcTable.info(pid) != nil }
    static func child(of parent: pid_t, named: String) -> pid_t? {
        ProcTable.descendants(of: [parent], in: ProcTable.all()).first { $0.name == named }?.pid
    }

    @MainActor static func run() async -> Int32 {
        var fails = 0
        func check(_ name: String, _ ok: Bool) {
            print((ok ? "  ✓ " : "  ✗ ") + name)
            if !ok { fails += 1 }
        }
        let m = Model.shared
        let sid = "local-stop-check"
        let other = "local-other-helper"
        // The engine's background programs: a test run, and a script that starts a long run and then exits (its
        // run is left with no parent, as a test app or dev server is when its script ends).
        let run = spawn("exec /bin/sleep 301")
        let script = spawn("/bin/sleep 302 & /bin/sleep 3")
        let stubborn = spawn("trap '' TERM; /bin/sleep 303 & wait")  // ignores a polite stop
        let others = spawn("exec /bin/sleep 304")  // another helper's
        let stranger = spawn("exec /bin/sleep 305")  // on nobody's record (the person's own)
        try? await Task.sleep(for: .milliseconds(600))
        let orphan = child(of: script, named: "sleep")
        check("set up: the script's run is under it", orphan != nil)
        let live: [String: [StopStatus.Live]] = [
            sid: [
                .init(pid: run, command: "./selftest.sh NotArc.app"), .init(pid: script, command: "./start.sh"),
                .init(pid: stubborn, command: "./x.sh"),
            ],
            other: [.init(pid: others, command: "npm run dev")],
        ]
        try? FileManager.default.createDirectory(at: StopStatus.dir, withIntermediateDirectories: true)
        try? JSONEncoder().encode(live).write(to: StopStatus.dir.appendingPathComponent("live.json"))
        check("the engine's live list is read", StopStatus.live()[sid]?.count == 3)

        var h = Helper(title: "Finish NotArc", task: "x", state: "working", line: "Running the self-test…")
        h.sid = sid
        var o = Helper(title: "Canvas price options", task: "y", state: "working", line: "Reading…")
        o.sid = other
        m.helpers = [h, o]
        m.tendJobTrees()
        try? await Task.sleep(for: .seconds(1))
        let rec = JobTree.ledger(h.id)
        check(
            "while it works, its programs and what runs under them are on its record",
            rec.contains { $0.pid == orphan ?? -1 } && rec.contains { $0.pid == run })
        check(
            "another helper's go on that helper's record, not this one's",
            !rec.contains { $0.pid == others } && JobTree.ledger(o.id).contains { $0.pid == others })
        try? await Task.sleep(for: .seconds(3))  // the script ends: its run now has no parent
        check(
            "set up: the run lost its parent (its script ended)",
            orphan.flatMap { ProcTable.info($0)?.ppid }.map { $0 != script } == true && !alive(script))

        // A pid on the record that now belongs to someone else (same number, another start time) is never touched.
        var fake = JobTree.ledger(h.id)
        fake.append(.init(pid: stranger, start: 12345, name: "sleep", command: nil))
        JobTree.save(h.id, fake)

        m.stopHelper(h.id)
        let s0 = m.helpers.first { $0.id == h.id }
        check("Stop marks it stopped, closing its tree", s0?.state == "stopped" && s0?.stopping == true && s0?.viewState == .stopped)
        check("the engine gets the mark (its wake-ups dropped, tools blocked)", StopMark.isMarked(sid) && !StopMark.isMarked(other))
        check("the orb line says it's stopping", s0?.line.hasPrefix("Stopping") == true)
        var closedAt: Date?
        let t0 = Date()
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(500))
            if m.helpers.first(where: { $0.id == h.id })?.stopping == nil {
                closedAt = Date()
                break
            }
        }
        let s1 = m.helpers.first { $0.id == h.id }
        check(
            "every program it started is closed, also the one with no parent and the one that ignores a polite stop",
            !alive(run) && !alive(orphan ?? run) && !alive(stubborn) && ProcTable.descendants(of: [stubborn], in: ProcTable.all()).isEmpty)
        check("then it says so", s1?.stopping == nil && s1?.line == HelperTrail.closedLine && s1?.viewState == .done)
        check("within 15 seconds", closedAt.map { $0.timeIntervalSince(t0) < 15 } == true)
        check("another helper's program is untouched", alive(others))
        check("a reused pid (someone else's program now) is untouched", alive(stranger))
        check("the other helper is still working", m.helpers.first { $0.id == o.id }?.state == "working")

        // Their own message in its thread lifts the mark.
        m.helpers[0].lookOnly = nil
        m.liftLookOnly(h.id)
        check("their message in its thread lifts the mark", !StopMark.isMarked(sid))

        // What the orb says while things are still closing, and after a minute.
        let names = JobTree.names([
            .init(pid: 1, start: 0, name: "sleep", command: "./selftest.sh"), .init(pid: 2, start: 0, name: "sleep", command: "./selftest.sh"),
            .init(pid: 3, start: 0, name: "NotArc", command: nil), .init(pid: 4, start: 0, name: "puma", command: nil),
        ])
        check("plain names: \(names)", names == ["2 test runs", "NotArc", "Rails server"])
        check("\"Stopping… 3 programs left\"", HelperTrail.stoppingLine(names).hasPrefix("Stopping… 3 programs left"))
        var stuck = h
        stuck.state = "stopped"
        stuck.stopping = true
        stuck.leftovers = ["NotArc"]
        check(
            "still alive after a minute: it needs you (orange) with \"won't close\"",
            stuck.viewState == .needsYes && HelperTrail.wontClose(["NotArc"]) == "NotArc won't close")
        check("One itself and the engine are never on a record", JobTree.protected(getpid()) && JobTree.protected(1))

        for p in [others, stranger] { kill(p, SIGKILL) }
        print(fails == 0 ? "stop tree ok" : "stop tree: \(fails) failed")
        return fails == 0 ? 0 : 1
    }
}
