import Foundation

// MARK: - Helpers see what earlier helpers found

/// A new helper's first prompt lists today's helper results that look related to its job (title + the file under
/// Ready for you), so a follow-up ("now add icons to that README") starts from what the earlier helper found
/// instead of being told where to look. Related = they share real words (the title counts double); at most 5,
/// best first; nothing when nothing matches. Only results from the last 24 hours, only files a helper made.
enum EarlierResults {
    static let window: TimeInterval = 24 * 3600
    static let most = 5
    /// A result needs at least this score: one shared title word, or two shared words in what it says.
    static let minScore = 2

    static func pick(job: String, title: String, from items: [ShelfItem], now: Date = Date(), read: (URL) -> String = head) -> [ShelfItem] {
        let want = words(title + " " + job)
        guard !want.isEmpty else { return [] }
        var scored: [(ShelfItem, Int)] = []
        for it in items where it.from.hasSuffix(" helper") && now.timeIntervalSince(it.made) < window && it.made <= now.addingTimeInterval(60) {
            let inTitle = words(it.title).intersection(want).count
            let inBody = words(it.detail + " " + read(it.url)).subtracting(words(it.title)).intersection(want).count
            let score = inTitle * 2 + inBody
            if score >= minScore { scored.append((it, score)) }
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.made > $1.0.made }.prefix(most).map(\.0)
    }

    static func note(_ items: [ShelfItem]) -> String {
        guard !items.isEmpty else { return "" }
        let lines = items.map { "- \"\($0.title)\": \($0.path)" }
        return "\n\n(One app note, not from the user: EARLIER TODAY. Other helpers finished these today and they may be related to "
            + "your job:\n" + lines.joined(separator: "\n")
            + "\nRead the ones that match your job before you start, and build on what they found or did instead of starting "
            + "over. Skip the ones that don't match.)"
    }

    /// The start of a text result (what it found), for matching. Other files: nothing.
    static func head(_ u: URL) -> String {
        guard ["md", "txt"].contains(u.pathExtension.lowercased()), let h = try? FileHandle(forReadingFrom: u) else { return "" }
        defer { try? h.close() }
        return String(decoding: (try? h.read(upToCount: 800)) ?? Data(), as: UTF8.self)
    }

    static func words(_ s: String) -> Set<String> {
        let parts = s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
        let me = NSUserName().lowercased()  // their own name shows up in every path
        return Set(parts.filter { $0.count >= 4 && !stop.contains($0) && $0 != me && !$0.allSatisfy(\.isNumber) })
    }
    static let stop: Set<String> = [
        "that", "this", "with", "from", "have", "what", "when", "where", "your", "them", "they", "their", "then", "than", "into",
        "just", "only", "also", "make", "made", "each", "every", "about", "after", "before", "there", "here", "which", "will",
        "would", "should", "could", "does", "done", "need", "needs", "want", "find", "found", "check", "look", "report", "helper",
        "helpers", "today", "said", "told", "give", "gets", "keep", "still", "more", "most", "some", "other", "over", "under",
        "like", "work", "working", "file", "files", "plain", "words", "short", "message", "lines", "sure", "thing", "things",
        "back", "help", "users", "documents", "library", "application", "support", "them", "were", "been", "being",
        "these", "those", "into", "onto", "while", "without", "says", "say", "what", "know", "next", "step", "steps", "tell",
        "finish", "finished", "start", "started", "time", "very", "much", "many", "good", "same", "show", "shows", "ready",
    ]
}
