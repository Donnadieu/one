import Foundation

/// `One --test-restart`: proves a changed folder list restarts the engine exactly once, with a lock
/// that has the new folder, only when nothing is mid-reply, and that an unchanged list never does.
/// Run with ONE_SUPPORT_DIR set to an empty folder. It never writes the person's settings: the
/// folder lists come from in-memory overrides.
enum RestartCheck {
    @MainActor
    static func run() async -> Int32 {
        var fails = 0
        func check(_ name: String, _ ok: Bool) {
            print("  \(ok ? "✓" : "✗") \(name)")
            if !ok { fails += 1 }
        }
        check("runs as a command-line tool (never restarts a real engine)", Env.commandLine)
        let scratch = Env.support.path
        let a = scratch + "/allowed-a"
        let b = scratch + "/allowed-b"
        let k = scratch + "/keepass.kdbx"
        Access.override = [a]
        Access.readsOverride = []

        var restarts: [(resume: Bool, profile: String)] = []
        var running = true
        // Stands in for Model.restartForFolders: what a real restart does to the watch is start the
        // engine again, which records the freshly built lock.
        func tick(busy: Bool) async {
            FolderWatch.tend(busy: busy, running: running) { resume in
                let p = Access.profile()
                restarts.append((resume, p))
                try? await Task.sleep(for: .milliseconds(200))
                FolderWatch.engineStarted(profile: p)
            }
            try? await Task.sleep(for: .milliseconds(400))
        }

        FolderWatch.engineStarted(profile: Access.profile())
        check("the engine's lock has the starting folder", FolderWatch.startedProfile.contains(a))
        for _ in 0..<4 { await tick(busy: false) }
        check("an unchanged folder list never restarts", restarts.isEmpty)

        // The assistant adds a folder in the middle of a reply.
        Access.override = [a, b]
        check("the change is noticed", FolderWatch.changed)
        for _ in 0..<3 { await tick(busy: true) }
        check("no restart while it's still replying", restarts.isEmpty)
        for _ in 0..<5 { await tick(busy: false) }
        check("exactly one restart once it's done", restarts.count == 1)
        check("the new lock has the new folder", restarts.first?.profile.contains(b) == true)
        check("the old one is still there", restarts.first?.profile.contains(a) == true)
        check("it carries on with what it was doing", restarts.first?.resume == true)
        check("the running engine now has the new lock", FolderWatch.startedProfile.contains(b) && !FolderWatch.changed)

        // A connection's path, added while nothing is running: wait for an engine to exist.
        FolderWatch.lastBusy = .distantPast
        Access.readsOverride = [k]
        running = false
        for _ in 0..<2 { await tick(busy: false) }
        check("no restart when no engine is running", restarts.count == 1)
        running = true
        for _ in 0..<3 { await tick(busy: false) }
        check("a connection's new path restarts once", restarts.count == 2)
        check("its lock can read that path", restarts.last?.profile.contains(k) == true)
        check("a quiet change doesn't send a carry-on note", restarts.last?.resume == false)

        // A shell write with a literal \n still counts as two folders.
        check("a literal \\n between folders is read as two", Access.lines("\(a)\\n\(b)") == [a, b])
        check("one folder per line is read as is", Access.lines("\(a)\n\(b)\n") == [a, b])

        // The background helper started under the old lock is stopped, and waited for.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-c", "import time; time.sleep(120)", "gateway", "run", "--quiet"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil {
            usleep(300_000)
            try? "{\"pid\": \(p.processIdentifier)}".write(to: GatewayGuard.pidFile, atomically: true, encoding: .utf8)
            // Healthy (its parent, this process, is alive): a plain engine start would keep it.
            Engine.stopStrayGateway(caller: "restart check start")
            check("a plain start would keep the old helper", p.isRunning)
            _ = await Task.detached { GatewayGuard.stopForNewAccess(previousEngine: nil) }.value
            usleep(300_000)
            check("new folder access stops the old helper", !p.isRunning)
        } else {
            check("could start a stand-in helper", false)
        }
        let other = Process()
        other.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        other.arguments = ["-c", "import time; time.sleep(120)", "not-a-gateway"]
        if (try? other.run()) != nil {
            usleep(300_000)
            try? "{\"pid\": \(other.processIdentifier)}".write(to: GatewayGuard.pidFile, atomically: true, encoding: .utf8)
            _ = await Task.detached { GatewayGuard.stopForNewAccess(previousEngine: nil) }.value
            check("a reused pid that isn't a helper is never touched", other.isRunning)
            other.terminate()
        }
        try? FileManager.default.removeItem(at: GatewayGuard.pidFile)
        check("the assistant is told One restarts by itself", FolderWatch.note.contains("restarts by itself"))
        Access.override = nil
        Access.readsOverride = nil
        print(fails == 0 ? "restart ok" : "restart: \(fails) failed")
        return fails == 0 ? 0 : 1
    }
}
