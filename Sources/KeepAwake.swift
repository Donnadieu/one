import AppKit
import IOKit.pwr_mgt

// MARK: - Keep the Mac awake while One works
//
// Ek started a research job and went to the gym: "if my computer goes to sleep, it'll keep going, right?".
// Before 0.9.51 it didn't: idle sleep froze every helper. Now, while a reply is in progress, a helper is working
// (or waits to be picked back up after a restart) or a scheduled routine is running, One holds ONE power
// assertion that stops idle system sleep. The screen still dims and turns off as usual. As soon as nothing is
// working, it lets go and the Mac sleeps as usual.
//
// Robustness:
// - One shared assertion, counted from the live state on every tick (`sync`), never retain/release calls a code
//   path could forget: a missed release can't leak, the next tick fixes it.
// - It carries a 5 minute timeout (release on timeout) and is renewed every minute while work goes on, so a
//   frozen One can't keep the Mac up for good. The OS drops it with the process on a crash; quit releases it.
// - Holds on battery too (the work matters more; it uses some battery), with the lid open only: closing the lid
//   or picking Sleep still sleeps the Mac. Routines can't wake a sleeping Mac (that needs an admin password).
// Check: `One --test-keep-awake` + `pmset -g assertions` in tools/keep-awake-check.sh (preflight).

@MainActor
enum KeepAwake {
    struct Work: Equatable {
        var helpers = 0
        var reply = false
        var routines = 0
        var any: Bool { helpers > 0 || reply || routines > 0 }
    }

    nonisolated static let type = kIOPMAssertPreventUserIdleSystemSleep as String
    static let timeout = 300  // seconds; renewed every `renewEvery` while work goes on
    static let renewEvery: TimeInterval = 60
    static let details = "One keeps the Mac awake while it works. The screen can still turn off. Closing the lid still sleeps the Mac."

    /// The one assertion One holds (0 = none).
    private(set) static var held: IOPMAssertionID = 0
    private(set) static var name = ""
    private static var armedAt = Date.distantPast
    /// Scheduled routines running now, read off the main thread every ~15 s (`refreshRoutines`).
    static var routinesRunning = 0
    static var watching = false

    /// What's working, from the app's own state. A helper cut off by a restart and waiting to be picked back up counts.
    static func work(reply: Bool, helpers: [Helper], routines: Int) -> Work {
        Work(helpers: helpers.filter { $0.state == "working" || $0.resumeQueued == true }.count, reply: reply, routines: routines)
    }

    /// The plain-words name `pmset -g assertions` (and Activity Monitor's energy tab) shows.
    static func label(_ w: Work) -> String {
        var parts: [String] = []
        if w.helpers > 0 { parts.append(w.helpers == 1 ? "1 helper" : "\(w.helpers) helpers") }
        if w.reply { parts.append("a reply") }
        if w.routines > 0 { parts.append(w.routines == 1 ? "a routine" : "\(w.routines) routines") }
        let list = parts.count > 1 ? parts.dropLast().joined(separator: ", ") + " and " + parts.last! : parts.first ?? "its work"
        return "One is finishing " + list
    }

    /// Hold the assertion while anything works, rename it when the count changes, let go when nothing does.
    static func sync(_ w: Work, now: Date = Date()) {
        guard w.any else { return releaseNow() }
        let want = label(w)
        if held == 0 {
            held = create(want)
            name = held == 0 ? "" : want
            armedAt = now
        } else if now.timeIntervalSince(armedAt) >= renewEvery {
            // Renew: the new one first, then drop the old, so there's no gap and never two for long.
            let fresh = create(want)
            if fresh != 0 {
                IOPMAssertionRelease(held)
                held = fresh
                name = want
                armedAt = now
            }
        } else if want != name {
            IOPMAssertionSetProperty(held, kIOPMAssertionNameKey as CFString, want as CFString)
            name = want
        }
    }

    static func releaseNow() {
        guard held != 0 else { return }
        IOPMAssertionRelease(held)
        held = 0
        name = ""
    }

    private static func create(_ label: String) -> IOPMAssertionID {
        let props: [String: Any] = [
            kIOPMAssertionTypeKey as String: type,
            kIOPMAssertionNameKey as String: label,
            kIOPMAssertionDetailsKey as String: details,
            kIOPMAssertionLevelKey as String: Int(kIOPMAssertionLevelOn),
            kIOPMAssertionTimeoutKey as String: timeout,
            kIOPMAssertionTimeoutActionKey as String: kIOPMAssertionTimeoutActionRelease as String,
        ]
        var id: IOPMAssertionID = 0
        return IOPMAssertionCreateWithProperties(props as CFDictionary, &id) == kIOReturnSuccess ? id : 0
    }

    /// Once: watch routines in the background, and let go when One quits.
    static func start() {
        guard !watching else { return }
        watching = true
        watchRoutines()
        // Quitting lets the Mac sleep again at once (a crash drops it too: the OS ends it with the process).
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { KeepAwake.releaseNow() }
        }
    }

    /// Every 15 s, off the main thread: how many scheduled routines are running (for `sync`).
    nonisolated static func watchRoutines() {
        Task.detached {
            while true {
                let n = countRoutines()
                await MainActor.run { routinesRunning = n }
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    /// Read which routines are running (jobs.json in One's own engine folder). Call from a background task.
    nonisolated static func countRoutines(now: Date = Date()) -> Int {
        Routines.jobs(at: Routines.cron, now: now).filter { $0.state == .running }.count
    }

    /// This process's assertions as the OS sees them (type, name), for checks.
    nonisolated static func mine() -> [(type: String, name: String)] {
        var out: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&out) == kIOReturnSuccess, let d = out?.takeRetainedValue() as? [AnyHashable: Any] else { return [] }
        let pid = Int(getpid())
        let list = d.first { ($0.key as? NSNumber)?.intValue == pid }?.value as? [[String: Any]] ?? []
        return list.map { ($0[kIOPMAssertionTypeKey as String] as? String ?? "", $0[kIOPMAssertionNameKey as String] as? String ?? "") }
    }

    // MARK: What the assistant tells people (SOUL + every prompt)

    nonisolated static let soul = """
        Sleep: while you, a helper or a routine is working, One keeps the Mac awake by itself, plugged in or on battery (on battery that uses some charge). The screen can still go dark; that's fine. When nothing is working, the Mac sleeps as usual. So if they ask "will it keep going if my Mac sleeps?" or "can I walk away?": yes, it keeps going while the lid stays open, even with the screen off. Closing the lid (or choosing Sleep) still puts the Mac to sleep and pauses the work until it's opened again, and a routine can't wake a sleeping Mac. If the Mac is closed or off, you're off. Say so if they ask why you didn't do something.
        """
    nonisolated static let marker = "KEEPS GOING WHILE THE MAC IS OPEN."
    nonisolated static var note: String {
        "\n\n(One app note, not from the user: \(marker) While you, a helper or a routine works, One keeps this Mac awake (plugged in or on battery; the screen may go dark). Asked \"will it keep going if my Mac sleeps?\": yes while the lid stays open; closing the lid or choosing Sleep still sleeps the Mac and pauses the work.)"
    }
}

extension Model {
    /// Every second from the main loop: no file reads here, routines are counted in the background.
    func tendKeepAwake() {
        KeepAwake.start()
        KeepAwake.sync(KeepAwake.work(reply: thinking, helpers: helpers, routines: KeepAwake.routinesRunning))
    }
}
