import CryptoKit
import Foundation

// MARK: - The front page: the engine's two always-on notes, written by One
// USER.md and MEMORY.md are what the engine puts in front of the assistant in every chat. They are a summary One
// writes, never the store (storage plan 3d). The store is the brain: `My Brain/assistant/how-to-work-with-me.md`
// (how the person wants to be worked with) and `assistant/this-mac.md` (facts about this Mac). Only each file's
// `## Always on` part goes on the front page; `## More` and `notes/` are back pages, found by search.
// USER.md: rebuilt at launch and whenever a connection changes, from the name, LIVE connections (never the
// setup answers when something is really connected), how-to-work-with-me and the newest 8 "don't save" kinds.
// MEMORY.md: the engine's memory tool still adds lines during the day. `fileNew` copies each new line into
// this-mac.md (nothing lost), then `rebuildMemory` writes MEMORY.md again from this-mac.md's Always on part.
// Nothing here ever reads a room: a private room's words can never reach the front page.

enum FrontPage {
    nonisolated(unsafe) static var lastSig = ""
    static let delimiter = "\n§\n"  // the engine's own entry separator (memory_tool_store.ENTRY_DELIMITER)
    static let pointer =
        "More notes in My Brain/assistant (this-mac.md, notes/); search them with One --search. Facts about one room go in that room, not here."
    static var memDir: URL { Env.hermesHome.appendingPathComponent("memories", isDirectory: true) }
    static var userFile: URL { memDir.appendingPathComponent("USER.md") }
    static var memoryFile: URL { memDir.appendingPathComponent("MEMORY.md") }
    static var assistantDir: URL { Brain.root.appendingPathComponent("assistant", isDirectory: true) }
    static var thisMac: URL { assistantDir.appendingPathComponent("this-mac.md") }
    static var howTo: URL { assistantDir.appendingPathComponent("how-to-work-with-me.md") }
    static var stateFile: URL { Env.support.appendingPathComponent(Env.selfTest ? "selftest-front-page.json" : "front-page.json") }
    static var logFile: URL { Env.hermesHome.appendingPathComponent("logs/one-front-page.log") }

    static func log(_ s: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        try? FileManager.default.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: logFile) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? line.write(to: logFile, atomically: true, encoding: .utf8)
        }
    }
    static func read(_ u: URL) -> String? { try? String(contentsOf: u, encoding: .utf8) }
    /// The engine counts characters the Python way (code points).
    static func size(_ s: String) -> Int { s.unicodeScalars.count }
    static func today() -> String { ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate]) }

    // MARK: The engine's settings (read only)

    static func config() -> String { read(Env.hermesHome.appendingPathComponent("config.yaml")) ?? "" }
    /// A plain value at a nested key of config.yaml (`["vault", "keepass", "database"]`), or nil. Block style only.
    static func value(_ path: [String], in cfg: String) -> String? {
        guard !path.isEmpty else { return nil }
        var indents: [Int] = []
        for raw in cfg.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let body = line.trimmingCharacters(in: .whitespaces)
            if body.isEmpty || body.hasPrefix("#") { continue }
            let ind = line.prefix { $0 == " " }.count
            while let last = indents.last, ind <= last { indents.removeLast() }
            let depth = indents.count
            guard depth < path.count, body.hasPrefix(path[depth] + ":") else { continue }
            if depth > 0 && ind <= indents[depth - 1] { continue }
            if depth == path.count - 1 {
                var v = String(body.dropFirst(path[depth].count + 1))
                if let r = v.range(of: " #") { v = String(v[..<r.lowerBound]) }
                v = v.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                return v.isEmpty || v == "null" || v == "~" ? nil : v
            }
            indents.append(ind)
        }
        return nil
    }
    static func limit(_ key: String, _ fallback: Int, _ cfg: String) -> Int {
        value(["memory", key], in: cfg).flatMap { Int($0) }.flatMap { $0 > 100 ? $0 : nil } ?? fallback
    }

    // MARK: USER.md

    /// What Connections shows as connected for passwords (`passwordsWith`), else a KeePass file set in the engine.
    static func passwordSource(_ with: String?, _ cfg: String) -> String? {
        if let w = with?.trimmingCharacters(in: .whitespaces), !w.isEmpty { return w }
        return value(["vault", "keepass", "database"], in: cfg) != nil ? "KeePass" : nil
    }
    /// A setup answer in Connections' words ("Gmail" → Email).
    static func canon(_ id: String) -> String {
        let l = id.lowercased().trimmingCharacters(in: .whitespaces)
        if ["gmail", "outlook", "mail", "email", "e-mail", "icloud mail", "yahoo"].contains(l) { return "Email" }
        if l.contains("calendar") { return "Calendar" }
        if ["passwords", "password", "keychain", "keepass", "1password", "bitwarden", "logins"].contains(l) { return "Passwords" }
        if ["files", "folders", "documents"].contains(l) { return "Files" }
        return id.trimmingCharacters(in: .whitespaces)
    }
    /// Asked for at setup and still not connected now (News is never connected: it isn't built yet).
    static func notConnected(_ wanted: [String], live: [String], folders: Bool) -> [String] {
        var on = Set(live.map(canon))
        on.remove("Files")
        if folders { on.insert("Files") }
        var out: [String] = []
        for w in wanted.map(canon) where !w.isEmpty && !on.contains(w) && !out.contains(w) { out.append(w) }
        return out
    }
    /// The `## Always on` part of a file, or the whole file (its `# ` title left out) when it has none.
    static func alwaysOn(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        if let k = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == "## always on" }) {
            var out: [String] = []
            for l in lines[(k + 1)...] {
                if l.hasPrefix("## ") || l.hasPrefix("# ") { break }
                out.append(l)
            }
            return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return lines.filter { !$0.hasPrefix("# ") }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// How the person works: the brain's file, else the old `hermes/owner-notes.md`.
    static func howToText(user: String) -> String? {
        var t: String?
        if let h = read(howTo) { t = alwaysOn(h) }
        if t?.isEmpty ?? true, let n = read(Env.hermesHome.appendingPathComponent("owner-notes.md")) {
            t = n.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard var t, !t.isEmpty else { return nil }
        t = t.components(separatedBy: "\n").map { $0.hasPrefix("- ") ? String($0.dropFirst(2)) : $0 }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: "\n")
        if !t.lowercased().hasPrefix("how ") { t = "How \(user.isEmpty ? "they" : user) work\(user.isEmpty ? "" : "s"): " + t }
        return t
    }
    /// Cuts text to at most `budget` characters, at the end of a sentence.
    static func cutAtSentence(_ t: String, _ budget: Int) -> String {
        guard size(t) > budget else { return t }
        guard budget > 0 else { return "" }
        let s = Array(t.unicodeScalars)
        var end = 0
        for i in 0..<min(budget, s.count) where ".!?".unicodeScalars.contains(s[i]) {
            if i + 1 == s.count || CharacterSet.whitespacesAndNewlines.contains(s[i + 1]) { end = i + 1 }
        }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: s[0..<end])
        return String(out)
    }

    /// USER.md's text. Everything live is passed in, so the check can set it up.
    static func userText(
        assistant: String, user: String, wanted: [String], passwords: String, passwordsWith: String?, live: [String], folders: Bool,
        cfg: String, declined: String?
    ) -> (text: String, trimmed: Bool) {
        var head = ["The user's name is \(user). They call their assistant \(assistant)."]
        let src = passwordSource(passwordsWith, cfg)
        let missing = notConnected(wanted, live: live + (src == nil ? [] : ["Passwords"]), folders: folders)
        if !missing.isEmpty {
            head.append(
                "They want these connected: \(missing.joined(separator: ", ")). Not connected yet; help them connect each one when it first comes up."
            )
        }
        if let src {
            head.append("For logins: \(src) is connected (Connections > Passwords); use it, never ask for a password in chat.")
        } else if !passwords.isEmpty {
            head.append("For logins: \(passwords).")
        }
        let tail = declined.map { [$0] } ?? []
        let cap = limit("user_char_limit", 1375, cfg)
        var how = howToText(user: user)
        func joined() -> String { (head + (how.map { [$0] } ?? []) + tail).joined(separator: delimiter) }
        var trimmed = false
        if size(joined()) > cap, let h = how {
            let rest = size(joined()) - size(h)
            let cut = cutAtSentence(h, cap - rest)
            how = cut.isEmpty ? nil : cut
            trimmed = true
        }
        return (joined(), trimmed)
    }

    /// Writes USER.md from the live state (only when it changed). `Persona.writeMemory` calls this.
    static func writeUser(assistant: String, user: String, wanted: [String], passwords: String, live: [String]? = nil) {
        try? FileManager.default.createDirectory(at: memDir, withIntermediateDirectories: true)
        let r = userText(
            assistant: assistant, user: user, wanted: wanted, passwords: passwords,
            passwordsWith: UserDefaults.standard.string(forKey: "passwordsWith"), live: live ?? ConnectionsWorld.connected(),
            folders: !Access.folders.isEmpty, cfg: config(), declined: Learning.declinedFact)
        guard read(userFile) != r.text else { return }
        try? r.text.write(to: userFile, atomically: true, encoding: .utf8)
        if r.trimmed { log("USER.md over the engine's limit: how-to-work-with-me cut at a sentence (the whole text stays in the brain)") }
    }
    /// After a connection changes: the same, from the saved settings.
    static func refreshUser() {
        let d = UserDefaults.standard
        let user = d.string(forKey: "userName") ?? ""
        guard !user.isEmpty || Env.selfTest else { return }
        writeUser(
            assistant: d.string(forKey: "assistantName") ?? "", user: user,
            wanted: (d.string(forKey: "connections") ?? "").split(separator: ",").map(String.init), passwords: d.string(forKey: "passwords") ?? "")
    }
}

// MARK: - MEMORY.md

struct FrontPageState: Codable {
    var hash = ""  // MEMORY.md right after One last wrote it
    var written: [String] = []  // the entries One wrote
    var rebuilt: Date?
}

extension FrontPage {
    static func loadState() -> FrontPageState {
        guard let d = try? Data(contentsOf: stateFile) else { return FrontPageState() }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode(FrontPageState.self, from: d)) ?? FrontPageState()
    }
    static func saveState(_ s: FrontPageState) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(s).write(to: stateFile, options: .atomic)
    }
    static func hash(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }

    static func entries(_ raw: String) -> [String] {
        raw.components(separatedBy: delimiter).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    static let addedMark = #"\s*\(added by the assistant [0-9-]+\)\s*$"#
    /// The same line however it's dressed: no bullet, no "(added by …)" note, spaces and case evened out.
    static func norm(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("- ") || t.hasPrefix("* ") { t = String(t.dropFirst(2)) }
        t = t.replacingOccurrences(of: addedMark, with: "", options: .regularExpression)
        return t.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    static func isPointer(_ e: String) -> Bool { norm(e).hasPrefix("more notes in my brain/assistant") }

    /// The Always on part of this-mac.md as entries: one per bullet (with its indented lines) or paragraph.
    static func alwaysOnEntries(_ text: String) -> [String] {
        var out: [String] = []
        var cur: [String] = []
        func flush() {
            let e = cur.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !e.isEmpty { out.append(e.replacingOccurrences(of: addedMark, with: "", options: .regularExpression)) }
            cur = []
        }
        for l in alwaysOn(text).components(separatedBy: "\n") {
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.isEmpty {
                flush()
            } else if t.hasPrefix("- ") || t.hasPrefix("* ") {
                flush()
                cur = [String(t.dropFirst(2))]
            } else {
                cur.append(t)
            }
        }
        flush()
        return out
    }

    /// Lines the assistant added to MEMORY.md today that aren't in this-mac.md yet go under `## Always on`, dated.
    /// Returns what was filed. Never removes anything.
    @discardableResult
    static func fileNew() -> [String] {
        guard let raw = read(memoryFile) else { return [] }
        let st = loadState()
        let mine = Set(st.written.map(norm))
        let mac = read(thisMac) ?? "# This Mac\n\nFacts about this Mac and its tools, for every room.\n\n## Always on\n"
        let have = norm(mac)
        var new: [String] = []
        for e in entries(raw) where !isPointer(e) && !mine.contains(norm(e)) && !have.contains(norm(e)) {
            let one = e.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
            if !new.contains(where: { norm($0) == norm(one) }) { new.append(one) }
        }
        guard !new.isEmpty else { return [] }
        let add = new.map { "- \($0) (added by the assistant \(today()))" }
        var lines = mac.components(separatedBy: "\n")
        if let k = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == "## always on" }) {
            var end = lines[(k + 1)...].firstIndex { $0.hasPrefix("## ") || $0.hasPrefix("# ") } ?? lines.count
            while end > k + 1, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
            lines.insert(contentsOf: add + (end < lines.count ? [""] : []), at: end)
        } else {
            while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
            lines += ["", "## Always on", ""] + add
        }
        var out = lines.joined(separator: "\n")
        if !out.hasSuffix("\n") { out += "\n" }
        try? FileManager.default.createDirectory(at: assistantDir, withIntermediateDirectories: true)
        do {
            try out.write(to: thisMac, atomically: true, encoding: .utf8)
        } catch {
            log("file-new: couldn't write this-mac.md (\(error.localizedDescription)); MEMORY.md left as it is")
            return []
        }
        log("file-new: \(new.count) line(s) from MEMORY.md added to assistant/this-mac.md under Always on")
        return new
    }

    /// The front page from this-mac.md: its Always on entries (the newest that fit) and the pointer line.
    static func memoryText(_ mac: String, cap: Int) -> (text: String, left: [String]) {
        let all = alwaysOnEntries(mac)
        var keep = Set<Int>()
        var used = size(pointer)
        for i in all.indices.reversed() {
            let n = size(all[i]) + size(delimiter)
            if used + n <= cap {
                keep.insert(i)
                used += n
            }
        }
        let kept = all.indices.filter { keep.contains($0) }.map { all[$0] }
        let left = all.indices.filter { !keep.contains($0) }.map { all[$0] }
        return ((kept + [pointer]).joined(separator: delimiter), left)
    }

    /// Writes MEMORY.md from this-mac.md (the old one kept as MEMORY.md.bak-<date>, the last 14). Returns false
    /// when there's no this-mac.md to build from (MEMORY.md is then left alone).
    @discardableResult
    static func rebuildMemory() -> Bool {
        guard let mac = read(thisMac) else { return false }
        let cap = limit("memory_char_limit", 2200, config())
        let r = memoryText(mac, cap: cap)
        let fm = FileManager.default
        try? fm.createDirectory(at: memDir, withIntermediateDirectories: true)
        if let old = read(memoryFile), old != r.text { backup(old) }
        try? r.text.write(to: memoryFile, atomically: true, encoding: .utf8)
        var st = loadState()
        st.hash = hash(r.text)
        st.written = entries(r.text)
        st.rebuilt = Date()
        saveState(st)
        if !r.left.isEmpty { log("rebuild: \(r.left.count) older Always on line(s) didn't fit in \(cap) characters; they stay in this-mac.md") }
        log("rebuild: MEMORY.md = \(st.written.count - 1) line(s) + pointer, \(size(r.text))/\(cap) characters")
        return true
    }

    static func backup(_ old: String) {
        let fm = FileManager.default
        var dest = memDir.appendingPathComponent("MEMORY.md.bak-\(today())")
        if fm.fileExists(atPath: dest.path) {
            if read(dest) == old { return }
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd-HHmmss"
            dest = memDir.appendingPathComponent("MEMORY.md.bak-\(f.string(from: Date()))")
        }
        try? old.write(to: dest, atomically: true, encoding: .utf8)
        let baks = ((try? fm.contentsOfDirectory(atPath: memDir.path)) ?? []).filter { $0.hasPrefix("MEMORY.md.bak-") }.sorted()
        for b in baks.dropLast(14) { try? fm.removeItem(at: memDir.appendingPathComponent(b)) }
    }

    /// At launch: only when the brain has assistant/this-mac.md and MEMORY.md changed since One last wrote it.
    static func atLaunch() {
        guard FileManager.default.fileExists(atPath: thisMac.path) else { return }
        let now = read(memoryFile) ?? ""
        guard hash(now) != loadState().hash else { return }
        fileNew()
        rebuildMemory()
    }

    /// `One --front-page [rebuild|file-new|show]` (the nightly routine runs `file-new` then `rebuild`).
    static func cli(_ args: [String]) -> Int32? {
        guard let k = args.firstIndex(of: "--front-page") else { return nil }
        let what = k + 1 < args.count ? args[k + 1] : "show"
        switch what {
        case "file-new":
            let n = fileNew()
            print(n.isEmpty ? "nothing new in MEMORY.md" : "added to assistant/this-mac.md:\n" + n.map { "- " + $0 }.joined(separator: "\n"))
        case "rebuild":
            guard rebuildMemory() else {
                print("no assistant/this-mac.md in the brain: MEMORY.md left as it is")
                return 1
            }
            print("MEMORY.md rebuilt (\(size(read(memoryFile) ?? ""))/\(limit("memory_char_limit", 2200, config())) characters)")
        case "show":
            for (n, f, key, def) in [("USER.md", userFile, "user_char_limit", 1375), ("MEMORY.md", memoryFile, "memory_char_limit", 2200)] {
                let t = read(f) ?? ""
                print("\(n) (\(size(t))/\(limit(key, def, config())) characters)\n\(t)\n")
            }
        default:
            print("usage: One --front-page [rebuild|file-new|show]")
            return 2
        }
        return 0
    }
}

// MARK: - In the app

@MainActor
extension Model {
    /// USER.md follows Connections: when a password manager, Google, Mail, a connection built together, the engine's
    /// settings, the folders or the setup answers change, it's written again (only if its text changed).
    func tendFrontPage() {
        guard onboarded else { return }
        let d = UserDefaults.standard
        func stamp(_ u: URL) -> String {
            (((try? FileManager.default.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date)?.timeIntervalSince1970).map { "\($0)" } ?? "-"
        }
        let sig = [
            d.string(forKey: "passwordsWith") ?? "", "\(d.bool(forKey: "googleConnected"))", "\(d.bool(forKey: "mailConnected"))",
            stamp(ConnectionsWorld.customFile), stamp(Env.hermesHome.appendingPathComponent("config.yaml")), stamp(FrontPage.howTo),
            Access.folders.joined(separator: ","), connectionsRaw, passwords, userName, assistantName,
        ].joined(separator: "|")
        guard sig != FrontPage.lastSig else { return }
        FrontPage.lastSig = sig
        Persona.writeMemory(assistant: assistantName, user: userName, connections: connections, passwords: passwords)
    }
}
