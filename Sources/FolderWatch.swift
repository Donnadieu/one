import Foundation

// MARK: - Restart by itself after a new folder is allowed

/// The folder lock is fixed when the engine starts. When the allowed folders (`folders`) or a
/// connection's paths (`connectorReads`) change after that, including the assistant adding one from
/// a chat with `defaults write`, One waits until nothing is mid-reply, restarts its engine with a
/// freshly built lock (stopping the old background helper too, which would otherwise keep the old
/// lock), reopens the same conversation and, if the assistant was busy, tells it to carry on.
enum FolderWatch {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var startedWith: String?
    nonisolated(unsafe) private static var startedProfileText = ""
    nonisolated(unsafe) private static var restarting = false
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

    /// Called from the main loop tick. Restarts at most once per change, never while busy.
    /// `restart(resume)`: resume = the change came from a job that was running, so tell it to carry on.
    @MainActor
    static func tend(busy: Bool, running: Bool, restart: @escaping @MainActor (Bool) async -> Void) {
        if busy { lastBusy = Date() }
        lock.lock()
        let already = restarting
        lock.unlock()
        guard !already, running, !busy, changed else { return }
        lock.lock()
        restarting = true
        lock.unlock()
        let resume = Date().timeIntervalSince(lastBusy) < 30
        GatewayGuard.log("folder access changed: restarting the engine (resume: \(resume))")
        Task { @MainActor in
            await restart(resume)
            lock.lock()
            restarting = false
            lock.unlock()
        }
    }

    static let restartedLine = "I restarted to use the new folder access."
    static let carryOn =
        "(One app note, not from the user: One restarted with the new folder access; carry on with what you were doing.)"

    /// Told to the assistant every turn.
    static var note: String {
        "\n\n(One app note, not from the user: FOLDER ACCESS. You can only open One's own data, the brain and the folders on One's list. "
            + "If they agree to let you open a new folder, add it with: CUR=\"$(defaults read ai.forjado.one folders 2>/dev/null)\"; "
            + "defaults write ai.forjado.one folders -string \"$CUR\"$'\\n'\"<full path>\" (one text with one folder per line, not an array). "
            + "Then just say you'll restart to use it and end your reply. One notices, restarts by itself once you're done, reopens this "
            + "conversation and tells you to carry on. Never restart or stop One, its engine or its background helper yourself, and never "
            + "ask them to reopen One.)"
    }
}
