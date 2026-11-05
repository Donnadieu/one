import Darwin
import Foundation

// MARK: - Earlier versions and putting one back (`One --restore`, the note reader's "Earlier versions")

extension History {
    /// One earlier version of a file or folder: the newest copy that holds it, its size, when it last changed.
    struct Version: Identifiable {
        let snapshot: Snapshot
        let url: URL
        let size: Int64
        let changed: Date
        let isDir: Bool
        var id: String { snapshot.name }
    }

    /// The same path written one way, so `/var/…` and `/private/var/…` (or a deleted file's path) still match.
    static func std(_ path: String) -> String {
        let u = URL(fileURLWithPath: path).standardizedFileURL
        if FileManager.default.fileExists(atPath: u.path) { return u.resolvingSymlinksInPath().path }
        let parent = u.deletingLastPathComponent().path
        return parent == u.path || parent == "/" ? u.path : std(parent) + "/" + u.lastPathComponent
    }
    /// Where `path` sits inside a copy (`My Brain/…` or `shared/<folder>/…`), and the folder it belongs to now.
    static func inside(_ path: String) -> (rel: String, root: URL, part: String)? {
        let p = std(path)
        var roots = [("My Brain", Brain.root)]
        for s in Shared.paths {
            let u = URL(fileURLWithPath: s, isDirectory: true)
            roots.append(("shared/" + u.lastPathComponent, u))
        }
        for (part, root) in roots {
            let r = std(root.path)
            if p == r { return (part, root, part) }
            if p.hasPrefix(r + "/") { return (part + "/" + p.dropFirst(r.count + 1), root, part) }
        }
        return nil
    }

    /// What a file or folder looks like, to tell versions apart: size and last change (a clone keeps both).
    static func signature(_ u: URL) -> (sig: String, size: Int64, changed: Date, dir: Bool)? {
        var st = stat()
        guard lstat(u.path, &st) == 0 else { return nil }
        if st.st_mode & S_IFMT == S_IFDIR {
            var n = 0
            var bytes: Int64 = 0
            var newest = 0
            walk(u) { _, s in
                n += 1
                bytes += s.st_size
                newest = max(newest, s.st_mtimespec.tv_sec)
            }
            return ("d\(n)-\(bytes)-\(newest)", bytes, Date(timeIntervalSince1970: TimeInterval(newest)), true)
        }
        let m = st.st_mtimespec
        return ("f\(st.st_size)-\(m.tv_sec).\(m.tv_nsec)", st.st_size, Date(timeIntervalSince1970: TimeInterval(m.tv_sec)), false)
    }

    /// Earlier versions of a file or folder in the brain or a shared room, newest first: only versions that
    /// differ from each other and from what's there now.
    static func versions(of path: String) -> [Version] {
        guard let at = inside(path) else { return [] }
        var seen = Set<String>()
        if let now = signature(URL(fileURLWithPath: path)) { seen.insert(now.sig) }
        var out: [Version] = []
        for s in list() {
            let u = s.url.appendingPathComponent(at.rel)
            guard let v = signature(u), seen.insert(v.sig).inserted else { continue }
            out.append(Version(snapshot: s, url: u, size: v.size, changed: v.changed, isDir: v.dir))
        }
        return out
    }

    /// "Today 3:00 PM", "Yesterday 9:15 AM", "Nov 2, 3:00 PM".
    static func when(_ d: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let t = d.formatted(date: .omitted, time: .shortened)
        if cal.isDate(d, inSameDayAs: now) { return "Today " + t }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: y) { return "Yesterday " + t }
        let sameYear = cal.component(.year, from: d) == cal.component(.year, from: now)
        return d.formatted(sameYear ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated).day().year()) + ", " + t
    }
    static func size(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

    // MARK: putting one back

    struct Restored {
        let text: String
        let before: URL
    }

    /// Puts an earlier version of `path` back. First the version there now goes into a new copy labeled
    /// `before restore`, so this can be undone too. `from`: a copy's folder name; `before`: the newest copy
    /// older than that time; neither: the newest version that differs from now.
    static func restore(_ path: String, from: String? = nil, before: Date? = nil) -> Result<Restored, CopyError> {
        guard let at = inside(path) else { return .failure(CopyError(text: "\(path) isn't in your brain or a shared room.")) }
        let fm = FileManager.default
        let source: URL
        let snap: Snapshot
        if let from {
            let u = folder.appendingPathComponent(from).appendingPathComponent(at.rel)
            guard let s = list().first(where: { $0.name == from }), fm.fileExists(atPath: u.path) else {
                return .failure(CopyError(text: "The copy \"\(from)\" has no \(at.rel)."))
            }
            (source, snap) = (u, s)
        } else if let before {
            guard let s = list().first(where: { $0.date < before && fm.fileExists(atPath: $0.url.appendingPathComponent(at.rel).path) }) else {
                return .failure(CopyError(text: "No copy of \(at.rel) from before \(when(before))."))
            }
            (source, snap) = (s.url.appendingPathComponent(at.rel), s)
        } else {
            guard let v = versions(of: path).first else { return .failure(CopyError(text: "No earlier version of \(at.rel) that differs from now.")) }
            (source, snap) = (v.url, v.snapshot)
        }
        return locked {
            let now = Date()
            guard case .success(let b) = takeLocked(label: "before restore", force: true, now: now) else {
                return .failure(CopyError(text: "I couldn't save the version there now first, so I left everything as it is."))
            }
            let away = folder.appendingPathComponent(name(now, label: "removed-by-restore"), isDirectory: true)
            let target = URL(fileURLWithPath: path)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: source.path, isDirectory: &isDir), isDir.boolValue {
                let skipped = skippedPaths(snap)
                let n = replaceTree(
                    target, with: source, away: away.appendingPathComponent(at.rel), removeExtras: true, skipped: skipped, rel: at.rel)
                log("restored folder \(at.rel) from \(snap.name)")
                return .success(
                    Restored(
                        text: "Put back \(at.rel) as it was \(when(snap.date)): \(n.put) files back, \(n.moved) newer files moved to \(away.path). "
                            + "What you had is saved in \(b.url.path).", before: b.url))
            }
            guard putBack(source, at: target) else { return .failure(CopyError(text: "I couldn't put \(at.rel) back.")) }
            log("restored \(at.rel) from \(snap.name)")
            return .success(
                Restored(
                    text: "Put back \(at.rel) from \(when(snap.date)). The version you had is saved in \(b.url.path).", before: b.url))
        }
    }

    /// "Undo last night": the whole brain (and the assistant's memory files) as they were in copy `name`.
    /// Files there now that the copy doesn't have are moved to `history/<now> removed-by-restore/`, never deleted.
    /// A shared room only gets its changed or missing files back: new files in it may be someone else's.
    static func restoreAll(_ snapName: String) -> Result<Restored, CopyError> {
        guard let snap = list().first(where: { $0.name == snapName }) else {
            return .failure(CopyError(text: "There's no copy named \"\(snapName)\" in \(folder.path)."))
        }
        let fm = FileManager.default
        return locked {
            let now = Date()
            guard case .success(let b) = takeLocked(label: "before restore", force: true, now: now) else {
                return .failure(CopyError(text: "I couldn't save what's there now first, so I left everything as it is."))
            }
            let away = folder.appendingPathComponent(name(now, label: "removed-by-restore"), isDirectory: true)
            let skipped = skippedPaths(snap)
            var put = 0
            var moved = 0
            var targets: [(String, URL, Bool)] = [
                ("My Brain", Brain.root, true), ("engine-files/memories", Env.hermesHome.appendingPathComponent("memories"), true),
                ("engine-files/owner-notes.md", Env.hermesHome.appendingPathComponent("owner-notes.md"), false),
            ]
            for s in Shared.paths {
                let u = URL(fileURLWithPath: s, isDirectory: true)
                targets.append(("shared/" + u.lastPathComponent, u, false))
            }
            for (rel, target, extras) in targets {
                let src = snap.url.appendingPathComponent(rel)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: src.path, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    let n = replaceTree(target, with: src, away: away.appendingPathComponent(rel), removeExtras: extras, skipped: skipped, rel: rel)
                    put += n.put
                    moved += n.moved
                } else if signature(src)?.sig != signature(target)?.sig, putBack(src, at: target) {
                    put += 1
                }
            }
            log("restored everything from \(snap.name): \(put) back, \(moved) moved away")
            let movedLine = moved == 0 ? "" : " \(moved) newer files were moved to \(away.path)."
            return .success(
                Restored(
                    text: "Put your brain back as it was \(when(snap.date)): \(put) files back.\(movedLine) What you had is saved in \(b.url.path).",
                    before: b.url))
        }
    }

    /// Clones `src` over `dst` in one step (a clone next to it, then a rename), making folders as needed.
    static func putBack(_ src: URL, at dst: URL) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = dst.deletingLastPathComponent().appendingPathComponent(".\(dst.lastPathComponent).one-restore-\(getpid())")
        try? fm.removeItem(at: tmp)
        var st = stat()
        if lstat(dst.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR { return false }  // a folder there now: never replaced by a file
        guard clone(src.path, tmp.path) != .failed else { return false }
        if rename(tmp.path, dst.path) == 0 { return true }
        try? fm.removeItem(at: tmp)
        return false
    }

    /// Makes folder `cur` match `snap`: changed and missing files come back; with `removeExtras`, files the copy
    /// doesn't have move into `away` (never deleted). Files still only in iCloud are never touched.
    static func replaceTree(_ cur: URL, with snap: URL, away: URL, removeExtras: Bool, skipped: Set<String>, rel: String) -> (put: Int, moved: Int) {
        let fm = FileManager.default
        var put = 0
        var moved = 0
        var inSnap = Set<String>()
        var snapDirs = Set<String>()
        try? fm.createDirectory(at: cur, withIntermediateDirectories: true)
        walk(
            snap, dir: { r, _ in snapDirs.insert(r) },
            visit: { r, _ in
                inSnap.insert(r)
                let s = snap.appendingPathComponent(r)
                let c = cur.appendingPathComponent(r)
                if signature(s)?.sig != signature(c)?.sig, putBack(s, at: c) { put += 1 }
            })
        guard removeExtras else { return (put, moved) }
        var extra: [String] = []
        var dirs: [String] = []
        walk(
            cur, dir: { r, _ in dirs.append(r) },
            visit: { r, _ in
                if !inSnap.contains(r) && !skipped.contains(rel + "/" + r) { extra.append(r) }
            })
        for r in extra {
            let to = away.appendingPathComponent(r)
            try? fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? fm.moveItem(at: cur.appendingPathComponent(r), to: to)) != nil { moved += 1 }
        }
        for r in dirs.reversed() where !r.isEmpty && !snapDirs.contains(r) {
            let u = cur.appendingPathComponent(r)
            if ((try? fm.contentsOfDirectory(atPath: u.path)) ?? ["x"]).allSatisfy({ $0 == ".DS_Store" }) { try? fm.removeItem(at: u) }
        }
        return (put, moved)
    }

    /// Told on every prompt: how to undo a change to a note (One's own binary does it; the engine runs in the lock).
    static var note: String {
        let x = "`\(Bridge.exe)"
        return "\n\n(One app note, not from the user: UNDO. One keeps an instant copy of the brain and shared rooms every hour. "
            + "When they ask to undo a change to a note or folder: \(x) --restore --list \"<path>\"` lists earlier versions (newest first), "
            + "then \(x) --restore \"<path>\" --from \"<copy>\"` (or `--before 2026-11-05T09:00`) puts one back; it saves what's there now "
            + "first, so it can be undone too. Say in plain words what you put back. Before changing many notes at once, take a copy: "
            + "\(x) --snapshot \"before <what>\"`.)"
    }

    // MARK: command line (the engine runs inside the folder lock, so it asks One's own binary)

    /// `One --snapshot [label]`, `One --restore <path> [--from <copy>|--before <time>]`, `One --restore --list <path>`,
    /// `One --restore --snapshot <copy>`. Plain-words results; nil when none of these was asked.
    static func cli(_ args: [String]) -> Int32? {
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count, !args[i + 1].hasPrefix("--") else { return nil }
            return args[i + 1]
        }
        if args.contains("--restore") {
            if let p = value("--list") {
                let vs = versions(of: p)
                guard inside(p) != nil else {
                    print("\(p) isn't in your brain or a shared room.")
                    return 1
                }
                if vs.isEmpty { print("No earlier versions of \(p) yet. One keeps a copy every hour.") }
                for v in vs { print("\(v.snapshot.name)\t\(when(v.snapshot.date))\tchanged \(when(v.changed))\t\(size(v.size))") }
                return 0
            }
            let r: Result<Restored, CopyError>
            if let s = value("--snapshot") {
                r = restoreAll(s)
            } else if let p = value("--restore") {
                let before = value("--before").flatMap(parseTime)
                if value("--before") != nil && before == nil {
                    print("I couldn't read that time. Use one like 2026-11-05T14:00 or 2026-11-05 14:00.")
                    return 2
                }
                r = restore(p, from: value("--from"), before: before)
            } else {
                print("Usage: One --restore <path> [--from <copy>|--before <time>] | --restore --list <path> | --restore --snapshot <copy>")
                return 2
            }
            switch r {
            case .success(let ok): print(ok.text)
            case .failure(let e): print(e.text)
            }
            if case .success = r { return 0 }
            return 1
        }
        guard let k = args.firstIndex(of: "--snapshot") else { return nil }
        let label = k + 1 < args.count && !args[k + 1].hasPrefix("--") ? args[k + 1] : nil
        switch take(label: label, force: true) {
        case .success(let t):
            print(t.url.path)
            return 0
        case .failure(let e):
            print(e.text)
            return 1
        }
    }
    static func parseTime(_ s: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: s) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd HHmm", "yyyy-MM-dd"] {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        return nil
    }
}
