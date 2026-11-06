import Foundation

// MARK: - The whole chat, kept by day (so "all the way back" really goes all the way back)

/// UserDefaults `bubbles` keeps only the last `Model.maxSavedBubbles` messages for a quick start. Everything
/// the person and the assistant said is also kept here, one file per day: `<support>/chat/YYYY-MM-DD.json`
/// (a JSON list of `{me, t, f, d}`, the same shape as the saved bubbles). Only days whose messages changed are
/// rewritten, off the main thread, a moment after the last change. A day file is merged, never shrunk: a
/// message already in it stays even after it has left the in-memory list.
///
/// Only the real One (or a test inside its own scratch folder) reads or writes these files. Renders from a
/// test copy see an empty archive, so made-up messages never reach the person's real chat.
enum ChatArchive {
    static var folder: URL { Env.support.appendingPathComponent("chat", isDirectory: true) }
    /// The real One, or a test working in its own scratch folder. Never a render or a command-line mode.
    static var allowed: Bool { Env.production || Env.selfTest }

    /// A message's lasting name inside its day: when it was said (to the millisecond) and who said it.
    static func key(_ d: [String: Any]) -> String {
        "\(Int(((d["d"] as? Double) ?? 0) * 1000))-\((d["me"] as? Bool) == true ? "me" : "ai")"
    }
    static func dict(_ b: Bubble) -> [String: Any] {
        ["me": b.fromMe, "t": b.text, "f": b.followUps, "d": b.date.timeIntervalSince1970]
    }
    static func bubble(_ d: [String: Any]) -> Bubble? {
        guard let t = d["t"] as? String, !t.isEmpty else { return nil }
        return Bubble(
            fromMe: d["me"] as? Bool ?? false, text: t,
            date: (d["d"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date(), followUps: d["f"] as? [String] ?? [])
    }

    static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // MARK: Writing

    nonisolated(unsafe) static var lastWritten: [String: Int] = [:]  // day -> hash of what was last written
    nonisolated(unsafe) static var pending: [Bubble]?
    static let queue = DispatchQueue(label: "one.chat-archive", qos: .utility)

    /// Called with the whole in-memory chat after every save. Coalesced: writes about a second after the last call.
    static func keep(_ bubbles: [Bubble]) {
        guard allowed else { return }
        let snapshot = bubbles.filter { !$0.text.isEmpty }
        queue.async {
            let first = pending == nil
            pending = snapshot
            guard first else { return }
            queue.asyncAfter(deadline: .now() + 1.0) {
                if let b = pending { write(b) }
                pending = nil
            }
        }
    }

    /// Writes every day of `bubbles` that changed since it was last written (merged with what the file holds).
    static func write(_ bubbles: [Bubble]) {
        var byDay: [String: [Bubble]] = [:]
        for b in bubbles { byDay[day.string(from: b.date), default: []].append(b) }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (d, bs) in byDay {
            var h = Hasher()
            for b in bs {
                h.combine(b.text)
                h.combine(b.date)
                h.combine(b.fromMe)
            }
            let hash = h.finalize()
            if lastWritten[d] == hash { continue }
            let url = folder.appendingPathComponent("\(d).json")
            var merged: [String: [String: Any]] = [:]
            for e in read(url) { merged[key(e)] = e }
            for b in bs { merged[key(dict(b))] = dict(b) }  // the in-memory copy wins (a reply may have grown)
            let list = merged.values.sorted { ($0["d"] as? Double ?? 0) < ($1["d"] as? Double ?? 0) }
            if let data = try? JSONSerialization.data(withJSONObject: list) {
                try? data.write(to: url, options: .atomic)
                lastWritten[d] = hash
            }
        }
    }

    static func read(_ url: URL) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
    }

    // MARK: Reading

    /// Every kept day, oldest first ("2026-11-04").
    static func days() -> [String] {
        guard allowed else { return [] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.filter { day.date(from: $0) != nil }.sorted()
    }

    /// Every kept message said before `date`, oldest first. Read off the main thread: months of chat is a few MB.
    static func before(_ date: Date) -> [Bubble] {
        let last = day.string(from: date)
        var out: [Bubble] = []
        for d in days() where d <= last {
            out += read(folder.appendingPathComponent("\(d).json")).compactMap(bubble).filter { $0.date < date }
        }
        return out.sorted { $0.date < $1.date }
    }
}
