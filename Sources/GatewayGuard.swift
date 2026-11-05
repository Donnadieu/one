import Darwin
import Foundation

// MARK: - The engine's background helper (Hermes gateway): restart it only when it's really stale

/// Hermes keeps one background helper (the gateway) per home and writes its pid to `gateway.pid`.
/// One used to SIGTERM whatever that file named on every engine start. Any second One process
/// (a `make check` run, a test copy, a render) then killed the gateway the person's live One was
/// using, and the message in flight failed with "Internal error". Now it's only stopped when it's
/// stale: orphaned (its engine is gone) or the child of the engine this process is replacing.
enum GatewayGuard {
    enum Verdict: Equatable {
        case none  // nothing alive at that pid
        case notGateway  // pid reused by something else (or not readable): never touch it
        case healthy(parent: pid_t)  // serving a live engine (maybe another One's): leave it alone
        case stale  // orphaned, or the child of the engine we're replacing
    }

    static var pidFile: URL { Env.hermesHome.appendingPathComponent("gateway.pid") }

    static func recordedPID() -> pid_t? {
        guard let d = try? Data(contentsOf: pidFile),
            let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
            let pid = j["pid"] as? Int, pid > 1
        else { return nil }
        return pid_t(pid)
    }

    static func verdict(_ pid: pid_t, previousEngine: pid_t?) -> Verdict {
        guard kill(pid, 0) == 0, let pp = parent(of: pid) else { return .none }
        guard isGateway(arguments(of: pid)) else { return .notGateway }
        if pp <= 1 || pp == previousEngine || kill(pp, 0) != 0 { return .stale }
        return .healthy(parent: pp)
    }

    /// Stops the gateway only if it's stale. Returns what it decided (also logged for later forensics).
    @discardableResult
    static func stopIfStale(previousEngine: pid_t?, caller: String) -> Verdict {
        guard let pid = recordedPID() else { return .none }
        let v = verdict(pid, previousEngine: previousEngine)
        log("\(caller): gateway \(pid) \(v), previous engine \(previousEngine.map(String.init) ?? "none")")
        guard v == .stale else { return v }
        kill(pid, SIGTERM)
        usleep(900_000)
        return v
    }

    /// The folder list changed: the helper in this home must go even if it looks healthy, because it
    /// was started under the old folder lock and a new engine would reuse it. Only a real gateway at
    /// the pid this home recorded is stopped; a reused pid is never touched. Waits until it's gone.
    @discardableResult
    static func stopForNewAccess(previousEngine: pid_t?) -> Verdict {
        guard let pid = recordedPID() else { return .none }
        let v = verdict(pid, previousEngine: previousEngine)
        log("new folder access: gateway \(pid) \(v), previous engine \(previousEngine.map(String.init) ?? "none")")
        if v == .none || v == .notGateway { return v }
        kill(pid, SIGTERM)
        var waited = 0
        while kill(pid, 0) == 0 && waited < 40 {
            usleep(250_000)
            waited += 1
        }
        if kill(pid, 0) == 0, isGateway(arguments(of: pid)) {
            kill(pid, SIGKILL)
            usleep(300_000)
        }
        return v
    }

    /// Is this argv a Hermes gateway (`… gateway run …`)? Hermes can relaunch itself under its managed
    /// Python as `python3 -I -I -c "import sys, runpy; …; sys.argv = ['-c', 'gateway', 'run', '--quiet']; …"`
    /// (`hermes_cli/venv_sync.relaunch_command`), so the words live inside the script, not as their own
    /// arguments. Missing that shape called the live gateway "not a gateway": a new folder never reached it
    /// and the assistant kept getting "Operation not permitted" on a folder it had just been given (Nov 5 2026).
    static func isGateway(_ argv: [String]) -> Bool {
        let a = hermesArguments(argv)
        return a.contains("gateway") && a.contains("run")
    }

    /// The arguments Hermes itself sees: the `sys.argv = [...]` list of a relaunch script, else argv as is.
    static func hermesArguments(_ argv: [String]) -> [String] {
        guard let c = argv.firstIndex(of: "-c"), c + 1 < argv.count,
            let start = argv[c + 1].range(of: "sys.argv = [")
        else { return argv }
        var out: [String] = []
        var cur = ""
        var quote: Character?
        var escaped = false
        for ch in argv[c + 1][start.upperBound...] {
            if let q = quote {
                if escaped {
                    cur.append(ch)
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == q {
                    out.append(cur)
                    cur = ""
                    quote = nil
                } else {
                    cur.append(ch)
                }
            } else if ch == "'" || ch == "\"" {
                quote = ch
            } else if ch == "]" {
                return out
            }
        }
        return argv  // not a list we could read: never guess
    }

    static func parent(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// argv of a process (empty when it can't be read, e.g. another user's).
    static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return [] }
        let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
        var i = 4
        while i < size && buf[i] != 0 { i += 1 }  // the executable path
        while i < size && buf[i] == 0 { i += 1 }
        var out: [String] = []
        while out.count < argc && i < size {
            var j = i
            while j < size && buf[j] != 0 { j += 1 }
            out.append(String(decoding: buf[i..<j], as: UTF8.self))
            i = j + 1
        }
        return out
    }

    static func log(_ line: String) {
        let f = Env.hermesHome.appendingPathComponent("logs/one-gateway-guard.log")
        try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        let s = "\(ISO8601DateFormatter().string(from: Date())) pid \(getpid()) \(line)\n"
        if let h = try? FileHandle(forWritingTo: f) {
            h.seekToEndOfFile()
            h.write(Data(s.utf8))
            try? h.close()
        } else {
            try? s.write(to: f, atomically: true, encoding: .utf8)
        }
    }
}
