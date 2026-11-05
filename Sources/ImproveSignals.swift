import Foundation

// MARK: - The signals the score is built from (no AI, plain rules)
// "One gets better by itself", build step 1: the person's corrections, steps that failed, walls and
// where each conversation came from. Shared by the collector (ImproveCollect.swift) and FrictionLog.

/// The person's own words saying "that's not right". A phrase list, checked on what they typed, with
/// One's hidden notes and the engine's wrappers taken out first (they would otherwise match everything).
enum Corrections {
    enum Kind: String {
        case phrase
        case statedRule = "stated_rule"  // "always…" / "never…": their own rule, counts at once
    }

    /// Rows that are never the person's own words: helper jobs, picked-back-up notes, routine reports
    /// echoed into a phone chat, the engine's own notices.
    static let notTheirs = [
        "(One app note", "You're one of", "You were interrupted by a restart", "[Cron delivery", "[IMPORTANT:", "[ASYNC DELEGATION",
        "[CONTEXT COMPACTION", "[STILL IN PROGRESS", "[SYSTEM:", "Gateway shutting down",
    ]

    /// What the person actually typed, or nil when the row isn't theirs.
    static func clean(_ raw: String) -> String? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("Gateway message origin") {  // phone chat: the engine's routing header, then their words
            guard let r = t.range(of: "\n\n") else { return nil }
            t = String(t[r.upperBound...])
        }
        if t.hasPrefix("[OUT-OF-BAND") {  // a message sent mid-turn: keep the words, drop the wrapper
            guard let r = t.range(of: "]\n") else { return nil }
            t = String(t[r.upperBound...]).replacingOccurrences(of: "[/OUT-OF-BAND USER MESSAGE]", with: "")
        }
        if t.hasPrefix("[Replying to:"), let r = t.range(of: "\"]\n") { t = String(t[r.upperBound...]) }
        if notTheirs.contains(where: { t.hasPrefix($0) }) { return nil }
        if t.range(of: #"^From [^,\n]{1,40}, via [^:\n]{1,40}:"#, options: .regularExpression) != nil { return nil }
        if let r = t.range(of: "(One app note") { t = String(t[..<r.lowerBound]) }
        t = t.replacingOccurrences(of: #"(?m)^\(This is about[^\n]*\)\n?"#, with: "", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// "No that's okay", "no thanks": a polite no, not a correction.
    static let politeNo =
        #"^(no[,.!]?\s+(that'?s|it'?s|that is|it is)\s+(ok|okay|fine|good|alright|all right|perfect)|no,?\s+thanks?|no,?\s+thank you|no worries|no problem|no need|no rush|no hurry|nope,?\s+(that'?s|all) (fine|good|ok))"#
    static let phrases = [
        #"^no\b"#, #"^nope\b"#, #"\bi (still )?(don'?t|do not|can'?t|cannot) see\b"#, #"\bi'?m confused\b"#, #"\bi am confused\b"#,
        #"\bwhere is\b"#, #"\bwhere'?s\b"#, #"\bi told you\b"#, #"\bi said\b"#, #"\byou didn'?t\b"#, #"\byou did not\b"#,
        #"\b(that|this|it)'?s wrong\b"#, #"\b(that|this|it) is wrong\b"#, #"\bthat'?s not (it|right|what)\b"#, #"\bnot what i\b"#,
        #"\bstill not\b"#, #"\bstill (doesn'?t|isn'?t|can'?t|won'?t|don'?t)\b"#, #"\bagain\?"#, #"\bwhy did you\b"#, #"\bwrong\b"#,
        #"\bincorrect\b"#, #"\bthat was not\b"#, #"\bnot working\b"#, #"\bdoesn'?t work\b"#,
    ]
    static let rules = [
        #"^(always|never|from now on|don'?t ever|stop doing)\b"#, #"\bfrom now on\b"#,
        #"\b(always|never) (do|use|open|send|ask|say|put|make|show|run|start|post|give|tell|let|check)\b"#,
    ]

    /// A pasted transcript or log ("Speaker 1: …", "0:23 …"): the words are someone else's.
    static func pasted(_ t: String) -> Bool {
        if t.count > 1500 { return true }
        let lines = t.split(separator: "\n").prefix(40)
        let speakers = lines.filter {
            $0.range(of: #"^\s*(\[?\d{1,2}:\d{2}|@?[A-Z][\w .'-]{0,30}( \[\d{1,2}:\d{2}\])?: )"#, options: .regularExpression) != nil
        }
        return speakers.count >= 3 || t.range(of: #"^(Speaker \d|\d{1,2}:\d{2}:)"#, options: .regularExpression) != nil
    }

    static func has(_ t: String, _ pats: [String]) -> Bool {
        pats.contains { t.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    /// The correction in a message from the person, if any. `raw` may still carry One's hidden notes.
    static func find(_ raw: String) -> Kind? {
        guard let t = clean(raw), !pasted(t) else { return nil }
        let head = String(t.prefix(400))
        if has(head, rules) { return .statedRule }
        if head.range(of: politeNo, options: [.regularExpression, .caseInsensitive]) != nil { return nil }
        return has(head, phrases) ? .phrase : nil
    }

    static func matches(_ text: String) -> Bool { find(text) != nil }
}

/// Where a conversation came from.
enum JobPlace: String {
    case main, helper, resumed, phone, routine, other

    static func of(source: String, first: String) -> JobPlace {
        switch source {
        case "cron": return .routine
        case "oneshot", "subagent": return .other
        case _ where Messenger.phoneSources.contains(source): return .phone
        default:
            if first.hasPrefix("You're one of"), first.prefix(80).contains("helpers") { return .helper }
            if first.hasPrefix("You were interrupted by a restart") { return .resumed }
            return .main
        }
    }
    /// Places where the person talks (their messages count).
    var personTalks: Bool { self == .main || self == .helper || self == .resumed || self == .phone }
}

/// One tool step's result, read the strict way (design appendix): a step failed when it says so.
enum StepCheck {
    static let cutOff = "Gateway shutting down: this turn was interrupted"

    static func failed(_ c: String) -> Bool {
        let s = c.drop { $0 == " " || $0 == "\n" }
        if s.hasPrefix("Error executing tool") { return true }
        guard s.hasPrefix("{"), c.contains("\"exit_code\"") || c.contains("\"error\"") || c.contains("\"success\""),
            let d = c.data(using: .utf8), let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        else { return false }
        if let e = j["exit_code"] as? Int, e != 0 { return true }
        if let e = j["error"], !(e is NSNull), "\(e)" != "", "\(e)" != "0" { return true }
        if let ok = j["success"] as? Bool, !ok { return true }
        return false
    }

    /// A command that hit the time limit.
    static func timedOut(_ c: String) -> Bool {
        (c.hasPrefix("Error executing tool") && c.contains("timed out after")) || c.contains("\"exit_code\": 124")
            || c.hasPrefix("{\"output\": \"[Command timed out after")
    }

    static let signedOut =
        #"\b401\b|unauthori[sz]ed|signed out|not signed in|not logged in|expired token|token (has )?expired|invalid_grant|session expired|please (log|sign) in"#
    static let rateLimit = #"\b429\b|rate.?limit|quota"#

    /// The wall a FAILED step hit: the folder lock, a sign-in that ran out, or a rate limit.
    static func wall(_ c: String) -> String? {
        if c.contains("Operation not permitted") { return "folder_lock" }
        let head = String(c.prefix(2000))
        if head.range(of: signedOut, options: [.regularExpression, .caseInsensitive]) != nil { return "signed_out" }
        if head.range(of: rateLimit, options: [.regularExpression, .caseInsensitive]) != nil { return "rate_limit" }
        return nil
    }

    /// Tools that are meant to be called again and again (checking on a running command).
    static let polling: Set<String> = ["process_manage", "process", "todo", "todo_list", "process_wait"]
}

/// Never read, quote or show: a private room (room.yaml, through `RoomPrivacy`, e.g. a Nyx room), any
/// locked drawer and the shared rooms. A whole conversation is private when the person's words, the assistant's
/// words or any step it took mention one of them, or a step's result shows a file from one. One's own hidden notes
/// don't count (they name every room).
enum ImprovePrivate {
    /// What marks a private place: folder and path pieces (`paths`), and private rooms' titles and AI names as
    /// whole words (`words`).
    struct Marks {
        var paths: [String]
        var words: [String]
        func contains(_ s: String) -> Bool { paths.contains { s.contains($0) } }
    }
    static var paths: Marks { marks() }
    static func marks(rooms: [URL] = RoomMap.roomFolders(), shared: [String] = Shared.paths) -> Marks {
        var m = ["confidential/", "One Rooms/", "com~apple~CloudDocs"]
        m += shared.filter { !$0.contains("One Rooms/") }
        var words: [String] = []
        for r in RoomPrivacy.privateRooms(rooms, shared: shared) {
            m.append(r.lastPathComponent)
            let y = RoomYaml.read(r)
            for w in [y?.title ?? RoomMap.roomTitle(r), y?.ai ?? ""] where w.count >= 3 && !words.contains(w) { words.append(w) }
        }
        return Marks(paths: m, words: words)
    }
    /// The person's (cleaned) words, the assistant's words and step arguments.
    static func touches(_ text: String, _ marks: Marks) -> Bool {
        if marks.contains(text) { return true }
        return marks.words.contains { w in
            text.range(of: w, options: .caseInsensitive) != nil
                && text.range(of: "\\b" + NSRegularExpression.escapedPattern(for: w) + "\\b", options: [.regularExpression, .caseInsensitive]) != nil
        }
    }
    /// A step's result: only a path from a private place counts (a word in a web page doesn't).
    static func showsFile(_ output: String, _ marks: Marks) -> Bool { marks.contains(output) }

    /// True when any row of the conversation touches a private place.
    static func conversation(_ rows: [ImproveRow], _ paths: Marks) -> Bool {
        rows.contains { r in
            switch r.role {
            case "user": return Corrections.clean(r.content).map { touches($0, paths) } ?? false
            case "assistant": return touches(r.content, paths) || touches(r.calls, paths)
            case "tool": return showsFile(r.content, paths)
            default: return false
            }
        }
    }
}
