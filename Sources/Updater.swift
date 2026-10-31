import Quartz
import SwiftUI
import AppKit
import AVFoundation
import Speech
import PDFKit
import Carbon
import EventKit
import CoreAudio
import UniformTypeIdentifiers
import UserNotifications

// MARK: - Updates: checks GitHub releases, downloads the new app, swaps it and reopens. Brain, rooms and settings live outside the app and are never touched.

@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    static let repo = "Donnadieu/one"
    @Published var available: (version: String, notes: String, zip: URL)?
    @Published var state: String?  // "Downloading…", errors
    /// The newest release with One.zip above the running version, even after "Later" (told to the assistant every turn).
    private(set) var newest: String?
    var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    static func newer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0
            let q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
    /// Where releases are listed. `ONE_RELEASES_URL` points it at a fake list (a file or a local server) for tests.
    static var releasesURL: URL? {
        if let o = ProcessInfo.processInfo.environment["ONE_RELEASES_URL"], !o.isEmpty {
            return o.hasPrefix("/") ? URL(fileURLWithPath: o) : URL(string: o)
        }
        return URL(string: "https://api.github.com/repos/\(Updater.repo)/releases?per_page=10")
    }
    /// Tests keep their own settings, so they never touch the person's real ones.
    static var store: UserDefaults {
        Env.selfTest ? (UserDefaults(suiteName: "ai.forjado.one.updates-test") ?? .standard) : .standard
    }
    static let every: Double = 15 * 60
    /// Longest an update waits for the reply in progress before it goes ahead.
    static let replyWait: Double = 20
    /// Longest an update waits for a routine at work (a scheduled job mid-run) before it goes ahead.
    static var routineWait: Double = 2 * 3600
    /// Longest an update waits for a helper mid a sensitive dev step (building, testing, pushing, releasing)
    /// before it goes ahead: cutting that off mid-way can corrupt a build or leave a half-finished push.
    static var sensitiveWait: Double = 20 * 60
    /// What the card says while an update waits for routines to finish.
    static func routineLine(_ names: [String]) -> String {
        let n = Routines.list(names.map { "\u{201C}\($0)\u{201D}" })
        return "I'll update as soon as \(n) \(names.count == 1 ? "finishes" : "finish"), so \(names.count == 1 ? "it isn't" : "they aren't") cut off."
    }
    /// What the card says while an update waits for a sensitive helper step to finish.
    static func sensitiveLine(_ names: [String]) -> String {
        let n = Routines.list(names.map { "\u{201C}\($0)\u{201D}" })
        return "I'll update once \(n) \(names.count == 1 ? "finishes" : "finish") this step, so nothing's left half-done."
    }
    /// The script that waits for One to quit, then swaps the downloaded app into place. Before the swap: the new
    /// bundle's code signature must verify (`codesign --verify --deep --strict`) AND its signing team must match
    /// the one running right now — a tampered zip (unsigned, altered, or re-signed by someone else) is left
    /// untouched on disk and the old app stays in place, never installed. Static + parameterized so a test can run
    /// it against fixture bundles without touching the real app.
    static func swapScript(newApp: String, target: String, dir: String, waitPID: Int32, enginePID: Int32?, noReopen: Bool) -> String {
        """
        #!/bin/bash
        while kill -0 \(waitPID) 2>/dev/null; do sleep 0.5; done
        if [ \(Env.selfTest ? 1 : 0) = 0 ]; then
        pkill -f "\(Env.engineDir.path)" 2>/dev/null; pkill -f "\(Env.support.path)/voice" 2>/dev/null
        else \(enginePID.map { "kill \($0)" } ?? ": # no engine pid to kill (never \"kill 0\" — that signals the whole process group)") 2>/dev/null; fi
        if ! /usr/bin/codesign --verify --deep --strict "\(newApp)" 2>/dev/null; then
        echo "Update aborted: the downloaded app's code signature did not verify. The current version was kept." >&2
        rm -rf "\(dir)"
        exit 1
        fi
        NEWTEAM=$(/usr/bin/codesign -dvv "\(newApp)" 2>&1 | sed -n 's/^TeamIdentifier=//p')
        RUNTEAM=$(/usr/bin/codesign -dvv "\(target)" 2>&1 | sed -n 's/^TeamIdentifier=//p')
        if [ "$NEWTEAM" != "$RUNTEAM" ]; then
        echo "Update aborted: signing team mismatch (update=$NEWTEAM, running=$RUNTEAM). The current version was kept." >&2
        rm -rf "\(dir)"
        exit 1
        fi
        xattr -dr com.apple.quarantine "\(newApp)" 2>/dev/null
        rm -rf "\(target).old" && mv "\(target)" "\(target).old" && mv "\(newApp)" "\(target)" && rm -rf "\(target).old" || { [ -d "\(target)" ] || mv "\(target).old" "\(target)"; }
        \(noReopen ? "echo done > \"\(dir)/swapped\"" : "open \"\(target)\"")
        """
    }
    private var etag: String?
    private var lastList: Data?
    private var lastCheck = Date.distantPast
    /// "Later" lasts only until One is opened again: it lives in memory, never in settings.
    private(set) var laterThisRun: String?
    private(set) var wait = Updater.every  // grows after errors and rate limits, back to 15 minutes after a good check
    /// Versions already announced (newest last); tests read this.
    var announced: [String] { Updater.store.stringArray(forKey: "updateAnnounced") ?? [] }

    /// The newest release above `current` that has One.zip attached.
    /// Defense in depth: only a `browser_download_url` on github.com (or its githubusercontent.com asset
    /// host) is ever downloaded, in case the releases JSON response is ever tampered with or spoofed.
    static func trustedDownloadHost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "github.com" || host.hasSuffix(".githubusercontent.com")
    }
    static func pick(_ list: [[String: Any]], current: String) -> (String, String, URL)? {
        var best: (String, String, URL)?
        for r in list where (r["draft"] as? Bool) != true {
            let tag = ((r["tag_name"] as? String) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            guard Updater.newer(tag, than: best?.0 ?? current),
                let zip = (r["assets"] as? [[String: Any]])?.first(where: { ($0["name"] as? String) == "One.zip" })?["browser_download_url"]
                    as? String,
                let zu = URL(string: zip)
            else { continue }
            guard Updater.trustedDownloadHost(zu) else {
                print(
                    "Update aborted: release \(tag) points at an unexpected download host (\(zu.host ?? "unknown")), not github.com/*.githubusercontent.com. Skipping it."
                )
                continue
            }
            best = (tag, (r["body"] as? String) ?? "", zu)
        }
        return best
    }
    /// Asks GitHub for the release list. Unchanged lists cost almost nothing (If-None-Match); errors and rate limits slow the next check down.
    func check(current cur: String? = nil) async {
        guard let u = Updater.releasesURL else { return }
        lastCheck = Date()
        var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let etag, lastList != nil { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        guard let (d, resp) = try? await URLSession(configuration: .ephemeral).data(for: req) else {
            wait = min(wait * 2, 4 * 3600)
            return
        }
        var data = d
        if let h = resp as? HTTPURLResponse {
            switch h.statusCode {
            case 200: etag = h.value(forHTTPHeaderField: "ETag")
            case 304:
                wait = Updater.every
                guard let old = lastList else { return }
                data = old
            default:  // 403/429 rate limit, 5xx: wait longer, at least until GitHub says the limit resets
                wait = min(wait * 2, 4 * 3600)
                if let reset = h.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(Double.init) {
                    wait = max(wait, reset - Date().timeIntervalSince1970 + 60)
                }
                return
            }
        }
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            wait = min(wait * 2, 4 * 3600)
            return
        }
        lastList = data
        wait = Updater.every
        guard let best = Updater.pick(list, current: cur ?? current) else { return }
        newest = best.0
        if laterThisRun != best.0 {
            available = (best.0, best.1, best.2)
        }
        announce(best.0, notes: best.1)
    }
    /// Tells the owner once per version, even with the window closed: a notification, an orb note and a spoken line.
    func announce(_ version: String, notes: String) {
        // Command-line runs (--check-update, renders, test copies) never announce or mark a version as told.
        if Env.commandLine && !Env.selfTest { return }
        guard !announced.contains(version) else { return }
        Updater.store.set(Array((announced + [version]).suffix(30)), forKey: "updateAnnounced")
        if Env.selfTest { return }
        let first =
            notes.components(separatedBy: "\n").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " -*#\t")) }
            .first { !$0.isEmpty } ?? "One \(version)"
        UpdateAlerts.post(title: "A new version of One is ready", body: first)
        Model.shared.updateReady()
    }
    /// The notification was clicked: undo this run's "Later" so the card comes back.
    func forgetLater() { laterThisRun = nil }
    func loop() {
        // Older versions kept "Later" for 6 hours across restarts; clear what they left behind.
        UserDefaults.standard.removeObject(forKey: "updateSkipped")
        UserDefaults.standard.removeObject(forKey: "updateSkippedAt")
        UpdateAlerts.setUp()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(20))  // let the network come back first
                if Date().timeIntervalSince(Updater.shared.lastCheck) > 120 { await Updater.shared.check() }
            }
        }
        Task {
            while true {
                await check()
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }
    /// Downloads, unpacks, then a tiny script waits for One to quit, swaps the app and reopens it.
    func install() async {
        guard let a = available else { return }
        let m = Model.shared
        // Only the reply in progress is waited for, and not for long. Working helpers never hold an update back:
        // they're paused just before the restart and pick back up by themselves after it.
        if m.thinking {
            state = "I'll update as soon as I finish this reply."
            let end = Date().addingTimeInterval(Updater.replyWait)
            while m.thinking && Date() < end { try? await Task.sleep(for: .milliseconds(500)) }
        }
        // A routine at work is never cut off: restarting kills its run midway (a post made but the rest not done, and
        // the routine shows as failed). Wait for it, up to `routineWait`, then go ahead.
        var busy = await Task.detached { Routines.inFlight() }.value
        let until = Date().addingTimeInterval(Updater.routineWait)
        while !busy.isEmpty && Date() < until {
            state = Updater.routineLine(busy)
            try? await Task.sleep(for: .seconds(15))
            busy = await Task.detached { Routines.inFlight() }.value
        }
        // Working helpers never hold an update back for long, except one mid a sensitive dev step (a build,
        // a test run, a git push, a release): pausing there could corrupt a build or leave a half-finished
        // push. Wait for that step to clear, up to `sensitiveWait`, then go ahead (paused like any other).
        var sensitive = m.helpersInSensitiveStep()
        let sensitiveUntil = Date().addingTimeInterval(Updater.sensitiveWait)
        while !sensitive.isEmpty && Date() < sensitiveUntil {
            state = Updater.sensitiveLine(sensitive)
            try? await Task.sleep(for: .seconds(10))
            sensitive = m.helpersInSensitiveStep()
        }
        state = "Downloading the new version…"
        // A test copy keeps its download in its own throwaway home, never in the person's update folder.
        let dir = (Env.selfTest ? Env.hermesHome : Env.support).appendingPathComponent("update", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let (tmp, resp) = try? await URLSession.shared.download(from: a.zip), (resp as? HTTPURLResponse)?.statusCode == 200 else {
            state = "The download didn't work. Check the internet and try again."
            return
        }
        let zip = dir.appendingPathComponent("One.zip")
        try? FileManager.default.moveItem(at: tmp, to: zip)
        state = "Getting it ready…"
        let ok: Bool = await withCheckedContinuation { c in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                p.arguments = ["-x", "-k", zip.path, dir.path]
                try? p.run()
                p.waitUntilExit()
                c.resume(returning: p.terminationStatus == 0)
            }
        }
        let newApp = dir.appendingPathComponent("One.app")
        guard ok, FileManager.default.fileExists(atPath: newApp.appendingPathComponent("Contents/MacOS/One").path) else {
            state = "The new version looked broken, so I kept this one. Try again later."
            return
        }
        let target = Bundle.main.bundlePath
        let script = Updater.swapScript(
            newApp: newApp.path, target: target, dir: dir.path, waitPID: ProcessInfo.processInfo.processIdentifier,
            enginePID: Engine.shared.enginePID, noReopen: ProcessInfo.processInfo.environment["ONE_UPDATE_NO_REOPEN"] == "1")
        let sh = dir.appendingPathComponent("swap.sh")
        try? script.write(to: sh, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [sh.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            state = "I couldn't start the update."
            return
        }
        state = "Restarting…"
        m.pauseHelpersForUpdate()  // after this, nothing they did is lost: each picks back up after the restart
        Engine.shared.stop()
        try? await Task.sleep(for: .milliseconds(400))
        QuitHold.bypass = true  // it already waited for routines at work
        NSApp.terminate(nil)
    }
    func later() {
        if let a = available { laterThisRun = a.version }
        available = nil
    }
}

struct UpdateCard: View {
    @ObservedObject var u = Updater.shared
    var body: some View {
        if let a = u.available {
            VStack(alignment: .leading, spacing: 10) {
                Label("A new version of One is ready (\(a.version))", systemImage: "arrow.down.circle.fill").font(.headline)
                let notes = a.notes.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(4)
                    .joined(separator: "\n")
                if !notes.isEmpty { MarkdownText(text: notes, size: 13).foregroundStyle(.secondary) }
                Text("It only takes a moment. Your memory, rooms and settings stay exactly as they are.").font(.caption).foregroundStyle(.secondary)
                if let st = u.state { Text(st).font(.callout) }
                HStack(spacing: 8) {
                    Button("Update now") { Task { await u.install() } }
                        .buttonStyle(.borderedProminent).tint(Color(hex: 0xF4EFE8)).foregroundStyle(Color(hex: 0x141416))
                        .disabled(
                            u.state != nil && !(u.state ?? "").contains("try again") && !(u.state ?? "").contains("Try again")
                                && !(u.state ?? "").contains("couldn't"))
                    Button("Later") { u.later() }.buttonStyle(.bordered)
                }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial))
        }
    }
}

/// macOS notifications for a new version. Asks permission once, the first time there's something to say.
@MainActor
final class UpdateAlerts: NSObject, UNUserNotificationCenterDelegate {
    static let shared = UpdateAlerts()
    static func setUp() { UNUserNotificationCenter.current().delegate = shared }
    static func post(title: String, body: String) {
        let c = UNUserNotificationCenter.current()
        c.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            guard ok else { return }
            let n = UNMutableNotificationContent()
            n.title = title
            n.body = body
            n.sound = .default
            c.add(UNNotificationRequest(identifier: "one-update", content: n, trigger: nil))
        }
    }
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) { completionHandler([.banner, .sound]) }
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in Model.shared.showUpdate() }
        completionHandler()
    }
}
