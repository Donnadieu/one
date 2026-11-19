import Foundation

// MARK: - Star path chat (Claude Design "Chosen Star path with summary", picked by Omar Nov 19 2026)
// One chat look for a bot, the assistant and a helper: the speaker's words hang off a faint thread in its colour
// (a small star each, its orb and name at the start of a run), the person's words sit on the right in a cream
// capsule. Every past day folds into one day star ("Mon Nov 16 · 7 messages · Back to the goal"), long replies show
// 3 lines then "Read all", a day dial on the right jumps to any day, and search lights the days and messages that
// match. A summary card on top (folded to one line) says what it did and what's waiting on you.
// This file is the pure part (no views), so `--test-star-chat` can check it line by line.

/// One message in a star path chat.
struct StarLine: Identifiable, Equatable, Codable {
    var id: String
    var me: Bool
    var text: String
    var date: Date?
}

/// A day of a chat: its messages, how it's named, and the one line its folded star shows.
struct StarDay: Identifiable, Equatable {
    let id: String  // "2026-11-16"; "earlier" for messages kept from before dates were saved
    let label: String  // Today, Yesterday, Mon Nov 16, Earlier
    let lines: [StarLine]
    let title: String
    var count: Int { lines.count }
}

/// Who is speaking in this chat, and in which colour.
struct StarSpeaker: Equatable {
    enum Kind: Equatable { case assistant, bot, helper }
    let name: String
    let hex: UInt32
    let kind: Kind
    static let cream: UInt32 = 0xF4EFE8
    static let helperTint: UInt32 = 0xD9C7B0
    static func assistant(_ name: String) -> StarSpeaker { StarSpeaker(name: name, hex: cream, kind: .assistant) }
    static func of(_ h: Helper) -> StarSpeaker {
        if let b = h.bot { return StarSpeaker(name: b.name, hex: Bots.hex(b.color), kind: .bot) }
        return StarSpeaker(name: h.title, hex: helperTint, kind: .helper)
    }
}

enum StarPath {
    static let you = "**You:** "

    /// A helper's or bot's kept log ("**You:** ask\n\nanswer", or an answer alone) as messages, oldest first.
    static func lines(log: [String], at dates: [Date?] = []) -> [StarLine] {
        var out: [StarLine] = []
        for (i, e) in log.enumerated() {
            let d = i < dates.count ? dates[i] : nil
            let stamp = d.map { "\(Int($0.timeIntervalSince1970 * 1000))" } ?? "e\(i)"
            if e.hasPrefix(you), let cut = e.range(of: "\n\n") {
                let ask = String(e[e.index(e.startIndex, offsetBy: you.count)..<cut.lowerBound])
                out.append(StarLine(id: "\(stamp)-me-\(i)", me: true, text: ask, date: d))
                out.append(StarLine(id: "\(stamp)-ai-\(i)", me: false, text: String(e[cut.upperBound...]), date: d))
            } else {
                out.append(StarLine(id: "\(stamp)-ai-\(i)", me: false, text: e, date: d))
            }
        }
        return out
    }

    static let dayKey: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    static let dayName: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "EEE MMM d"
        return f
    }()
    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "h:mm"
        return f
    }()

    /// Today, Yesterday, or "Mon Nov 16".
    static func label(_ d: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDate(d, inSameDayAs: now) { return "Today" }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: y) { return "Yesterday" }
        return dayName.string(from: d)
    }

    /// Messages by day, oldest first. Undated messages (kept from before dates were saved) come first, as "Earlier".
    static func days(_ lines: [StarLine], now: Date = Date()) -> [StarDay] {
        var order: [String] = []
        var by: [String: [StarLine]] = [:]
        var names: [String: String] = [:]
        for l in lines {
            let k = l.date.map { dayKey.string(from: $0) } ?? "earlier"
            if by[k] == nil {
                order.append(k)
                names[k] = l.date.map { label($0, now: now) } ?? "Earlier"
            }
            by[k, default: []].append(l)
        }
        let sorted = order.sorted { a, b in a == "earlier" ? b != "earlier" : (b == "earlier" ? false : a < b) }
        return sorted.map { k in StarDay(id: k, label: names[k] ?? k, lines: by[k] ?? [], title: title(by[k] ?? [])) }
    }

    /// The one line a folded day shows: what they asked first that day, else how its first reply starts.
    static func title(_ lines: [StarLine]) -> String {
        let pick = lines.first(where: \.me) ?? lines.first
        return short(pick?.text ?? "", 56)
    }

    /// The first line of `t` in plain words, at most `n` characters.
    static func short(_ t: String, _ n: Int) -> String {
        let first =
            t.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        let plain = first.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "#", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " -*>"))
        return plain.count > n ? String(plain.prefix(n - 1)).trimmingCharacters(in: .whitespaces) + "…" : plain
    }

    /// Only the newest day is open when a chat opens; every earlier day is one folded star.
    static func openByDefault(_ days: [StarDay]) -> Set<String> { days.last.map { [$0.id] } ?? [] }

    /// A reply longer than this many lines shows its first `keep` lines, then "Read all".
    static let foldOver = 6
    static let keep = 3
    static func folds(_ t: String) -> Bool { LongFold.lines(t) > foldOver }
    /// What a folded reply hands to the text view: its first lines only (a long report never lays out whole).
    static func head(_ t: String) -> String {
        let ls = t.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").prefix(keep + 2)
        let h = ls.joined(separator: "\n")
        return h.count > 420 ? String(h.prefix(420)) : h
    }

    /// Lowercased, without accents ("Germán" is found by "german").
    static func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }

    /// The messages that match `q`, oldest first (ids). Empty when `q` is under 2 characters.
    static func matches(_ lines: [StarLine], _ q: String) -> [String] {
        let w = fold(q.trimmingCharacters(in: .whitespaces))
        guard w.count >= 2 else { return [] }
        return lines.filter { fold($0.text.replacingOccurrences(of: "**", with: "")).contains(w) }.map(\.id)
    }

    /// Matches per day id.
    static func dayMatches(_ days: [StarDay], _ hits: [String]) -> [String: Int] {
        let set = Set(hits)
        var out: [String: Int] = [:]
        for d in days {
            let n = d.lines.filter { set.contains($0.id) }.count
            if n > 0 { out[d.id] = n }
        }
        return out
    }

    /// "8 messages · 4 days"
    static func found(_ hits: Int, days: Int) -> String {
        hits == 0 ? "Nothing found" : "\(hits) message\(hits == 1 ? "" : "s") · \(days) day\(days == 1 ? "" : "s")"
    }

    /// A day's dot on the dial: bigger for busier days, 5 to 11 points.
    static func dot(_ count: Int, max top: Int) -> Double {
        guard top > 0 else { return 5 }
        return 5 + 6 * min(1, Double(count) / Double(top))
    }

    /// "66 messages since Nov 6"
    static func since(_ lines: [StarLine]) -> String {
        let n = lines.count
        guard n > 0 else { return "No messages yet" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "MMM d"
        let first = lines.compactMap(\.date).first
        return "\(n) message\(n == 1 ? "" : "s")" + (first.map { " since " + f.string(from: $0) } ?? "")
    }
}

/// The card on top of a chat: what it did and what's waiting on you. Folded to one line until tapped.
struct StarSummary: Equatable {
    struct Done: Equatable {
        let when: String
        let what: String
    }
    struct Wait: Equatable {
        let what: String
        var choices: [String] = []
        var helper: UUID?  // the assistant's card: tapping it opens that helper
    }
    let didTitle: String
    let waitTitle: String
    var did: [Done] = []
    var waiting: [Wait] = []
    var isEmpty: Bool { did.isEmpty && waiting.isEmpty }

    /// A bot: the last days of its memory, and the question its newest reply asks.
    static func bot(_ h: Helper, days: [(day: String, what: String)], steps: [String] = []) -> StarSummary {
        var s = StarSummary(didTitle: "What I did", waitTitle: "Waiting on you")
        s.did = days.suffix(3).map { Done(when: $0.day, what: $0.what) }
        s.waiting = asking(h) + steps.map { Wait(what: $0) }
        return s
    }
    /// A helper: how its findings start, and what it needs from you.
    static func helper(_ h: Helper) -> StarSummary {
        var s = StarSummary(didTitle: "What I found", waitTitle: "What I need from you")
        let found = Choices.split(Helpers.strip(h.reply)).body
        if !found.isEmpty, h.state != "working" {
            s.did = [Done(when: h.started.map { StarPath.label($0) } ?? "Today", what: StarPath.short(found, 90))]
        }
        s.waiting = asking(h)
        return s
    }
    /// The assistant: helpers it finished today, and everything waiting on you.
    static func assistant(_ helpers: [Helper], asks: [String], now: Date = Date()) -> StarSummary {
        var s = StarSummary(didTitle: "What I did today", waitTitle: "Waiting on you")
        let cal = Calendar.current
        let jobs = helpers.filter { $0.bot == nil }
        s.did = jobs.filter { $0.state == "done" && $0.started.map { cal.isDate($0, inSameDayAs: now) } == true }.suffix(3)
            .map { Done(when: "Today", what: $0.title) }
        s.waiting =
            asks.map { Wait(what: $0) } + jobs.filter { $0.state == "needsYes" }.map { Wait(what: "\($0.title) needs your yes", helper: $0.id) }
        return s
    }
    static func asking(_ h: Helper) -> [Wait] {
        guard h.state == "needsYes" else { return [] }
        let parts = Choices.split(Helpers.strip(h.reply))
        let lines = parts.body.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let ask = lines.last { $0.hasSuffix("?") } ?? lines.last ?? "Needs your yes"
        return [Wait(what: StarPath.short(ask, 80), choices: parts.choices)]
    }
}
