import Foundation

// MARK: - Which rooms are private: room.yaml decides, in code (storage design 3i)
//
// Each room folder may have a `room.yaml` with `title`, `ai` (the room AI's name) and `private: true|false`.
// Privacy comes from that file, never from a folder name: a private room is never offered for sharing, never in the
// engine's global recipe list, and left out of cross-room answers unless they name it. A local room with no
// room.yaml counts as private (safe default: a room is only ever offered for sharing when room.yaml says
// `private: false`). A shared room is never private: it's already shared.

/// The few keys One reads from `room.yaml`. A tiny hand parser: top-level `key: value` lines, quotes, `#` comments.
struct RoomYaml: Equatable {
    var title: String?
    var ai: String?
    var isPrivate: Bool?

    static let comment =
        "# private: true = never offered for sharing, never in cross-room search, the front page, the morning brief or the global recipe list (One checks this in code)."

    static func parse(_ text: String) -> RoomYaml {
        var y = RoomYaml()
        for raw in text.split(separator: "\n") {
            let line = String(raw)
            guard let first = line.first, first != " ", first != "\t", first != "#", let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let v = value(String(line[line.index(after: colon)...]))
            switch key {
            case "title": y.title = v.isEmpty ? nil : v
            case "ai": y.ai = v.isEmpty ? nil : v
            case "private":
                let b = v.lowercased()
                y.isPrivate = ["true", "yes", "on"].contains(b) ? true : ["false", "no", "off"].contains(b) ? false : nil
            default: continue
            }
        }
        return y
    }

    /// `"quoted # kept"`, `'single'`, or a bare value cut at ` #`.
    static func value(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        if let q = t.first, q == "\"" || q == "'" {
            let rest = t.dropFirst()
            return String(rest.prefix { $0 != q })
        }
        if let r = t.range(of: " #") { return String(t[..<r.lowerBound]).trimmingCharacters(in: .whitespaces) }
        return t
    }

    static func read(_ room: URL) -> RoomYaml? {
        guard let t = try? String(contentsOf: room.appendingPathComponent("room.yaml"), encoding: .utf8) else { return nil }
        return parse(t)
    }

    var text: String {
        func q(_ s: String?) -> String { "\"" + (s ?? "").replacingOccurrences(of: "\"", with: "'") + "\"" }
        return "title: \(q(title))\nai: \(q(ai))\nprivate: \(isPrivate ?? true)\n\(RoomYaml.comment)\n"
    }

    /// Writes room.yaml only when the room has none. True when it wrote one.
    @discardableResult func writeIfMissing(_ room: URL) -> Bool {
        let f = room.appendingPathComponent("room.yaml")
        guard !FileManager.default.fileExists(atPath: f.path) else { return false }
        return (try? text.write(to: f, atomically: true, encoding: .utf8)) != nil
    }
}

enum RoomPrivacy {
    static func isShared(_ room: URL, shared: [String] = Shared.paths) -> Bool {
        let p = room.standardizedFileURL.path
        return LearnedDirs.isShared(p, shared) || p.hasPrefix(Shared.base.standardizedFileURL.path + "/")
    }

    /// Private unless room.yaml says `private: false`. A shared room is never private.
    static func isPrivate(_ room: URL, shared: [String] = Shared.paths) -> Bool {
        if isShared(room, shared: shared) { return false }
        return RoomYaml.read(room)?.isPrivate ?? true
    }

    static func privateRooms(_ rooms: [URL] = RoomMap.roomFolders(), shared: [String] = Shared.paths) -> [URL] {
        rooms.filter { isPrivate($0, shared: shared) }
    }

    /// Local rooms that may be offered for sharing: only those whose room.yaml says `private: false`.
    static func shareable(_ rooms: [URL] = RoomMap.roomFolders(), shared: [String] = Shared.paths) -> [URL] {
        rooms.filter { !isShared($0, shared: shared) && RoomYaml.read($0)?.isPrivate == false }
    }

    static func title(_ room: URL) -> String {
        RoomYaml.read(room)?.title ?? RoomMap.roomTitle(room)
    }

    // MARK: Launch-time migration for brains made before room.yaml

    /// Words that make a room private when it has no room.yaml yet (conservative: in doubt, private).
    static let privateWords = #"(?i)\b(private|intimate|just for me|confidant|fantas\w*|desires?)\b"#
    /// Lines every starter room's AGENTS.md has, which say nothing about this room's own privacy.
    static let boilerplate = ["## Private things", "other people's private information"]

    /// The local room folders (`*-room`) of a brain; shared rooms live elsewhere and are never touched here.
    static func localRooms(_ brain: URL = Brain.root) -> [URL] {
        let items =
            (try? FileManager.default.contentsOfDirectory(at: brain, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? []
        return items.filter {
            let v = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return $0.lastPathComponent.hasSuffix("-room") && v?.isDirectory == true && v?.isSymbolicLink != true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The room's row in the brain's AGENTS.md table: (title, AI name).
    static func row(_ folder: String, brain: URL) -> (String, String)? {
        guard let t = try? String(contentsOf: brain.appendingPathComponent("AGENTS.md"), encoding: .utf8) else { return nil }
        guard let l = t.split(separator: "\n").first(where: { $0.hasPrefix("|") && $0.contains("`\(folder)/`") }) else { return nil }
        let cols = l.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard cols.count > 3 else { return nil }
        return (cols[1], cols[3])
    }

    /// What a room with no room.yaml should say, from its folder name and its AGENTS.md.
    static func guess(_ room: URL, brain: URL) -> RoomYaml {
        let folder = room.lastPathComponent
        var ag = (try? String(contentsOf: room.appendingPathComponent("AGENTS.md"), encoding: .utf8)) ?? ""
        for b in boilerplate { ag = ag.replacingOccurrences(of: b, with: "") }
        let named = folder.replacingOccurrences(of: "-", with: " ")
        let priv =
            ["personal-room", "private-room"].contains(folder) || named.range(of: privateWords, options: .regularExpression) != nil
            || ag.range(of: privateWords, options: .regularExpression) != nil
        let r = row(folder, brain: brain)
        return RoomYaml(title: r?.0 ?? RoomMap.roomTitle(folder), ai: r?.1, isPrivate: priv)
    }

    /// Writes room.yaml into every local room that has none. Never touches a room that has one, or a shared room.
    /// Returns the folders it wrote.
    @discardableResult static func migrate(brain: URL = Brain.root, shared: [String] = Shared.paths) -> [String] {
        var wrote: [String] = []
        for r in localRooms(brain) where !isShared(r, shared: shared) {
            if guess(r, brain: brain).writeIfMissing(r) { wrote.append(r.lastPathComponent) }
        }
        return wrote
    }
}

// MARK: - What the assistant is told (per prompt)

/// A snapshot of the rooms, read off the main thread (the brain is in Documents) and used by the per-prompt notes.
struct RoomFacts: Sendable, Equatable {
    var url: URL
    var title: String
    var ai: String?
    var isPrivate: Bool
    var isShared: Bool
}

extension RoomPrivacy {
    private static let box = RoomBox()

    /// Reads every room's facts now (call off the main thread). Tests call it directly.
    static func refresh(_ rooms: [URL] = RoomMap.roomFolders(), shared: [String] = Shared.paths) {
        let facts = rooms.map { u -> RoomFacts in
            let y = RoomYaml.read(u)
            let s = isShared(u, shared: shared)
            return RoomFacts(url: u, title: y?.title ?? RoomMap.roomTitle(u), ai: y?.ai, isPrivate: !s && (y?.isPrivate ?? true), isShared: s)
        }
        box.set(facts)
    }
    /// At most once a minute, in the background.
    static func refreshSoon() {
        guard box.due() else { return }
        Task.detached { refresh() }
    }
    static var facts: [RoomFacts] { box.get() }

    /// The rooms a conversation names: its folder, its title or its AI's name, as whole words.
    static func named(in text: String, facts: [RoomFacts] = facts) -> [RoomFacts] {
        facts.filter { f in
            var names = [f.url.lastPathComponent, f.title]
            if let a = f.ai, !a.isEmpty { names.append(a) }
            return names.contains { n in
                n.count >= 3
                    && text.range(of: "\\b" + NSRegularExpression.escapedPattern(for: n) + "\\b", options: [.regularExpression, .caseInsensitive])
                        != nil
            }
        }
    }

    /// A private or shared room's recipes stay out of the engine's global list. When a conversation works in one,
    /// it's told where they are. "" when it works in no such room.
    static func recipesNote(_ rooms: [RoomFacts]) -> String {
        var seen = Set<String>()
        let lines = rooms.filter { ($0.isPrivate || $0.isShared) && seen.insert($0.url.path).inserted }.map {
            "this room (\($0.title)) has its own recipes in \($0.url.path)/skills; read them there"
        }
        return lines.isEmpty ? "" : "\n\n(One app note, not from the user: " + lines.joined(separator: "; ") + ".)"
    }

    /// Room folder for a room the router claimed ("personal", "work", "cofounder").
    static func claimed(_ room: String?, facts: [RoomFacts] = facts) -> [RoomFacts] {
        guard let room else { return [] }
        return facts.filter {
            $0.url.lastPathComponent == "\(room)-room" || (room == "cofounder" && $0.isShared && $0.title.lowercased().contains("founder"))
        }
    }

    /// Every conversation: private rooms stay out of cross-room answers unless they name the room.
    static var crossRoomNote: String {
        let p = facts.filter(\.isPrivate).map(\.title)
        guard !p.isEmpty else { return "" }
        return "\n\n(One app note, not from the user: PRIVATE ROOMS: \(p.joined(separator: ", ")). Leave them out of cross-room answers "
            + "(a morning brief, what's due this week, a search across rooms) unless they name that room. Their recipes aren't in your "
            + "skills list; when you work in one, One tells you where they are.)"
    }
}

/// Thread-safe holder for the room snapshot.
final class RoomBox: @unchecked Sendable {
    private let lock = NSLock()
    private var facts: [RoomFacts] = []
    private var at = Date.distantPast
    func set(_ f: [RoomFacts]) {
        lock.lock()
        facts = f
        at = Date()
        lock.unlock()
    }
    func get() -> [RoomFacts] {
        lock.lock()
        defer { lock.unlock() }
        return facts
    }
    func due() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard Date().timeIntervalSince(at) > 60 else { return false }
        at = Date()
        return true
    }
}
