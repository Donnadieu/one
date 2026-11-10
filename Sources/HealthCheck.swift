import AppKit
import Foundation

/// `One --test-health` (preflight, CI only, a test copy): the watchdog's rules on a made-up process table (each
/// class; never Docker, a database, Chrome or anything under /Applications; "leave it" remembered; a stopped
/// helper's dev server closed, a working helper's kept; the plain lines), then a real program left with no parent
/// by a stopped helper, closed by the real loop.
enum HealthCheck {
    static func main(_ args: [String]) {
        guard args.contains("--test-health") else { return }
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

    @MainActor static func run() async -> Int32 {
        var fails = 0
        func check(_ name: String, _ ok: Bool) {
            print((ok ? "  ✓ " : "  ✗ ") + name)
            if !ok { fails += 1 }
        }
        let home = "/Users/sam"
        let stopped = UUID().uuidString
        let working = UUID().uuidString
        let finished = UUID().uuidString
        var w = HealthWorld()
        w.home = home
        w.known = [stopped, working, finished]
        w.stopped = [stopped]
        w.busy = [working]
        w.work = "/Users/sam/Library/Application Support/One/work"
        w.copies = [("/Users/sam/Repos/forge-fix-login", working), ("/Users/sam/Repos/forge-old-job", finished)]
        w.roots = [500]
        func p(_ pid: pid_t, _ path: String, ppid: pid_t = 1, cwd: String = "", mem: UInt64 = 0, args: [String] = []) -> HealthProc {
            HealthProc(p: ProcInfo(pid: pid, ppid: ppid, start: 7, path: path), cwd: cwd, cpu: 0, memory: mem, written: 0, args: args)
        }
        let node = "/opt/homebrew/bin/node"
        let ruby = "/opt/homebrew/bin/ruby"
        let procs = [
            p(500, "/Applications/One.app/Contents/MacOS/One", ppid: 1),
            p(101, ruby, cwd: home + "/Repos/notarc"),  // on the stopped helper's record
            p(102, "/bin/sleep", ppid: 1, cwd: home + "/Repos/notarc"),  // a stopped helper's: anything goes
            p(103, node, cwd: home + "/Repos/forge-fix-login"),  // on the working helper's record
            p(104, node, cwd: home + "/Repos/x"),  // on the finished helper's record (a dev server)
            p(105, "/bin/sleep", cwd: home + "/Repos/x"),  // on the finished helper's record, not a dev server
            p(106, node, ppid: 501, cwd: w.work + "/ledger"),  // run under One's engine, in One's work folder
            p(501, "/bin/zsh", ppid: 500, cwd: w.work),
            p(107, node, cwd: "/Users/sam/Repos/forge-old-job"),  // a finished helper's copy of a repo, no parent
            p(108, node, cwd: "/Users/sam/Repos/forge-fix-login/web"),  // the working helper's copy: kept
            p(201, ruby, cwd: home + "/conductor/workspaces/lisbon/app"),  // Conductor's
            p(202, node, cwd: home + "/conductor/workspaces/oslo"),
            p(203, node, cwd: home + "/forge-workspaces/w1"),  // Forge's
            p(204, "/usr/local/bin/vite", cwd: home + "/Repos/site"),  // his repos
            p(205, node, cwd: home + "/conductor/workspaces/x", args: [node, "agent-browser/daemon.js"]),  // a browser tool: never
            p(301, "/opt/homebrew/opt/postgresql@16/bin/postgres", cwd: home + "/Repos/site"),
            p(302, "/Applications/Docker.app/Contents/MacOS/com.docker.backend", mem: 9_000_000_000),
            p(303, "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", mem: 2_000_000_000),
            p(304, "/Applications/Cursor.app/Contents/Resources/node", cwd: home + "/Repos/site"),
            p(305, "/Applications/Xcode.app/Contents/MacOS/Xcode"),
            p(306, "/usr/local/bin/redis-server", cwd: home + "/Repos/site"),
            p(307, node, cwd: home + "/Documents/my-app"),  // his own project elsewhere: only his
        ]
        func entry(_ pid: Int32) -> JobTree.Entry { .init(pid: pid, start: 7, name: "x", command: nil) }
        w.records = [
            stopped: [101, 102, 301, 302, 303, 304].map(entry),  // a database, Docker, Chrome and an app on a record: still his
            working: [103].map(entry),
            finished: [104, 105].map(entry),
        ]
        let under = Set(ProcTable.descendants(of: w.roots, in: procs.map(\.p)).map(\.pid))
        let cls = Dictionary(uniqueKeysWithValues: procs.map { ($0.p.pid, HealthWatch.owner($0, world: w, under: under)) })
        check("a stopped helper's dev server and its other programs are One's own", cls[101] == .one("stopped") && cls[102] == .one("stopped"))
        check("a working helper's are kept", cls[103] == .keep && cls[108] == .keep)
        check("a finished helper's are One's own", cls[104] == .one("finished") && cls[105] == .one("finished"))
        check("a dev server in a finished helper's copy of a repo is One's", cls[107] == .one("helpers"))
        var calmWorld = w
        calmWorld.busy = []
        check(
            "one One's engine runs in its work folder is One's, but only while no helper works",
            cls[106] == .keep && HealthWatch.owner(procs[6], world: calmWorld, under: under) == .one("helpers"))
        check(
            "Conductor's, Forge's and his repos' leftovers are his tools'",
            cls[201] == .tools("Conductor") && cls[202] == .tools("Conductor") && cls[203] == .tools("Forge") && cls[204] == .tools("your repos"))
        check(
            "never Docker, a database, Chrome, Xcode, an app under /Applications (even on a record), a browser tool or his own project",
            ([205, 301, 302, 303, 304, 305, 306, 307] as [pid_t]).allSatisfy { cls[$0] == .his })
        var unsure = w
        unsure.sure = false
        check("when the helper list can't be read, nothing on a record is closed", HealthWatch.owner(procs[1], world: unsure, under: under) == .keep)

        // Idle for half an hour first: a look now, a look later with some CPU used by one of them.
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        var r = HealthReading(at: t0, pressure: 1, swap: 0, free: 200_000_000_000, total: 500_000_000_000, procs: procs)
        var t = HealthWatch.Track()
        let l = HealthLimits()
        let first = HealthWatch.decide(r, world: w, track: &t, limits: l) { _ in nil }
        check("nothing is closed or named before it has been idle half an hour", first.close.isEmpty && first.rows.isEmpty)
        r.at = t0.addingTimeInterval(31 * 60)
        r.procs[r.procs.firstIndex { $0.p.pid == 202 }!].cpu = 120_000_000_000  // Oslo's server is busy
        let plan = HealthWatch.decide(r, world: w, track: &t, limits: l) { _ in nil }
        let closing = Set(plan.close.map(\.proc.p.pid))
        check("One closes its own idle ones: \(closing.sorted())", closing == [101, 102, 104, 107])
        check("a finished helper's program that isn't a dev server is left alone", !closing.contains(105))
        check(
            "never a working helper's, his tools' or his own", closing.isDisjoint(with: [103, 106, 108, 201, 203, 204, 301, 302, 303, 304, 305, 306]))
        let rows = plan.rows.map(\.title)
        check(
            "his tools' leftovers: one row per group: \(rows)",
            rows == [
                "1 dev server left running from Conductor.", "1 dev server left running from Forge.", "1 dev server left running in your repos.",
            ])
        check("a busy one isn't in its group", plan.rows.first { $0.id == "tools:Conductor" }?.pids == [201])
        check("one tap closes the group", plan.rows.first { $0.id == "tools:Conductor" }?.act == "Close it")
        let done = HealthWatch.doneLine(plan.close.filter { $0.why == "stopped" && $0.proc.p.pid == 101 } + [(procs[4], "stopped")])
        check("\"\(done ?? "")\"", done == "I closed 2 dev servers a stopped helper left running.")
        check(
            "and for other programs",
            HealthWatch.doneLine(plan.close.filter { $0.proc.p.pid == 102 }) == "I closed 1 program a stopped helper left running.")

        // The disk, a runaway writer, memory: the plain lines.
        var d = HealthReading(at: t0, pressure: 4, swap: 3_000_000_000, free: 21_000_000_000, total: 500_000_000_000)
        d.procs = [
            p(302, "/Applications/Docker.app/Contents/MacOS/com.docker.backend", mem: 9_000_000_000), p(401, "/Users/sam/bin/qa-runner", ppid: 40),
        ]
        var t2 = HealthWatch.Track()
        let qa = { (_: pid_t) -> (path: String, size: Int64)? in ("/Users/sam/Downloads/qa.log", 78_000_000_000) }
        for k in 0...1 {
            d.at = t0.addingTimeInterval(Double(k) * 30)
            d.procs[1].written = UInt64(k) * 9_000_000_000
            _ = HealthWatch.decide(d, world: w, track: &t2, limits: l, fileOf: qa)
        }
        d.at = t0.addingTimeInterval(45)
        d.procs[1].written = 13_500_000_000
        let early = HealthWatch.decide(d, world: w, track: &t2, limits: l, fileOf: qa)
        check("a fast writer isn't named before a minute", early.rows.first?.detail?.contains("qa.log") != true)
        d.at = t0.addingTimeInterval(90)
        d.procs[1].written = 27_000_000_000
        let full = HealthWatch.decide(d, world: w, track: &t2, limits: l, fileOf: qa)
        let disk = full.rows.first
        check("\"\(disk?.title ?? "")\"", disk?.title == "Your Mac is almost full: 21 GB left.")
        check("\"\(disk?.detail ?? "")\"", disk?.detail == "qa-runner is writing a 78 GB file in Downloads/qa.log, fast. Stop it?")
        check("with Stop it / Leave it", disk?.act == "Stop it" && disk?.leave == "Leave it" && disk?.pids == [401])
        let mem = full.rows.first { $0.id.hasPrefix("memory") }
        check("\"\(mem?.title ?? "")\"", mem?.title == "Memory is tight. Docker is using 9 GB.")
        check("Docker: only Quit Docker, on a tap", mem?.act == "Quit Docker" && mem?.app == "com.docker.docker" && mem?.gentle == true)
        check("critical first", full.rows.first?.critical == true)
        let calm = HealthWatch.decide(
            HealthReading(at: t0, pressure: 1, swap: 0, free: 200_000_000_000, total: 500_000_000_000), world: w, track: &t2)
        check("a healthy Mac says nothing", calm.rows.isEmpty)
        var warn = HealthWatch.Track()
        let pressed = HealthReading(at: t0, pressure: 2, swap: 0, free: 200_000_000_000, total: 500_000_000_000)
        let w1 = HealthWatch.decide(pressed, world: w, track: &warn, limits: l)
        var later = pressed
        later.at = t0.addingTimeInterval(301)
        let w2 = HealthWatch.decide(later, world: w, track: &warn, limits: l)
        check("memory \"warn\" is said only after 5 minutes", w1.rows.isEmpty && w2.rows.first?.title == "Memory is tight.")
        check("sizes in plain words", HealthWatch.plainBytes(21_400_000_000) == "21 GB" && HealthWatch.plainBytes(1_500_000_000) == "1.5 GB")

        // The line under the orb, and "Leave it" for a day.
        let b = HealthBoard()
        b.show(full.rows, done: [])
        check(
            "the line: \"\(b.line?.text ?? "") · \(b.line?.more ?? 0) more\"",
            b.line?.text == "Your Mac is almost full: 21 GB left" && b.line?.more == 1)
        check("orange only when critical", b.critical && !HealthBoard().critical)
        HealthStore.leave(disk!.id, now: t0)
        check("\"Leave it\" is kept in health.json", HealthStore.load().leave[disk!.id] != nil)
        check("left alone for a day", HealthStore.shown(full.rows, now: t0.addingTimeInterval(3600)).map(\.id) == [mem!.id])
        check("then said again", HealthStore.shown(full.rows, now: t0.addingTimeInterval(86401)).count == 2)

        // Real: a stopped helper's program that lost its parent is closed by the real loop; a working helper's lives.
        let m = Model.shared
        let sid = "local-health-stopped"
        let osid = "local-health-working"
        let script = spawn("/bin/sleep 300 & /bin/sleep 2")
        let other = spawn("/bin/sleep 301 & /bin/sleep 2")
        try? await Task.sleep(for: .milliseconds(600))
        var h = Helper(title: "Finish NotArc", task: "x", state: "working", line: "")
        h.sid = sid
        var o = Helper(title: "Canvas price options", task: "y", state: "working", line: "")
        o.sid = osid
        let live: [String: [StopStatus.Live]] = [sid: [.init(pid: script, command: "./run.sh")], osid: [.init(pid: other, command: "./run.sh")]]
        let table = ProcTable.all()
        _ = JobTree.track(h.id, sessions: [sid], live: live, table: table)
        _ = JobTree.track(o.id, sessions: [osid], live: live, table: table)
        let orphan = ProcTable.descendants(of: [script], in: table).first { GatewayGuard.arguments(of: $0.pid).contains("300") }
        let kept = ProcTable.descendants(of: [other], in: table).first { GatewayGuard.arguments(of: $0.pid).contains("301") }
        let onRecord = JobTree.ledger(h.id).contains { $0.pid == orphan?.pid ?? -1 } && JobTree.ledger(o.id).contains { $0.pid == kept?.pid ?? -1 }
        check("set up: both runs are on their helpers' records", orphan != nil && kept != nil && onRecord)
        try? await Task.sleep(for: .seconds(3))
        let lost = ProcTable.all().filter { p in JobTree.ledger(h.id).contains { $0.pid == p.pid && $0.start == p.start } }
        // Its new parent is whatever the Mac picks (pid 1 here, a reaper on CI): only "not its script" holds.
        check("set up: the stopped helper's run lost its parent", !lost.isEmpty && lost.allSatisfy { $0.ppid != script } && !alive(script))
        h.state = "stopped"
        h.stoppedByYou = true
        m.helpers = [h, o]
        HealthWatch.lastPass = .distantPast
        HealthWatch.tend(helpers: m.helpers)
        var said: String?
        for _ in 0..<60 {
            try? await Task.sleep(for: .milliseconds(500))
            if let f = HealthBoard.shared.fresh, !HealthWatch.running {
                said = f
                break
            }
        }
        check("closed by itself: \(lost.map { "\($0.name)[\($0.pid)]" })", lost.allSatisfy { !alive($0.pid) })
        check("the working helper's is kept", kept.map { alive($0.pid) } == true)
        check("then it says so: \"\(said ?? "")\"", said == "I closed 1 program a stopped helper left running.")
        check("it's in the list", HealthBoard.shared.done.contains { $0.line == said })
        check("the home line shows the warning first", HealthBoard.shared.line?.text == "Your Mac is almost full: 21 GB left")
        let logged = (try? String(contentsOf: Env.hermesHome.appendingPathComponent("logs/one-health.log"), encoding: .utf8)) ?? ""
        check("logged in one-health.log", logged.contains("closing sleep[") && logged.contains(said ?? "-"))
        check("Leave it logged", logged.contains("leave it: "))

        // `One --health`: the same lines, read-only (a fake 21 GB left, ONE_HEALTH_FAKE_DISK_GB=21).
        let before = (try? Data(contentsOf: HealthStore.url)) ?? Data()
        let out = HealthWatch.report(helpers: m.helpers)
        print(out.map { "    | " + $0 }.joined(separator: "\n"))
        check(
            "--health prints the plain lines",
            out.first == "How your Mac is doing:" && out.contains { $0.contains("Your Mac is almost full: 21 GB left.") })
        check("--health writes nothing", ((try? Data(contentsOf: HealthStore.url)) ?? Data()) == before)
        if let k = kept { kill(k.pid, SIGKILL) }
        print(fails == 0 ? "health ok" : "health FAILED (\(fails))")
        return fails == 0 ? 0 : 1
    }
}
