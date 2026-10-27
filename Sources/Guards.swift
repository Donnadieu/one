import Foundation

// MARK: - Guards: safety rules enforced by One's code, not by asking the assistant nicely.

/// Shared rooms: a new file you (or your assistant) add to a shared room is held back if it copies
/// text from your private rooms. It moves to One's own folder (never synced) and you're told.
enum SharedGuard {
    static var heldDir: URL { Env.support.appendingPathComponent("held", isDirectory: true) }
    static var seenFile: URL { Env.support.appendingPathComponent("shared-guard-seen.json") }
    /// Lines shorter than this are too common ("## Notes", dates) to mean anything was copied.
    static let minLine = 40

    static func normalize(_ line: String) -> String {
        line.lowercased().components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-*#>• "))
    }

    /// Fingerprints of every meaningful line in the private (not shared) rooms.
    static func privateLines() -> Set<String> {
        let shared = Set(Shared.paths)
        var out = Set<String>()
        for room in RoomMap.roomFolders() where !shared.contains(room.path) {
            guard let en = FileManager.default.enumerator(at: room, includingPropertiesForKeys: nil) else { continue }
            for case let f as URL in en {
                if RoomMap.skipDirs.contains(f.lastPathComponent) {
                    en.skipDescendants()
                    continue
                }
                guard f.pathExtension == "md", let t = try? String(contentsOf: f, encoding: .utf8) else { continue }
                for l in t.split(separator: "\n") {
                    let n = normalize(String(l))
                    if n.count >= minLine { out.insert(n) }
                }
            }
        }
        return out
    }

    /// Lines of `text` that also appear in a private room.
    static func copied(_ text: String, from priv: Set<String>) -> [String] {
        text.split(separator: "\n").map { normalize(String($0)) }.filter { $0.count >= minLine && priv.contains($0) }
    }

    static func loadSeen() -> Set<String>? {
        guard let d = try? Data(contentsOf: seenFile) else { return nil }
        return (try? JSONDecoder().decode([String].self, from: d)).map(Set.init)
    }
    static func saveSeen(_ s: Set<String>) {
        try? JSONEncoder().encode(s.sorted()).write(to: seenFile, options: .atomic)
    }

    /// Checks files added to shared rooms since last time. Returns plain-words notes for each file held back.
    static func tend() -> [String] {
        let fm = FileManager.default
        var files: [URL] = []
        for p in Shared.paths {
            guard let en = fm.enumerator(at: URL(fileURLWithPath: p), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for case let f as URL in en where f.pathExtension == "md" { files.append(f) }
        }
        let all = Set(files.map(\.path))
        guard var seen = loadSeen() else {
            saveSeen(all)  // first run: what's already shared stays as it is
            _ = changedSkills(files, seen: all)
            return []
        }
        // A skill in a shared room that was CHANGED (not only added) is checked too: any chat that finds a skill can edit it.
        let fresh = files.filter { !seen.contains($0.path) } + changedSkills(files, seen: seen)
        guard !fresh.isEmpty else { return [] }
        let priv = privateLines()
        var notes: [String] = []
        for f in fresh {
            seen.insert(f.path)
            // Moved back out of the held folder on purpose ("share it anyway"): let it through.
            let room0 = f.pathComponents.first { c in Shared.paths.contains { $0.hasSuffix("/" + c) } } ?? "shared room"
            if released(f, room0) { continue }
            guard let t = try? String(contentsOf: f, encoding: .utf8), byMe(t, f) else { continue }
            let hits = copied(t, from: priv)
            guard !hits.isEmpty else { continue }
            let room = f.pathComponents.first { c in Shared.paths.contains { $0.hasSuffix("/" + c) } } ?? "shared room"
            let dest = heldDir.appendingPathComponent(room, isDirectory: true)
            try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
            let target = dest.appendingPathComponent(f.lastPathComponent)
            try? fm.removeItem(at: target)
            if (try? fm.moveItem(at: f, to: target)) != nil {
                markHeld(f, room)
                notes.append(
                    "I held back \"\(f.deletingPathExtension().lastPathComponent)\" from \(room): it copies \(hits.count) line\(hits.count == 1 ? "" : "s") from your private rooms, so the others can't see it. Say \"share it anyway\" if that's fine."
                )
                seen.remove(f.path)
            }
        }
        saveSeen(seen.intersection(all).union(fresh.map(\.path)))
        return notes
    }

    static var skillStampsFile: URL { Env.support.appendingPathComponent("shared-guard-skills.json") }
    /// Skill files under a shared room's skills/ that changed since last time (new ones are already "fresh").
    static func changedSkills(_ files: [URL], seen: Set<String>) -> [URL] {
        let old = (try? JSONDecoder().decode([String: Double].self, from: Data(contentsOf: skillStampsFile))) ?? [:]
        var now: [String: Double] = [:]
        var changed: [URL] = []
        for f in files where f.path.contains("/skills/") {
            let t = ((try? FileManager.default.attributesOfItem(atPath: f.path))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            now[f.path] = t
            if seen.contains(f.path), let o = old[f.path], o != t { changed.append(f) }
        }
        try? JSONEncoder().encode(now).write(to: skillStampsFile, options: .atomic)
        return changed
    }

    static var heldList: URL { heldDir.appendingPathComponent(".held.json") }
    static func heldPaths() -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: heldList))) ?? [:]
    }
    static func markHeld(_ f: URL, _ room: String) {
        var h = heldPaths()
        h[f.path] = room
        try? JSONEncoder().encode(h).write(to: heldList, options: .atomic)
    }
    /// True if this file was held before and its held copy is gone, i.e. it was put back on purpose.
    static func released(_ f: URL, _ room: String) -> Bool {
        var h = heldPaths()
        guard h[f.path] != nil else { return false }
        let copy = heldDir.appendingPathComponent(room, isDirectory: true).appendingPathComponent(f.lastPathComponent)
        guard !FileManager.default.fileExists(atPath: copy.path) else { return false }
        h.removeValue(forKey: f.path)
        try? JSONEncoder().encode(h).write(to: heldList, options: .atomic)
        return true
    }

    /// Only your own additions are checked; files the other members wrote are theirs to share.
    static func byMe(_ text: String, _ f: URL) -> Bool {
        let me = Shared.me.lowercased()
        let head = text.prefix(400).lowercased()
        return head.contains("by \(me)") || f.lastPathComponent.lowercased().contains(" \(me) - ") || !head.contains("by ")
    }

    /// Told to the assistant when something is waiting in the held folder.
    static var note: String {
        let items = (try? FileManager.default.subpathsOfDirectory(atPath: heldDir.path))?.filter { $0.hasSuffix(".md") } ?? []
        guard !items.isEmpty else { return "" }
        return
            "\n\n(One app note: these files were held back from shared rooms because they copy private notes; they are in \(heldDir.path): \(items.joined(separator: "; ")). Only if the user clearly says to share one anyway, move it back into that shared room's entries/ folder.)"
    }
}

/// Experimental connections ("Something else…"): a skill the assistant built stays switched off in
/// the engine until its test passed and it's listed with a test date in connections.json.
enum ExperimentalGuard {
    static var dir: URL { Env.hermesHome.appendingPathComponent("skills/my-connections", isDirectory: true) }

    /// Skill names the engine should not load.
    static func untested() -> [String] {
        let tested = Set(ConnectionsWorld.custom().filter { ($0.tested ?? "").count >= 8 }.compactMap(\.skill))
        let dirs = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.filter { !$0.hasPrefix(".") } ?? []
        var off: [String] = []
        for d in dirs.sorted() where !tested.contains("my-connections/\(d)") && !tested.contains(d) {
            off.append("my-connections/\(d)")
            off.append(d)
            if let t = try? String(contentsOf: dir.appendingPathComponent("\(d)/SKILL.md"), encoding: .utf8),
                let line = t.split(separator: "\n").first(where: { $0.hasPrefix("name:") })
            {
                let n = line.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                if !n.isEmpty && !off.contains(n) { off.append(n) }
            }
        }
        return off
    }

    /// Writes `skills.disabled` when the set changed. Returns the list now switched off.
    @discardableResult
    static func sync() async -> [String] {
        let off = untested()
        let key = Env.selfTest ? "experimentalOffTest" : "experimentalOff"
        if UserDefaults.standard.stringArray(forKey: key) == off { return off }
        let yaml = "[" + off.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
        let (code, _) = await hermesRun(["config", "set", "skills.disabled", yaml, "--force"])
        if code == 0 { UserDefaults.standard.set(off, forKey: key) }
        return off
    }
}

/// "That annoyed me": every complaint goes to a list that gets fixed weekly.
enum FrictionLog {
    static var file: URL { Env.support.appendingPathComponent("friction-log.md") }
    static let triggers = ["annoyed me", "that's annoying", "that is annoying", "so annoying", "friction:", "this is frustrating"]

    static func matches(_ text: String) -> Bool {
        let t = text.lowercased()
        return triggers.contains { t.contains($0) }
    }

    /// Appends the complaint and what the assistant last said, so the fix has context.
    static func add(_ text: String, context: String) {
        let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withTime, .withColonSeparatorInTime])
        let ctx = context.split(separator: "\n").prefix(3).joined(separator: " ").prefix(240)
        let entry = "- \(day) | \(text.replacingOccurrences(of: "\n", with: " ")) | after: \(ctx)\n"
        if !FileManager.default.fileExists(atPath: file.path) {
            try? "# Friction log\n\nEvery time something in One annoyed you. Fixed weekly.\n\n".write(to: file, atomically: true, encoding: .utf8)
        }
        if let h = try? FileHandle(forWritingTo: file) {
            h.seekToEndOfFile()
            h.write(Data(entry.utf8))
            try? h.close()
        }
    }
}
