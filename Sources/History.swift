import Darwin
import Foundation

// MARK: - Instant copies of the brain (storage plan 3g)

/// Hourly instant copies into `<support>/history/<YYYY-MM-DD HHMM>[ label]/`. Every file is an APFS clone
/// (clonefile), so a copy costs almost no space until a file changes. What goes in:
/// - the brain, as `My Brain`
/// - each shared room, as `shared/<folder>`: only files on this Mac; a file still only in iCloud is skipped,
///   never downloaded (listed in `skipped.txt` so a restore leaves it alone)
/// - the files One rebuilds the front page from, as `engine-files/…` (memories, owner-notes.md,
///   cron/jobs.json, SOUL.md, config.yaml)
/// Never: sockets, state.db, logs, the engine, Python folders, `.git` folders (git keeps its own history).
/// Pruning only ever touches folders named exactly like a copy (`YYYY-MM-DD HHMM`, optionally ` <label>`);
/// anything else in history/ (Omar's `before-move`, `before-rooms-step5 …`) is never touched.
enum History {
    struct Snapshot: Equatable {
        let name: String
        let url: URL
        let date: Date
        let label: String?
    }
    /// One source and where it goes inside a copy.
    struct Part {
        let name: String
        let src: URL
    }
    struct Taken {
        let url: URL
        let fresh: Bool  // false: nothing had changed, this is the newest copy already there
    }

    static var folder: URL { Env.support.appendingPathComponent("history", isDirectory: true) }
    static let engineFiles = ["memories", "owner-notes.md", "cron/jobs.json", "SOUL.md", "config.yaml"]
    static let skipDirs: Set<String> = [".git", "node_modules", ".venv", "__pycache__"]
    static let skipFiles: Set<String> = [".DS_Store", "state.db", "state.db-wal", "state.db-shm"]
    static let dataless: UInt32 = 0x4000_0000  // SF_DATALESS: the file's contents are still only in iCloud

    // MARK: names

    static let pattern = try! NSRegularExpression(pattern: #"^(\d{4})-(\d{2})-(\d{2}) (\d{2})(\d{2})(?: (.+))?$"#)
    static func parse(_ name: String) -> (date: Date, label: String?)? {
        let r = NSRange(name.startIndex..., in: name)
        guard let m = pattern.firstMatch(in: name, range: r) else { return nil }
        func g(_ i: Int) -> String? { Range(m.range(at: i), in: name).map { String(name[$0]) } }
        var c = DateComponents()
        c.year = Int(g(1) ?? "")
        c.month = Int(g(2) ?? "")
        c.day = Int(g(3) ?? "")
        c.hour = Int(g(4) ?? "")
        c.minute = Int(g(5) ?? "")
        guard let d = Calendar.current.date(from: c), (c.hour ?? 99) < 24, (c.minute ?? 99) < 60 else { return nil }
        return (d, g(6))
    }
    static func name(_ d: Date, label: String? = nil) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmm"
        let l = label?.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-") ?? ""
        return f.string(from: d) + (l.isEmpty ? "" : " " + l)
    }
    /// Every copy in history/, newest first. Folders not named like a copy are not copies.
    static func list() -> [Snapshot] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.compactMap { n in
            parse(n).map { Snapshot(name: n, url: folder.appendingPathComponent(n, isDirectory: true), date: $0.date, label: $0.label) }
        }
        .sorted { $0.date == $1.date ? $0.name > $1.name : $0.date > $1.date }
    }

    // MARK: what goes in

    static func parts() -> [Part] {
        let fm = FileManager.default
        var out = [Part(name: "My Brain", src: Brain.root)]
        for s in Shared.paths {
            let u = URL(fileURLWithPath: s, isDirectory: true)
            out.append(Part(name: "shared/" + u.lastPathComponent, src: u))
        }
        for e in engineFiles { out.append(Part(name: "engine-files/" + e, src: Env.hermesHome.appendingPathComponent(e))) }
        return out.filter { fm.fileExists(atPath: $0.src.path) }
    }

    /// Calls `visit` for every file a copy keeps under `root` (relative path, lstat), and `dir` for each folder.
    /// Files still only in iCloud are reported to `skipped`, never opened.
    static func walk(
        _ root: URL, dir: (String, stat) -> Void = { _, _ in }, skipped: (String) -> Void = { _ in }, visit: (String, stat) -> Void
    ) {
        var st = stat()
        guard lstat(root.path, &st) == 0 else { return }
        if st.st_mode & S_IFMT != S_IFDIR {
            if keeps(root.lastPathComponent, st) { visit("", st) } else if isCloudOnly(root.lastPathComponent, st) { skipped("") }
            return
        }
        dir("", st)
        func go(_ rel: String) {
            let here = rel.isEmpty ? root.path : root.path + "/" + rel
            for n in ((try? FileManager.default.contentsOfDirectory(atPath: here)) ?? []).sorted() {
                let r = rel.isEmpty ? n : rel + "/" + n
                var s = stat()
                guard lstat(here + "/" + n, &s) == 0 else { continue }
                if s.st_mode & S_IFMT == S_IFDIR {
                    if skipDirs.contains(n) { continue }
                    dir(r, s)
                    go(r)
                } else if keeps(n, s) {
                    visit(r, s)
                } else if isCloudOnly(n, s) {
                    skipped(r)
                }
            }
        }
        go("")
    }
    static func isCloudOnly(_ name: String, _ s: stat) -> Bool {
        (name.hasPrefix(".") && name.hasSuffix(".icloud")) || s.st_flags & dataless != 0
    }
    /// Regular files and links only (never sockets, pipes or devices), never a file still only in iCloud.
    static func keeps(_ name: String, _ s: stat) -> Bool {
        let t = s.st_mode & S_IFMT
        return (t == S_IFREG || t == S_IFLNK) && !skipFiles.contains(name) && !isCloudOnly(name, s)
    }

    /// Cheap "did anything change?": how many files and folders, their bytes, the newest change.
    static func fingerprint(_ ps: [Part]) -> String {
        var n = 0
        var bytes: Int64 = 0
        var newest = 0
        for p in ps {
            walk(
                p.src, dir: { _, s in newest = max(newest, s.st_mtimespec.tv_sec) },
                visit: { _, s in
                    n += 1
                    bytes += s.st_size
                    newest = max(newest, s.st_mtimespec.tv_sec)
                })
        }
        return "\(n)-\(bytes)-\(newest)"
    }

    // MARK: taking a copy

    /// Takes a copy now. `force: false` (the hourly one) skips when nothing changed since the newest copy.
    static func take(label: String? = nil, force: Bool = true, now: Date = Date()) -> Result<Taken, CopyError> {
        locked { takeLocked(label: label, force: force, now: now) }
    }
    struct CopyError: Error { let text: String }

    static func takeLocked(label: String?, force: Bool, now: Date) -> Result<Taken, CopyError> {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        cleanPartials()
        let ps = parts()
        let fp = fingerprint(ps)
        let newest = list().first
        if !force, let n = newest, info(n)?["fingerprint"] as? String == fp { return .success(Taken(url: n.url, fresh: false)) }
        var final = name(now, label: label)
        if fm.fileExists(atPath: folder.appendingPathComponent(final).path) {
            var i = 2
            while fm.fileExists(atPath: folder.appendingPathComponent(name(now, label: (label ?? "copy") + " \(i)")).path) { i += 1 }
            final = name(now, label: (label ?? "copy") + " \(i)")
        }
        let tmp = folder.appendingPathComponent(".partial-\(UUID().uuidString)", isDirectory: true)
        guard (try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)) != nil else {
            return .failure(CopyError(text: "I couldn't make a folder in \(folder.path)."))
        }
        var summary: [[String: Any]] = []
        var cloned = 0
        var copied = 0
        var skipped: [String] = []
        for p in ps {
            let dst = tmp.appendingPathComponent(p.name)
            try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            var files = 0
            var bytes: Int64 = 0
            walk(
                p.src, dir: { r, _ in try? fm.createDirectory(atPath: r.isEmpty ? dst.path : dst.path + "/" + r, withIntermediateDirectories: true) },
                skipped: { r in skipped.append(r.isEmpty ? p.name : p.name + "/" + r) },
                visit: { r, s in
                    let from = r.isEmpty ? p.src.path : p.src.path + "/" + r
                    let to = r.isEmpty ? dst.path : dst.path + "/" + r
                    switch clone(from, to) {
                    case .cloned: cloned += 1
                    case .copied: copied += 1
                    case .failed: return
                    }
                    files += 1
                    bytes += s.st_size
                })
            summary.append(["name": p.name, "files": files, "bytes": bytes])
        }
        let meta: [String: Any] = [
            "time": ISO8601DateFormatter().string(from: now), "label": label ?? "", "fingerprint": fp, "parts": summary, "cloned": cloned,
            "copied": copied, "notOnThisMac": skipped.count,
        ]
        if let d = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: tmp.appendingPathComponent("snapshot.json"))
        }
        if !skipped.isEmpty {
            try? skipped.joined(separator: "\n").write(to: tmp.appendingPathComponent("skipped.txt"), atomically: true, encoding: .utf8)
        }
        let out = folder.appendingPathComponent(final, isDirectory: true)
        guard rename(tmp.path, out.path) == 0 else {
            try? fm.removeItem(at: tmp)
            return .failure(CopyError(text: "I couldn't finish the copy in \(folder.path)."))
        }
        log("copy \(final): \(cloned) cloned, \(copied) copied, \(skipped.count) not on this Mac")
        return .success(Taken(url: out, fresh: true))
    }

    enum Cloned { case cloned, copied, failed }
    /// An instant copy (APFS clone) of one file or link; a plain copy only where clones aren't possible.
    static func clone(_ from: String, _ to: String) -> Cloned {
        if clonefile(from, to, UInt32(CLONE_NOFOLLOW)) == 0 { return .cloned }
        return (try? FileManager.default.copyItem(atPath: from, toPath: to)) != nil ? .copied : .failed
    }

    static func info(_ s: Snapshot) -> [String: Any]? {
        guard let d = try? Data(contentsOf: s.url.appendingPathComponent("snapshot.json")) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }
    /// Files a copy left alone because they were still only in iCloud (paths inside the copy).
    static func skippedPaths(_ s: Snapshot) -> Set<String> {
        let t = (try? String(contentsOf: s.url.appendingPathComponent("skipped.txt"), encoding: .utf8)) ?? ""
        return Set(t.split(separator: "\n").map(String.init))
    }
    /// A copy cut off half way (One quit, the Mac slept) is never left lying around.
    static func cleanPartials() {
        let fm = FileManager.default
        for n in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where n.hasPrefix(".partial-") {
            let u = folder.appendingPathComponent(n)
            let d = (try? fm.attributesOfItem(atPath: u.path)[.modificationDate] as? Date) ?? .distantPast
            if Date().timeIntervalSince(d) > 6 * 3600 { try? fm.removeItem(at: u) }
        }
    }

    // MARK: pruning

    /// Which copies stay: every one from the last 2 days, then the newest of each day for 30 days, then the newest
    /// of each week for 6 months. Copies with a label (`before restore`, `before nightly review`) stay 30 days.
    /// The newest copy always stays.
    static func keep(_ snaps: [Snapshot], now: Date) -> Set<String> {
        let cal = Calendar(identifier: .gregorian)
        let day = 86_400.0
        var keep = Set<String>()
        var days = Set<DateComponents>()
        var weeks = Set<DateComponents>()
        if let newest = snaps.max(by: { $0.date < $1.date }) { keep.insert(newest.name) }
        for s in snaps.sorted(by: { $0.date > $1.date }) {
            let age = now.timeIntervalSince(s.date)
            if s.label != nil {
                if age <= 30 * day { keep.insert(s.name) }
                continue
            }
            if age <= 2 * day {
                keep.insert(s.name)
            } else if age <= 30 * day {
                if days.insert(cal.dateComponents([.year, .month, .day], from: s.date)).inserted { keep.insert(s.name) }
            } else if age <= 183 * day {
                if weeks.insert(cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: s.date)).inserted { keep.insert(s.name) }
            }
        }
        return keep
    }
    /// Deletes the copies `keep` lets go. Returns their names.
    @discardableResult
    static func prune(now: Date = Date()) -> [String] {
        locked {
            let snaps = list()
            let keep = keep(snaps, now: now)
            var gone: [String] = []
            for s in snaps where !keep.contains(s.name) && parse(s.url.lastPathComponent) != nil {
                if (try? FileManager.default.removeItem(at: s.url)) != nil { gone.append(s.name) }
            }
            if !gone.isEmpty { log("pruned \(gone.count): \(gone.joined(separator: ", "))") }
            return gone
        }
    }

    // MARK: the hourly loop

    /// Hourly copies for the person's own One: one at launch when the newest is over an hour old, then every hour
    /// (skipped when nothing changed), pruning after each, and the nightly locked copy when it's on. Never on the
    /// main thread.
    static func loop() {
        guard Env.production else { return }
        Task.detached(priority: .utility) {
            var last = list().first?.date ?? .distantPast
            while true {
                if Date().timeIntervalSince(last) >= 3600 {
                    last = Date()
                    if case .failure(let e) = take(force: false) { log("copy failed: \(e.text)") }
                    prune()
                }
                Offsite.tend()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    // MARK: helpers

    /// One copy, restore or prune at a time, across One and its command line (`One --snapshot`, `--restore`).
    static func locked<T>(_ body: () -> T) -> T {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fd = open(folder.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o600)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer {
            if fd >= 0 {
                flock(fd, LOCK_UN)
                close(fd)
            }
        }
        return body()
    }
    static func log(_ line: String) {
        guard !Env.selfTest else { return }
        let u = Env.hermesHome.appendingPathComponent("logs/one-history.log")
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        let l = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        if let h = try? FileHandle(forWritingTo: u) {
            h.seekToEndOfFile()
            h.write(Data(l.utf8))
            try? h.close()
        } else {
            try? l.write(to: u, atomically: true, encoding: .utf8)
        }
    }
}
