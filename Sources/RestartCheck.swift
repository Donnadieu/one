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

        var restarts: [(resume: Bool, profile: String, paused: Bool)] = []
        var running = true
        var clock = Date()
        // Stands in for Model.restartForFolders: what a real restart does to the watch is start the
        // engine again, which records the freshly built lock. Each tick is 3 s of One's main loop.
        func tick(busy: Bool, helpers: Bool = false) async {
            clock += 3
            FolderWatch.tend(talking: busy, helpersWorking: helpers, running: running, now: clock) { resume, pause in
                let p = Access.profile()
                restarts.append((resume, p, pause))
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

        // A helper (or a routine's helper) adds a folder it needs and keeps working: the restart must
        // not wait for it, or the helper holds up its own fix (Oct 28: the Ledger morning run).
        let c = scratch + "/allowed-c"
        Access.override = [a, b, c]
        check("only the new folder is named", FolderWatch.added == [c])
        for _ in 0..<3 { await tick(busy: false, helpers: true) }
        check("helpers get a short grace first", restarts.count == 2)
        for _ in 0..<3 { await tick(busy: false, helpers: true) }
        check("then it restarts while helpers still work", restarts.count == 3)
        check("and pauses them so they pick back up", restarts.last?.paused == true)
        check("the new lock has that folder", restarts.last?.profile.contains(c) == true)
        check(
            "the restart line names the folder in plain words",
            FolderWatch.restartingLine([NSHomeDirectory() + "/.hermes/ai-content-chrome"], helpers: true)
                == "Restarting to open ~/.hermes/ai-content-chrome. Your helpers will pick up where they left off.")
        check(
            "and says helpers pick back up",
            FolderWatch.restartingLine([c], helpers: true).hasSuffix("Your helpers will pick up where they left off."))
        check("within a minute", FolderWatch.helperGrace < 60 && FolderWatch.maxWait < 60)
        check(
            "a routine at work holds the restart (it would cut its run off)",
            !FolderWatch.due(talking: false, helpersWorking: false, waited: 600, routineBusy: true))
        check(
            "but not for longer than an update would wait",
            FolderWatch.due(talking: false, helpersWorking: false, waited: FolderWatch.routineWait, routineBusy: true))

        // A helper mid a build/test/push/release holds the restart too, with its own (shorter) cap.
        check(
            "a helper mid a sensitive dev step holds the restart",
            !FolderWatch.due(talking: false, helpersWorking: true, waited: 60, sensitiveBusy: true))
        check(
            "but only up to its own cap, not forever",
            FolderWatch.due(talking: false, helpersWorking: true, waited: FolderWatch.sensitiveWait, sensitiveBusy: true))
        check("building is sensitive", Plain.sensitive("Building One…"))
        check("packaging is sensitive", Plain.sensitive("Packaging One…"))
        check("running tests is sensitive", Plain.sensitive("Running tests…"))
        check("pushing to GitHub is sensitive", Plain.sensitive("Pushing to GitHub…"))
        check("publishing a release is sensitive", Plain.sensitive("Publishing a release…"))
        check("plain browsing is never sensitive", !Plain.sensitive("Searching the web for “flights”…"))
        check("reading a file is never sensitive", !Plain.sensitive("Reading a file…"))

        // A reply that never ends doesn't hold it forever either.
        let d = scratch + "/allowed-d"
        Access.override = [a, b, c, d]
        for _ in 0..<10 { await tick(busy: true) }
        check("a long reply gets time to finish", restarts.count == 3)
        for _ in 0..<7 { await tick(busy: true) }
        check("but the restart still comes within a minute", restarts.count == 4)
        check("and the assistant is told to carry on", restarts.last?.resume == true)

        // The Folders window must never drop a folder added meanwhile by a chat or a routine.
        let merged = Access.merge(opened: [a, b], chosen: [a], current: [a, b, c])
        check("the Folders window keeps a folder added while it was open", merged.contains(c))
        check("and still removes the one they took out", !merged.contains(b))
        check("and adds the one they picked", Access.merge(opened: [a], chosen: [a, d], current: [a, c]) == [a, c, d])

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
        await relaunchedHelperChecks(check)
        grantedFolderChecks(check)
        try? FileManager.default.removeItem(at: GatewayGuard.pidFile)
        check("the assistant is told One restarts by itself", FolderWatch.note.contains("restarts by itself"))
        Access.override = nil
        Access.readsOverride = nil
        print(fails == 0 ? "restart ok" : "restart: \(fails) failed")
        return fails == 0 ? 0 : 1
    }

    /// Hermes can relaunch itself under its own Python, which hides "gateway run" inside a `-c` script
    /// (the shape seen live on Nov 5 2026). That helper must still be stopped when a folder is added,
    /// or the assistant keeps the old lock and gets "Operation not permitted" on the new folder.
    @MainActor
    static func relaunchedHelperChecks(_ check: (String, Bool) -> Void) async {
        let live = [
            "/x/python3", "-I", "-I", "-c",
            "import sys, runpy; sys.path.insert(0, '/Users/x/Library/Application Support/One/engine'); "
                + "sys.argv = ['-c', 'gateway', 'run', '--quiet']; exec(\"import os, re, sys\\nprint('a]b')\")",
        ]
        check("a relaunched helper is recognised as the helper", GatewayGuard.isGateway(live))
        check("its own arguments are read from the script", GatewayGuard.hermesArguments(live) == ["-c", "gateway", "run", "--quiet"])
        check(
            "a relaunched engine (not the helper) is not",
            !GatewayGuard.isGateway(["/x/python3", "-I", "-c", "import sys; sys.argv = ['-c', 'acp']; exec('gateway run')"]))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-I", "-I", "-c", "import sys, runpy; sys.argv = ['-c', 'gateway', 'run', '--quiet']; import time; time.sleep(120)"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return check("could start a relaunched stand-in helper", false) }
        usleep(300_000)
        try? "{\"pid\": \(p.processIdentifier)}".write(to: GatewayGuard.pidFile, atomically: true, encoding: .utf8)
        check("the running relaunched helper is seen as alive", Messenger.helperAlive)
        let v = await Task.detached { GatewayGuard.stopForNewAccess(previousEngine: nil) }.value
        usleep(300_000)
        check("new folder access stops a relaunched helper too", !p.isRunning && v != .notGateway)
        if p.isRunning { p.terminate() }
    }

    /// A folder granted under ~/Library/Application Support (closed by default) with a space in its name
    /// is readable under the lock built after the grant, and a folder next to it that was never granted
    /// stays closed.
    static func grantedFolderChecks(_ check: (String, Bool) -> Void) {
        let base = NSHomeDirectory() + "/Library/Application Support"
        let granted = base + "/One check \(getpid()) granted folder"
        let other = base + "/One check \(getpid()) never granted"
        defer {
            try? FileManager.default.removeItem(atPath: granted)
            try? FileManager.default.removeItem(atPath: other)
        }
        for d in [granted, other] {
            try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
            try? "workflow \(getpid())".write(toFile: d + "/WORKFLOW.md", atomically: true, encoding: .utf8)
        }
        let saved = Access.override
        Access.override = (saved ?? []) + [granted]
        let profile = Access.profile()
        Access.override = saved
        func run(_ tool: String, _ path: String) -> (Int32, String) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            p.arguments = ["-p", profile, tool, path]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return (-1, "") }
            let d = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(decoding: d, as: UTF8.self))
        }
        let read = run("/bin/cat", granted + "/WORKFLOW.md")
        check("a granted folder under Application Support with a space is readable", read.0 == 0 && read.1 == "workflow \(getpid())")
        check("and its listing too", run("/bin/ls", granted).1.contains("WORKFLOW.md"))
        check("a folder next to it that was never granted stays closed", run("/bin/cat", other + "/WORKFLOW.md").0 != 0)
    }
}
