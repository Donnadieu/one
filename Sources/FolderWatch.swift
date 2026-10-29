import Foundation

// MARK: - Restart by itself after a new folder is allowed

/// The folder lock is fixed when the engine starts. When the allowed folders (`folders`) or a
/// connection's paths (`connectorReads`) change after that, including the assistant adding one from
/// a chat with `defaults write`, One restarts its engine with a freshly built lock (stopping the old
/// background helper too, which would otherwise keep the old lock), reopens the same conversation and,
/// if the assistant was busy, tells it to carry on. It never waits on helpers for long: a helper is
/// often the one that needs the folder, so after `helperGrace` working helpers are paused and picked
/// back up after the restart. A reply in progress gets up to `maxWait`. A routine at work (a scheduled job mid-run) is
/// waited for, up to `routineWait`: restarting the engine would cut its run off midway.
enum FolderWatch {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var startedWith: String?
    nonisolated(unsafe) private static var startedProfileText = ""
    nonisolated(unsafe) private static var restarting = false
    nonisolated(unsafe) private static var startedPaths: [String] = []
    /// When the running engine's lock first fell behind the folder list.
    nonisolated(unsafe) private static var changedSince: Date?
    /// How long a change waits for working helpers to finish before they're paused for the restart.
    static let helperGrace: TimeInterval = 15
    /// The longest a change waits for anything, a reply in progress included (a newly allowed folder works within a minute).
    static let maxWait: TimeInterval = 45
    /// The longest a change waits for a routine at work.
    static let routineWait: TimeInterval = 2 * 3600  // same as an update (Updater.routineWait)
    /// Last time the assistant or a helper was busy: a change seen soon after came from that job.
    nonisolated(unsafe) static var lastBusy = Date.distantPast

    /// What the lock is built from. Reads fresh values (another process may have written them).
    static func fingerprint() -> String {
        if Access.override == nil || Access.readsOverride == nil {
            CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        }
        return (Access.folders + ["\u{1}"] + Access.connectorReads).joined(separator: "\n")
    }

    /// Engine.start calls this with the lock it starts the engine under.
    static func engineStarted(profile: String) {
        let f = fingerprint()
        lock.lock()
        startedWith = f
        startedProfileText = profile
        startedPaths = Access.folders + Access.connectorReads
        changedSince = nil
        lock.unlock()
    }

    static var startedProfile: String {
        lock.lock()
        defer { lock.unlock() }
        return startedProfileText
    }

    /// True when the running engine's lock is older than the folder list.
    static var changed: Bool {
        lock.lock()
        let s = startedWith
        lock.unlock()
        guard let s else { return false }
        return s != fingerprint()
    }

    /// Folders and connection paths allowed since the engine started (shown in the restart line).
    static var added: [String] {
        lock.lock()
        let before = Set(startedPaths)
        lock.unlock()
        return (Access.folders + Access.connectorReads).filter { !before.contains($0) }
    }

    /// Should a changed lock restart the engine now? Right away when nothing is working; past
    /// `helperGrace` even with helpers working (they're paused and pick back up); past `maxWait` even
    /// mid-reply. Waiting for every helper to finish could wait forever: the helper that needs the folder
    /// keeps working (retrying) until it gets it.
    static func due(talking: Bool, helpersWorking: Bool, waited: TimeInterval, routineBusy: Bool = false) -> Bool {
        if routineBusy && waited < routineWait { return false }
        if !talking && !helpersWorking { return true }
        if !talking && waited >= helperGrace { return true }
        return waited >= maxWait
    }

    /// Called from the main loop tick. Restarts at most once per change.
    /// `restart(resume, pauseHelpers)`: resume = the change came from a job that was running, so tell
    /// it to carry on; pauseHelpers = helpers are still working and must be paused first.
    @MainActor
    static func tend(
        talking: Bool, helpersWorking: Bool, running: Bool, now: Date = Date(), routineBusy: () -> Bool = { false },
        restart: @escaping @MainActor (Bool, Bool) async -> Void
    ) {
        if talking || helpersWorking { lastBusy = now }
        lock.lock()
        let already = restarting
        lock.unlock()
        guard !already, running, changed else { return }
        lock.lock()
        if changedSince == nil { changedSince = now }
        let waited = now.timeIntervalSince(changedSince ?? now)
        lock.unlock()
        guard due(talking: talking, helpersWorking: helpersWorking, waited: waited, routineBusy: routineBusy()) else { return }
        lock.lock()
        restarting = true
        lock.unlock()
        let resume = talking || now.timeIntervalSince(lastBusy) < 30
        GatewayGuard.log(
            "folder access changed: restarting the engine (resume: \(resume), helpers working: \(helpersWorking), waited \(Int(waited)) s)")
        Task { @MainActor in
            await restart(resume, helpersWorking)
            lock.lock()
            restarting = false
            lock.unlock()
        }
    }

    /// The plain line shown (and said) just before the restart.
    static func restartingLine(_ paths: [String], helpers: Bool) -> String {
        let names = paths.map { ($0 as NSString).abbreviatingWithTildeInPath }
        let what = names.isEmpty ? "use the new folder access" : "open " + names.joined(separator: ", ")
        return "Restarting to \(what)." + (helpers ? " Your helpers will pick up where they left off." : "")
    }
    static let restartedLine = "I restarted to use the new folder access."
    static let pausedLine = "Paused to open a new folder · picks back up by itself"
    static let carryOn =
        "(One app note, not from the user: One restarted with the new folder access; carry on with what you were doing.)"

    /// Told to the assistant every turn.
    static var note: String {
        "\n\n(One app note, not from the user: FOLDER ACCESS. You can only open One's own data, the brain and the folders on One's list. "
            + "If they agree to let you open a new folder, add it with: CUR=\"$(defaults read ai.forjado.one folders 2>/dev/null)\"; "
            + "defaults write ai.forjado.one folders -string \"$CUR\"$'\\n'\"<full path>\" (one text with one folder per line, not an array). "
            + "Then just say you'll restart to use it and end your reply. One notices, restarts by itself within a minute (or once a routine at work finishes; helpers that "
            + "are working are paused and pick back up by themselves), reopens this conversation and tells you to carry on. Never restart "
            + "or stop One, its engine or its background helper yourself, never wait in a loop for the folder to open, and never "
            + "ask them to reopen One.)"
    }
}
