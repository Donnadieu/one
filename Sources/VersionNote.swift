import Foundation

// MARK: - Which One is running: told to the assistant and to every helper on every prompt, so they answer
// "how does One work / did X ship" from the code at that version, never from old notes or memory.

@MainActor
enum VersionNote {
    /// The running version (CFBundleShortVersionString), the newest GitHub release if it's newer, and how to read the code at the tag.
    static var note: String { text(running: Updater.shared.current, newest: Updater.shared.newest) }

    static func text(running v: String, newest: String?) -> String {
        var s = "\n\n(One app note, not from the user: THIS MAC RUNS ONE \(v)."
        if let n = newest, Updater.newer(n, than: v) {
            s += " A newer release, One \(n), is on GitHub (the update card offers it); it isn't installed here yet."
        }
        s +=
            " Before saying how One works or whether something shipped, read the code at tag v\(v)"
            + " (git -C ~/Repos/one-assistant show v\(v):Sources/<file>, or gh api repos/\(Updater.repo)/contents/Sources/<file>?ref=v\(v))"
            + " and name the version you checked. Never answer that from memory, skills or old notes: they go stale with every release.)"
        return s
    }
}
