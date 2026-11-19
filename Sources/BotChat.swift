import Foundation

// MARK: - A bot's whole chat, kept in a file (so hundreds of messages never weigh on the saved helpers)

/// UserDefaults `helpers` keeps only a bot's last 40 entries (`Helper.log`, saved on every change). Everything it and
/// the person said is also kept here with its time, one file per bot: `<support>/chat/bots/<bot id>.json` (a JSON
/// list of `{id, me, text, date}`), written off the main thread. A bot from before this existed starts from its
/// `log`, undated ("Earlier"). Only the real One or a test in its own scratch folder reads or writes the files;
/// renders hand their made-up history in through `still`.
enum BotChat {
    static var folder: URL { Env.support.appendingPathComponent("chat/bots", isDirectory: true) }
    static var allowed: Bool { Env.production || Env.selfTest }
    /// The most messages kept per bot (oldest dropped first).
    static let cap = 2_000
    nonisolated(unsafe) static var cache: [UUID: [StarLine]] = [:]
    nonisolated(unsafe) static var still: [UUID: [StarLine]] = [:]  // renders only
    static let queue = DispatchQueue(label: "one.bot-chat", qos: .utility)

    static func url(_ id: UUID) -> URL { folder.appendingPathComponent("\(id.uuidString).json") }

    /// Its messages, oldest first: the file (read once), else its kept log.
    static func lines(_ h: Helper) -> [StarLine] {
        if let s = still[h.id] { return s }
        if let c = cache[h.id] { return c }
        var out: [StarLine] = []
        if allowed, let d = try? Data(contentsOf: url(h.id)), let l = try? JSONDecoder().decode([StarLine].self, from: d) { out = l }
        if out.isEmpty { out = StarPath.lines(log: h.log ?? []) }
        cache[h.id] = out
        return out
    }

    /// A finished turn or a routine report joins its chat (`entry` is a log entry: "**You:** ask\n\nanswer" or an answer).
    static func add(_ h: Helper, entry: String, at: Date = Date()) {
        var all = lines(h)
        let ms = Int(at.timeIntervalSince1970 * 1000)
        for (k, l) in StarPath.lines(log: [entry], at: [at]).enumerated() {
            var l = l
            l.id = "\(ms)-\(l.me ? "me" : "ai")-\(all.count + k)"
            all.append(l)
        }
        all = Array(all.suffix(cap))
        cache[h.id] = all
        save(h.id, all)
    }

    static func save(_ id: UUID, _ all: [StarLine]) {
        guard allowed else { return }
        let dir = folder
        let file = url(id)
        queue.async {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let d = try? JSONEncoder().encode(all) { try? d.write(to: file, options: .atomic) }
        }
    }

    /// A deleted bot's chat goes with it.
    static func remove(_ id: UUID) {
        cache[id] = nil
        guard allowed else { return }
        let file = url(id)
        queue.async { try? FileManager.default.removeItem(at: file) }
    }
    /// Waits for every write (checks only).
    static func flush() { queue.sync {} }
}
