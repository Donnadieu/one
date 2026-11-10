import AppKit
import Darwin
import Foundation

// MARK: - The health watchdog: memory, swap, free disk and stray programs, every 30 s

/// Nov 9, 2026: the Mac got slow and full while nobody watched: dozens of idle dev servers left over by Conductor
/// and Forge workspaces, a QA log that grew to 78 GB in minutes, and the assistant couldn't even look (ps and top
/// are blocked in the folder lock). Now One reads the Mac itself (libproc, sysctl; never ps/top), every 30 s, off
/// the main thread, and sorts every stray program into one of three classes, by rules, never by guessing:
/// - One's own (on a finished or stopped helper's record, or run by One's engine from a helper's copy of a repo or
///   from `Support/One/work`): One closes it by itself (TERM, KILL after 5 s) and says one line after.
/// - His tools' leftovers (dev servers with no parent, working in `~/conductor`, `~/forge-workspaces`, `~/Repos`):
///   a warning with Close them / Leave them.
/// - His own (everything else; always anything under /Applications, Docker, databases, Chrome, Xcode): only named,
///   never touched without a tap. "Leave it" is remembered for 24 h (`Support/One/health.json`).
/// Never deletes a file. Log: `hermes/logs/one-health.log`. `One --health` prints the same lines (read-only).

/// One program as the watchdog reads it.
struct HealthProc {
    var p: ProcInfo
    var cwd = ""
    var cpu: UInt64 = 0  // nanoseconds of CPU so far
    var memory: UInt64 = 0  // bytes it holds (its footprint)
    var written: UInt64 = 0  // bytes it wrote to disk so far
    var args: [String] = []  // only read for dev servers
    var key: String { "\(p.pid):\(p.start)" }
}

/// One look at the Mac.
struct HealthReading {
    var at = Date()
    var pressure = 1  // kern.memorystatus_vm_pressure_level: 1 normal, 2 warn, 4 critical
    var swap: UInt64 = 0  // bytes of swap in use
    var free: Int64 = 0  // bytes free on / for important use
    var total: Int64 = 0
    var procs: [HealthProc] = []
}

/// The limits, as named numbers. Checks may change a few through ONE_HEALTH_FAKE_* (only in a test, `Env.selfTest`).
struct HealthLimits {
    var every: TimeInterval = 30
    var idle: TimeInterval = 30 * 60  // a dev server with no CPU for this long is idle
    var idleCPU = 0.005  // under half a percent of one core counts as no CPU
    var writeRate: Double = 200_000_000  // bytes a second
    var writeFor: TimeInterval = 60
    var swapWarn: UInt64 = 8_000_000_000
    var pressureFor: TimeInterval = 5 * 60  // "warn" this long before it's said
    var diskWarn: Int64 = 30_000_000_000
    var diskWarnShare = 0.10
    var diskCritical: Int64 = 10_000_000_000
    var diskCriticalShare = 0.05
    var grace: TimeInterval = 5  // TERM, then KILL
    var leaveFor: TimeInterval = 24 * 3600
    static var now: HealthLimits {
        var l = HealthLimits()
        if let v = HealthWatch.fake("IDLE") { l.idle = v }
        if let v = HealthWatch.fake("WRITE_FOR") { l.writeFor = v }
        return l
    }
}

/// What One knows about its own helpers, taken on the main thread before each look.
struct HealthWorld {
    var busy: Set<String> = []  // helper ids still at work (or waiting for a yes, or closing)
    var stopped: Set<String> = []  // stopped with Stop
    var known: Set<String> = []  // helpers still on the screen
    var records: [String: [JobTree.Entry]] = [:]  // helper id: its programs (JobTree, feature 1)
    var copies: [(path: String, helper: String)] = []  // helpers' own copies of repos (HelperRepos)
    var work = ""  // Support/One/work
    var roots: Set<pid_t> = []  // One and its engine helper: what runs under them is One's
    var home = NSHomeDirectory()
    /// False when the helper list couldn't be read: then nothing on a record is closed or offered.
    var sure = true
}

/// One warning row: what it is, and the one thing a tap does.
struct HealthRow: Codable, Equatable, Identifiable {
    var id: String  // also the "Leave it" key
    var short: String  // the quiet line under the orb
    var title: String
    var detail: String? = nil
    var critical = false
    var act: String? = nil  // "Stop it", "Close them", "Quit Docker"
    var gentle = false  // the person's own: the button is outlined, not filled
    var leave = "Leave it"
    var pids: [Int32] = []
    var starts: [Int] = []
    var app: String? = nil  // bundle id the button asks to quit
}

/// A look's result: the rows, and what One closes by itself.
struct HealthPlan {
    var rows: [HealthRow] = []
    var close: [(proc: HealthProc, why: String)] = []
}

enum HealthWatch {
    static let devNames: Set<String> = ["puma", "rails", "node", "vite", "esbuild", "sidekiq", "ruby", "webpack"]
    static let databases: Set<String> = ["postgres", "postmaster", "redis-server", "redis", "mysqld", "mysqld_safe", "mysql", "mongod"]

    /// A test's stand-in number (`ONE_HEALTH_FAKE_<name>`), only inside a test.
    static func fake(_ name: String) -> Double? {
        guard Env.selfTest else { return nil }
        return ProcessInfo.processInfo.environment["ONE_HEALTH_FAKE_\(name)"].flatMap(Double.init)
    }

    // MARK: Whose is it

    /// The person's own, always: never closed by One, never put in a group a tap closes.
    static func personal(_ h: HealthProc, home: String = NSHomeDirectory()) -> Bool {
        let path = h.p.path
        let n = h.p.name.lowercased()
        let apps = ["/Applications/", home + "/Applications/", "/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/"]
        if apps.contains(where: { path.hasPrefix($0) }) { return true }
        if path.contains("/Docker.app/") || n.hasPrefix("com.docker") || n.hasPrefix("docker") || n.contains("vmnetd") { return true }
        if path.contains("Google Chrome") || path.contains("/Xcode") || n == "xcodebuild" { return true }
        return databases.contains(n)
    }
    static func isDev(_ h: HealthProc) -> Bool {
        guard devNames.contains(h.p.name.lowercased()) else { return false }
        // One's hidden browsers and browser tools run on node too: never a dev server.
        return !h.args.contains { a in ["browser", "playwright", "puppeteer", "chrome"].contains { a.lowercased().contains($0) } }
    }
    static func inside(_ path: String, _ folder: String) -> Bool {
        guard !path.isEmpty, !folder.isEmpty else { return false }
        let p = HelperRepos.norm(path)
        let f = HelperRepos.norm(folder)
        return p == f || p.hasPrefix(f + "/")
    }

    enum Owner: Equatable {
        case one(String)  // One closes it by itself: "stopped", "finished" or "helpers"
        case keep  // a working helper's, or One's own but not idle: left alone, not mentioned
        case tools(String)  // his tools' leftovers, by group
        case his  // his own
    }

    /// The three classes, by rules. `under` = what runs under One and its engine now.
    static func owner(_ h: HealthProc, world w: HealthWorld, under: Set<pid_t>) -> Owner {
        if personal(h, home: w.home) { return .his }
        for (id, entries) in w.records where entries.contains(where: { $0.pid == h.p.pid && $0.start == h.p.start }) {
            if !w.sure || w.busy.contains(id) { return .keep }
            return .one(w.stopped.contains(id) ? "stopped" : w.known.contains(id) ? "finished" : "helpers")
        }
        let copy = w.copies.first { inside(h.cwd, $0.path) }
        let ours = copy != nil || inside(h.cwd, w.work)
        if ours && isDev(h) && (under.contains(h.p.pid) || h.p.ppid == 1) {
            if !w.sure || copy.map({ w.busy.contains($0.helper) }) == true || (copy == nil && !w.busy.isEmpty) { return .keep }
            return .one("helpers")
        }
        guard h.p.ppid == 1, isDev(h) else { return .his }
        if inside(h.cwd, w.home + "/conductor") { return .tools("Conductor") }
        if inside(h.cwd, w.home + "/forge-workspaces") { return .tools("Forge") }
        if inside(h.cwd, w.home + "/Repos") { return .tools("your repos") }
        return .his
    }

    // MARK: Deciding

    /// Between looks: when each program last used the CPU, what it had written, since when it writes fast.
    struct Track {
        var cpu: [String: UInt64] = [:]
        var busyAt: [String: Date] = [:]
        var written: [String: (bytes: UInt64, at: Date)] = [:]
        var fastSince: [String: Date] = [:]
        var rate: [String: Double] = [:]
        var pressureSince: Date?
    }
    nonisolated(unsafe) static var track = Track()

    /// One look, decided. Pure: the readings, One's helpers and what came before go in; rows and closes come out.
    static func decide(
        _ r: HealthReading, world w: HealthWorld, track t: inout Track, limits l: HealthLimits = .now,
        fileOf: (pid_t) -> (path: String, size: Int64)? = { ProcTable.biggestFile($0) }
    ) -> HealthPlan {
        var plan = HealthPlan()
        let now = r.at
        var seen = Set<String>()
        for h in r.procs {
            let k = h.key
            seen.insert(k)
            if let before = t.cpu[k], let at = t.written[k]?.at {
                let secs = max(1, now.timeIntervalSince(at))
                if Double(h.cpu &- before) / 1e9 > secs * l.idleCPU { t.busyAt[k] = now }
            } else {
                t.busyAt[k] = now  // first seen: idle counts from now
            }
            t.cpu[k] = h.cpu
            if let w = t.written[k] {
                let rate = Double(h.written &- w.bytes) / max(1, now.timeIntervalSince(w.at))
                t.rate[k] = rate
                if rate >= l.writeRate {
                    if t.fastSince[k] == nil { t.fastSince[k] = w.at }
                } else {
                    t.fastSince[k] = nil
                }
            }
            t.written[k] = (h.written, now)
        }
        for k in Array(t.cpu.keys) where !seen.contains(k) {
            t.cpu[k] = nil
            t.busyAt[k] = nil
            t.written[k] = nil
            t.fastSince[k] = nil
            t.rate[k] = nil
        }
        let under = Set(ProcTable.descendants(of: w.roots, in: r.procs.map(\.p)).map(\.pid))
        var groups: [String: [HealthProc]] = [:]
        for h in r.procs {
            let idle = now.timeIntervalSince(t.busyAt[h.key] ?? now) >= l.idle
            switch owner(h, world: w, under: under) {
            case .one(let why) where idle && (why == "stopped" || isDev(h)): plan.close.append((h, why))
            case .tools(let g) where idle: groups[g, default: []].append(h)
            default: break
            }
        }

        // The disk, and anything filling it fast.
        let gb = { (b: Int64) in plainBytes(UInt64(max(0, b))) }
        let share = r.total > 0 ? Double(r.free) / Double(r.total) : 1
        let diskCritical = r.free < l.diskCritical || share < l.diskCriticalShare
        let diskLow = diskCritical || r.free < l.diskWarn || share < l.diskWarnShare
        let writers = r.procs.filter { h in t.fastSince[h.key].map { now.timeIntervalSince($0) >= l.writeFor } == true }
            .sorted { (t.rate[$0.key] ?? 0) > (t.rate[$1.key] ?? 0) }
        var writerRows: [HealthRow] = []
        for h in writers.prefix(2) {
            let who = programName(h)
            let file = fileOf(h.p.pid)
            let what =
                file.map { "\(who) is writing a \(plainBytes(UInt64(max(0, $0.size)))) file in \(shortPath($0.path, home: w.home)), fast." }
                ?? "\(who) is writing to the disk very fast (\(plainBytes(UInt64(t.rate[h.key] ?? 0))) a second)."
            var row = HealthRow(id: "writer:\(file?.path ?? h.p.path)", short: "\(who) is filling the disk", title: what, detail: "Stop it?")
            row.pids = [h.p.pid]
            row.starts = [h.p.start]
            if personal(h, home: w.home) {
                row.gentle = true
                if databases.contains(h.p.name.lowercased()) {
                    row.detail = "It holds your data, so I leave it alone."
                } else if isDocker(h) {
                    row.act = "Quit Docker"
                    row.app = "com.docker.docker"
                    row.detail = "I'll only quit it if you tap."
                } else {
                    row.act = "Stop it"
                }
            } else {
                row.act = "Stop it"
            }
            writerRows.append(row)
        }
        if diskLow {
            let left = "Your Mac is almost full: \(gb(r.free)) left"
            var row = HealthRow(id: diskCritical ? "disk-critical" : "disk-warn", short: left, title: left + ".", critical: diskCritical)
            if let first = writerRows.first {  // the writer goes on the disk's row, as in the design
                row.detail = first.title + (first.act == "Stop it" ? " Stop it?" : " " + (first.detail ?? ""))
                row.act = first.act
                row.gentle = first.gentle
                row.app = first.app
                row.pids = first.pids
                row.starts = first.starts
                row.id += ":" + first.id
                row.critical = true
                writerRows.removeFirst()
            } else {
                row.detail = "Ask me to find what takes the room. I never delete anything without your yes."
            }
            plan.rows.append(row)
        }
        plan.rows += writerRows

        // Memory: critical at once, "warn" once it has lasted, or a lot of swap.
        if r.pressure >= 2 { t.pressureSince = t.pressureSince ?? now } else { t.pressureSince = nil }
        let pressed = r.pressure >= 4 || (t.pressureSince.map { now.timeIntervalSince($0) >= l.pressureFor } ?? false)
        if pressed || r.swap > l.swapWarn {
            plan.rows.append(memoryRow(r, critical: r.pressure >= 4, home: w.home))
        }

        // His tools' leftovers: one row per group, one tap closes the group.
        for g in ["Conductor", "Forge", "your repos"] {
            guard let hs = groups[g], !hs.isEmpty else { continue }
            let n = hs.count
            let noun = n == 1 ? "1 dev server" : "\(n) dev servers"
            let place = g == "your repos" ? "in your repos" : "from \(g)"
            var row = HealthRow(
                id: "tools:\(g)", short: "\(noun) left running \(place)", title: "\(noun) left running \(place).",
                detail: "Nothing has used \(n == 1 ? "it" : "them") for half an hour. I'll only close \(n == 1 ? "it" : "them") if you tap.",
                act: "Close them", leave: "Leave them")
            if n == 1 { row.act = "Close it" }
            if n == 1 { row.leave = "Leave it" }
            row.pids = hs.map(\.p.pid)
            row.starts = hs.map(\.p.start)
            plan.rows.append(row)
        }
        plan.rows = plan.rows.filter(\.critical) + plan.rows.filter { !$0.critical }  // critical first, order kept
        return plan
    }

    static func isDocker(_ h: HealthProc) -> Bool {
        let n = h.p.name.lowercased()
        return h.p.path.contains("/Docker.app/") || n.hasPrefix("com.docker") || n.hasPrefix("docker") || n.contains("vmnetd")
    }

    /// "Memory is tight. Docker is using 9 GB." Docker gets Quit Docker; the rest is only named.
    static func memoryRow(_ r: HealthReading, critical: Bool, home: String) -> HealthRow {
        var sums: [String: UInt64] = [:]
        for h in r.procs { sums[appName(h), default: 0] += h.memory }
        let top = sums.max { $0.value < $1.value }
        var row = HealthRow(id: critical ? "memory-critical" : "memory-warn", short: "Memory is tight", title: "Memory is tight.", critical: critical)
        if r.swap > 0 { row.detail = "Your Mac is using \(plainBytes(r.swap)) of the disk as extra memory, so it's slow." }
        if let top, top.value > 0 {
            row.title = "Memory is tight. \(top.key) is using \(plainBytes(top.value))."
            row.short = "Memory is tight: \(top.key) is using \(plainBytes(top.value))"
            row.id += ":" + top.key
            if top.key == "Docker" {
                row.act = "Quit Docker"
                row.app = "com.docker.docker"
                row.gentle = true
                row.detail = "I'll only quit it if you tap."
            }
        }
        return row
    }

    /// The name a person knows: the app it belongs to (Docker, Google Chrome), else the program.
    static func appName(_ h: HealthProc) -> String {
        if isDocker(h) { return "Docker" }
        if let r = h.p.path.range(of: ".app/") {
            return ((String(h.p.path[..<r.lowerBound]) as NSString).lastPathComponent)
        }
        return programName(h)
    }
    static func programName(_ h: HealthProc) -> String {
        let plain = JobTree.plain(.init(pid: h.p.pid, start: h.p.start, name: h.p.name, command: nil))
        return plain == "script" || plain == h.p.name ? h.p.name : plain.prefix(1).uppercased() + plain.dropFirst()
    }
    static func shortPath(_ p: String, home: String) -> String { p.hasPrefix(home + "/") ? String(p.dropFirst(home.count + 1)) : p }

    /// 21 GB, 9 GB, 1.5 GB, 300 MB (decimal, as Finder counts).
    static func plainBytes(_ b: UInt64) -> String {
        let gb = Double(b) / 1e9
        if gb >= 10 { return "\(Int(gb.rounded())) GB" }
        if gb >= 1 {
            let s = String(format: "%.1f", gb)
            return (s.hasSuffix(".0") ? String(s.dropLast(2)) : s) + " GB"
        }
        return "\(max(1, Int((Double(b) / 1e6).rounded()))) MB"
    }

    /// "I closed 4 dev servers a stopped helper left running."
    static func doneLine(_ closed: [(proc: HealthProc, why: String)]) -> String? {
        guard !closed.isEmpty else { return nil }
        let n = closed.count
        let dev = closed.allSatisfy { isDev($0.proc) }
        let noun = dev ? (n == 1 ? "1 dev server" : "\(n) dev servers") : (n == 1 ? "1 program" : "\(n) programs")
        let whys = Set(closed.map(\.why))
        let who =
            whys == ["stopped"]
            ? "a stopped helper" : whys == ["finished"] ? "a finished helper" : whys.contains("stopped") ? "stopped helpers" : "my helpers"
        return "I closed \(noun) \(who) left running."
    }
}

// MARK: - Reading the Mac (libproc and sysctl: ps and top are blocked in the folder lock)

extension ProcTable {
    /// Its CPU so far (ns), its footprint and what it wrote, in one call.
    static func usage(_ pid: pid_t) -> (cpu: UInt64, memory: UInt64, written: UInt64)? {
        var ri = rusage_info_v2()
        let ok = withUnsafeMutablePointer(to: &ri) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        guard ok == 0 else { return nil }
        let ticks = ri.ri_user_time &+ ri.ri_system_time
        return (ticks &* UInt64(timebase.numer) / UInt64(max(1, timebase.denom)), ri.ri_phys_footprint, ri.ri_diskio_byteswritten)
    }
    static let timebase: mach_timebase_info_data_t = {
        var t = mach_timebase_info_data_t()
        mach_timebase_info(&t)
        return t
    }()

    /// The folder it works in.
    static func cwd(_ pid: pid_t) -> String {
        var v = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &v, size) == size else { return "" }
        return withUnsafePointer(to: v.pvi_cdir.vip_path) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
    }

    /// The biggest file it has open for writing (not a device).
    static func biggestFile(_ pid: pid_t) -> (path: String, size: Int64)? {
        let stride = MemoryLayout<proc_fdinfo>.stride
        let need = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard need > 0 else { return nil }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(need) / stride + 16)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard got > 0 else { return nil }
        var best: (path: String, size: Int64)?
        for f in fds.prefix(Int(got) / stride) where f.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var v = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, f.proc_fd, PROC_PIDFDVNODEPATHINFO, &v, size) == size, v.pfi.fi_openflags & 0x0002 != 0 else { continue }
            let path = withUnsafePointer(to: v.pvip.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            let bytes = v.pvip.vip_vi.vi_stat.vst_size
            if path.hasPrefix("/dev/") || path.isEmpty { continue }
            if best == nil || bytes > best!.size { best = (path, bytes) }
        }
        return best
    }
}

extension HealthWatch {
    static func sysInt(_ name: String) -> Int? {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &v, &size, nil, 0) == 0 ? Int(v) : nil
    }

    /// One look at the Mac, with a test's stand-ins (ONE_HEALTH_FAKE_DISK_GB, _PRESSURE, _SWAP_GB) inside a test.
    static func read(now: Date = Date()) -> HealthReading {
        var r = HealthReading(at: now)
        r.pressure = sysInt("kern.memorystatus_vm_pressure_level") ?? 1
        var x = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &x, &size, nil, 0) == 0 { r.swap = x.xsu_used }
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        if let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys) {
            r.free = v.volumeAvailableCapacityForImportantUsage ?? 0
            r.total = Int64(v.volumeTotalCapacity ?? 0)
        }
        if let g = fake("DISK_GB") { r.free = Int64(g * 1e9) }
        if let p = fake("PRESSURE") { r.pressure = Int(p) }
        if let g = fake("SWAP_GB") { r.swap = UInt64(g * 1e9) }
        r.procs = ProcTable.all().map { p in
            var h = HealthProc(p: p)
            if let u = ProcTable.usage(p.pid) { (h.cpu, h.memory, h.written) = u }
            if devNames.contains(p.name.lowercased()) {
                h.cwd = ProcTable.cwd(p.pid)
                h.args = GatewayGuard.arguments(of: p.pid)
            }
            return h
        }
        return r
    }

    /// One's helpers as the main thread knows them, plus their records and copies from disk.
    static func world(helpers: [Helper], sure: Bool = true) -> HealthWorld {
        var w = HealthWorld()
        w.sure = sure
        for h in helpers {
            let id = h.id.uuidString
            w.known.insert(id)
            if HelperClose.busy(h) { w.busy.insert(id) }
            if h.state == "stopped" { w.stopped.insert(id) }
        }
        let dir = Env.support.appendingPathComponent("helpers", isDirectory: true)
        for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where f.hasSuffix(".procs.json") {
            let id = String(f.dropLast(".procs.json".count))
            if let u = UUID(uuidString: id) { w.records[id] = JobTree.ledger(u) }
        }
        w.copies = HelperRepos.load().map { ($0.path, $0.helper) }
        w.work = Env.support.appendingPathComponent("work", isDirectory: true).path
        w.roots = Set([getpid(), GatewayGuard.recordedPID()].compactMap { $0 })
        return w
    }
}
