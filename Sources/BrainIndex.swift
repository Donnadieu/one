import CoreServices
import Foundation
import SQLite3

// MARK: - The brain's search index: one SQLite file per room, in One's own folder, rebuildable

/// A room the search knows about: a `<x>-room` folder in the brain, the assistant's own folder, or a shared room.
struct SearchRoom {
    let name: String
    let folder: URL
    let shared: Bool
    let isPrivate: Bool
    /// `<support>/index/<name>.sqlite`. Never inside the brain or a shared iCloud folder.
    let db: URL
}

/// Which rooms exist and which are private (storage design 3f: a private room is searched only when named).
enum BrainRooms {
    /// Tests only: shared room folders instead of the saved list (`Shared.paths`).
    nonisolated(unsafe) static var sharedOverride: [String]?
    static var indexDir: URL {
        let u = Env.support.appendingPathComponent("index", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func all() -> [SearchRoom] {
        let fm = FileManager.default
        var out: [SearchRoom] = []
        let local = (try? fm.contentsOfDirectory(at: Brain.root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for u in local.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where u.lastPathComponent.hasSuffix("-room") {
            guard (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let n = u.lastPathComponent
            out.append(SearchRoom(name: n, folder: u, shared: false, isPrivate: isPrivate(u), db: file(n)))
        }
        let mine = Brain.root.appendingPathComponent("assistant", isDirectory: true)
        if fm.fileExists(atPath: mine.path) {
            out.append(SearchRoom(name: "assistant", folder: mine, shared: false, isPrivate: false, db: file("assistant")))
        }
        for p in sharedOverride ?? Shared.paths {
            let u = URL(fileURLWithPath: p, isDirectory: true)
            let title = Shared.info(u)?.title ?? u.lastPathComponent
            out.append(SearchRoom(name: title, folder: u, shared: true, isPrivate: false, db: file("shared-" + title)))
        }
        return out
    }

    static func file(_ name: String) -> URL {
        let safe = String(name.map { "/:\\".contains($0) ? "-" : $0 })
        return indexDir.appendingPathComponent(safe + ".sqlite")
    }

    // TODO(storage): use RoomInfo.isPrivate once storage-guards lands
    /// A room is private when its `room.yaml` says `private: true`. No room.yaml (or no clear `false`) = private:
    /// the safe default. Shared rooms and the assistant's own folder are never private (they don't come here).
    static func isPrivate(_ room: URL) -> Bool {
        guard let s = try? String(contentsOf: room.appendingPathComponent("room.yaml"), encoding: .utf8) else { return true }
        for line in s.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("private:") else { continue }
            var v = t.dropFirst("private:".count).trimmingCharacters(in: .whitespaces)
            if let hash = v.firstIndex(of: "#") { v = String(v[..<hash]).trimmingCharacters(in: .whitespaces) }
            v = v.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")).lowercased()
            return !(v == "false" || v == "no")
        }
        return true
    }
}

// MARK: - A small SQLite handle

final class IndexDB {
    let db: OpaquePointer
    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init?(_ path: String, readOnly: Bool = false) {
        var p: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        guard sqlite3_open_v2(path, &p, flags | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let p else {
            sqlite3_close(p)
            return nil
        }
        db = p
        sqlite3_busy_timeout(db, 2000)
    }
    deinit { sqlite3_close(db) }

    @discardableResult func exec(_ sql: String) -> Bool { sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK }

    func prepare(_ sql: String) -> OpaquePointer? {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else {
            sqlite3_finalize(s)
            return nil
        }
        return s
    }

    /// Runs one statement with these values; returns every row as text/number values.
    @discardableResult func rows(_ sql: String, _ args: [Any?] = []) -> [[Any?]]? {
        guard let s = prepare(sql) else { return nil }
        defer { sqlite3_finalize(s) }
        IndexDB.bind(s, args)
        var out: [[Any?]] = []
        while true {
            let rc = sqlite3_step(s)
            if rc == SQLITE_DONE { return out }
            guard rc == SQLITE_ROW else { return nil }
            out.append(IndexDB.row(s))
        }
    }

    static func bind(_ s: OpaquePointer, _ args: [Any?]) {
        for (i, a) in args.enumerated() {
            let k = Int32(i + 1)
            switch a {
            case let v as String: sqlite3_bind_text(s, k, v, -1, transient)
            case let v as Int: sqlite3_bind_int64(s, k, Int64(v))
            case let v as Int64: sqlite3_bind_int64(s, k, v)
            case let v as Double: sqlite3_bind_double(s, k, v)
            default: sqlite3_bind_null(s, k)
            }
        }
    }

    static func row(_ s: OpaquePointer) -> [Any?] {
        (0..<sqlite3_column_count(s)).map { c -> Any? in
            switch sqlite3_column_type(s, c) {
            case SQLITE_INTEGER: return Int(sqlite3_column_int64(s, c))
            case SQLITE_FLOAT: return sqlite3_column_double(s, c)
            case SQLITE_TEXT: return sqlite3_column_text(s, c).map { String(cString: $0) }
            default: return nil
            }
        }
    }
}

// MARK: - Building and refreshing a room's index

enum BrainIndex {
    static let version = "1"
    static let maxBytes = 1_000_000
    static let chunkCap = 1500
    static let kinds: Set<String> = ["md", "txt"]

    struct Stats {
        var files = 0, changed = 0, removed = 0, chunks = 0
        var rebuilt = false
        var ok = true
    }

    /// Opens a room's index, making the tables when new. A missing, broken or old index is deleted and made again:
    /// it only ever holds what can be read back from the files.
    static func open(_ room: SearchRoom) -> (IndexDB, rebuilt: Bool)? {
        if let d = IndexDB(room.db.path), ready(d) { return (d, false) }
        remove(room.db)
        guard let d = IndexDB(room.db.path), ready(d) else { return nil }
        return (d, true)
    }

    static func remove(_ db: URL) {
        for x in ["", "-wal", "-shm", "-journal"] { try? FileManager.default.removeItem(atPath: db.path + x) }
    }

    /// Word search (porter stemming, ranked by bm25) and, when this Mac's SQLite has it, a trigram copy for close
    /// spellings and parts of words. Both are FTS5, checked here at run time.
    private static func ready(_ d: IndexDB) -> Bool {
        guard d.exec("PRAGMA journal_mode=WAL"), d.exec("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT)")
        else { return false }
        let v = d.rows("SELECT value FROM meta WHERE key='version'")
        guard let v else { return false }
        if let have = v.first?.first as? String { return have == version && d.rows("SELECT count(*) FROM files") != nil }
        let made =
            d.exec("CREATE TABLE files(path TEXT PRIMARY KEY, mtime REAL, size INTEGER)")
            && d.exec("CREATE TABLE spans(id INTEGER PRIMARY KEY, path TEXT)") && d.exec("CREATE INDEX spans_path ON spans(path)")
            && d.exec(
                "CREATE VIRTUAL TABLE chunks USING fts5(file UNINDEXED, title, heading, text, date UNINDEXED, room UNINDEXED, tokenize='porter unicode61')"
            )
        guard made else { return false }
        let tri = d.exec("CREATE VIRTUAL TABLE grams USING fts5(title, heading, text, tokenize='trigram')")
        d.exec("INSERT INTO meta VALUES('trigram', '\(tri ? 1 : 0)')")
        return d.exec("INSERT INTO meta VALUES('version', '\(version)')")
    }

    static func hasTrigram(_ d: IndexDB) -> Bool { (d.rows("SELECT value FROM meta WHERE key='trigram'")?.first?.first as? String) == "1" }

    /// Every `.md`/`.txt` file the index may hold: never a `confidential/` folder, `.git`, hidden files (iCloud's
    /// `.name.icloud` placeholders too), shortcuts, or anything over 1 MB.
    static func files(in folder: URL) -> [(rel: String, url: URL, mtime: Double, size: Int)] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard
            let en = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        let base = folder.standardizedFileURL.path
        var out: [(String, URL, Double, Int)] = []
        for case let u as URL in en {
            let name = u.lastPathComponent
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isDirectory == true {
                if ["confidential", ".git", "node_modules"].contains(name.lowercased()) { en.skipDescendants() }
                continue
            }
            guard v.isSymbolicLink != true, v.isRegularFile == true, kinds.contains(u.pathExtension.lowercased()),
                !name.hasSuffix(".icloud"), let size = v.fileSize, size <= maxBytes
            else { continue }
            let p = u.standardizedFileURL.path
            guard p.hasPrefix(base + "/") else { continue }
            let rel = String(p.dropFirst(base.count + 1))
            if rel.lowercased().split(separator: "/").contains("confidential") { continue }  // belt and braces
            out.append((rel, u, v.contentModificationDate?.timeIntervalSince1970 ?? 0, size))
        }
        return out
    }

    /// Brings a room's index up to date: only files whose time or size changed are read again; gone files leave.
    @discardableResult static func refresh(_ room: SearchRoom) -> Stats {
        var st = Stats()
        guard let (d, rebuilt) = open(room) else { return Stats(ok: false) }
        st.rebuilt = rebuilt
        let tri = hasTrigram(d)
        var known: [String: (Double, Int)] = [:]
        for r in d.rows("SELECT path, mtime, size FROM files") ?? [] {
            if let p = r[0] as? String { known[p] = ((r[1] as? Double) ?? Double((r[1] as? Int) ?? 0), (r[2] as? Int) ?? -1) }
        }
        let now = files(in: room.folder)
        st.files = now.count
        let changed = now.filter { f in known[f.rel].map { $0.0 != f.mtime || $0.1 != f.size } ?? true }
        let seen = Set(now.map(\.rel))
        let gone = known.keys.filter { !seen.contains($0) }
        guard !changed.isEmpty || !gone.isEmpty else { return st }
        guard d.exec("BEGIN IMMEDIATE") else { return Stats(ok: false) }
        let w = Writer(d, room: room.name, trigram: tri)
        for p in gone {
            w.drop(p)
            d.rows("DELETE FROM files WHERE path=?", [p])
        }
        for f in changed {
            w.drop(f.rel)
            let text = read(f.url)
            st.chunks += w.add(f.rel, title: title(f.url), date: date(f.url, mtime: f.mtime), text: text)
            d.rows("INSERT OR REPLACE INTO files VALUES(?,?,?)", [f.rel, f.mtime, f.size])
        }
        st.changed = changed.count
        st.removed = gone.count
        st.ok = d.exec("COMMIT")
        if !st.ok { d.exec("ROLLBACK") }
        return st
    }

    /// Plain text only: a file that isn't UTF-8 or holds zero bytes (a locked git-crypt file) is skipped.
    static func read(_ u: URL) -> String {
        guard let data = try? Data(contentsOf: u), !data.contains(0), let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    static func title(_ u: URL) -> String {
        u.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
    }

    /// The date in the file's name (`2026-11-04 …`), else the day it last changed.
    static func date(_ u: URL, mtime: Double) -> String {
        let n = u.lastPathComponent
        if n.count >= 10, n.prefix(10).range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil { return String(n.prefix(10)) }
        return day(mtime)
    }

    static func day(_ t: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: t))
    }

    /// Writes chunks with prepared statements (one refresh = one transaction).
    final class Writer {
        let d: IndexDB
        let room: String
        let trigram: Bool
        let span, chunk, gram: OpaquePointer?
        init(_ d: IndexDB, room: String, trigram: Bool) {
            self.d = d
            self.room = room
            self.trigram = trigram
            span = d.prepare("INSERT INTO spans(path) VALUES(?)")
            chunk = d.prepare("INSERT INTO chunks(rowid, file, title, heading, text, date, room) VALUES(?,?,?,?,?,?,?)")
            gram = trigram ? d.prepare("INSERT INTO grams(rowid, title, heading, text) VALUES(?,?,?,?)") : nil
        }
        deinit { [span, chunk, gram].forEach { sqlite3_finalize($0) } }

        func drop(_ path: String) {
            let ids = "SELECT id FROM spans WHERE path=?"
            d.rows("DELETE FROM chunks WHERE rowid IN (\(ids))", [path])
            if trigram { d.rows("DELETE FROM grams WHERE rowid IN (\(ids))", [path]) }
            d.rows("DELETE FROM spans WHERE path=?", [path])
        }

        func add(_ path: String, title: String, date: String, text: String) -> Int {
            guard let span, let chunk else { return 0 }
            let parts = BrainIndex.chunks(text)
            for c in parts {
                step(span, [path])
                let id = Int(sqlite3_last_insert_rowid(d.db))
                step(chunk, [id, path, title, c.heading, c.text, date, room])
                if let gram { step(gram, [id, title, c.heading, c.text]) }
            }
            return parts.count
        }

        private func step(_ s: OpaquePointer, _ args: [Any?]) {
            sqlite3_reset(s)
            sqlite3_clear_bindings(s)
            IndexDB.bind(s, args)
            sqlite3_step(s)
        }
    }

    /// A note split at its headings, each piece at most `chunkCap` characters (split again at blank lines, then at
    /// a space). `heading` is the nearest heading above the text. Headings inside code blocks don't count.
    static func chunks(_ s: String) -> [(heading: String, text: String)] {
        var out: [(String, String)] = []
        var heading = ""
        var body: [Substring] = []
        var fenced = false
        func flush() {
            let t = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            body = []
            if t.isEmpty {
                if !heading.isEmpty { out.append((heading, "")) }
                return
            }
            for piece in split(t) { out.append((heading, piece)) }
        }
        for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("```") || line.hasPrefix("~~~") { fenced.toggle() }
            if !fenced, line.hasPrefix("#") {
                let hashes = line.prefix { $0 == "#" }.count
                let rest = line.dropFirst(hashes)
                if hashes <= 6, rest.isEmpty || rest.first == " " {
                    flush()
                    heading = rest.trimmingCharacters(in: .whitespaces)
                    continue
                }
            }
            body.append(line)
        }
        flush()
        return out
    }

    static func split(_ t: String) -> [String] {
        guard t.count > chunkCap else { return [t] }
        var out: [String] = []
        var cur = ""
        for para in t.components(separatedBy: "\n\n") {
            var p = para
            while p.count > chunkCap {  // one long paragraph: cut at the last space before the cap
                if !cur.isEmpty {
                    out.append(cur)
                    cur = ""
                }
                let end = p.index(p.startIndex, offsetBy: chunkCap)
                let cut = p[..<end].lastIndex(of: " ") ?? end
                out.append(String(p[..<cut]))
                p = String(p[cut...]).trimmingCharacters(in: .whitespaces)
            }
            if cur.count + p.count + 2 > chunkCap, !cur.isEmpty {
                out.append(cur)
                cur = ""
            }
            cur = cur.isEmpty ? p : cur + "\n\n" + p
        }
        if !cur.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(cur) }
        return out
    }
}

// MARK: - When the index is refreshed: at launch, when brain files change (or every 10 min), and at night

extension BrainIndex {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var dirty = true
    nonisolated(unsafe) private static var stream: FSEventStreamRef?
    static let every: TimeInterval = 10 * 60

    /// Called once when the person's One opens. Never on the main thread, never in a command-line run.
    static func start() {
        guard !Env.commandLine else { return }
        Task.detached(priority: .utility) {
            watch()
            var last = Date.distantPast
            var night = ""
            while true {
                let now = Date()
                let today = day(now.timeIntervalSince1970)
                let wantNight = Calendar.current.component(.hour, from: now) == 3 && night != today
                if takeDirty() || now.timeIntervalSince(last) >= every || wantNight {
                    for r in BrainRooms.all() { refresh(r) }
                    last = Date()
                }
                if wantNight {
                    night = today
                    for r in BrainRooms.all() { tidy(r) }
                }
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    static func markDirty() {
        lock.lock()
        dirty = true
        lock.unlock()
    }

    private static func takeDirty() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let d = dirty
        dirty = false
        return d
    }

    /// File changes in the brain and the shared rooms' folder mark the index for a refresh (3 s apart at most).
    private static func watch() {
        let paths = [Brain.root.path, Shared.base.path].filter { FileManager.default.fileExists(atPath: $0) }
        guard stream == nil, !paths.isEmpty else { return }
        var ctx = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, _, _, _, _, _ in BrainIndex.markDirty() }
        guard
            let s = FSEventStreamCreate(
                nil, cb, &ctx, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 3.0,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone))
        else { return }
        FSEventStreamSetDispatchQueue(s, DispatchQueue(label: "one.brain-index.watch", qos: .utility))
        FSEventStreamStart(s)
        stream = s
    }

    /// At night: a damaged index is made again, a healthy one is packed tighter.
    static func tidy(_ room: SearchRoom) {
        guard let (d, _) = open(room) else { return }
        if (d.rows("PRAGMA quick_check")?.first?.first as? String) != "ok" {
            remove(room.db)
            refresh(room)
            return
        }
        d.exec("INSERT INTO chunks(chunks) VALUES('optimize')")
        if hasTrigram(d) { d.exec("INSERT INTO grams(grams) VALUES('optimize')") }
    }
}
