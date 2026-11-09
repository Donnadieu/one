import AppKit
import Foundation
import ServiceManagement

// MARK: - One comes back by itself (0.9.99)
//
// Nov 6 2026: One quit for an update during a dark wake, the new copy crashed at launch, and nothing started it again
// for 18 hours, so the phone chat and every routine were down. The keeper is a small background job macOS runs every
// minute (a launch agent inside One.app, registered with `SMAppService`): `One --keeper` looks at `keeper.json` and,
// when One should be open but isn't (a crash, a failed relaunch after an update), opens it again in the background.
// It waits longer after each try (1, 5, 15, 30, then 60 minutes), and after three failed starts of a version an update
// just installed it puts the previous version back. A quit the person asked for (⌘Q, Dock › Quit, `kill`) is
// remembered and respected: the keeper never opens One against their wish. The Mac logging out, restarting or shutting
// down isn't a quit of One: it comes back after they log in again (0.9.100).

enum Keeper {
    static let label = "ai.forjado.one.keeper"
    static let plist = "\(label).plist"
    static var file: URL { Env.support.appendingPathComponent("keeper.json") }
    static var log: URL { Env.hermesHome.appendingPathComponent("logs/one-keeper.log") }
    /// The version an update replaced, kept until the next update (`Updater.swapScript` moves it here).
    /// (Outside `update/`, which every new download empties.)
    static var previous: URL { Env.support.appendingPathComponent("update-previous/One.app") }
    /// Present while the update script swaps the app: never open One halfway through.
    static var swapping: URL { Env.support.appendingPathComponent("update-swapping") }

    struct State: Codable, Equatable {
        var want = false  // One should be open (it is, or it ended without being asked to)
        var app = ""  // the One.app to keep open
        var startedAt: Date?  // when the open One started
        var launches: [Date] = []  // the keeper's own starts since One last stayed up `healthyAfter`
        var updatedAt: Date?  // an update swapped the app in (the window for putting the old one back)
        var updatedTo: String?
        var badVersions: [String] = []  // versions put back after they failed to start; the updater skips them
    }

    enum Action: Equatable {
        case nothing(String)
        case wait(Double)
        case launch
        case rollBack
    }

    /// Waits between the keeper's own starts: right away, then 1, 5, 15, 30 and 60 minutes.
    static let delays: [Double] = [0, 60, 300, 900, 1800, 3600]
    /// One up this long counts as a good start (the tries start over).
    static let healthyAfter: Double = 600
    /// Failed starts of a just-installed version before the previous one is put back.
    static let rollbackAfter = 3

    /// What to do now. Pure, so the check can walk every case.
    static func decide(_ s: State, running: Bool, now: Date, previousExists: Bool, swapping: Bool = false) -> Action {
        guard s.want else { return .nothing("One was quit on purpose") }
        guard !s.app.isEmpty else { return .nothing("no One recorded yet") }
        if running { return .nothing("One is open") }
        if swapping { return .wait(30) }
        let n = s.launches.count
        if n >= rollbackAfter, previousExists, let u = s.updatedAt, now.timeIntervalSince(u) < 2 * 86400, let to = s.updatedTo,
            !s.badVersions.contains(to)
        {
            return .rollBack
        }
        if let last = s.launches.last {
            let left = last.addingTimeInterval(delays[min(n, delays.count - 1)]).timeIntervalSince(now)
            if left > 0 { return .wait(left) }
        }
        return .launch
    }

    // MARK: State file

    static func load() -> State {
        guard let d = try? Data(contentsOf: file) else { return State() }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode(State.self, from: d)) ?? State()
    }
    static func save(_ s: State) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? enc.encode(s).write(to: file, options: .atomic)
    }
    static func note(_ line: String) {
        let s = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: log) {
            h.seekToEndOfFile()
            h.write(Data(s.utf8))
            try? h.close()
        } else {
            try? s.write(to: log, atomically: true, encoding: .utf8)
        }
    }

    // MARK: The background job (`One --keeper`, every minute)

    /// `One --keeper`: run by macOS every minute. Opens One again if it should be open and isn't. Returns nil for other arguments.
    static func cli(_ args: [String]) -> Int32? {
        guard args.contains("--keeper") else { return nil }
        tick(now: testNow ?? Date())
        return 0
    }
    /// Checks only: the keeper's clock (seconds since 1970), honoured only with a scratch One folder.
    static var testNow: Date? {
        let e = ProcessInfo.processInfo.environment
        guard e["ONE_SUPPORT_DIR"] != nil, let t = e["ONE_KEEPER_NOW"].flatMap(Double.init) else { return nil }
        return Date(timeIntervalSince1970: t)
    }

    static func tick(now: Date) {
        var s = load()
        let fm = FileManager.default
        if s.want, !s.app.isEmpty, !fm.fileExists(atPath: s.app) && !fm.fileExists(atPath: swapping.path) {
            return note("One isn't at \(s.app) any more; nothing to open")
        }
        let isSwapping =
            (try? swapping.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map {
                now.timeIntervalSince($0) < 180
            } ?? false
        let action = decide(s, running: running(s.app), now: now, previousExists: fm.fileExists(atPath: previous.path), swapping: isSwapping)
        switch action {
        case .nothing, .wait: return
        case .rollBack:
            if putBack(&s) {
                s.launches = []
                save(s)
            } else {
                s.badVersions.append(s.updatedTo ?? "?")  // can't put it back: don't try again, keep opening this one
                save(s)
                return
            }
            launch(&s, now: now, why: "the previous version is back")
        case .launch:
            launch(&s, now: now, why: s.launches.isEmpty ? "One ended without being asked to" : "try \(s.launches.count + 1)")
        }
    }

    /// Whether a copy of One from this app is open (any bundle id the app carries; never this keeper process).
    static func running(_ app: String) -> Bool {
        guard let id = Bundle(path: app)?.bundleIdentifier else { return false }
        return NSRunningApplication.runningApplications(withBundleIdentifier: id).contains {
            !$0.isTerminated && $0.processIdentifier != getpid()
        }
    }

    static func launch(_ s: inout State, now: Date, why: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-g", s.app]  // in the background: it never takes the focus from what the person is doing
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        var ok = false
        do {
            try p.run()
            p.waitUntilExit()
            ok = p.terminationStatus == 0
        } catch {}
        s.launches.append(now)
        save(s)
        note("opened One again (\(why))\(ok ? "" : ": macOS refused, trying again later")")
    }

    /// Puts the version an update replaced back in place (same signer only). The failed one is kept beside it.
    static func putBack(_ s: inout State) -> Bool {
        let fm = FileManager.default
        guard let bad = s.updatedTo, sameSigner(previous.path, s.app) else {
            note("couldn't put the previous version back (missing or signed by someone else)")
            return false
        }
        let keep = Env.support.appendingPathComponent("update-failed/\(bad)", isDirectory: true)
        try? fm.removeItem(at: keep)
        try? fm.createDirectory(at: keep, withIntermediateDirectories: true)
        let app = URL(fileURLWithPath: s.app)
        guard (try? fm.moveItem(at: app, to: keep.appendingPathComponent("One.app"))) != nil else {
            note("couldn't move \(bad) aside")
            return false
        }
        guard (try? fm.moveItem(at: previous, to: app)) != nil else {
            try? fm.moveItem(at: keep.appendingPathComponent("One.app"), to: app)
            note("couldn't put the previous version back")
            return false
        }
        s.badVersions.append(bad)
        s.updatedAt = nil
        note("One \(bad) failed to start \(rollbackAfter) times: put the previous version back")
        return true
    }

    static func sameSigner(_ a: String, _ b: String) -> Bool {
        func team(_ path: String) -> String? {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            p.arguments = ["-dvv", path]
            let pipe = Pipe()
            p.standardError = pipe
            p.standardOutput = pipe
            guard (try? p.run()) != nil else { return nil }
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { return nil }
            return out.split(separator: "\n").first { $0.hasPrefix("TeamIdentifier=") }.map(String.init) ?? "TeamIdentifier=none"
        }
        guard FileManager.default.fileExists(atPath: a), let ta = team(a), let tb = team(b) else { return false }
        return ta == tb
    }

    // MARK: The app's side

    /// Set just before an update's own quit: One must come back after it, so `want` stays on.
    nonisolated(unsafe) static var restarting = false

    /// At launch of the person's real One: keep it open from now on, and make sure the background job is on.
    static func started() {
        guard Env.production else { return }
        var s = load()
        s.want = true
        s.app = Bundle.main.bundlePath
        s.startedAt = Date()
        save(s)
        register()
        watchPowerOff()
        Task.detached {
            try? await Task.sleep(for: .seconds(healthyAfter))
            var s = load()
            guard s.want, !s.launches.isEmpty || s.updatedAt != nil else { return }
            if s.updatedAt != nil { note("One \(s.updatedTo ?? "?") stayed up \(Int(healthyAfter / 60)) minutes: the update is good") }
            s.launches = []
            s.updatedAt = nil
            save(s)
        }
    }

    /// One is quitting. A quit the person asked for turns the keeper off until One is opened again.
    static func quitting() {
        guard Env.production else { return }
        var s = load()
        let off = poweringOffAt.map { Date().timeIntervalSince($0) < powerOffWindow } ?? false
        s.want = wantAfterQuit(restarting: restarting, poweringOff: off)
        save(s)
        note(
            restarting
                ? "quit for an update: One comes back by itself"
                : off ? "the Mac is logging out, restarting or shutting down: One comes back after it" : "quit by the person: staying closed")
    }

    /// Whether One should be opened again after this quit. An update's own quit: yes. The Mac logging out, restarting
    /// or shutting down (an overnight macOS update, a restart they chose): yes, they ended the session, not One, and the
    /// phone chat and routines must come back once they log in again (0.9.100; before, a restart counted as a quit and
    /// One stayed closed). A quit they asked for (Cmd-Q, Dock, `kill`): no. Pure, so the check can walk every case.
    static func wantAfterQuit(restarting: Bool, poweringOff: Bool) -> Bool { restarting || poweringOff }

    /// When macOS said it's logging out, restarting or shutting down (`NSWorkspace.willPowerOffNotification`).
    nonisolated(unsafe) static var poweringOffAt: Date?
    /// A logout they cancelled longer ago than this no longer turns a later Cmd-Q into "come back".
    static let powerOffWindow: Double = 300

    /// Once, at launch: notice when the Mac is about to log out, restart or shut down.
    static func watchPowerOff() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: nil) { _ in
            poweringOffAt = Date()
        }
    }

    /// An update is about to swap the app: remember what for the keeper's put-back.
    static func updating(to version: String) {
        guard Env.production else { return }
        var s = load()
        s.want = true
        s.updatedAt = Date()
        s.updatedTo = version
        s.launches = []
        save(s)
        restarting = true
    }

    /// Versions put back after they failed to start; the updater never offers them again.
    static var badVersions: [String] { load().badVersions }

    /// Turns the background job on (once; macOS shows "One added a background item" the first time).
    static func register() {
        let svc = SMAppService.agent(plistName: plist)
        guard svc.status != .enabled else { return }
        do {
            try svc.register()
            note("background keeper on")
        } catch {
            note("background keeper couldn't start (\(svc.status.rawValue)): \(error.localizedDescription)")
        }
    }
}
