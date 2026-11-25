import Foundation

// MARK: - The room is a bot's only source of truth (Omar, Nov 25 2026: "never a discrepancy between bots and rooms")
// Facts, decisions and results live in the bot's room: its daily `memory/<date>.md` and its notes. A line that
// belongs to one bot starts with its tag, `- [Ascend] Decided: …` (the tag is the bot's name, from its card's title).
// The bot's own `memory.md` keeps only how it works: `## Rules` and a short `## Working state`; its old log sits under
// `## Archive …` and is never read into its turns. So a bot starts from the same truth as the room, and writes new
// facts back to the room with its tag.

enum BotRoom {
    struct Line: Equatable {
        let day: String  // "2026-11-25" for a memory day, "" for a line in the room's notes
        let text: String  // the line as written, trimmed ("- [Ascend] Decided: X")
        let file: String  // where it is, from the room's folder ("memory/2026-11-25.md")
    }
    /// How many recent days of the room's memory a bot's start context reads.
    static let days = 14
    /// At most this many lines go into a turn (the newest win).
    static let cap = 60

    /// "[Ascend]": the bot's name as its card's title says it (`# Ascend`), else its saved name.
    static func tag(_ b: BotInfo) -> String {
        let first = (try? String(contentsOf: Bots.card(b), encoding: .utf8))?.split(separator: "\n", maxSplits: 1).first.map(String.init)
        if let t = first, t.hasPrefix("# ") {
            let n = t.dropFirst(2).trimmingCharacters(in: .whitespaces)
            if !n.isEmpty { return "[\(n)]" }
        }
        return "[\(b.name)]"
    }
    /// Its tag and the tags of its earlier names (a renamed bot's older room lines are still its).
    static func tags(_ b: BotInfo) -> [String] {
        var out = [tag(b)]
        for n in b.was ?? [] where !out.contains(where: { $0.lowercased() == "[\(n)]".lowercased() }) { out.append("[\(n)]") }
        return out
    }
    static func room(_ b: BotInfo) -> URL { URL(fileURLWithPath: b.roomPath, isDirectory: true) }
    /// The room's memory file for a day: `<room>/memory/<yyyy-MM-dd>.md`.
    static func memoryFile(_ b: BotInfo, now: Date = Date()) -> URL {
        room(b).appendingPathComponent("memory/\(Bots.today(now)).md")
    }

    /// A line is the bot's when, after its bullet, it starts with one of its tags (any case). A mention later on
    /// doesn't count.
    static func tagged(_ raw: String, tags: [String]) -> String? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        var body = Substring(t)
        for bullet in ["- ", "* ", "+ "] where body.hasPrefix(bullet) {
            body = body.dropFirst(bullet.count)
            break
        }
        let low = body.lowercased()
        guard tags.contains(where: { low.hasPrefix($0.lowercased()) }) else { return nil }
        return t
    }

    /// The room's lines tagged with this bot: the last `days` days of `memory/` (oldest first), then the room's notes
    /// (`vault/`; `notes: false` skips them, for screens that redraw). Never a `confidential/` folder (BrainIndex.files
    /// leaves it out).
    static func lines(_ b: BotInfo, now: Date = Date(), notes: Bool = true) -> [Line] {
        let tags = tags(b)
        let base = room(b)
        let fm = FileManager.default
        var out: [Line] = []
        let oldest = Bots.today(Calendar.current.date(byAdding: .day, value: -(days - 1), to: now) ?? now)
        let newest = Bots.today(now)
        let mem = base.appendingPathComponent("memory", isDirectory: true)
        let names = ((try? fm.contentsOfDirectory(atPath: mem.path)) ?? []).filter { $0.hasSuffix(".md") }.sorted()
        for name in names {
            let day = String(name.prefix(10))
            guard day.count == 10, day.first?.isNumber == true, day >= oldest, day <= newest,
                let t = try? String(contentsOf: mem.appendingPathComponent(name), encoding: .utf8)
            else { continue }
            for raw in t.components(separatedBy: "\n") {
                if let l = tagged(raw, tags: tags) { out.append(Line(day: day, text: l, file: "memory/\(name)")) }
            }
        }
        guard notes else { return out }
        let vault = base.appendingPathComponent("vault", isDirectory: true)
        for f in BrainIndex.files(in: vault).sorted(by: { $0.rel < $1.rel }) {
            guard let t = try? String(contentsOf: f.url, encoding: .utf8), tags.contains(where: { t.localizedCaseInsensitiveContains($0) })
            else { continue }
            for raw in t.components(separatedBy: "\n") {
                if let l = tagged(raw, tags: tags) { out.append(Line(day: "", text: l, file: "vault/\(f.rel)")) }
            }
        }
        return out
    }

    /// Its memory file's `## Rules` and `## Working state` sections, as written. Nothing under any other heading
    /// (the archived log, old day headings).
    static func howItWorks(_ b: BotInfo) -> String {
        guard let t = try? String(contentsOf: Bots.memory(b), encoding: .utf8) else { return "" }
        var keep: [String] = []
        var on = false
        for raw in t.components(separatedBy: "\n") {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("## ") {
                let h = l.dropFirst(3).lowercased()
                on = h.hasPrefix("rules") || h.hasPrefix("working state")
            } else if l.hasPrefix("# ") {
                on = false
            }
            if on, !l.isEmpty { keep.append(raw) }
        }
        return keep.joined(separator: "\n")
    }

    /// What the bot is told about its room on its turns: its rules and working state, the room's lines tagged with
    /// it, and where new facts go. Changes when the room does, so the notes go again then (NoteCache).
    static func context(_ b: BotInfo, now: Date = Date()) -> String {
        let tag = tag(b)
        let found = lines(b, now: now)
        let shown = found.suffix(cap).map { l in l.day.isEmpty ? "\(l.text) (\(l.file))" : "\(l.day): \(l.text)" }
        let how = howItWorks(b)
        var s = "The room is your only source of truth. "
        s +=
            "Your own file \(Bots.memory(b).path) holds only how you work (its ## Rules and a short ## Working state; anything under ## Archive is an old log you never edit)."
        if !how.isEmpty { s += " Right now it says:\n\(how)\n" }
        if shown.isEmpty {
            s += " The room has no lines tagged \(tag) yet."
        } else {
            let which = found.count > cap ? "the newest \(cap) of \(found.count)" : "all \(found.count)"
            s += " What the room says about your job (its lines tagged \(tag), oldest first; \(which)):\n" + shown.joined(separator: "\n") + "\n"
        }
        s +=
            " Write every new fact, decision or result as one line starting \"- \(tag) \" (Done:, Decided:, Learned:, Owe: or Open:) at the end of \(memoryFile(b, now: now).path) (make it with a \"# \(Bots.today(now))\" heading if it's missing; add only, never change an earlier line), never in \(Bots.memory(b).path). There, change only your Working state lines and add a lasting rule they give you under ## Rules."
        return s
    }

    /// A new fact from the bot, in the room with its tag: one line at the end of today's room memory file.
    static func record(_ b: BotInfo, _ fact: String, now: Date = Date()) {
        let f = fact.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        guard !f.isEmpty else { return }
        let tag = tag(b)
        let line = "- " + (f.lowercased().hasPrefix(tag.lowercased()) ? f : "\(tag) \(f)")
        let url = memoryFile(b, now: now)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var t = (try? String(contentsOf: url, encoding: .utf8)) ?? "# \(Bots.today(now))\n\n"
        if !t.isEmpty, !t.hasSuffix("\n") { t += "\n" }
        t += line + "\n"
        try? t.write(to: url, atomically: true, encoding: .utf8)
    }

    /// What it did, newest last: the first tagged room line of each of the last few days. Nil when the room has none
    /// yet, so a bot from before still shows its old log.
    static func days(_ b: BotInfo, max n: Int = 4, now: Date = Date()) -> [(day: String, what: String)]? {
        let tags = tags(b)
        var out: [(String, String)] = []
        var seen = Set<String>()
        for l in lines(b, now: now, notes: false) where !l.day.isEmpty && !seen.contains(l.day) {
            seen.insert(l.day)
            var what = Substring(l.text)
            if what.hasPrefix("- ") { what = what.dropFirst(2) }
            if let t = tags.first(where: { what.lowercased().hasPrefix($0.lowercased()) }) { what = what.dropFirst(t.count) }
            out.append((Bots.dayWord(l.day, now: now), what.trimmingCharacters(in: .whitespaces)))
        }
        return out.isEmpty ? nil : Array(out.suffix(n))
    }
}
