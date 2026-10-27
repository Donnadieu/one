import Foundation

// MARK: - Test world: everything on the person's Mac is production

/// Owner's rule: the person's documents, settings and One's own folder are production. A test, check or
/// render never reads-writes them; it runs in a world of its own. On Oct 27, 2026 a check run as the real
/// One (`--test-connections-open`) moved every file in Documents › Made by Elias into a test folder.
///
/// What this guarantees, in code:
/// - `enter()` is the only way into a test mode (one-lint `test-world`). It refuses to run as the real One
///   (bundle id `ai.forjado.one`), so the person's settings are never the test's settings. Make a test copy
///   with `tools/test-copy.sh` (own bundle id, own settings).
/// - A test's One folder is never the real one: `ONE_SUPPORT_DIR` when set, otherwise a fresh scratch folder.
///   Anything a test needs from the real folder (the sign-in file, the engine's tools) is read from
///   `realSupport` and copied or linked into the test world, never written back.
/// - Files and cards on the Ready for you shelf are only ever moved by the real One (`Env.production`).
enum TestWorld {
    static let productionID = "ai.forjado.one"
    nonisolated(unsafe) static var scratch: URL?

    /// The first line of every test mode.
    static func enter() {
        Env.selfTest = true
        let mode = CommandLine.arguments.dropFirst().first { $0.hasPrefix("--") } ?? "this test"
        if Bundle.main.bundleIdentifier == productionID {
            print("refusing: \(mode) is a test and never runs as your real One (your files and settings are left alone).")
            print("FIX: run it from a test copy: APP=$(tools/test-copy.sh) && \"$APP/Contents/MacOS/One\" \(mode)")
            exit(2)
        }
        if ProcessInfo.processInfo.environment["ONE_SUPPORT_DIR"] == nil {
            let base = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
            let u = URL(fileURLWithPath: base).appendingPathComponent("one-test-\(getpid())", isDirectory: true)
            try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
            scratch = u
            atexit { if let s = TestWorld.scratch { try? FileManager.default.removeItem(at: s) } }
        }
        guard !isProduction(Env.support) else {
            print("refusing: \(mode) would use your real One folder. Set ONE_SUPPORT_DIR to an empty folder.")
            exit(2)
        }
    }

    /// The real One folder, for reading fixtures only (never written by a test).
    static var realSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("One", isDirectory: true)
    }

    /// True for the person's real One folder, Documents, Desktop, Downloads or anything inside them.
    static func isProduction(_ u: URL) -> Bool {
        let p = u.standardizedFileURL.resolvingSymlinksInPath().path
        // The engine's own scratch folder is pruned by itself and holds no one's things: tests may work there.
        let scratchArea = realSupport.appendingPathComponent("hermes/cache/scratch").standardizedFileURL.resolvingSymlinksInPath().path
        if p.hasPrefix(scratchArea + "/") { return false }
        let fm = FileManager.default
        var roots = [realSupport]
        for d in [FileManager.SearchPathDirectory.documentDirectory, .desktopDirectory, .downloadsDirectory] {
            roots += fm.urls(for: d, in: .userDomainMask)
        }
        return roots.contains {
            let r = $0.standardizedFileURL.resolvingSymlinksInPath().path
            return p == r || p.hasPrefix(r + "/")
        }
    }

}

extension Env {
    /// The person's own One, opened by them: the only mode that may move or drop their files and cards.
    static var production: Bool { !selfTest && !commandLine && Bundle.main.bundleIdentifier == TestWorld.productionID }
}
