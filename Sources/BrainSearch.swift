import Foundation
import SQLite3

// MARK: - Searching the brain: `One --search "words" [--room <name>] [--limit N] [--json]`

/// One search result: where it is (full path, so the assistant can open it) and a short piece of the text.
struct SearchHit {
    let room: String
    let file: String
    let heading: String
    let snippet: String
    let date: String
    let score: Double
}

struct SearchResult {
    var hits: [SearchHit] = []
    var searched: [String] = []
    var privateLeftOut = 0
    /// "words" (every word found), "close" (close spellings or parts of words), "some" (only some words), "none".
    var match = "none"
    /// In "some" mode: asked words no note here has at all.
    var missing: [String] = []
    var error: String?
}

/// Storage design 3f. Privacy is in code: with no room named, private rooms are left out and their index file is
/// never even opened. A private room is searched only when it is named with `--room`.
enum BrainSearch {
    static let usage = "Usage: One --search \"words\" [--room <room>] [--limit N] [--json]"

    /// The assistant is told this on every prompt (SessionNotes).
    static var note: String {
        "\n\n(One app note, not from the user: SEARCH THEIR NOTES. To find something in their notes, run `\(Bridge.exe) --search \"words\"` "
            + "(add `--room <name>` to look inside one room; private rooms are only searched when you name them, so name one only "
            + "when you're working in it or they ask). It's faster than reading folders, and each result gives the file's full path to open.)"
    }

    /// The rooms a search looks in: the named one (private or not), or every room that isn't private.
    static func rooms(named: String?, from all: [SearchRoom]) -> (rooms: [SearchRoom], leftOut: Int, error: String?) {
        guard let named else { return (all.filter { !$0.isPrivate }, all.filter(\.isPrivate).count, nil) }
        let n = named.lowercased().trimmingCharacters(in: .whitespaces)
        if let r = all.first(where: { $0.name.lowercased() == n }) ?? all.first(where: { !$0.shared && $0.name.lowercased() == n + "-room" }) {
            return ([r], 0, nil)
        }
        let open = all.filter { !$0.isPrivate }.map(\.name)
        let more = all.contains(where: \.isPrivate) ? " (private rooms aren't listed; name one exactly)" : ""
        return ([], 0, "No room called \"\(named)\". Rooms: \(open.joined(separator: ", "))\(more).")
    }

    static func search(_ q: String, room: String? = nil, limit: Int = 10, refresh: Bool = true, all: [SearchRoom]? = nil) -> SearchResult {
        var res = SearchResult()
        let pick = rooms(named: room, from: all ?? BrainRooms.all())
        res.privateLeftOut = pick.leftOut
        if let e = pick.error {
            res.error = e
            return res
        }
        let tokens = words(q)
        guard !tokens.isEmpty else {
            res.error = usage
            return res
        }
        var dbs: [(SearchRoom, IndexDB, Bool)] = []
        for r in pick.rooms {  // only these index files are ever opened
            if refresh { BrainIndex.refresh(r) }
            if let (d, _) = BrainIndex.open(r) { dbs.append((r, d, BrainIndex.hasTrigram(d))) }
        }
        res.searched = pick.rooms.map(\.name)
        let found = dbs.flatMap { wordHits($0.1, room: $0.0, query: ftsQuery(tokens, any: false), limit: limit * 4) }
        if !found.isEmpty {
            res.hits = best(found.sorted { $0.score < $1.score }, limit)
            res.match = "words"
            return res
        }
        let close = dbs.filter(\.2).flatMap { closeHits($0.1, room: $0.0, tokens: tokens) }
        if !close.isEmpty {
            res.hits = best(close.sorted { $0.score > $1.score }, limit)
            res.match = "close"
            return res
        }
        if tokens.count > 1 {
            let some = dbs.flatMap { wordHits($0.1, room: $0.0, query: ftsQuery(tokens, any: true), limit: limit * 4) }
            res.hits = best(some.sorted { $0.score < $1.score }, limit)
            if !some.isEmpty { res.match = "some" }
            res.missing = tokens.filter { t in
                dbs.allSatisfy {
                    (($0.1.rows("SELECT count(*) FROM chunks WHERE chunks MATCH ?", [ftsQuery([t], any: false)])?.first?.first as? Int) ?? 0) == 0
                }
            }
        }
        return res
    }

    /// The best piece of each note, best first: a list of notes, not the same note several times.
    static func best(_ hits: [SearchHit], _ limit: Int) -> [SearchHit] {
        var seen = Set<String>()
        return Array(hits.filter { seen.insert($0.file).inserted }.prefix(limit))
    }

    /// Letters and digits only, lower case: nothing typed can turn into a search operator.
    static func words(_ q: String) -> [String] {
        var out: [String] = []
        var cur = ""
        for ch in q.lowercased() {
            if ch.isLetter || ch.isNumber {
                cur.append(ch)
            } else if !cur.isEmpty {
                out.append(cur)
                cur = ""
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    static func ftsQuery(_ tokens: [String], any: Bool) -> String {
        tokens.map { "\"\($0)\"" }.joined(separator: any ? " OR " : " ")
    }

    /// Ranked word search (bm25: a match in the note's name counts most, then its heading, then the text).
    static func wordHits(_ d: IndexDB, room: SearchRoom, query: String, limit: Int) -> [SearchHit] {
        let sql = """
            SELECT file, heading, snippet(chunks, 3, '«', '»', '…', 18), date, bm25(chunks, 0.0, 4.0, 2.0, 1.0, 0.0, 0.0) AS r
            FROM chunks WHERE chunks MATCH ? ORDER BY r LIMIT ?
            """
        return (d.rows(sql, [query, limit]) ?? []).map { r in
            SearchHit(
                room: room.name, file: room.folder.appendingPathComponent((r[0] as? String) ?? "").path, heading: (r[1] as? String) ?? "",
                snippet: flat((r[2] as? String) ?? ""), date: (r[3] as? String) ?? "", score: (r[4] as? Double) ?? 0)
        }
    }

    /// Close spellings and parts of words (the trigram copy): candidates share pieces of three letters with the
    /// words asked for; each is kept only when every word has a close match in it, best match first.
    static func closeHits(_ d: IndexDB, room: SearchRoom, tokens: [String]) -> [SearchHit] {
        let qs = tokens.map { Fuzzy.scalars($0) }.filter { $0.count >= 3 }
        let grams = Set(qs.flatMap { Fuzzy.grams($0[...]) })
        guard !grams.isEmpty else { return [] }
        let terms = tokens.filter { $0.unicodeScalars.count >= 3 }.flatMap { t -> [String] in
            let s = Array(t.unicodeScalars)
            return (0...(s.count - 3)).map { i in "\"" + String(String.UnicodeScalarView(s[i..<(i + 3)])) + "\"" }
        }
        let ids = (d.rows("SELECT rowid FROM grams WHERE grams MATCH ? ORDER BY bm25(grams) LIMIT 40", [Set(terms).joined(separator: " OR ")]) ?? [])
            .compactMap { $0.first as? Int }
        guard !ids.isEmpty else { return [] }
        let rows =
            d.rows("SELECT file, title, heading, text, date, rowid FROM chunks WHERE rowid IN (\(ids.map(String.init).joined(separator: ",")))") ?? []
        return rows.compactMap { r -> SearchHit? in
            let text = (r[3] as? String) ?? ""
            let head = "\((r[1] as? String) ?? "") \((r[2] as? String) ?? "")"
            let inHead = Fuzzy.match(head, qs)
            guard let m = Fuzzy.match(text, qs) ?? inHead.map({ ($0.score, nil) }) else { return nil }
            // Ties: a match in the note's name or heading first, then the trigram ranking's order.
            let rank = Double(ids.firstIndex(of: (r[5] as? Int) ?? 0) ?? ids.count)
            return SearchHit(
                room: room.name, file: room.folder.appendingPathComponent((r[0] as? String) ?? "").path, heading: (r[2] as? String) ?? "",
                snippet: m.at.map { Fuzzy.snippet(text, at: $0) } ?? flat(String(text.prefix(160))), date: (r[4] as? String) ?? "",
                score: m.score + (inHead == nil ? 0 : 0.1) - rank * 1e-4)
        }
    }

    static func flat(_ s: String) -> String { s.split(whereSeparator: { $0 == "\n" || $0 == "\t" || $0 == " " }).joined(separator: " ") }

    // MARK: Command line

    /// `--search …` (runs before any window, like `--cal`), and `--test-search` (CI only).
    static func cli(_ args: [String]) -> Int32? {
        if args.contains("--test-search") {
            TestWorld.enter()  // scratch brain, scratch index; run with ONE_SUPPORT_DIR set to an empty folder
            return BrainIndexCheck.run()
        }
        guard let k = args.firstIndex(of: "--search") else { return nil }
        guard let o = parse(Array(args[(k + 1)...])) else {
            print(usage)
            return 2
        }
        let res = search(o.query, room: o.room, limit: o.limit)
        print(o.json ? json(o.query, res) : text(o.query, res))
        return res.error == nil ? 0 : 2
    }

    struct Options {
        var query = ""
        var room: String?
        var limit = 10
        var json = false
    }

    static func parse(_ a: [String]) -> Options? {
        var o = Options()
        var q: [String] = []
        var i = 0
        while i < a.count {
            switch a[i] {
            case "--room":
                guard i + 1 < a.count else { return nil }
                o.room = a[i + 1]
                i += 2
            case "--limit":
                guard i + 1 < a.count, let n = Int(a[i + 1]), n > 0 else { return nil }
                o.limit = min(n, 100)
                i += 2
            case "--json":
                o.json = true
                i += 1
            default:
                q.append(a[i])
                i += 1
            }
        }
        o.query = q.joined(separator: " ")
        return words(o.query).isEmpty ? nil : o
    }

    static func text(_ q: String, _ r: SearchResult) -> String {
        if let e = r.error { return e }
        let left = r.privateLeftOut > 0 ? " (\(r.privateLeftOut) private room\(r.privateLeftOut == 1 ? "" : "s") left out: name one with --room)" : ""
        let in_ = "in \(r.searched.joined(separator: ", "))\(left)"
        guard !r.hits.isEmpty else { return "Nothing found for \"\(q)\" \(in_)." }
        var out = ["\(r.hits.count) found for \"\(q)\" \(in_)."]
        if r.match == "close" { out.append("No note has those exact words; these are close spellings or parts of words.") }
        if r.match == "some" {
            let none = r.missing.isEmpty ? "" : " No note here mentions \(r.missing.joined(separator: ", "))."
            out.append("No note has all those words; these have some of them.\(none)")
        }
        for (i, h) in r.hits.enumerated() {
            out.append("")
            out.append("\(i + 1). \(h.room) · \(h.date) · \(h.file)")
            if !h.heading.isEmpty { out.append("   # \(h.heading)") }
            if !h.snippet.isEmpty { out.append("   \(h.snippet)") }
        }
        return out.joined(separator: "\n")
    }

    static func json(_ q: String, _ r: SearchResult) -> String {
        var o: [String: Any] = ["query": q, "searched": r.searched, "privateRoomsLeftOut": r.privateLeftOut, "match": r.match, "missing": r.missing]
        if let e = r.error { o["error"] = e }
        o["results"] = r.hits.map { ["room": $0.room, "file": $0.file, "heading": $0.heading, "snippet": $0.snippet, "date": $0.date] }
        let d = (try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(data: d, encoding: .utf8) ?? "{}"
    }
}

// MARK: - Close spellings: pieces of three letters

enum Fuzzy {
    /// Lower-case letters and digits as numbers, keeping one number per character of the original text.
    static func scalars(_ s: String) -> [UInt32] {
        s.unicodeScalars.map { c in
            let v = c.value
            if v >= 65 && v <= 90 { return v + 32 }
            if v < 128 { return v }
            return c.properties.lowercaseMapping.unicodeScalars.first?.value ?? v
        }
    }

    static func isWord(_ v: UInt32) -> Bool {
        if v < 128 { return (v >= 97 && v <= 122) || (v >= 48 && v <= 57) }
        return Unicode.Scalar(v).map { $0.properties.isAlphabetic || $0.properties.numericType != nil } ?? false
    }

    static func grams(_ w: ArraySlice<UInt32>) -> [UInt64] {
        guard w.count >= 3 else { return [] }
        let b = w.startIndex
        var out: [UInt64] = []
        for i in 0...(w.count - 3) {
            let g = UInt64(w[b + i]) << 42 | UInt64(w[b + i + 1]) << 21 | UInt64(w[b + i + 2])
            if !out.contains(g) { out.append(g) }
        }
        return out
    }
    /// With a space before and after, so the start and end of a word count too (a typo in the middle costs less).
    static func padded(_ w: ArraySlice<UInt32>) -> [UInt64] { grams([32] + w + [32]) }

    /// How well each asked word matches its closest word in the text: share of its letter-trios found (mostly) and
    /// overall likeness. Nil unless every asked word has a word sharing 60% of its trios. `at` = where the first asked word's match is.
    static func match(_ text: String, _ qs: [[UInt32]]) -> (score: Double, at: Range<Int>?)? {
        let t = scalars(text)
        let qg = qs.map { Array(padded($0[...]).prefix(64)) }  // up to 64 trios per word: one bit each
        var best = Array(repeating: 0.0, count: qs.count)
        var at: Range<Int>?
        var wg: [UInt64] = []
        wg.reserveCapacity(48)
        var i = 0
        while i < t.count {
            guard isWord(t[i]) else {
                i += 1
                continue
            }
            var j = i
            while j < t.count, isWord(t[j]) { j += 1 }
            let n = j - i
            if n >= 2 && n <= 40 {
                // The word's trios (with a space on each side), built once without new arrays.
                wg.removeAll(keepingCapacity: true)
                var a: UInt32 = 32
                var b = t[i]
                for p in (i + 1)...j {
                    let c = p < j ? t[p] : 32
                    wg.append(UInt64(a) << 42 | UInt64(b) << 21 | UInt64(c))
                    a = b
                    b = c
                }
                for k in 0..<qg.count where !qg[k].isEmpty && Double(n) >= 0.6 * Double(qg[k].count) {
                    var mask: UInt64 = 0
                    for g in wg {
                        if let x = qg[k].firstIndex(of: g) { mask |= 1 << UInt64(x) }
                    }
                    let hit = Double(mask.nonzeroBitCount)
                    let have = hit / Double(qg[k].count)
                    guard have >= 0.6 else { continue }
                    let s = 0.7 * have + 0.3 * hit / (Double(qg[k].count + wg.count) - hit)
                    if s > best[k] {
                        best[k] = s
                        if k == 0 { at = i..<j }
                    }
                }
            }
            i = j
        }
        guard !best.isEmpty, best.allSatisfy({ $0 > 0 }) else { return nil }
        return (best.reduce(0, +) / Double(best.count), at)
    }

    /// About 160 characters around the match, the matching word marked «like this», on one line.
    static func snippet(_ text: String, at r: Range<Int>) -> String {
        let s = Array(text.unicodeScalars)
        guard r.upperBound <= s.count else { return BrainSearch.flat(String(text.prefix(160))) }
        let lo = max(0, r.lowerBound - 70)
        let hi = min(s.count, r.upperBound + 90)
        func part(_ a: Int, _ b: Int) -> String { String(String.UnicodeScalarView(s[a..<b])) }
        let mid = part(lo, r.lowerBound) + "«" + part(r.lowerBound, r.upperBound) + "»" + part(r.upperBound, hi)
        return (lo > 0 ? "…" : "") + BrainSearch.flat(mid) + (hi < s.count ? "…" : "")
    }
}
