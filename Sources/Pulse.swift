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
    }

    /// Checks the previous beat, then starts this process's own and arranges to clear it on a
    /// clean quit (so a crash is the only way `checkPrevious()` finds a stale one next launch).
    static func launch() {
        checkPrevious()
        start()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in stop() }
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
