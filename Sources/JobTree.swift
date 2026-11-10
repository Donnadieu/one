import AppKit
import Darwin
import Foundation

// MARK: - Stop means stop: stopping a helper ends its whole tree

/// Nov 9, 2026: Omar stopped "Finish NotArc". Its turn ended, but its background test runs kept going, and the first
/// one to finish woke the stopped conversation up again; it sent out 5 new sub-helpers. The orb said "Stopped" for
/// 26 minutes while it worked, and about 90 programs (test apps, test runs) had to be killed by hand.
///
/// Now stopping a helper:
/// 1. marks its conversation in `guard/stopped/` (engine-readable, not writable). The engine plugin
///    `one-stop` (tools/overlay/plugins/one-stop) then drops every wake-up for it, blocks every tool call it or its
///    sub-helpers still try, kills the background programs the engine started for it and stops its sub-helpers;
/// 2. here, kills what the engine doesn't know about: everything that ran under those programs while the helper
///    worked (recorded every 6 s in `helpers/<id>.procs.json`, so a program that later lost its parent, like a
///    test app or a dev server, is still known to be the helper's), checked by start time so a reused pid is
///    never touched;
/// 3. shows "Stopping… N programs left" until the tree is empty, then "Stopped · everything it started is closed".
///    Still alive after a minute: "<name> won't close" and Force stop.
/// Never: another helper's programs, the main chat, routines, the engine, One's hidden browsers, or anything
/// that isn't in this helper's record. The person's own message in its thread lifts the mark.
enum StopMark {
    static var dir: URL { BrowserGuard.dir.appendingPathComponent("stopped", isDirectory: true) }
    static func file(_ sid: String) -> URL { dir.appendingPathComponent(LookOnly.safe(sid) + ".json") }
    static func mark(_ sid: String, title: String) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let j: [String: Any] = ["session": sid, "title": title, "at": Date().timeIntervalSince1970]
        if let d = try? JSONSerialization.data(withJSONObject: j) { try? d.write(to: file(sid), options: .atomic) }
        prune()
    }
    static func lift(_ sid: String) { try? FileManager.default.removeItem(at: file(sid)) }
    static func isMarked(_ sid: String) -> Bool { FileManager.default.fileExists(atPath: file(sid).path) }
    /// Marks older than a week go: the engine only reads them, and their helpers are long gone.
    static func prune(now: Date = Date()) {
        let fm = FileManager.default
        for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let at = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            if now.timeIntervalSince(at) > 7 * 86400 { try? fm.removeItem(at: f) }
        }
    }
}

/// One process as libproc sees it (ps and top are blocked inside One's folder lock).
struct ProcInfo: Equatable {
    let pid: pid_t
    let ppid: pid_t
    let start: Int  // seconds since 1970: with the pid, who it is (pids get reused)
    let path: String
    var name: String { (path as NSString).lastPathComponent }
}

enum ProcTable {
    static func all() -> [ProcInfo] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return pids.prefix(Int(max(0, got))).compactMap { $0 > 0 ? info($0) : nil }
    }
    static func info(_ pid: pid_t) -> ProcInfo? {
        var b = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &b, size) == size else { return nil }
        guard b.pbi_uid == getuid(), b.pbi_status != UInt32(SZOMB) else { return nil }  // the person's own, still running
        var buf = [CChar](repeating: 0, count: 4096)
        let path = proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : ""
        return ProcInfo(pid: pid, ppid: pid_t(b.pbi_ppid), start: Int(b.pbi_start_tvsec), path: path)
    }
    /// Every process under these (children, theirs), from one snapshot.
    static func descendants(of roots: Set<pid_t>, in table: [ProcInfo]) -> [ProcInfo] {
        var kids: [pid_t: [ProcInfo]] = [:]
        for p in table { kids[p.ppid, default: []].append(p) }
        var out: [ProcInfo] = []
        var seen = Set<pid_t>()
        var queue = Array(roots)
        while let p = queue.popLast() {
            for c in kids[p] ?? [] where seen.insert(c.pid).inserted {
                out.append(c)
                queue.append(c.pid)
            }
        }
        return out
    }
}

/// What the engine plugin says about a conversation: its live background programs (`one-stop/live.json`), and for
/// a stopped one, what it couldn't end (`one-stop/<session>.json`).
enum StopStatus {
    static var dir: URL { Env.hermesHome.appendingPathComponent("one-stop", isDirectory: true) }
    struct Live: Codable {
        var pid: Int32
        var command: String?
    }
    /// {conversation: its live background programs}, as the engine last wrote it.
    static func live() -> [String: [Live]] {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("live.json")),
            let j = try? JSONDecoder().decode([String: [Live]].self, from: d)
        else { return [:] }
        return j
    }
    struct Report: Codable {
        var session: String
        var killed: Int?
        var pids: [Int32]?
        var commands: [String]?
        var delegations: Int?
        var at: Double?
    }
    static func report(_ sid: String) -> Report? {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent(LookOnly.safe(sid) + ".json")) else { return nil }
        return try? JSONDecoder().decode(Report.self, from: d)
    }
}

enum JobTree {
    @MainActor static var ticks = 0
    struct Entry: Codable, Equatable {
        var pid: Int32
        var start: Int
        var name: String
        var command: String?
    }
    static func ledgerURL(_ id: UUID) -> URL { Env.support.appendingPathComponent("helpers/\(id.uuidString).procs.json") }
    static func ledger(_ id: UUID) -> [Entry] {
        guard let d = try? Data(contentsOf: ledgerURL(id)) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: d)) ?? []
    }
    static func save(_ id: UUID, _ v: [Entry]) {
        try? FileManager.default.createDirectory(at: ledgerURL(id).deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(v) { try? d.write(to: ledgerURL(id), options: .atomic) }
    }

    /// Never these, whatever a record says: One itself, the engine, launchd, and processes that aren't the person's.
    static func protected(_ pid: pid_t) -> Bool {
        pid <= 1 || pid == getpid() || pid == GatewayGuard.recordedPID() || pid == getppid()
    }

    /// Every 6 s while a helper works: its engine programs and everything under them go into its record.
    static func track(_ id: UUID, sessions: [String], live: [String: [StopStatus.Live]], table: [ProcInfo]) -> [Entry] {
        let roots = sessions.flatMap { live[$0] ?? [] }
        guard !roots.isEmpty else { return ledger(id) }
        var have = ledger(id)
        let byPid = Dictionary(table.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let rootPids = Set(roots.map { pid_t($0.pid) })
        var found: [(ProcInfo, String?)] = roots.compactMap { r in byPid[pid_t(r.pid)].map { ($0, r.command) } }
        found += ProcTable.descendants(of: rootPids, in: table).map { ($0, nil) }
        var changed = false
        for (p, cmd) in found where !protected(p.pid) && !have.contains(where: { $0.pid == p.pid && $0.start == p.start }) {
            have.append(Entry(pid: p.pid, start: p.start, name: p.name, command: cmd))
            changed = true
        }
        // Only ones still alive (or gone less than a day ago) stay on the record.
        if have.count > 400 { have = Array(have.suffix(400)) }
        if changed { save(id, have) }
        return have
    }

    /// What of this record is still running now (same pid AND same start time).
    static func alive(_ entries: [Entry], table: [ProcInfo]) -> [Entry] {
        let now = Dictionary(table.map { ($0.pid, $0.start) }, uniquingKeysWith: { a, _ in a })
        return entries.filter { now[pid_t($0.pid)] == $0.start && !protected(pid_t($0.pid)) }
    }

    /// One pass of the stop: everything on the record (and whatever runs under it now) gets TERM, then KILL once
    /// it has had `grace` seconds. Apps are asked to quit first. Returns what's still alive.
    static func sweep(_ id: UUID, sessions: [String], firstAt: Date, now: Date = Date(), grace: TimeInterval = 5, force: Bool = false)
        -> [Entry]
    {
        let table = ProcTable.all()
        var entries = track(id, sessions: sessions, live: StopStatus.live(), table: table)
        let under = ProcTable.descendants(of: Set(alive(entries, table: table).map { pid_t($0.pid) }), in: table)
        for p in under where !entries.contains(where: { $0.pid == p.pid && $0.start == p.start }) && !protected(p.pid) {
            entries.append(Entry(pid: p.pid, start: p.start, name: p.name, command: nil))
        }
        save(id, entries)
        let left = alive(entries, table: table)
        let hard = force || now.timeIntervalSince(firstAt) >= grace
        for e in left {
            let pid = pid_t(e.pid)
            if let app = NSRunningApplication(processIdentifier: pid) {
                if hard { app.forceTerminate() } else { app.terminate() }
            }
            kill(pid, hard ? SIGKILL : SIGTERM)
        }
        if !left.isEmpty {
            log("\(id.uuidString.prefix(8)): \(hard ? "KILL" : "TERM") \(left.map { "\($0.name)[\($0.pid)]" }.joined(separator: ", "))")
        }
        return alive(entries, table: ProcTable.all())
    }

    /// Plain names for what's left: "NotArc test app", "2 test runs", "Rails server".
    static func names(_ left: [Entry]) -> [String] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for e in left {
            let n = plain(e)
            if counts[n] == nil { order.append(n) }
            counts[n, default: 0] += 1
        }
        return order.map { n in
            let c = counts[n] ?? 1
            return c == 1 ? n : "\(c) \(n.hasSuffix("s") ? n : n + "s")"
        }
    }
    static func plain(_ e: Entry) -> String {
        let n = e.name.lowercased()
        let cmd = (e.command ?? "").lowercased()
        if cmd.contains("test") || n.contains("test") { return "test run" }
        switch n {
        case "puma", "rails": return "Rails server"
        case "node", "vite", "esbuild", "npm", "bun": return "web dev server"
        case "sidekiq": return "Sidekiq worker"
        case "python", "python3", "ruby", "bash", "sh", "zsh", "perl": return "script"
        default: return e.name.isEmpty ? "program" : e.name
        }
    }

    static func log(_ s: String) {
        let f = Env.hermesHome.appendingPathComponent("logs/one-stop.log")
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
}

extension HelperTrail {
    static let stoppingLine = "Stopping…"
    static let closedLine = "Stopped · everything it started is closed"
    static func stoppingLine(_ left: [String]) -> String {
        left.isEmpty ? stoppingLine : "Stopping… \(left.count == 1 ? "1 program" : "\(left.count) programs") left · " + left.joined(separator: ", ")
    }
    static func wontClose(_ left: [String]) -> String { (left.first ?? "A program") + " won't close" }
}

@MainActor
extension Model {
    /// The person stopped this helper on purpose: its work is cancelled and it stays stopped, even after a restart.
    func stopHelper(_ id: UUID) {
        if helpers.first(where: { $0.id == id })?.pausedForBudget == true { return stopPausedHelper(id) }  // Budget.swift
        var cancel = false
        var busy = false
        update(id) {
            busy = HelperClose.busy($0)
            cancel = HelperTrail.stopByYou(&$0)
        }
        saveTrail(id)
        if cancel, let sid = helpers.first(where: { $0.id == id })?.sid { Engine.shared.cancel(session: sid) }
        if busy { stopTree(id) }  // its whole tree: sub-helpers, background programs, test apps (JobTree.swift)
    }

    /// Every 2 s from the main loop: a standing goal's line (ModelGoals.swift), and every 6 s each helper's record.
    func tendEveryTwo() {
        tendGoals()
        JobTree.ticks += 1
        if JobTree.ticks % 3 == 0 { tendJobTrees() }
        if JobTree.ticks % 15 == 0 { tendBudgets() }  // what each job used of the week (Budget.swift)
        HealthWatch.tend(helpers: helpers)  // a look at the Mac's health every 30 s, off the main thread (HealthRun.swift)
        tendPhoneHandoffs()  // a step only they can do goes to their phone (PhoneSession.swift)
    }

    /// Every 6 s while helpers work: each one's programs go into its record (JobTree.track).
    func tendJobTrees() {
        let working = helpers.filter { $0.state == "working" && $0.sid != nil }
        guard !working.isEmpty else { return }
        let pairs = working.map { ($0.id, [$0.sid!]) }
        Task.detached {
            let live = StopStatus.live()
            guard !live.isEmpty else { return }
            let table = ProcTable.all()
            for (id, sids) in pairs { _ = JobTree.track(id, sessions: sids, live: live, table: table) }
        }
    }

    /// The stop itself, after the helper is marked stopped: mark the conversation, then sweep until its tree is
    /// empty. Called by `stopHelper` for a helper that was working, waiting for a yes, or waiting to pick back up.
    func stopTree(_ id: UUID, force: Bool = false) {
        guard let h = helpers.first(where: { $0.id == id }), force || h.stopping != true else { return }  // one sweep at a time
        let sids = [h.sid].compactMap { $0 }
        for s in sids { StopMark.mark(s, title: h.title) }
        update(id) {
            $0.stopping = true
            $0.leftovers = nil
            $0.line = HelperTrail.stoppingLine
        }
        let started = Date()
        Task { @MainActor in
            var left: [JobTree.Entry] = []
            for k in 0..<120 {
                left = await Task.detached { JobTree.sweep(id, sessions: sids, firstAt: started, force: force) }.value
                let engineLeft = sids.compactMap { StopStatus.report($0) }.reduce(0) { $0 + ($1.pids?.count ?? 0) }
                let names = JobTree.names(left) + (engineLeft > 0 ? ["\(engineLeft) background \(engineLeft == 1 ? "run" : "runs")"] : [])
                guard helpers.contains(where: { $0.id == id && $0.stopping == true }) else { return }  // started again
                if names.isEmpty && k >= 1 {
                    update(id) {
                        $0.stopping = nil
                        $0.leftovers = nil
                        $0.line = HelperTrail.closedLine
                    }
                    saveTrail(id)
                    JobTree.log("\(id.uuidString.prefix(8)): stopped, nothing left")
                    return
                }
                let stuck = Date().timeIntervalSince(started) >= 60
                update(id) {
                    $0.leftovers = stuck ? names : nil
                    $0.line = stuck ? HelperTrail.wontClose(names) : HelperTrail.stoppingLine(names)
                }
                try? await Task.sleep(for: .seconds(stuck ? 5 : 1))
            }
        }
    }

    /// "Force stop" on a helper whose programs won't close.
    func forceStop(_ id: UUID) {
        update(id) { $0.stopping = true }
        stopTree(id, force: true)
    }
}

/// The engine half of stop means stop (`tools/overlay/plugins/one-stop`), installed at every engine start like the
/// learning cap. Takes effect at the engine's next start.
enum StopPlugin {
    static let plugin = "one-stop"
    static var pluginDir: URL { Env.hermesHome.appendingPathComponent("plugins/\(plugin)", isDirectory: true) }

    @discardableResult static func installPlugin(from src: URL? = Bundle.main.url(forResource: plugin, withExtension: nil)) -> Bool {
        let fm = FileManager.default
        guard let src, fm.fileExists(atPath: src.appendingPathComponent("__init__.py").path) else { return false }
        try? fm.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        for f in ["__init__.py", "plugin.yaml"] {
            let a = src.appendingPathComponent(f)
            let b = pluginDir.appendingPathComponent(f)
            if (try? Data(contentsOf: a)) != (try? Data(contentsOf: b)) {
                try? fm.removeItem(at: b)
                guard (try? fm.copyItem(at: a, to: b)) != nil else { return false }
            }
        }
        return true
    }

    /// What `hermes config set` must change so the plugin is on (other plugins stay as they are).
    static func configFixes(_ config: String) -> [[String]] {
        let on = BrowserGuard.enabledPlugins(config)
        var fixes: [[String]] = []
        if !on.contains(plugin) {
            fixes.append(["config", "set", "plugins.enabled", "[" + (on + [plugin]).map { "\"\($0)\"" }.joined(separator: ", ") + "]", "--force"])
        }
        let off = BrowserGuard.enabledPlugins(config, key: "disabled")
        if off.contains(plugin) {
            fixes.append([
                "config", "set", "plugins.disabled", "[" + off.filter { $0 != plugin }.map { "\"\($0)\"" }.joined(separator: ", ") + "]", "--force",
            ])
        }
        return fixes
    }

    /// Before every engine start (`ensureEngine`): the learning cap, then this plugin, each on in plugins.enabled.
    static func sync() async {
        await LearningCap.sync()
        let ok = installPlugin()
        let cfg = (try? String(contentsOf: Env.hermesHome.appendingPathComponent("config.yaml"), encoding: .utf8)) ?? ""
        for f in configFixes(cfg) {
            let (code, out) = await hermesRun(f)
            if code != 0 { BrowserGuard.log("stop: couldn't set \(f[2]): \(out.suffix(200))") }
        }
        if !ok { BrowserGuard.log("stop: the one-stop plugin isn't in this copy of One; Stop ends only the helper's turn") }
        await MainQueuePlugin.sync()  // one helper at a time on a repo's main (RepoQueue.swift)
    }
}
