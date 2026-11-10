import Foundation

// MARK: - A tag in a reply ends at the "]" that balances its own "[", however many lines on
// Nov 5, 2026: [tell-helper: …] was read up to its FIRST "]". When the message to a helper quoted a [choices: …]
// tag, the helper got only the text up to that bracket; the rest showed in the main chat and was read aloud.
// Nov 10, 2026: a [helper: …] job over several paragraphs was read only to the end of its first line: the helper
// got the first paragraph, and the rest showed in the chat and was read aloud.
// Now every hidden tag ([helper: …], [tell-helper: …], [stop-helper: …], [done-helper: …], [job-kind: …],
// [learned: …]) runs from its opening "[name:" to the "]" that closes it, across blank lines, counting the brackets
// inside, so a choices tag, a link or code stays in it. A "]" later on that closes nothing there still belongs to it
// (up to the next tag). A tag inside another tag's brackets is part of it, never read on its own.
// Fail safe: a tag that never closes hides everything from it to the end of the reply; what's there still goes
// where it was meant to (up to the next tag of the same kind at the start of a line), and it's logged.
// Checked in `One --test-helpers` (HelperLinesCheck.swift, HelperSpanCheck.swift).

enum TagLines {
    /// Every tag One hides from a reply and acts on (Helpers.read). Learning reads job-kind and learned afterwards.
    static let acted = ["helper", "tell-helper", "stop-helper", "done-helper", "close-helper"]
    /// Every tag that's never shown or spoken.
    static let hidden = acted + ["job-kind", "learned"]

    /// One tag found: which, where it starts and ends (end exclusive) and what's after "name:". nil body = still
    /// streaming in. `open` = it never closed: everything from it to the end of the reply is hidden.
    struct Hit {
        var start: Int
        var end: Int
        var body: String?
        var tag = ""
        var open = false
    }

    /// Every "[tag: …]" of this kind in the text, case-insensitive.
    static func hits(_ c: [Character], tag: String, streaming: Bool) -> [Hit] { hits(c, tags: [tag], streaming: streaming) }

    /// Every outermost tag of these kinds, in reading order: one inside another's brackets belongs to that one.
    static func hits(_ c: [Character], tags: [String], streaming: Bool) -> [Hit] {
        let opens = tags.map { (tag: $0.lowercased(), open: Array("[" + $0.lowercased() + ":")) }
        var out: [Hit] = []
        var i = 0
        while i < c.count {
            guard c[i] == "[", let o = opens.first(where: { self.opens(c, at: i, $0.open) }) else {
                i += 1
                continue
            }
            let from = i + o.open.count
            let (close, _) = closing(c, from: i)
            if let k = close {
                let end = stray(c, after: k, tags: opens.map(\.open))
                out.append(Hit(start: i, end: end, body: String(c[from..<(end - 1)]), tag: o.tag))
                i = end
            } else if streaming {
                out.append(Hit(start: i, end: c.count, body: nil, tag: o.tag, open: true))  // still being written: hidden to the end
                break
            } else {
                // Never closed: hidden to the end; its text runs up to the next tag of its kind at a line's start.
                let next = nextLineStart(c, after: from, o.open) ?? c.count
                out.append(
                    Hit(start: i, end: next, body: String(c[from..<next]).trimmingCharacters(in: .whitespacesAndNewlines), tag: o.tag, open: true))
                i = next
            }
        }
        return out
    }
    static func opens(_ c: [Character], at i: Int, _ open: [Character]) -> Bool {
        guard i + open.count <= c.count else { return false }
        for (k, o) in open.enumerated() where c[i + k].lowercased() != String(o) { return false }
        return true
    }
    /// The "]" balancing the "[" at `i`, and whether the text ran out before it closed.
    static func closing(_ c: [Character], from i: Int) -> (Int?, Bool) {
        var depth = 0
        var j = i
        while j < c.count {
            if c[j] == "[" {
                depth += 1
            } else if c[j] == "]" {
                depth -= 1
                if depth == 0 { return (j, false) }
            }
            j += 1
        }
        return (nil, true)
    }
    /// A "]" later on that closes nothing there still ends this tag ("[tell-helper: X | a] b]", or a job whose
    /// text had a lone "]" in its first paragraph). Looks no further than the next tag.
    static func stray(_ c: [Character], after k: Int, tags: [[Character]]) -> Int {
        var end = k + 1
        var depth = 0
        var low = 0
        var m = k + 1
        while m < c.count {
            if c[m] == "[" {
                if tags.contains(where: { opens(c, at: m, $0) }) { break }
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
    /// Where the next tag of this kind starts a line (spaces before it allowed), after `from`.
    static func nextLineStart(_ c: [Character], after from: Int, _ open: [Character]) -> Int? {
        var m = from
        while m < c.count {
            if c[m] == "\n" {
                var s = m + 1
                while s < c.count, c[s] == " " || c[s] == "\t" { s += 1 }
                if opens(c, at: s, open) { return s }
            }
            m += 1
        }
        return nil
    }

    /// The text with those tags taken out. A tag run into a sentence keeps the two sentences on their own lines.
    /// From a tag that never closed, nothing more is kept.
    static func cut(_ c: [Character], _ hs: [Hit]) -> String {
        var out: [Character] = []
        var at = 0
        for h in hs {
            var s = h.start
            while s > at, c[s - 1] == " " || c[s - 1] == "\t" { s -= 1 }
            if h.open {
                out += c[at..<s]
                at = c.count
                break
            }
            var e = h.end
            while e < c.count, c[e] == " " || c[e] == "\t" { e += 1 }
            if s == 0 || c[s - 1] == "\n", e < c.count, c[e] == "\n" { e += 1 }  // a tag on lines of its own: no blank line left
            out += c[at..<s]
            let after: Character = e < c.count ? c[e] : "\n"
            if let b = out.last, b != "\n", after != "\n" { out.append("\n") }
            at = e
        }
        if at < c.count { out += c[at...] }
        var lines = String(out).components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        var t = lines.joined(separator: "\n")
        while t.contains("\n\n\n") { t = t.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return t
    }

    /// A finished reply: the text without the tags, and each tag's body (what's after "name:", untrimmed).
    static func extract(_ text: String, tag: String) -> (String, [String]) {
        let c = Array(text)
        let hs = hits(c, tag: tag, streaming: false)
        guard !hs.isEmpty else { return (text, []) }
        logOpen(hs)
        return (cut(c, hs), hs.compactMap(\.body))
    }

    /// While a reply streams in: every one of these tags hidden, a half-written one too (even "[tell-hel").
    static func hide(_ text: String, tags: [String]) -> String {
        let c = Array(text)
        let hs = hits(c, tags: tags, streaming: true)
        var t = hs.isEmpty ? text : cut(c, hs)
        if let k = t.lastIndex(of: "[") {
            let tail = t[k...].lowercased()
            if tags.contains(where: { ("[" + $0.lowercased() + ":").hasPrefix(tail) }) {
                t = String(t[..<k]).trimmingCharacters(in: .whitespaces)
            }
        }
        return t
    }

    /// A tag that never closed: logged to hermes/logs/one-helpers.log (what it held still went where it was meant to).
    static func logOpen(_ hs: [Hit]) {
        for h in hs where h.open {
            let stamp = ISO8601DateFormatter().string(from: Date())
            Helpers.appendLog("\(stamp) a [\(h.tag): …] tag never closed; hid the rest of the reply: \(String((h.body ?? "").prefix(300)))\n")
        }
    }

    /// Last line of defence for the voice: from anything that still looks like a hidden tag ("[helper", "[Tell-Helper ",
    /// a colon or not), nothing more is read aloud.
    static func unspoken(_ text: String) -> String {
        var cut = text.endIndex
        for tag in hidden {
            for opener in ["[" + tag, "[ " + tag] {
                if let r = text.range(of: opener, options: .caseInsensitive), r.lowerBound < cut { cut = r.lowerBound }
            }
        }
        return String(text[..<cut])
    }
}
