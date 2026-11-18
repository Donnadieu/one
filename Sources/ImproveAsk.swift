import Foundation

// MARK: - The nightly review's one question reaches the person, and their answer does something
// Before (Nov 5 to 18 2026): the review's "ask" sat in its own routine chat and in the weekday morning brief. The
// Saturday and Sunday asks were never shown anywhere, the same Ledger ask went out 4 times, and Omar's "Yes, fix it"
// on Nov 10 reached the main chat with nothing to tie it to ("I'm not sure what 'fix it' points to").
// Now: the morning after (7 AM or later, any day) the ask shows in the main chat with Yes / Not now, and goes to the
// phone chat too. Yes sends a helper with the ask's own job. Not now holds that topic for 7 days. An ask is shown
// once, and the review is told every ask it already made, so it never repeats one (ImproveSeen.swift).

struct NightAsk: Codable, Equatable {
    var key: String
    var date: String  // the night that asked
    var text: String
    var title: String
    var job: String
    var shown: Double?
    var phone: Bool?
    var answer: String?  // "yes" | "no"
    var answeredAt: Double?
    var via: String?  // "chat" | "phone" | "helper"
}

enum ImproveAsk {
    static var file: URL { Improve.dir.appendingPathComponent("asks.json") }
    static let yes = "Yes"
    static let no = "Not now"
    static let holdDays = 7.0

    static func all() -> [NightAsk] {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([NightAsk].self, from: $0) } ?? []
    }
    static func save(_ a: [NightAsk]) {
        try? FileManager.default.createDirectory(at: Improve.dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(a).write(to: file, options: .atomic)
    }

    /// A short key for an ask the review wrote without one.
    static func key(for text: String) -> String {
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }.filter { $0.count > 3 }.prefix(5).map(String.init)
        return words.isEmpty ? "ask" : words.joined(separator: "-")
    }

    /// The ask in a night's review file, if any.
    static func fromReview(_ date: String) -> NightAsk? {
        guard let d = try? Data(contentsOf: ImproveNight.reviewFile(date)),
            let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let a = j["ask"] as? [String: Any],
            let text = (a["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return nil }
        let key = (a["key"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? key(for: text)
        let title = (a["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Nightly review: \(Improve.short(text, 28))"
        let job = (a["job"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Omar said yes to this from One's nightly review: \(text)"
        return NightAsk(key: key, date: date, text: text, title: title, job: job)
    }

    /// Whether this topic may be asked now: never after a yes, not within 7 days of a "not now", never twice unanswered.
    static func allowed(_ key: String, _ list: [NightAsk], now: Date) -> Bool {
        for a in list where a.key == key {
            if a.answer == "yes" { return false }
            if a.answer == "no", now.timeIntervalSince1970 - (a.answeredAt ?? 0) < holdDays * 86400 { return false }
            if a.answer == nil { return false }  // already asked and not answered: asked once is enough
        }
        return true
    }

    /// The ask to show now (the morning after, from 7 AM), or nil.
    static func due(now: Date) -> NightAsk? {
        guard Calendar.current.component(.hour, from: now) >= 7 else { return nil }
        let list = all()
        for back in 0...1 {
            guard let d = Calendar.current.date(byAdding: .day, value: -back, to: now) else { continue }
            let date = Improve.dayKey(d)
            guard let a = fromReview(date), !list.contains(where: { $0.date == date && $0.key == a.key }) else { continue }
            if allowed(a.key, list, now: now) { return a }
        }
        return nil
    }

    /// Records that `a` is on screen (and on the phone when `phone`).
    static func markShown(_ a: NightAsk, phone: Bool, now: Date) {
        var list = all()
        var x = a
        x.shown = now.timeIntervalSince1970
        x.phone = phone
        list.removeAll { $0.key == a.key && $0.answer == nil }
        list.append(x)
        save(list)
    }

    /// The ask waiting on an answer, if any. One left unanswered for 3 days lapses (and is never asked again).
    static func open(now: Date = Date()) -> NightAsk? {
        all().last { $0.answer == nil && ($0.shown.map { now.timeIntervalSince1970 - $0 < 3 * 86400 } ?? false) }
    }

    /// Records an answer to the open ask. Returns it, or nil when nothing was waiting.
    @discardableResult static func answer(_ yes: Bool, via: String, now: Date = Date()) -> NightAsk? {
        var list = all()
        guard let o = open(now: now), let k = list.lastIndex(where: { $0.key == o.key && $0.date == o.date }) else { return nil }
        list[k].answer = yes ? "yes" : "no"
        list[k].answeredAt = now.timeIntervalSince1970
        list[k].via = via
        save(list)
        return list[k]
    }

    /// The helper line a yes sends.
    static func helperLine(_ a: NightAsk) -> String { "[helper: \(a.title) | \(a.job)]" }

    /// What the main chat is told on every prompt while an ask waits (so a typed "yes" works too).
    static var mainNote: String {
        guard let a = open() else { return "" }
        return "\n\n(One app note, not from the user: ONE'S NIGHTLY REVIEW ASKED THEM in this chat: \"\(a.text)\" with Yes / Not now. "
            + "If their message answers it with a yes, send exactly this helper line: \(helperLine(a)) and run `\"\(Bridge.exe)\" --improve ask yes`. "
            + "If it's a no or not now, run `\"\(Bridge.exe)\" --improve ask no`. Otherwise leave it.)"
    }
    /// The same for the phone chat (PhoneTags' news file).
    static var phoneNote: String {
        guard let a = open(), a.phone == true else { return "" }
        return "\nWaiting on their yes, from One's nightly review: \"\(a.text)\". If they say yes, send exactly: \(helperLine(a)) "
            + "and run `\"\(Bridge.exe)\" --improve ask yes`; if not now, run `\"\(Bridge.exe)\" --improve ask no`."
    }

    /// For the review: every ask already made and its answer.
    static func section() -> String {
        let list = all()
        guard !list.isEmpty else { return "" }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let lines = list.suffix(30).map { a -> String in
            let ans = a.answer.map {
                $0 == "yes" ? "yes" : "not now (held 7 days from \(df.string(from: Date(timeIntervalSince1970: a.answeredAt ?? 0))))"
            }
            return
                "- \(a.key) (\(a.date)): \(ans ?? (a.shown == nil ? "not shown yet" : "asked, no answer: don't ask again")): \(Improve.short(a.text, 120))"
        }
        return "\n## ASKS ALREADY MADE (reuse the key for the same topic; never ask one that was answered or is waiting)\n"
            + lines.joined(separator: "\n") + "\n"
    }

    /// `One --improve ask [show | yes | no]`: for the assistant on the phone or in the chat.
    static func cli(_ a: [String]) -> Int32 {
        switch a.first ?? "show" {
        case "yes", "no":
            guard let x = answer(a.first == "yes", via: "assistant") else {
                print("No question from the nightly review is waiting.")
                return 0
            }
            print(
                a.first == "yes"
                    ? "Recorded yes. Send its helper if you haven't: \(helperLine(x))" : "Recorded not now: it won't be asked for 7 days.")
            return 0
        default:
            guard let x = open() else {
                print("No question from the nightly review is waiting.")
                return 0
            }
            print("Waiting: \(x.text)\nOn yes: \(helperLine(x))")
            return 0
        }
    }
}
