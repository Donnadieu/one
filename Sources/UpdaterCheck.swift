import Foundation

/// `One --test-updates`: proves a new version is announced exactly once, and that an equal, older or
/// zip-less release is never announced. Uses a fake release list (ONE_RELEASES_URL) in ONE_SUPPORT_DIR
/// and its own settings suite, so the person's real settings are never touched.
@MainActor
enum UpdaterCheck {
    static func release(_ tag: String, zip: Bool) -> [String: Any] {
        let assets: [[String: Any]] =
            zip
            ? [["name": "One.zip", "browser_download_url": "https://example.invalid/\(tag)/One.zip"]]
            : [["name": "One.dmg", "browser_download_url": "https://example.invalid/\(tag)/One.dmg"]]
        return ["tag_name": "v\(tag)", "draft": false, "body": "- Test release \(tag)\n- more", "assets": assets]
    }
    /// An update never cuts a routine off: it sees which routines are mid-run (a fake jobs.json in the test home)
    /// and says it waits for them; a run cut by a restart, and a partly done one, read as such on the card.
    static func routineChecks(_ check: (String, Bool) -> Void) {
        let now = Date()
        let iso = ISO8601DateFormatter()
        let cron = Routines.cron
        try? FileManager.default.createDirectory(at: cron, withIntermediateDirectories: true)
        let sched: [String: Any] = ["kind": "cron", "expr": "30 16 * * *"]
        func job(_ id: String, _ name: String, _ extra: [String: Any]) -> [String: Any] {
            var j: [String: Any] = ["id": id, "name": name, "enabled": true, "state": "scheduled", "schedule": sched]
            j.merge(extra) { $1 }
            return j
        }
        let jobs: [[String: Any]] = [
            job("a1", "Afternoon run", ["fire_claim": ["owner": "x"], "last_run_at": iso.string(from: now.addingTimeInterval(-86400))]),
            job(
                "b2", "Morning run",
                [
                    "last_run_at": iso.string(from: now.addingTimeInterval(-3600)), "last_status": "error",
                    "last_error": "Gateway shutdown (post-interrupt) killed the job's tool subprocess before the run finished.",
                ]),
            job(
                "c3", "Evening run",
                [
                    "last_run_at": iso.string(from: now.addingTimeInterval(-3600)), "last_status": "error",
                    "last_error": "Partly done: the X post worked; the Facebook post didn't (signed out).",
                ]),
            job(
                "d4", "Other run",
                ["last_run_at": iso.string(from: now.addingTimeInterval(-3600)), "last_status": "error", "last_error": "No credits left."]),
        ]
        try? JSONSerialization.data(withJSONObject: ["jobs": jobs]).write(to: cron.appendingPathComponent("jobs.json"))
        defer { try? FileManager.default.removeItem(at: cron.appendingPathComponent("jobs.json")) }
        check("an update sees the routine at work", Routines.inFlight(now: now) == ["Afternoon run"])
        let line = Updater.routineLine(Routines.inFlight(now: now))
        check("and says it waits for it", line.contains("Afternoon run") && line.contains("as soon as") && line.contains("finishes"))
        let rs = Dictionary(uniqueKeysWithValues: Routines.jobs(at: cron, now: now).map { ($0.id, $0) })
        check("a run cut by a restart reads as cut short, not failed", rs["b2"].map { Routines.missLine($0).hasPrefix("Cut short") } ?? false)
        check("its reason names the restart", rs["b2"]?.reason?.contains("One restarted") ?? false)
        check("a partly done run says so", rs["c3"].map { Routines.missLine($0) == "Partly done last time." } ?? false)
        check("its reason keeps which part failed", rs["c3"]?.reason?.contains("Facebook") ?? false)
        check("any other failure still reads as didn't finish", rs["d4"].map { Routines.missWord($0) == "didn't finish" } ?? false)
    }

    static func run() async -> Int32 {
        let store = Updater.store
        guard store != UserDefaults.standard else {
            print("refusing: test settings would be the real ones")
            return 2
        }
        store.removePersistentDomain(forName: "ai.forjado.one.updates-test")
        defer { store.removePersistentDomain(forName: "ai.forjado.one.updates-test") }
        let file = Env.support.appendingPathComponent("fake-releases.json")
        try? FileManager.default.createDirectory(at: Env.support, withIntermediateDirectories: true)
        setenv("ONE_RELEASES_URL", file.path, 1)
        let u = Updater.shared
        var fails = 0
        func check(_ name: String, _ ok: Bool) {
            print("  \(ok ? "✓" : "✗") \(name)")
            if !ok { fails += 1 }
        }
        func serve(_ list: [[String: Any]]) {
            try? JSONSerialization.data(withJSONObject: list).write(to: file)
        }
        let cur = "1.0.0"
        serve([release("1.0.0", zip: true), release("0.9.0", zip: true)])
        await u.check(current: cur)
        check("same and older versions are not announced", u.announced.isEmpty)
        serve([release("2.0.0", zip: false), release("1.0.0", zip: true)])
        await u.check(current: cur)
        check("a newer release without One.zip is not announced", u.announced.isEmpty)
        serve([release("1.1.0", zip: true), release("2.0.0", zip: false), release("1.0.0", zip: true)])
        await u.check(current: cur)
        check("a newer version is announced", u.announced == ["1.1.0"])
        check("and offered on the card", u.available?.version == "1.1.0")
        let vn = VersionNote.text(running: cur, newest: u.newest)
        check(
            "every prompt names the running version, the newer release and the tag to read",
            vn.contains("RUNS ONE 1.0.0") && vn.contains("One 1.1.0") && vn.contains("show v1.0.0:Sources/") && vn.contains("ref=v1.0.0"))
        check("no newer release: the note says nothing about one", !VersionNote.text(running: "1.1.0", newest: "1.1.0").contains("newer release"))
        await u.check(current: cur)
        await u.check(current: cur)
        check("only once, however often it checks", u.announced == ["1.1.0"])
        u.later()
        await u.check(current: cur)
        check("Later hides the card while One stays open", u.available == nil)
        check("after Later the assistant still knows a newer release exists", u.newest == "1.1.0")
        check(
            "Later is never saved, so reopening One shows the card again",
            UserDefaults.standard.object(forKey: "updateSkipped") == nil && UserDefaults.standard.object(forKey: "updateSkippedAt") == nil)
        u.forgetLater()
        await u.check(current: cur)
        check("after reopening (Later forgotten) the card is back", u.available?.version == "1.1.0")
        check("checks every 15 minutes after a good check", u.wait == 15 * 60)
        setenv("ONE_RELEASES_URL", Env.support.appendingPathComponent("missing.json").path, 1)
        await u.check(current: cur)
        check("backs off after an error", u.wait > 15 * 60)
        routineChecks(check)
        print(fails == 0 ? "updates ok" : "updates FAILED (\(fails))")
        return fails == 0 ? 0 : 1
    }
}
