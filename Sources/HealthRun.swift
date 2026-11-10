import AppKit
import Darwin
import Foundation

// MARK: - The watchdog's loop, its memory (health.json), what a tap does, and `One --health`

/// `Support/One/health.json`: "Leave it" choices (24 h), what One closed by itself (a day), the last reading.
enum HealthStore {
    struct Done: Codable, Equatable {
        var at: Double
        var line: String
    }
    struct File: Codable {
        var leave: [String: Double] = [:]  // row id: until
        var done: [Done] = []
        var last: [String: Double]?
    }
    static var url: URL { Env.support.appendingPathComponent("health.json") }
    static let lock = NSLock()
    static func load() -> File {
        guard let d = try? Data(contentsOf: url) else { return File() }
        return (try? JSONDecoder().decode(File.self, from: d)) ?? File()
    }
    static func change(_ f: (inout File) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var v = load()
        f(&v)
        if let d = try? JSONEncoder().encode(v) { try? d.write(to: url, options: .atomic) }
    }
    static func leave(_ id: String, now: Date = Date(), limits: HealthLimits = .now) {
        change { $0.leave[id] = now.addingTimeInterval(limits.leaveFor).timeIntervalSince1970 }
        HealthWatch.log("leave it: \(id) for a day")
    }
    static func done(_ line: String, now: Date = Date()) {
        change {
            $0.done.append(Done(at: now.timeIntervalSince1970, line: line))
            $0.done = Array($0.done.filter { now.timeIntervalSince1970 - $0.at < 86400 }.suffix(20))
        }
    }
    /// The rows left after the person's "Leave it" choices that still hold.
    static func shown(_ rows: [HealthRow], now: Date = Date()) -> [HealthRow] {
        let leave = load().leave
        return rows.filter { (leave[$0.id] ?? 0) <= now.timeIntervalSince1970 }
    }
    static func recentDone(now: Date = Date()) -> [Done] { load().done.filter { now.timeIntervalSince1970 - $0.at < 86400 } }
}

extension HealthWatch {
    static func log(_ s: String) {
        let f = Env.hermesHome.appendingPathComponent("logs/one-health.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) one: \(s)\n"
        try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: f) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? Data(line.utf8).write(to: f)
        }
    }

    /// TERM, then KILL whatever still runs after `grace`; only the same program (pid AND start time), never One,
    /// its engine helper or launchd. Returns how many are gone.
    static func close(_ targets: [(pid: pid_t, start: Int)], grace: TimeInterval = HealthLimits.now.grace) async -> Int {
        let same = { (t: (pid: pid_t, start: Int)) in ProcTable.info(t.pid)?.start == t.start && !JobTree.protected(t.pid) }
        let live = targets.filter(same)
        for t in live { kill(t.pid, SIGTERM) }
        let end = Date().addingTimeInterval(grace)
        while Date() < end, live.contains(where: same) { try? await Task.sleep(for: .milliseconds(200)) }
        for t in live where same(t) { kill(t.pid, SIGKILL) }
        try? await Task.sleep(for: .milliseconds(300))
        return live.filter { !same($0) }.count
    }

    /// One whole look: read, decide, close One's own, log. Off the main thread.
    static func pass(_ w: HealthWorld, limits: HealthLimits = .now) async -> (rows: [HealthRow], done: [HealthStore.Done]) {
        let r = read()
        var t = track
        let plan = decide(r, world: w, track: &t, limits: limits)
        track = t
        HealthStore.change {
            $0.last = ["at": r.at.timeIntervalSince1970, "pressure": Double(r.pressure), "swap": Double(r.swap), "free": Double(r.free)]
        }
        if !plan.close.isEmpty {
            log("closing \(plan.close.map { "\($0.proc.p.name)[\($0.proc.p.pid)] (\($0.why), \($0.proc.cwd))" }.joined(separator: ", "))")
            let n = await close(plan.close.map { ($0.proc.p.pid, $0.proc.p.start) }, grace: limits.grace)
            if n > 0, let line = doneLine(Array(plan.close.prefix(n))) {
                HealthStore.done(line)
                log(line)
            }
        }
        let rows = HealthStore.shown(plan.rows)
        let said = Set(lastSaid)
        for row in rows where !said.contains(row.id) { log("warn: \(row.title) \(row.detail ?? "")") }
        lastSaid = rows.map(\.id)
        return (rows, HealthStore.recentDone())
    }
    nonisolated(unsafe) static var lastSaid: [String] = []

    /// What the row's button does, on the person's tap. Returns the line to show after.
    static func act(_ row: HealthRow) async -> String {
        log("tap: \(row.act ?? "?") on \(row.id)")
        if let app = row.app {
            let apps = await MainActor.run { NSRunningApplication.runningApplications(withBundleIdentifier: app) }
            for a in apps { _ = await MainActor.run { a.terminate() } }
            let line = apps.isEmpty ? "Docker wasn't open any more." : "I asked Docker to quit."
            HealthStore.done(line)
            return line
        }
        let n = await close(Array(zip(row.pids.map { pid_t($0) }, row.starts)).map { ($0.0, $0.1) })
        let line: String
        if row.id.hasPrefix("tools:") {
            let g = String(row.id.dropFirst(6))
            line = "I closed \(n == 1 ? "1 dev server" : "\(n) dev servers") left running \(g == "your repos" ? "in your repos" : "from \(g)")."
        } else {
            line = n > 0 ? "I stopped it. The file is still there." : "It had already stopped."
        }
        HealthStore.done(line)
        log(line)
        return line
    }

    // MARK: The loop (every 2 s from Model.tendEveryTwo; a look every 30 s)

    @MainActor static var lastPass = Date.distantPast
    @MainActor static var running = false
    @MainActor static func tend(helpers: [Helper], now: Date = Date()) {
        guard !running, now.timeIntervalSince(lastPass) >= HealthLimits.now.every else { return }
        lastPass = now
        running = true
        let hs = helpers
        Task.detached {
            let w = world(helpers: hs)
            let out = await pass(w)
            await MainActor.run {
                HealthBoard.shared.show(out.rows, done: out.done)
                running = false
            }
        }
    }

    // MARK: `One --health` (read-only): for the assistant inside the folder lock, where ps and top are blocked

    static func cli(_ args: [String]) -> Int32? {
        guard args.contains("--health") else { return nil }
        print(report().joined(separator: "\n"))
        return 0
    }

    /// The same plain lines, from two looks 2 s apart (a program counts as idle when it used no CPU between
    /// them). Writes nothing and closes nothing.
    static func report(helpers: [Helper]? = nil) -> [String] {
        let saved = helpers ?? (try? JSONDecoder().decode([Helper].self, from: UserDefaults.standard.data(forKey: "helpers") ?? Data()))
        let w = world(helpers: saved ?? [], sure: saved != nil)
        var l = HealthLimits.now
        l.idle = 0
        l.writeFor = 0
        l.pressureFor = 0
        var t = Track()
        _ = decide(read(), world: w, track: &t, limits: l)
        Thread.sleep(forTimeInterval: 2)
        let r = read()
        let plan = decide(r, world: w, track: &t, limits: l)
        let pressure = r.pressure >= 4 ? "very tight" : r.pressure >= 2 ? "tight" : "fine"
        var out = [
            "How your Mac is doing:",
            "Memory: \(pressure) · extra memory on the disk: \(plainBytes(r.swap)) · free disk: \(plainBytes(UInt64(max(0, r.free)))) of \(plainBytes(UInt64(max(0, r.total))))",
        ]
        let rows = HealthStore.shown(plan.rows)
        if rows.isEmpty { out.append("Nothing needs you.") }
        for row in rows { out.append("• " + row.title + (row.detail.map { " " + $0 } ?? "") + (row.act.map { " [\($0) / \(row.leave)]" } ?? "")) }
        if let line = doneLine(plan.close) {
            out.append("One would close by itself (idle now): " + line.replacingOccurrences(of: "I closed ", with: ""))
        }
        for d in HealthStore.recentDone() { out.append("Done: " + d.line) }
        return out
    }
}
