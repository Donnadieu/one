import Foundation

// MARK: - A tag in a reply ends at the "]" that balances its own "["
// Nov 5, 2026: [tell-helper: …] was read up to its FIRST "]". When the message to a helper quoted a [choices: …]
// tag, the helper got only the text up to that bracket; the rest showed in the main chat and was read aloud.
// Now a tag ([tell-helper: …], [stop-helper: …], [done-helper: …], [job-kind: …], [learned: …]) runs from its
// opening "[name:" to the "]" that closes it, counting the brackets inside, so a choices tag, a link or code stays
// in the message. A stray "]" later on that same line still belongs to it (the whole line, like a helper line), and
// another tag beside it on the line stays its own tag. A tag that ran onto more lines ends at its closing "]"
// (at most `maxLines` lines on). One that never closes is its own line only, like a helper line missing its "]".
// While a reply streams in, a tag still being written is hidden to the end. Checked in `One --test-helpers`
// (HelperLinesCheck.swift).

enum TagLines {
    /// How many lines on a tag may still close.
    static let maxLines = 20
    /// One tag found: where it starts and ends (end exclusive) and what's after "name:". nil body = still streaming in.
    struct Hit {
        var start: Int
        var end: Int
        var body: String?
    }

    /// Every "[tag: …]" in the text, case-insensitive.
    static func hits(_ c: [Character], tag: String, streaming: Bool) -> [Hit] {
        let open = Array("[" + tag.lowercased() + ":")
        var out: [Hit] = []
        var i = 0
        while i + open.count <= c.count {
            guard opens(c, at: i, open) else {
                i += 1
                continue
            }
            let from = i + open.count
            let lineEnd = c[i...].firstIndex(of: "\n") ?? c.count
            let (close, atEnd) = closing(c, from: i)
            if let k = close {
                let end = stray(c, after: k)
                out.append(Hit(start: i, end: end, body: String(c[from..<(end - 1)])))
                i = end
            } else if streaming && atEnd {
                out.append(Hit(start: i, end: c.count, body: nil))  // still being written: hidden to the end
                break
            } else {
                out.append(Hit(start: i, end: lineEnd, body: String(c[from..<lineEnd])))  // never closed: its own line
                i = lineEnd
            }
        }
        return out
    }
    static func opens(_ c: [Character], at i: Int, _ open: [Character]) -> Bool {
        for (k, o) in open.enumerated() where c[i + k].lowercased() != String(o) { return false }
        return true
    }
    /// The "]" balancing the "[" at `i`, and whether the text ran out before it closed.
    static func closing(_ c: [Character], from i: Int) -> (Int?, Bool) {
        var depth = 0
        var lines = 0
        var j = i
        while j < c.count {
            switch c[j] {
            case "[": depth += 1
            case "]":
                depth -= 1
                if depth == 0 { return (j, false) }
            case "\n":
                lines += 1
                if lines > maxLines { return (nil, false) }
            default: break
            }
            j += 1
        }
        return (nil, true)
    }
    /// A "]" later on the same line that closes nothing there still ends this tag ("[tell-helper: X | a] b]").
    static func stray(_ c: [Character], after k: Int) -> Int {
        var end = k + 1
        var depth = 0
        var low = 0
        var m = k + 1
        while m < c.count, c[m] != "\n" {
            if c[m] == "[" {
                depth += 1
            } else if c[m] == "]" {
                depth -= 1
                if depth < low {
                    low = depth
                    end = m + 1
                }
            }
            m += 1
        }
        return end
    }

    /// The text with those tags taken out. A tag run into a sentence keeps the two sentences on their own lines.
    static func cut(_ c: [Character], _ hs: [Hit]) -> String {
        var out: [Character] = []
        var at = 0
        for h in hs {
            var s = h.start
            while s > at, c[s - 1] == " " || c[s - 1] == "\t" { s -= 1 }
            var e = h.end
            while e < c.count, c[e] == " " || c[e] == "\t" { e += 1 }
            if s == 0 || c[s - 1] == "\n", e < c.count, c[e] == "\n" { e += 1 }  // a tag on lines of its own: no blank line left
            out += c[at..<s]
            let after: Character = e < c.count ? c[e] : "\n"
            if let b = out.last, b != "\n", after != "\n" { out.append("\n") }
            at = e
        }
        out += c[at...]
        var lines = String(out).components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        return lines.joined(separator: "\n").replacingOccurrences(of: "\n\n\n", with: "\n\n")
    }

    /// A finished reply: the text without the tags, and each tag's body (what's after "name:", untrimmed).
    static func extract(_ text: String, tag: String) -> (String, [String]) {
        let c = Array(text)
        let hs = hits(c, tag: tag, streaming: false)
        guard !hs.isEmpty else { return (text, []) }
        return (cut(c, hs), hs.compactMap(\.body))
    }

    /// While a reply streams in: every one of these tags hidden, a half-written one too (even "[tell-hel").
    static func hide(_ text: String, tags: [String]) -> String {
        var t = text
        for tag in tags {
            let c = Array(t)
            let hs = hits(c, tag: tag, streaming: true)
            if !hs.isEmpty { t = cut(c, hs) }
        }
        if let k = t.lastIndex(of: "[") {
            let tail = t[k...].lowercased()
            if tags.contains(where: { ("[" + $0.lowercased() + ":").hasPrefix(tail) }) {
                t = String(t[..<k]).trimmingCharacters(in: .whitespaces)
            }
        }
        return t
    }
}
