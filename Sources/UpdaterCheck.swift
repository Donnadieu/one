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
            job(
                "a1", "Afternoon run",
                [
                    "fire_claim": ["owner": "x", "at": iso.string(from: now.addingTimeInterval(-10))],
                    "last_run_at": iso.string(from: now.addingTimeInterval(-86400)),
                ]),
            // A claim with no `at` at all is left by an engine that died mid-fire (crash, force quit, the
            // update-swap script's kill): it must read as stale, not running, even though it's still in jobs.json.
            job(
                "a0", "Stale-claim run",
                ["fire_claim": ["owner": "x"], "last_run_at": iso.string(from: now.addingTimeInterval(-86400))]),
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
        check("a claim with no `at` at all reads as stale, not running", !Routines.inFlight(now: now).contains("Stale-claim run"))
        let line = Updater.routineLine(Routines.inFlight(now: now))
        check("and says it waits for it", line.contains("Afternoon run") && line.contains("as soon as") && line.contains("finishes"))
        let rs = Dictionary(uniqueKeysWithValues: Routines.jobs(at: cron, now: now).map { ($0.id, $0) })
        check("a run cut by a restart reads as cut short, not failed", rs["b2"].map { Routines.missLine($0).hasPrefix("Cut short") } ?? false)
        check("its reason names the restart", rs["b2"]?.reason?.contains("One restarted") ?? false)
        check(
            "a partly done run says so in its own words", rs["c3"].map { Routines.missLine($0).hasPrefix("Partly done: the X post worked") } ?? false)
        check("and isn't orange", rs["c3"].map { $0.miss == .partly && !$0.needsLook } ?? false)
        check("its reason keeps which part failed", rs["c3"]?.reason?.contains("Facebook") ?? false)
        check("any other failure reads as didn't run", rs["d4"].map { Routines.missWord($0) == "didn't run" } ?? false)
        check("and is orange", rs["d4"]?.needsLook ?? false)
        runChecks(check, now: now)
        quitChecks(check)
    }

    /// A run's real outcome from its report and step log (RoutineRuns.swift): caught up later shows as done, a run that
    /// did some of its work shows as partly done (not orange), one that did nothing stays orange.
    static func runChecks(_ check: (String, Bool) -> Void, now _: Date) {
        // A fixed clock (6 PM today, runs at 1 PM) so the dial's marks don't depend on when the check runs.
        let now = Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: Date()) ?? Date()
        let iso = ISO8601DateFormatter()
        let cron = Routines.cron
        let fm = FileManager.default
        try? fm.createDirectory(at: cron.appendingPathComponent("steps"), withIntermediateDirectories: true)
        let start = now.addingTimeInterval(-5 * 3600)
        func at(_ m: Double) -> String { iso.string(from: start.addingTimeInterval(m * 60)) }
        let ran = iso.string(from: start.addingTimeInterval(60 * 60))
        let disp: [String: Any] = ["scheduled_at": iso.string(from: start), "dispatched_at": iso.string(from: start)]
        func job(_ id: String, _ err: String) -> [String: Any] {
            [
                "id": id, "name": id, "enabled": true, "state": "scheduled", "schedule": ["kind": "cron", "expr": "0 13 * * *"],
                "last_run_at": ran, "last_status": "error", "last_error": err, "last_dispatch": disp,
                "next_run_at": iso.string(from: now.addingTimeInterval(3600)),
            ]
        }
        func steps(_ id: String, _ rows: [[String: Any]]) {
            let text = rows.compactMap { try? JSONSerialization.data(withJSONObject: $0) }.compactMap { String(data: $0, encoding: .utf8) }
            try? (text.joined(separator: "\n") + "\n").write(to: Routines.stepsFile(cron, id), atomically: true, encoding: .utf8)
        }
        let cut = "Gateway shutdown (post-interrupt) killed the job's tool subprocess before the run finished."
        let jobs: [[String: Any]] = [
            job("caught", "The evening post didn't go out: signed out."), job("cut", cut), job("bare", cut), job("half", "Signed out."),
            job("stale", "Signed out."),
        ]
        // caught: two parts failed, both made up later by catch-ups.
        steps(
            "caught",
            [
                ["at": at(5), "step": "Morning post", "ok": false], ["at": at(5), "step": "Replies", "ok": true],
                ["at": at(6), "step": "Evening post", "ok": false, "why": "signed out"],
                ["at": at(20), "step": "Morning post", "ok": true, "catch_up": true],
                ["at": at(180), "step": "Evening post", "ok": true, "catch_up": true],
            ])
        // cut: a post went out, then One restarted.
        steps("cut", [["at": at(3), "step": "Morning post", "ok": true], ["at": at(30), "step": "4 of 12 rounds", "ok": true]])
        // half: one part worked, one didn't and was never made up.
        steps("half", [["at": at(3), "step": "Morning post", "ok": true], ["at": at(4), "step": "Evening post", "ok": false]])
        // stale: only lines from the day before, which belong to an earlier run.
        steps("stale", [["at": iso.string(from: start.addingTimeInterval(-20 * 3600)), "step": "Morning post", "ok": true]])
        try? JSONSerialization.data(withJSONObject: ["jobs": jobs]).write(to: cron.appendingPathComponent("jobs.json"))
        defer {
            try? fm.removeItem(at: cron.appendingPathComponent("jobs.json"))
            try? fm.removeItem(at: cron.appendingPathComponent("steps"))
        }
        let rs = Dictionary(uniqueKeysWithValues: Routines.jobs(at: cron, now: now).map { ($0.id, $0) })
        let c = rs["caught"]
        check("a run whose missed parts were made up later shows as done", c?.state == .worked && c?.caughtUpAt != nil)
        check("the dial just says done (its card says when)", c.map { Dial.word($0) == "done" } ?? false)
        check("and which parts were made up", c?.notes.caughtUp == ["Morning post", "Evening post"])
        let k = rs["cut"]
        check("a run cut by a restart after its post shows as partly done", k?.state == .failed && k?.miss == .partly && k?.needsLook == false)
        check(
            "its line says what worked and that the rest was cut",
            k.map {
                Routines.partlyLine($0.notes) == "Partly done: Morning post and 4 of 12 rounds worked. The rest was cut short when One restarted."
            }
                ?? false)
        check("and the card says partly done, then lists what worked", k.map { Routines.missLine($0) == "Partly done last time." } ?? false)
        check("a run cut with nothing recorded stays orange", rs["bare"].map { $0.needsLook && $0.miss == .cut } ?? false)
        let h = rs["half"]
        check("a part that never worked is named", h?.notes.didnt == ["Evening post"] && h?.notes.did == ["Morning post"])
        check("and that run is partly done, not orange", h?.miss == .partly && h?.needsLook == false)
        check("steps from an earlier run don't count", rs["stale"].map { $0.needsLook && $0.notes.did.isEmpty } ?? false)
        let snap = RoutinesSnapshot(routines: Array(rs.values), skills: [], now: now)
        check("the header counts need a look and partly done apart", snap.needLook == 2 && snap.partly == 2)
        let L = Dial.layout(snap)
        let kinds = Dictionary(L.marks.map { ($0.rid, $0.kind) }) { a, _ in a }
        check("the dial draws a partly done run half filled", kinds["cut"] == .partly && kinds["half"] == .partly)
        check("a caught up run with a check, a bare one orange", kinds["caught"] == .done && kinds["bare"] == .failed)
        check(
            "one short legend", Dial.legend == "Done · Partly · Didn't run"
        )
    }

    /// Quitting while a routine is at work waits for it; logout, a second quit, an update's own quit and test copies don't.
    static func quitChecks(_ check: (String, Bool) -> Void) {
        let busy = ["Morning run"]
        check(
            "a quit with a routine at work waits for it",
            QuitHold.shouldHold(busy: busy, waiting: false, bypass: false, system: false, testCopy: false))
        check("nothing at work: quits right away", !QuitHold.shouldHold(busy: [], waiting: false, bypass: false, system: false, testCopy: false))
        check(
            "quitting again while it waits quits now", !QuitHold.shouldHold(busy: busy, waiting: true, bypass: false, system: false, testCopy: false))
        check(
            "logging out or shutting down never waits", !QuitHold.shouldHold(busy: busy, waiting: false, bypass: false, system: true, testCopy: false)
        )
        check(
            "an update's own quit (it already waited) goes through",
            !QuitHold.shouldHold(busy: busy, waiting: false, bypass: true, system: false, testCopy: false))
        check("a test copy never waits", !QuitHold.shouldHold(busy: busy, waiting: false, bypass: false, system: false, testCopy: true))
        check("it says so plainly", QuitHold.line(busy) == "Morning run is still working. I'll quit as soon as it's done. Quit again to stop it now.")
        check("the shutdown reasons are the real codes", QuitHold.systemReasons.contains(0x7368_7574) && QuitHold.fourCC("why?") == 0x7768_793F)
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
        signingChecks(check)
        print(fails == 0 ? "updates ok" : "updates FAILED (\(fails))")
        return fails == 0 ? 0 : 1
    }

    /// Proves the swap script really refuses a bundle whose signature doesn't verify, with fixture app
    /// bundles (never the real /Applications/One.app): a corrupted/unsigned "update" is rejected before
    /// anything is touched (the old app stays exactly as it was), while a properly verified bundle swaps in.
    static func signingChecks(_ check: (String, Bool) -> Void) {
        let fm = FileManager.default
        let base = Env.support.appendingPathComponent("signing-check", isDirectory: true)
        try? fm.removeItem(at: base)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        func makeApp(_ name: String, sign: Bool, corruptAfterSigning: Bool = false) -> URL {
            let app = base.appendingPathComponent(name)
            let mac = app.appendingPathComponent("Contents/MacOS")
            try? fm.createDirectory(at: mac, withIntermediateDirectories: true)
            try? fm.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: mac.appendingPathComponent(name))
            if sign {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
                p.arguments = ["-fs", "-", app.path]  // ad-hoc: the running test binary is ad-hoc too in dev/CI
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                try? p.run()
                p.waitUntilExit()
            }
            // Models a tampered zip: looks signed, but the signature no longer matches the bundle's contents.
            if corruptAfterSigning { try? "tampered".write(to: mac.appendingPathComponent(name), atomically: true, encoding: .utf8) }
            return app
        }
        func runSwap(newApp: URL, target: URL) -> Bool {
            let dir = base.appendingPathComponent("dir-\(UUID().uuidString)")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let script = Updater.swapScript(
                newApp: newApp.path, target: target.path, dir: dir.path, waitPID: ProcessInfo.processInfo.processIdentifier,
                enginePID: nil, noReopen: true)
            let sh = dir.appendingPathComponent("swap.sh")
            try? script.write(to: sh, atomically: true, encoding: .utf8)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [sh.path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        }
        // Rejected case: unsigned update.
        do {
            let running = makeApp("running1", sign: true)
            let unsigned = makeApp("unsigned-update", sign: false)
            let ok = runSwap(newApp: unsigned, target: running)
            check(
                "an unsigned update is rejected and the old app is left exactly in place",
                !ok && fm.fileExists(atPath: running.appendingPathComponent("Contents/MacOS/running1").path))
        }
        // Rejected case: signed, but tampered after signing (signature no longer verifies).
        do {
            let running = makeApp("running2", sign: true)
            let tampered = makeApp("tampered-update", sign: true, corruptAfterSigning: true)
            let ok = runSwap(newApp: tampered, target: running)
            check(
                "a tampered (signed-then-modified) update fails verification and is rejected",
                !ok && fm.fileExists(atPath: running.appendingPathComponent("Contents/MacOS/running2").path))
        }
        // Accepted case: a properly signed, unmodified update with a verifying signature swaps in.
        do {
            let running = makeApp("running3", sign: true)
            let good = makeApp("good-update", sign: true)
            let ok = runSwap(newApp: good, target: running)
            check(
                "a verified update with a matching signing team swaps in",
                ok && fm.fileExists(atPath: running.appendingPathComponent("Contents/MacOS/good-update").path)
                    && !fm.fileExists(atPath: running.appendingPathComponent("Contents/MacOS/running3").path))
        }
    }
}
