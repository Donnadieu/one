import AppKit
import SwiftUI

// MARK: - A bot's things go to the bot (Omar, Nov 18 2026: "If a bot is doing something I want to be talking to the bot.")
//
// What went wrong (One 0.9.127): the "Part-time Work Finder" bot saved its drafts in its own folder
// (`<room>/bots/<name>/drafts/…`), which Ready for you never looked at, and its chat had no place for files, so Omar
// couldn't find them. Its sign-in ask (the engine's hand_off card) showed in whichever chat was open, the assistant's
// included, with a "needs your yes" line in her chat; and its morning routine's report, with its choices, landed in the
// assistant's chat, where his "Not now" reached her instead of the bot.
// Now: every file in a bot's folder (but its card and memory) goes on Ready for you, tagged with the bot, and in the
// bot's own chat (a private room's bot: its chat only). An ask whose conversation is a bot's shows only in that bot's
// chat, with the orange ring on its orb on the left; the hand-off window opens from its card there, and the answer goes
// to the step the bot is waiting on. A bot's routine reports into the bot's chat; the next thing they say to the bot
// carries that report. The assistant's chat keeps only her own asks and her helpers'. Checked by BotRouteCheck.swift.

enum BotRoute {
    /// The bot whose engine conversation this is.
    static func bot(session: String, in hs: [Helper]) -> Helper? {
        guard !session.isEmpty else { return nil }
        return hs.first { $0.bot != nil && $0.sid == session }
    }
    /// The bot an ask belongs to: its own conversation's step, or One's robot-check ask made for it. nil = not a bot's.
    static func owner(_ a: HumanStepAsk, in hs: [Helper], helperFor: [String: UUID]) -> UUID? {
        if let b = bot(session: a.session, in: hs) { return b.id }
        if let id = helperFor[a.id], hs.contains(where: { $0.id == id && $0.bot != nil }) { return id }
        return nil
    }
    /// The asks the open chat shows: a bot's chat only its own; every other view (the assistant, a helper) all but bots'.
    static func steps(_ all: [HumanStepAsk], open: UUID?, in hs: [Helper], helperFor: [String: UUID]) -> [HumanStepAsk] {
        let openBot = open.flatMap { id in hs.first { $0.id == id && $0.bot != nil }?.id }
        return all.filter { owner($0, in: hs, helperFor: helperFor) == openBot }
    }
    /// The ask a typed "Yes, show it" answers: in a helper's or bot's chat, its own; in the assistant's, never a bot's.
    static func askFor(helper: UUID?, steps: [HumanStepAsk], in hs: [Helper], helperFor: [String: UUID]) -> HumanStepAsk? {
        if let helper {
            if let a = steps.first(where: { helperFor[$0.id] == helper }) { return a }
            guard let sid = hs.first(where: { $0.id == helper })?.sid, !sid.isEmpty else { return nil }
            return steps.first { $0.session == sid }
        }
        return steps.first { $0.ask && helperFor[$0.id] == nil && owner($0, in: hs, helperFor: helperFor) == nil }
    }

    // MARK: Its routine

    /// The bot a routine belongs to: the conversation that made it, or its name ("<bot>: morning check").
    static func routineBot(title: String, origin: String?, in hs: [Helper]) -> Helper? {
        if let o = origin, let b = bot(session: o, in: hs) { return b }
        let t = title.lowercased()
        return hs.first { h in h.bot.map { t.hasPrefix($0.name.lowercased() + ":") } ?? false }
    }
    /// The engine conversation that made a routine (jobs.json `origin.chat_id`).
    static func origin(job: String, cron: URL = Routines.cron) -> String? {
        guard let d = try? Data(contentsOf: cron.appendingPathComponent("jobs.json")),
            let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let jobs = j["jobs"] as? [[String: Any]]
        else { return nil }
        return (jobs.first { $0["id"] as? String == job }?["origin"] as? [String: Any])?["chat_id"] as? String
    }

    // MARK: Its files

    static let notFiles: Set<String> = ["bot.md", "memory.md"]
    static let text: Set<String> = ["md", "markdown", "txt", "text"]
    /// New files in each bot's folder (any depth; never its card or memory), tagged with the bot. Off the main thread.
    static func adopt(_ have: [ShelfItem], bots: [Helper]) -> [ShelfItem] {
        let fm = FileManager.default
        let known = Set(have.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path })
        let hidden = Set(
            (UserDefaults.standard.stringArray(forKey: "shelfHidden") ?? []).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
        var out: [ShelfItem] = []
        for h in bots {
            guard let b = h.bot else { continue }
            let dir = Bots.folder(b).resolvingSymlinksInPath()
            let keys: [URLResourceKey] = [.isRegularFileKey, .creationDateKey]
            guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { continue }
            for case let u as URL in e {
                let real = u.resolvingSymlinksInPath()
                let name = u.lastPathComponent
                let top = real.deletingLastPathComponent().path == dir.path
                guard !known.contains(real.path), !hidden.contains(real.path), !(top && notFiles.contains(name)),
                    (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true, !name.hasSuffix(".part"), !name.hasPrefix("~")
                else { continue }
                out.append(item(u, path: real.path, bot: h.id, name: b.name))
            }
        }
        return out.sorted { $0.made > $1.made }
    }
    /// Its card: titled from a document's "# " heading, its first line as the detail, from the bot.
    static func item(_ u: URL, path: String, bot: UUID, name: String) -> ShelfItem {
        let made = (try? u.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        var title = u.deletingPathExtension().lastPathComponent
        let kind = u.pathExtension.uppercased()
        var detail = kind.isEmpty ? "A file \(name) made" : "\(kind) · ready to share"
        if text.contains(u.pathExtension.lowercased()), let h = try? FileHandle(forReadingFrom: u) {
            let head = String(decoding: h.readData(ofLength: 4096), as: UTF8.self)
            try? h.close()
            let lines = head.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            if let t = lines.first(where: { $0.hasPrefix("# ") }) { title = String(t.dropFirst(2)) }
            if let f = lines.first(where: { !$0.isEmpty && !$0.hasPrefix("#") && $0 != "---" }) { detail = Helpers.short(f, 60) }
        }
        return ShelfItem(title: title, detail: detail, from: name, path: path, made: made, fresh: true, bot: bot)
    }
    /// Bots whose room is private: their files stay in their own chat, never on Ready for you.
    static func privateBots(_ bots: [Helper]) -> Set<UUID> {
        Set(bots.compactMap { h in h.bot.flatMap { Bots.isPrivate($0) ? h.id : nil } })
    }
    static func shown(_ shelf: [ShelfItem], hiding: Set<UUID>) -> [ShelfItem] {
        hiding.isEmpty ? shelf : shelf.filter { $0.bot.map { !hiding.contains($0) } ?? true }
    }
    static func shown(_ shelf: [ShelfItem], bots: [Helper]) -> [ShelfItem] { shown(shelf, hiding: privateBots(bots)) }
    /// The files in a bot's own chat, newest first.
    static func chatFiles(_ shelf: [ShelfItem], bot: UUID) -> [ShelfItem] {
        shelf.filter { $0.bot == bot }.sorted { $0.made > $1.made }
    }
    @MainActor static var hidden: Set<UUID> = []  // private rooms' bots, read with each shelf scan

    // MARK: The assistant's chat

    /// Would this put a line in the assistant's chat?
    static func showsInChat(_ o: Outgoing) -> Bool {
        switch o {
        case .helperNews: return true
        case .line(let bubble, _): return bubble != nil
        default: return false
        }
    }
    /// The "While you were gone" card is the assistant's: her helpers only, never a bot.
    static func awayCard(_ h: Helper, away: Bool, open: UUID?) -> Bool {
        h.bot == nil && (away || (open != h.id && h.state == "needsYes"))
    }
}

@MainActor
extension Model {
    /// The sign-in, code and robot-check cards for the chat that's open (BotRoute.steps).
    var stepsHere: [HumanStepAsk] {
        BotRoute.steps(humanSteps.filter { !RoutineCare.isAsk($0.id) }, open: openHelper, in: helpers, helperFor: BlockedAsk.helperFor)
    }
    /// A step only they can do is waiting for this bot: the orange ring on its orb.
    func stepWaiting(_ h: Helper) -> Bool {
        h.bot != nil && humanSteps.contains { BotRoute.owner($0, in: helpers, helperFor: BlockedAsk.helperFor) == h.id }
    }
    /// Ready for you: everything but a private room's bot's files.
    var shelfShown: [ShelfItem] { BotRoute.shown(shelf, hiding: BotRoute.hidden) }

    /// A routine finished: a bot's report goes to the bot. False = the assistant's, as before.
    func routineToBot(title: String, body: String, job: String) -> Bool {
        guard let b = BotRoute.routineBot(title: title, origin: BotRoute.origin(job: job), in: helpers) else { return false }
        deliverToBot(b.id, title: title, body: body)
        return true
    }
    /// Its routine's report, in its own chat: its choices wait there with the orange ring; nothing in the assistant's chat.
    func deliverToBot(_ id: UUID, title: String, body: String) {
        guard let h = helpers.first(where: { $0.id == id }), h.bot != nil else { return }
        let parts = Choices.split(body)
        let said = "**\(title)**\n\n" + parts.body.trimmingCharacters(in: .whitespacesAndNewlines)
        BotChat.add(h, entry: said)  // its whole chat, with times (BotChat.swift)
        update(id) { b in
            b.log = Array(((b.log ?? []) + [said]).suffix(40))
            b.routineNews = (b.routineNews.map { $0 + "\n\n" } ?? "") + "\"\(title)\" reported:\n" + body
            guard b.state != "working" else { return }  // the turn at work ends on its own reply; the report stays in its chat
            b.reply = said + (parts.choices.isEmpty ? "" : "\n\n[choices: " + parts.choices.joined(separator: " | ") + "]")
            b.state = parts.choices.isEmpty ? "done" : "needsYes"
            b.line = parts.choices.isEmpty ? "Done · " + Helpers.summary(parts.body, 30) : "Needs your yes"
            b.seen = openHelper == id
            b.toldState = b.state  // its news is the ring on its orb, not a line in the assistant's chat
            b.finishedAway = false
        }
        saveHelpers()
        if !Env.selfTest { Floater.shared.note("\(h.title) has something new.") }
        enqueue(.line(bubble: nil, spoken: "\(h.title) has something new. It's on the left."))
    }
    /// What they say next to the bot carries its routine's report, once (the bot's conversation never saw it).
    func takeRoutineNews(_ id: UUID) -> String {
        guard let n = helpers.first(where: { $0.id == id })?.routineNews, !n.isEmpty else { return "" }
        update(id) { $0.routineNews = nil }
        saveHelpers()
        return "\n\n(One app note, not from the user: your routine posted this in your chat; their message may be answering it:\n" + n + ")"
    }
}

/// The files a bot made, in its own chat, newest first; a tap opens one in Ready for you's reader.
struct BotFiles: View {
    @ObservedObject var m: Model
    let h: Helper
    var body: some View {
        let files = BotRoute.chatFiles(m.shelf, bot: h.id)
        if !files.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("ITS FILES").font(.system(size: 9.5, weight: .semibold)).tracking(1.1).foregroundStyle(WorldLook.cream.opacity(0.32))
                ForEach(files.prefix(4)) { it in
                    ShelfCardView(item: it).onTapGesture { m.openShelf(it.id) }
                        .onDrag { NSItemProvider(contentsOf: it.url) ?? NSItemProvider() }.help("Click to open it")
                }
                if files.count > 4 {
                    Text("And \(files.count - 4) more in its folder").font(.system(size: 11)).foregroundStyle(WorldLook.cream.opacity(0.4))
                }
            }
        }
    }
}
