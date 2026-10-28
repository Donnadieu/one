import AppKit

/// `One --test-keep-awake` (preflight, from a test copy): the Mac stays awake while One works and sleeps as usual
/// after. A fake helper works → exactly one PreventUserIdleSystemSleep assertion in plain words, never one that
/// keeps the screen on; more work renames it instead of adding one; 300 flips leak nothing; a helper waiting to
/// be picked back up after a restart and a running routine count; nothing working → none. The pmset side (what
/// `pmset -g assertions` shows, and that a crash drops it) is `--test-keep-awake-hold` in tools/keep-awake-check.sh.
enum KeepAwakeCheck {
    static func launch() -> Bool {
        let args = CommandLine.arguments
        if args.contains("--test-keep-awake") {
            TestWorld.enter()  // scratch folder (a made-up jobs.json); run with ONE_SUPPORT_DIR set to an empty folder
            MainActor.assumeIsolated { exit(run()) }
        }
        if args.contains("--test-keep-awake-hold") {
            TestWorld.enter()  // holds for a fake helper, lets go, then waits so pmset can see both (keep-awake-check.sh)
            MainActor.assumeIsolated { hold() }
        }
        return false
    }

    static func fake(_ state: String, queued: Bool? = nil) -> Helper {
        var h = Helper(title: "Research", task: "x", sid: nil, state: state, line: "")
        h.resumeQueued = queued
        return h
    }

    @MainActor
    static func run() -> Int32 {
        var fails = 0
        func check(_ name: String, _ ok: Bool) {
            print("  \(ok ? "✓" : "✗") \(name)")
            fflush(stdout)
            if !ok { fails += 1 }
        }
        func ours() -> [(type: String, name: String)] { KeepAwake.mine().filter { $0.name.hasPrefix("One is") } }
        let sys = KeepAwake.type

        print("1. a fake helper works")
        check("nothing held before", ours().isEmpty)
        KeepAwake.sync(KeepAwake.work(reply: false, helpers: [fake("working")], routines: 0))
        check("one assertion while it works", ours().count == 1)
        check("it stops idle system sleep", ours().first?.type == sys)
        check("named in plain words", ours().first?.name == "One is finishing 1 helper")
        check("the screen can still sleep", !KeepAwake.mine().contains { $0.type.contains("DisplaySleep") })

        print("2. more work, still one")
        let three = [fake("working"), fake("working"), fake("working"), fake("done"), fake("needsYes"), fake("stopped")]
        KeepAwake.sync(KeepAwake.work(reply: true, helpers: three, routines: 1))
        check("one assertion, renamed", ours().count == 1 && ours().first?.name == "One is finishing 3 helpers, a reply and a routine")
        for i in 0..<300 {
            KeepAwake.sync(KeepAwake.work(reply: i % 2 == 0, helpers: i % 3 == 0 ? [] : [fake("working")], routines: 0))
        }
        check("300 flips leave at most one", ours().count <= 1)
        KeepAwake.sync(KeepAwake.work(reply: false, helpers: [fake("working")], routines: 0), now: Date().addingTimeInterval(3600))
        check("renewing keeps exactly one", ours().count == 1)

        print("3. what counts as working")
        check("a reply in progress", KeepAwake.work(reply: true, helpers: [], routines: 0).any)
        check("a helper picked back up after a restart", KeepAwake.work(reply: false, helpers: [fake("stopped", queued: true)], routines: 0).any)
        check(
            "not a finished, stopped or waiting-for-yes helper",
            !KeepAwake.work(reply: false, helpers: [fake("done"), fake("stopped"), fake("needsYes")], routines: 0).any)
        let cron = Routines.cron
        try? FileManager.default.createDirectory(at: cron, withIntermediateDirectories: true)
        let now = Date()
        let iso = ISO8601DateFormatter()
        let jobs: [[String: Any]] = [
            [
                "id": "a", "name": "Morning brief", "enabled": true, "schedule": ["kind": "cron", "expr": "0 8 * * *"],
                "last_run_at": iso.string(from: now.addingTimeInterval(-86400)),
                "last_dispatch": ["dispatched_at": iso.string(from: now.addingTimeInterval(-60))],
            ],
            [
                "id": "b", "name": "Price watch", "enabled": true, "schedule": ["kind": "cron", "expr": "0 9 * * *"],
                "last_run_at": iso.string(from: now.addingTimeInterval(-600)),
            ],
        ]
        try? JSONSerialization.data(withJSONObject: ["jobs": jobs]).write(to: cron.appendingPathComponent("jobs.json"))
        check("a running routine (and not one that's done)", KeepAwake.countRoutines(now: now) == 1)

        print("4. nothing working")
        KeepAwake.sync(KeepAwake.work(reply: false, helpers: [fake("done")], routines: 0))
        check("let go: the Mac sleeps as usual", ours().isEmpty && KeepAwake.held == 0)
        KeepAwake.sync(KeepAwake.work(reply: false, helpers: [fake("working")], routines: 0))
        KeepAwake.start()
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: NSApp)
        check("quitting lets go", ours().isEmpty && KeepAwake.held == 0)

        print("5. the assistant answers \"will it keep going if my Mac sleeps?\" right")
        let soul = Persona.soul(assistant: "Ava", user: "Ek")
        check("SOUL says yes while the lid is open", soul.contains(KeepAwake.soul) && soul.contains("keeps going while the lid stays open"))
        check("and that closing the lid still sleeps it", soul.contains("Closing the lid") && soul.contains("battery"))
        check("every prompt carries it", Helpers.note.contains(KeepAwake.marker))
        print(fails == 0 ? "keep awake ok" : "keep awake: \(fails) failed")
        return fails == 0 ? 0 : 1
    }

    /// For the pmset check: hold for a fake helper, print, wait; let go, print, wait (killed early = crash test).
    @MainActor
    static func hold() -> Never {
        let secs = Double(ProcessInfo.processInfo.environment["ONE_HOLD_SECS"] ?? "") ?? 4
        KeepAwake.sync(KeepAwake.work(reply: false, helpers: [fake("working"), fake("working")], routines: 0))
        print("holding \(getpid()) \(KeepAwake.name)")
        fflush(stdout)
        Thread.sleep(forTimeInterval: secs)
        KeepAwake.sync(KeepAwake.work(reply: false, helpers: [fake("done"), fake("done")], routines: 0))
        print("released \(getpid())")
        fflush(stdout)
        Thread.sleep(forTimeInterval: secs)
        exit(0)
    }
}
