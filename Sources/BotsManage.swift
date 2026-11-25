import AppKit
import Foundation

// MARK: - Managing a bot once it's made (Claude Design "One bots design", "Bots manage B - Glass sheet", picked by
// Omar Nov 17 2026: "We should have basic CRUD functionality for bots.").
// View: its info in one glass sheet (BotSheet.swift). Edit: its name, colour, job, what it may use and when it checks
// in; its chat (the same engine conversation), memory and routines stay with it. A rename moves its folder
// (`<room>/bots/<name>/`) and renames its routines "<old>: …" to "<new>: …"; a routine stays its own because it's
// tied to the bot's conversation, not its name. Moving rooms isn't offered yet. Archive: off the left, kept whole,
// its routines paused (and turned back on by Restore). Delete: the saved entry, its folder and its own routines
// (made in its conversation, or named "<bot>: …"), after one "Delete <bot>? Its memory and routines go too."
// From chat Iris writes [edit-bot: …], [archive-bot: …], [restore-bot: …] and [delete-bot: …] (never shown or read
// aloud), and a delete line acts only after they said yes to that question (`BotGate`, enforced here, not only in SOUL).
// Checked by BotsManageCheck.swift (`One --test-helpers`).

/// What a chat line or the sheet changes. nil = unchanged.
struct BotEdit: Equatable {
    var name: String?
    var color: String?
    var job: String?
    var uses: [String]?  // the whole new list
    var add: [String] = []  // \"let it use email drafts\"
    var drop: [String] = []
    var checkIn: String?  // morning, incoming or asked
    var isEmpty: Bool { name == nil && color == nil && job == nil && uses == nil && add.isEmpty && drop.isEmpty && checkIn == nil }
    /// What it may use after this edit: the new list (or the old one), less what's taken away, plus what's added.
    static func uses(_ now: [String], _ e: BotEdit) -> [String] {
        var out = (e.uses ?? now).filter { u in !e.drop.contains { $0.lowercased() == u.lowercased() } }
        for a in e.add where !out.contains(where: { $0.lowercased() == a.lowercased() }) { out.append(a) }
        return out
    }
    /// "morning", "Every morning", "when something comes in", "only when I ask" → morning / incoming / asked.
    static func checkIn(_ s: String) -> String {
        let c = s.lowercased()
        return c.contains("morning") ? "morning" : (c.contains("incoming") || c.contains("comes in")) ? "incoming" : "asked"
    }
}

/// Everything the sheet shows about a bot.
struct BotAbout {
    let name: String
    let color: String
    let room: String
    let job: String
    let uses: [String]
    let checksIn: String
    let routines: [Routine]
    let memory: String
    let remembered: Int
    let made: Date
    static func make(_ h: Helper, routines: [Routine]) -> BotAbout? {
        guard let b = h.bot else { return nil }
        return BotAbout(
            name: b.name, color: b.color.capitalizingFirst, room: b.room, job: b.job, uses: b.uses,
            checksIn: Bots.checkWord(b.checkIn).capitalizingFirst,
            routines: BotStore.owned(h, in: routines), memory: Bots.memory(b).path, remembered: Bots.remembered(b), made: b.made)
    }
}

// MARK: The chat lines

enum BotTags {
    static let tags = ["edit-bot", "archive-bot", "restore-bot", "delete-bot"]
    typealias Read = (said: String, edits: [(String, BotEdit)], archives: [String], restores: [String], deletes: [String])

    /// "Growth bot | name: Leads bot | colour: rose | job: … | uses: Browser, Email drafts | add uses: … |
    /// remove uses: … | check-in: morning" → the bot and what changes. nil when there's no bot or nothing to change.
    static func edit(_ body: String) -> (String, BotEdit)? {
        let p = body.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let who = p.first, !who.isEmpty else { return nil }
        var e = BotEdit()
        func list(_ s: String) -> [String] { s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        for part in p.dropFirst() {
            guard let colon = part.firstIndex(of: ":") else { continue }
            let key = part[..<colon].lowercased().filter(\.isLetter)
            let v = part[part.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !v.isEmpty else { continue }
            switch key {
            case "name", "rename", "newname": e.name = String(v.prefix(30))
            case "colour", "color":
                if Bots.colors.contains(where: { $0.name == v.lowercased() }) { e.color = v.lowercased() }
            case "job": e.job = v
            case "uses", "mayuse", "use": e.uses = list(v)
            case "adduses", "adduse", "add": e.add += list(v)
            case "removeuses", "removeuse", "remove", "drop": e.drop += list(v)
            case "checkin", "checksin": e.checkIn = BotEdit.checkIn(v)
            default: continue
            }
        }
        return e.isEmpty ? nil : (who, e)
    }

    /// The bot lines in a finished reply, taken out of what's shown.
    static func read(_ text: String) -> Read {
        let c = Array(text)
        let hs = TagLines.hits(c, tags: tags, streaming: false)
        guard !hs.isEmpty else { return (text, [], [], [], []) }
        TagLines.logOpen(hs)
        var r: Read = (TagLines.cut(c, hs), [], [], [], [])
        for h in hs {
            guard let body = h.body else { continue }
            let n = body.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            switch h.tag {
            case "edit-bot": if let e = edit(body) { r.edits.append(e) }
            case "archive-bot": if !n.isEmpty { r.archives.append(n) }
            case "restore-bot": if !n.isEmpty { r.restores.append(n) }
            default: if !n.isEmpty, !r.deletes.contains(where: { $0.lowercased() == n.lowercased() }) { r.deletes.append(n) }
            }
        }
        return r
    }
}

// MARK: Delete only after a yes

/// A [delete-bot: …] line from chat deletes only when the reply before asked "Delete <bot>?" (in the last 30 minutes)
/// and what they sent next was a yes ("Delete it"). Otherwise nothing is deleted and One asks the question itself.
enum BotGate {
    @MainActor static var asked: [String: Date] = [:]  // bot name (lowercased) → when the question was asked
    static let window: TimeInterval = 30 * 60
    static func question(_ name: String) -> String { "Delete \(name)? Its memory and routines go too." }
    static let choices = "[choices: Delete it | Keep it]"

    static func isYes(_ typed: String) -> Bool {
        let t = typed.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let no = ["keep", "don't", "dont", "do not", "not now", "cancel", "never mind", "wait", "stop"]
        if t == "no" || t.hasPrefix("no ") || t.hasPrefix("no,") || t.hasPrefix("nope") || no.contains(where: t.contains) { return false }
        return ["delete", "yes", "yep", "yeah", "sure", "ok", "go ahead", "do it", "confirm"].contains { t.hasPrefix($0) } || t.contains("delete it")
    }
    /// Names a reply asked about: "Delete <name>?".
    static func asks(in said: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"(?i)\bdelete ([^?\n\[\]]{1,40})\?"#) else { return [] }
        let ns = said as NSString
        return re.matches(in: said, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: 1)).trimmingCharacters(in: CharacterSet(charactersIn: " *_\"'"))
        }
    }

    /// Which of these delete lines may act now, and the question One adds for the others.
    @MainActor static func decide(_ deletes: [String], said: String, typed: String, now: Date = Date()) -> (act: [String], ask: String) {
        var act: [String] = []
        var ask: [String] = []
        for n in deletes {
            let k = n.lowercased().trimmingCharacters(in: .whitespaces)
            if let at = asked[k], now.timeIntervalSince(at) < window, now >= at, isYes(typed) {
                act.append(n)
                asked[k] = nil
            } else {
                ask.append(question(n))
                asked[k] = now
            }
        }
        for n in asks(in: said) { asked[n.lowercased()] = now }  // asked in this reply: a yes next time counts
        return (act, ask.isEmpty ? "" : ask.joined(separator: "\n\n") + "\n\n" + choices)
    }
}

// MARK: The changes themselves (on the saved list; One runs the routine steps through the engine)

enum BotStore {
    struct Edited {
        var steps: [[String]] = []
        var miss: String?
        var tell: String?  // passed on to the bot (its check-in changed)
    }

    /// A routine is the bot's when its conversation made it, or it's named "<bot>: …".
    static func owns(_ h: Helper, _ r: Routine) -> Bool {
        guard let b = h.bot else { return false }
        if let s = h.sid, r.owner == s { return true }
        return r.title.lowercased().hasPrefix(b.name.lowercased() + ":")
    }
    static func owned(_ h: Helper, in routines: [Routine]) -> [Routine] { routines.filter { owns(h, $0) } }

    static func edit(_ hs: inout [Helper], at i: Int, _ e: BotEdit, routines: [Routine]) -> Edited {
        guard hs.indices.contains(i), let old = hs[i].bot else { return Edited(miss: "I couldn't find that bot.") }
        var b = old
        if let n = e.name?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty {
            let taken = hs.indices.contains { $0 != i && hs[$0].bot?.name.lowercased() == n.lowercased() }
            if taken { return Edited(miss: "There's already a bot called \(n), so I left \(old.name)'s name as it is.") }
            b.name = String(n.prefix(30))
        }
        if let c = e.color, Bots.colors.contains(where: { $0.name == c }) { b.color = c }
        if let j = e.job?.trimmingCharacters(in: .whitespacesAndNewlines), !j.isEmpty { b.job = j }
        b.uses = BotEdit.uses(b.uses, e)
        if let c = e.checkIn { b.checkIn = BotEdit.checkIn(c) }
        var out = Edited()
        if b.name != old.name {
            b.was = ((old.was ?? []) + [old.name]).filter { $0.lowercased() != b.name.lowercased() }  // its room lines keep its old tag
            move(old, to: b)
            for r in owned(hs[i], in: routines) where r.title.lowercased().hasPrefix(old.name.lowercased() + ":") {
                out.steps.append(["cron", "edit", r.id, "--name", b.name + r.title.dropFirst(old.name.count)])
            }
        }
        Bots.writeCard(b)  // the card again; its memory is kept as it is
        if b.checkIn != old.checkIn { out.tell = checkInNote(b) }
        hs[i].bot = b
        hs[i].title = b.name
        hs[i].task = b.job
        return out
    }

    /// A rename: its folder moves to the new name, and its memory's title follows.
    static func move(_ old: BotInfo, to b: BotInfo) {
        let fm = FileManager.default
        let from = Bots.folder(old)
        let to = Bots.folder(b)
        if from.standardizedFileURL.path != to.standardizedFileURL.path, fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) {
            try? fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.moveItem(at: from, to: to)
        }
        let mem = Bots.memory(b)
        for (from, to) in [("# What \(old.name) did", "# What \(b.name) did"), ("# How \(old.name) works", "# How \(b.name) works")] {
            if var t = try? String(contentsOf: mem, encoding: .utf8), t.hasPrefix(from) {
                t = to + t.dropFirst(from.count)
                try? t.write(to: mem, atomically: true, encoding: .utf8)
            }
        }
    }

    /// What the bot is told when they change when it checks in: it keeps its own routines in step.
    static func checkInNote(_ b: BotInfo) -> String {
        let what: String
        switch b.checkIn {
        case "morning": what = "make sure one routine of yours runs every morning at 8 AM, named \"\(b.name): morning check\""
        case "incoming":
            what =
                "make sure one routine of yours checks every 30 minutes for anything new and reports only when there is something, named \"\(b.name): new things\""
        default: what = "you now work only when they ask"
        }
        return
            "They changed when you check in: now \(Bots.checkWord(b.checkIn)). With your scheduling tool, \(what), and pause any routine of yours that no longer fits (never delete one). Then say what you changed in one short line."
    }

    static func archive(_ hs: inout [Helper], at i: Int, routines: [Routine]) -> [[String]] {
        guard hs.indices.contains(i), var b = hs[i].bot, b.archived == nil else { return [] }
        let on = owned(hs[i], in: routines).filter { $0.state != .paused && $0.state != .finished }.map(\.id)
        b.archived = Date()
        b.paused = on
        hs[i].bot = b
        return on.map { ["cron", "pause", $0] }
    }

    static func restore(_ hs: inout [Helper], at i: Int) -> [[String]] {
        guard hs.indices.contains(i), var b = hs[i].bot, b.archived != nil else { return [] }
        let back = b.paused ?? []
        b.archived = nil
        b.paused = nil
        hs[i].bot = b
        return back.map { ["cron", "resume", $0] }
    }

    @MainActor static func delete(_ hs: inout [Helper], at i: Int, routines: [Routine]) -> [[String]] {
        guard hs.indices.contains(i), let b = hs[i].bot else { return [] }
        let steps = owned(hs[i], in: routines).map { ["cron", "remove", $0.id] }
        try? FileManager.default.removeItem(at: Bots.folder(b))
        try? FileManager.default.removeItem(at: HelperTrail.url(hs[i].id))
        hs.remove(at: i)
        return steps
    }
}

extension Bots {
    /// On the left: every bot that isn't archived.
    static func active(_ hs: [Helper]) -> [Helper] { hs.filter { $0.bot != nil && $0.bot?.archived == nil } }
    static func archived(_ hs: [Helper]) -> [Helper] { hs.filter { $0.bot?.archived != nil } }
}

// MARK: One does it

/// The sheet: which bot, and About / Edit / the delete question.
struct BotSheetAsk: Equatable {
    enum Mode { case about, edit, confirm }
    var id: UUID
    var mode: Mode
}

@MainActor
extension Model {
    var archivedBots: [Helper] { Bots.archived(helpers) }
    /// A bot by name, archived ones too.
    func botID(named n: String) -> UUID? {
        let k = n.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return helpers.first { $0.bot?.name.lowercased() == k }?.id
    }
    /// One's own routines (the engine's jobs.json), for what a bot owns.
    nonisolated static func ownRoutines() -> [Routine] { Routines.jobs(at: Routines.cron, now: Date()) }

    func runRoutineSteps(_ steps: [[String]]) {
        guard !steps.isEmpty, !Env.commandLine else { return }
        Task {
            for s in steps {
                let (code, out) = await hermesRun(s)
                Helpers.log("bot routine \(s.joined(separator: " ")): \(code == 0 ? "done" : "failed: " + Helpers.short(out, 160))")
            }
        }
    }

    /// Applies an edit; nil when done, else a plain line why not.
    @discardableResult func editBot(_ id: UUID, _ e: BotEdit) -> String? {
        guard let i = helpers.firstIndex(where: { $0.id == id }) else { return "I couldn't find that bot." }
        var hs = helpers
        let r = BotStore.edit(&hs, at: i, e, routines: Model.ownRoutines())
        if let miss = r.miss { return miss }
        helpers = hs
        saveHelpers()
        runRoutineSteps(r.steps)
        if let t = r.tell, hs[i].bot?.archived == nil {
            followUp(Composed(display: t, engine: t, images: [], typed: t), helper: id, hidden: true)
        }
        Helpers.log("bot \"\(hs[i].title)\" edited")
        return nil
    }

    func archiveBot(_ id: UUID) {
        guard let i = helpers.firstIndex(where: { $0.id == id }), helpers[i].bot != nil else { return }
        if helpers[i].state == "working" { stopHelper(id) }
        if openHelper == id { openHelper = nil }
        var hs = helpers
        let steps = BotStore.archive(&hs, at: i, routines: Model.ownRoutines())
        helpers = hs
        saveHelpers()
        runRoutineSteps(steps)
    }

    func restoreBot(_ id: UUID) {
        guard let i = helpers.firstIndex(where: { $0.id == id }) else { return }
        var hs = helpers
        let steps = BotStore.restore(&hs, at: i)
        helpers = hs
        saveHelpers()
        runRoutineSteps(steps)
    }

    /// Only after the confirmation (the sheet's \"Delete it\", or `BotGate` for a chat line).
    func deleteBot(_ id: UUID) {
        guard let i = helpers.firstIndex(where: { $0.id == id }), helpers[i].bot != nil else { return }
        if helpers[i].state == "working" { stopHelper(id) }
        if openHelper == id { openHelper = nil }
        if botSheet?.id == id { botSheet = nil }
        var hs = helpers
        let name = hs[i].title
        let steps = BotStore.delete(&hs, at: i, routines: Model.ownRoutines())
        helpers = hs
        saveHelpers()
        BotChat.remove(id)  // its kept chat goes with it
        runRoutineSteps(steps)
        Helpers.log("bot \"\(name)\" deleted with \(steps.count) routine(s)")
    }

    /// A finished reply's bot lines: [bot: …] makes, then edits, archives, restores, and deletes behind the gate.
    func botLines(_ text: String, typed: String) -> String {
        let t = BotTags.read(makeBots(from: text))
        var full = t.said
        var misses: [String] = []
        func each(_ names: [String], _ act: (UUID) -> Void) {
            for n in names { if let id = botID(named: n) { act(id) } else { misses.append("I couldn't find a bot called \(n).") } }
        }
        for (n, e) in t.edits {
            if let id = botID(named: n) {
                if let miss = editBot(id, e) { misses.append(miss) }
            } else {
                misses.append("I couldn't find a bot called \(n).")
            }
        }
        each(t.archives) { archiveBot($0) }
        each(t.restores) { restoreBot($0) }
        let known = t.deletes.filter { botID(named: $0) != nil }
        misses += t.deletes.filter { botID(named: $0) == nil }.map { "I couldn't find a bot called \($0)." }
        let g = BotGate.decide(known, said: full, typed: typed)
        each(g.act) { deleteBot($0) }
        for s in misses + (g.ask.isEmpty ? [] : [g.ask]) { full += (full.isEmpty ? "" : "\n\n") + s }
        return full
    }
}
