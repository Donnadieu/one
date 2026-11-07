import AppKit
import Foundation

// MARK: - A heartbeat so a crash leaves a trace, even with no crash report reachable
//
// `applicationWillTerminate` only runs on a clean quit (Dock Quit, Cmd-Q, logout). A crash or a
// kill (jetsam under memory/CPU pressure, a forced-quit, a kernel panic survived by the disk)
// skips it entirely, so GatewayGuard's "quit:" line never appears and the gap looks silent —
// which is exactly what happened the night of Nov 1→2 2026: pid 85851 started 02:50Z, a helper's
// tool call was cut off mid-turn at 04:37:37Z, and nothing more was logged until a new One
// (pid 65943) found the old engine stale at 13:48Z. No "quit" line anywhere in between, and the
// crash report (if one exists) sits in ~/Library/Logs/DiagnosticReports, outside every folder
// this app (and Hermes acting for it) is allowed to read without Omar's say-so. `Pulse` writes a
// small breadcrumb this app CAN always read, so next time the gap is diagnosed in one grep.
enum Pulse {
    static var file: URL { Env.hermesHome.appendingPathComponent("pulse.json") }

    /// Call once at launch, BEFORE `start()` overwrites the file. If a previous pulse is still
    /// there, this app didn't shut down cleanly last time (a clean quit deletes it in `stop()`).
    static func checkPrevious() {
        guard let d = try? Data(contentsOf: file),
            let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
            let pid = j["pid"] as? Int,
            let ts = j["ts"] as? String,
            let last = ISO8601DateFormatter().date(from: ts)
        else { return }
        let gap = Date().timeIntervalSince(last)
        GatewayGuard.log(
            "no clean quit: previous One (pid \(pid)) last beat \(ts), \(Int(gap))s before this start — crashed or was killed, not a normal quit"
        )
        // macOS writes its crash report a few seconds after the crash: read it then, off the main thread, and keep
        // the part that names the code path where the assistant can read it (this log), not only in a folder it can't.
        Task.detached {
            try? await Task.sleep(for: .seconds(20))
            if let line = crashLine(pid: pid) { GatewayGuard.log(line) }
        }
    }

    /// The previous One's crash report, in one line: version, the exception, malloc's own words, and the top of the
    /// crashed thread (\"image symbol\" frames). nil when macOS wrote none (a kill, a force quit).
    nonisolated static func crashLine(pid: Int, dir: URL = reports) -> String? {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.lastPathComponent.hasPrefix("One-") && f.pathExtension == "ips" {
            guard let raw = try? String(contentsOf: f, encoding: .utf8), let nl = raw.firstIndex(of: "\n"),
                let b = try? JSONSerialization.jsonObject(with: Data(raw[raw.index(after: nl)...].utf8)) as? [String: Any],
                b["pid"] as? Int == pid
            else { continue }
            return summary(b, file: f.lastPathComponent)
        }
        return nil
    }

    /// `One --crash-line <pid> [folder]`: prints what Pulse logs for that crash (read-only; checks and debugging).
    nonisolated static func cli(_ args: [String]) {
        guard let k = args.firstIndex(of: "--crash-line"), k + 1 < args.count, let pid = Int(args[k + 1]) else { return }
        let dir = k + 2 < args.count ? URL(fileURLWithPath: args[k + 2]) : reports
        print(crashLine(pid: pid, dir: dir) ?? "no crash report for pid \(pid)")
        exit(0)
    }

    nonisolated static var reports: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
    }

    nonisolated static func summary(_ b: [String: Any], file: String) -> String {
        let version = (b["bundleInfo"] as? [String: Any])?["CFBundleShortVersionString"] as? String ?? "?"
        let ex = b["exception"] as? [String: Any] ?? [:]
        let why = ((b["asi"] as? [String: [String]]) ?? [:]).values.flatMap { $0 }.joined(separator: "; ")
        let images = (b["usedImages"] as? [[String: Any]]) ?? []
        let threads = (b["threads"] as? [[String: Any]]) ?? []
        let ft = b["faultingThread"] as? Int ?? 0
        let t = ft < threads.count ? threads[ft] : [:]
        let frames = ((t["frames"] as? [[String: Any]]) ?? []).prefix(14).map { fr -> String in
            let i = fr["imageIndex"] as? Int ?? -1
            let img = i >= 0 && i < images.count ? images[i]["name"] as? String ?? "?" : "?"
            return "\(img) \(fr["symbol"] as? String ?? "?")"
        }
        let q = (t["queue"] as? String) ?? (t["name"] as? String) ?? ""
        return "crash report \(file): One \(version) \(ex["type"] ?? "?") (\(ex["signal"] ?? "?"))"
            + (why.isEmpty ? "" : " \"\(why)\"") + " thread \(ft) \(q): " + frames.joined(separator: " < ")
    }

    /// Checks the previous beat, then starts this process's own and arranges to clear it on a
    /// clean quit (so a crash is the only way `checkPrevious()` finds a stale one next launch).
    static func launch() {
        checkPrevious()
        start()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            stop()
            Keeper.quitting()  // a quit they asked for: the keeper leaves One closed (Keeper.swift)
        }
        Keeper.started()  // from now on, if One ends without being asked to, it's opened again (Keeper.swift)
        watchTerm()
    }

    /// `kill <pid>` (SIGTERM) is someone ending One on purpose, like a quit: the keeper must not open it again
    /// (a reinstall kills One, swaps the app and opens the new one). The default action then runs as before.
    nonisolated(unsafe) private static var term: DispatchSourceSignal?
    private static func watchTerm() {
        guard Env.production else { return }
        signal(SIGTERM, SIG_IGN)
        let s = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        s.setEventHandler {
            Keeper.quitting()
            signal(SIGTERM, SIG_DFL)
            kill(getpid(), SIGTERM)
        }
        s.resume()
        term = s
    }

    /// Beats every 20s while running; the file always has this process's pid and the last beat time.
    static func start() {
        beat()
        Task.detached {
            while true {
                try? await Task.sleep(for: .seconds(20))
                beat()
            }
        }
    }

    /// Call from `applicationWillTerminate`: a clean quit removes the file, so `checkPrevious()`
    /// at the next launch stays quiet.
    static func stop() {
        try? FileManager.default.removeItem(at: file)
    }

    private static func beat() {
        let j: [String: Any] = ["pid": Int(getpid()), "ts": ISO8601DateFormatter().string(from: Date())]
        guard let d = try? JSONSerialization.data(withJSONObject: j) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: file, options: .atomic)
    }
}
