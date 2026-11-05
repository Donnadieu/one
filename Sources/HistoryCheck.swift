import Darwin
import Foundation

/// `One --test-history` (CI only, from preflight with ONE_SUPPORT_DIR and ONE_CLOUD_DIR set to empty scratch
/// folders): instant copies, earlier versions, putting one back, pruning, and the locked copy, all on a scratch
/// brain, scratch shared room and scratch iCloud folder. The lock's key is a test key, never the Keychain.
enum HistoryCheck {
    static func cli(_ args: [String]) -> Int32? {
        guard args.contains("--test-history") else { return nil }
        TestWorld.enter()  // scratch One folder and brain; run with ONE_SUPPORT_DIR and ONE_CLOUD_DIR set to empty folders
        guard ProcessInfo.processInfo.environment["ONE_CLOUD_DIR"] != nil else {
            print("refusing: set ONE_CLOUD_DIR to an empty folder first")
            return 2
        }
        let d = UserDefaults.standard
        let saved = (d.object(forKey: "sharedRooms"), d.object(forKey: Offsite.defaultsKey))
        defer {
            for (k, v) in [("sharedRooms", saved.0), (Offsite.defaultsKey, saved.1)] {
                if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) }
            }
        }
        return run()
    }

    nonisolated(unsafe) static var fails = 0
    static func check(_ name: String, _ ok: Bool) {
        print("  \(ok ? "✓" : "✗") \(name)")
        if !ok { fails += 1 }
    }
    static func read(_ u: URL) -> String { (try? String(contentsOf: u, encoding: .utf8)) ?? "" }
    static func write(_ s: String, _ u: URL) {
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? s.write(to: u, atomically: true, encoding: .utf8)
    }

    static func run() -> Int32 {
        let fm = FileManager.default
        let brain = Brain.root
        let note = brain.appendingPathComponent("personal-room/brain/garden.md")
        write("# Garden\n\nTomatoes by the fence. PELICAN-73-MARKER\n", note)
        write("ref: refs/heads/main\n", brain.appendingPathComponent("personal-room/.git/HEAD"))
        let room = Shared.cloud.appendingPathComponent("One Rooms/Biz", isDirectory: true)
        write("# Plan\n\nBy Omar\n\nLaunch in May.\n", room.appendingPathComponent("entries/plan.md"))
        write("", room.appendingPathComponent("entries/.later.md.icloud"))
        Shared.paths = [room.path]
        let h = Env.hermesHome
        write("Omar likes short answers.\n", h.appendingPathComponent("memories/MEMORY.md"))
        write("soul\n", h.appendingPathComponent("SOUL.md"))
        write("model: x\n", h.appendingPathComponent("config.yaml"))
        write("{\"jobs\": []}\n", h.appendingPathComponent("cron/jobs.json"))
        write("not a copy\n", h.appendingPathComponent("state.db"))

        print("Instant copies")
        let t0 = Date().addingTimeInterval(-7200)
        guard case .success(let first) = History.take(force: false, now: t0) else {
            check("a copy is taken", false)
            return 1
        }
        let c = first.url
        check("a copy is taken", first.fresh && History.parse(c.lastPathComponent) != nil)
        check("the brain is in it as My Brain", read(c.appendingPathComponent("My Brain/personal-room/brain/garden.md")).contains("Tomatoes"))
        check("git's own folder is left out", !fm.fileExists(atPath: c.appendingPathComponent("My Brain/personal-room/.git").path))
        check("the shared room is in it", read(c.appendingPathComponent("shared/Biz/entries/plan.md")).contains("May"))
        check(
            "a file still only in iCloud is skipped and listed, never downloaded",
            !fm.fileExists(atPath: c.appendingPathComponent("shared/Biz/entries/.later.md.icloud").path)
                && read(c.appendingPathComponent("skipped.txt")).contains("shared/Biz/entries/.later.md.icloud"))
        check(
            "the assistant's own files are in it, the chat database isn't",
            fm.fileExists(atPath: c.appendingPathComponent("engine-files/memories/MEMORY.md").path)
                && fm.fileExists(atPath: c.appendingPathComponent("engine-files/cron/jobs.json").path)
                && !fm.fileExists(atPath: c.appendingPathComponent("engine-files/state.db").path))
        let meta = History.list().first.flatMap(History.info) ?? [:]
        check(
            "every file is an instant copy (clonefile), none copied in full",
            (meta["cloned"] as? Int ?? 0) >= 6 && (meta["copied"] as? Int) == 0 && (meta["parts"] as? [[String: Any]])?.count ?? 0 >= 6)
        if case .success(let again) = History.take(force: false, now: t0.addingTimeInterval(3600)) {
            check("nothing changed: no new copy", !again.fresh && again.url == c)
        } else {
            check("nothing changed: no new copy", false)
        }

        print("Earlier versions and putting one back")
        Thread.sleep(forTimeInterval: 1.1)
        write("# Garden\n\nEverything here was rewritten by mistake.\n\n- one\n- two\n", note)
        let vs = History.versions(of: note.path)
        check("the note has one earlier version", vs.count == 1 && read(vs.first?.url ?? note).contains("Tomatoes"))
        check("the command line lists it", History.cli(["One", "--restore", "--list", note.path]) == 0)
        if case .success(let r) = History.restore(note.path) {
            check("putting it back brings the old words back", read(note).contains("Tomatoes"))
            check(
                "what was there is kept in a copy labeled before restore",
                r.before.lastPathComponent.hasSuffix("before restore")
                    && read(r.before.appendingPathComponent("My Brain/personal-room/brain/garden.md")).contains("rewritten by mistake"))
        } else {
            check("putting it back works", false)
        }
        check(
            "the undo can be undone: the rewritten version is listed now",
            History.versions(of: note.path).contains { read($0.url).contains("rewritten") })
        check("a path outside the brain is refused", History.cli(["One", "--restore", "/etc/hosts"]) == 1)

        print("Undo everything from one copy")
        let extra = brain.appendingPathComponent("personal-room/brain/new idea.md")
        write("# New idea\n", extra)
        write("# Plan\n\nBy Omar\n\nLaunch in June.\n", room.appendingPathComponent("entries/plan.md"))
        let theirs = room.appendingPathComponent("entries/2026-11-05 0900 Sam - hello.md")
        write("# Hello\n\nBy Sam\n", theirs)
        write("Someone else wrote this.\n", h.appendingPathComponent("memories/MEMORY.md"))
        if case .success(let r) = History.restoreAll(c.lastPathComponent) {
            let moved = History.list().first { $0.label == "removed-by-restore" }
            check(
                "the brain's newer file moved aside, not deleted",
                !fm.fileExists(atPath: extra.path)
                    && moved.map { fm.fileExists(atPath: $0.url.appendingPathComponent("My Brain/personal-room/brain/new idea.md").path) } == true)
            check("the shared room's changed file came back", read(room.appendingPathComponent("entries/plan.md")).contains("May"))
            check("a new file in the shared room (maybe someone else's) stays", fm.fileExists(atPath: theirs.path))
            check("the assistant's memory came back", read(h.appendingPathComponent("memories/MEMORY.md")).contains("short answers"))
            check("git's own folder was never touched", fm.fileExists(atPath: brain.appendingPathComponent("personal-room/.git/HEAD").path))
            check("it says what it did in plain words", r.text.hasPrefix("Put your brain back"))
        } else {
            check("undo everything works", false)
        }
        check(
            "One --snapshot <label> takes one now",
            History.cli(["One", "--snapshot", "before nightly review"]) == 0 && History.list().contains { $0.label == "before nightly review" })

        prune()
        offsite()
        print(fails == 0 ? "history ok" : "history: \(fails) failed")
        return fails == 0 ? 0 : 1
    }

    /// Made-up copies over 7 months (every hour for 3 days, then every 6 hours), labeled ones, and folders that
    /// aren't copies at all (like Omar's before-move).
    static func prune() {
        print("Pruning")
        let fm = FileManager.default
        let now = Date()
        var fakes: [String: Date] = [:]
        func make(_ d: Date, _ label: String? = nil) {
            let n = History.name(d, label: label)
            try? fm.createDirectory(at: History.folder.appendingPathComponent(n), withIntermediateDirectories: true)
            fakes[n] = d
        }
        for i in 0..<72 { make(now.addingTimeInterval(-Double(i) * 3600 - 1800)) }
        for i in 0..<(210 * 4) where i >= 12 { make(now.addingTimeInterval(-Double(i) * 6 * 3600 - 1800)) }
        make(now.addingTimeInterval(-10 * 86_400 - 1200), "before nightly review")
        make(now.addingTimeInterval(-40 * 86_400 - 1200), "before restore")
        let mine = ["before-move", "before-rooms-step5 2026-11-04 2300", "notes"]
        for n in mine { try? fm.createDirectory(at: History.folder.appendingPathComponent(n), withIntermediateDirectories: true) }
        check("Omar's own folders aren't named like copies", mine.allSatisfy { History.parse($0) == nil })
        History.prune(now: now)
        let left = Set((try? fm.contentsOfDirectory(atPath: History.folder.path)) ?? [])
        let kept = fakes.filter { left.contains($0.key) && History.parse($0.key)?.label == nil }
        let day = 86_400.0
        let recent = fakes.filter { now.timeIntervalSince($0.value) <= 2 * day && History.parse($0.key)?.label == nil }
        check("every copy from the last 2 days stays (\(recent.count))", recent.keys.allSatisfy { left.contains($0) })
        let cal = Calendar(identifier: .gregorian)
        let daily = kept.filter { (2 * day...30 * day).contains(now.timeIntervalSince($0.value)) }
        let perDay = Dictionary(grouping: daily.values) { cal.dateComponents([.year, .month, .day], from: $0) }
        check("one a day for 30 days (\(perDay.count) days)", perDay.values.allSatisfy { $0.count == 1 } && (27...29).contains(perDay.count))
        let weekly = kept.filter { (30 * day...183 * day).contains(now.timeIntervalSince($0.value)) }
        let perWeek = Dictionary(grouping: weekly.values) { cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: $0) }
        check("one a week for 6 months (\(perWeek.count) weeks)", perWeek.values.allSatisfy { $0.count == 1 } && (21...23).contains(perWeek.count))
        check("nothing older than 6 months", !kept.contains { now.timeIntervalSince($0.value) > 183 * day })
        check(
            "a labeled copy stays 30 days, then goes",
            left.contains(History.name(now.addingTimeInterval(-10 * 86_400 - 1200), label: "before nightly review"))
                && !left.contains(History.name(now.addingTimeInterval(-40 * 86_400 - 1200), label: "before restore")))
        check("before-move and every other folder are never touched", mine.allSatisfy { left.contains($0) })
    }

    /// The locked copy: a scratch iCloud folder (ONE_CLOUD_DIR) and a test key, never the Keychain.
    static func offsite() {
        print("Locked copy in iCloud")
        let fm = FileManager.default
        Offsite.on = false
        // Asked from a chat (inside the folder lock, no Keychain): One's own loop finishes turning it on.
        fm.createFile(atPath: Offsite.requestFile.path, contents: Data())
        Offsite.tend()
        check("a turn-on asked from a chat is finished by One itself", Offsite.on && !fm.fileExists(atPath: Offsite.requestFile.path))
        Offsite.on = false
        Offsite.testKey = nil
        try? fm.removeItem(at: Offsite.codeFile)
        guard case .success(let f) = Offsite.turnOn(), let codeFile = f, let key = Offsite.storedKey() else {
            check("turning it on makes a key and a recovery code", false)
            return
        }
        let perms = (try? fm.attributesOfItem(atPath: codeFile.path)[.posixPermissions] as? Int) ?? 0
        check("turning it on makes a key and a recovery code only you can read", Offsite.on && perms == 0o600)
        check("the recovery code gives back the key", Offsite.pendingCode.flatMap(Offsite.key(fromCode:)) == key)
        check("a second turn-on makes no new code", (try? Offsite.turnOn().get()) == .some(nil) && Offsite.storedKey() == key)
        guard case .success(let a) = Offsite.runNow() else {
            check("tonight's locked copy is made", false)
            return
        }
        let bytes = (try? Data(contentsOf: a)) ?? Data()
        check(
            "tonight's locked copy is in iCloud Drive › One Backups",
            a.deletingLastPathComponent() == Offsite.folder && Offsite.dateOf(a.lastPathComponent) != nil)
        check(
            "it's locked: nothing readable inside",
            bytes.prefix(4) == Data("AEA1".utf8) && bytes.range(of: Data("PELICAN-73".utf8)) == nil && bytes.range(of: Data("garden.md".utf8)) == nil)
        check("nothing else was left in iCloud", ((try? fm.contentsOfDirectory(atPath: Offsite.folder.path)) ?? []).count == 1)
        let out = Env.support.appendingPathComponent("verify", isDirectory: true)
        let v = Offsite.verify(a, into: out, key: key)
        v.lines.forEach { print("      \($0)") }
        check(
            "it opens with the key and every file is there",
            v.ok && read(out.appendingPathComponent("My Brain/personal-room/brain/garden.md")).contains("PELICAN"))
        let wrong = Offsite.verify(a, into: Env.support.appendingPathComponent("verify-wrong"), key: Offsite.newKey() ?? Data())
        check("a wrong key opens nothing", !wrong.ok)
        Offsite.codeSaved()
        check("I saved it: the code file is gone", !fm.fileExists(atPath: codeFile.path) && Offsite.pendingCode == nil)

        let now = Date()
        var names: [String] = []
        for i in 0..<400 {
            let n = "One brain \(Offsite.day(now.addingTimeInterval(-Double(i) * 86_400))).aea"
            names.append(n)
            fm.createFile(atPath: Offsite.folder.appendingPathComponent(n).path, contents: Data())
        }
        for n in ["One brain notes.aea", "Other.aea"] { fm.createFile(atPath: Offsite.folder.appendingPathComponent(n).path, contents: Data()) }
        Offsite.prune(now: now)
        let left = Set((try? fm.contentsOfDirectory(atPath: Offsite.folder.path)) ?? [])
        let dated = left.compactMap { n in Offsite.dateOf(n).map { (n, $0) } }.sorted { $0.1 > $1.1 }
        check("the 14 newest stay", names.prefix(14).allSatisfy { left.contains($0) })
        let cal = Calendar(identifier: .gregorian)
        let older = dated.dropFirst(14)
        let months = Dictionary(grouping: older) { cal.dateComponents([.year, .month], from: $0.1) }
        check(
            "then one a month for a year (\(older.count))",
            months.values.allSatisfy { $0.count == 1 } && (11...13).contains(older.count)
                && !older.contains { now.timeIntervalSince($0.1) > 366 * 86_400 })
        check("files not named like a locked copy are never touched", left.contains("One brain notes.aea") && left.contains("Other.aea"))
    }
}
