import Foundation

// MARK: - Bots: a helper you keep (Claude Design "One bots design", B · Moons, picked by Omar Nov 17 2026).
// One job, a name and a colour, its own chat that stays, its own memory of what it did, and only what it needs.
// A bot IS a `Helper` with `bot` set: the same engine conversation, kept forever, so stop, tell, picking back up
// after a restart and the ask-first rules all work the way they do for helpers. It never goes on the constellation:
// it lives in the moons column on the left (BotsColumn.swift). Made by saying it ("make me a growth bot": the
// assistant asks three questions, then writes a [bot: …] line) or with "Keep as a bot" on a finished helper.
// Its memory is a plain file in its room: `<room>/bots/<name>/memory.md`, next to `bot.md` (its job and rules).
// A bot is who, a routine is when: a routine the bot sets up in its own conversation belongs to it (the engine
// records that conversation as the routine's origin), and the Routines dial filters and tints by bot.

struct BotInfo: Codable, Equatable {
    var name: String
    var color: String  // one of `Bots.colors`
    var room: String  // the room's name as shown ("Co-Founder")
    var roomPath: String  // the room's folder
    var job: String
    var uses: [String] = []  // what it may use, in plain words ("Browser", "Email drafts")
    var checkIn: String = "asked"  // "morning", "incoming" or "asked"
    var made = Date()
    var from = "chat"  // "chat" or "helper"
    var archived: Date? = nil  // put away: off the left, kept, its routines paused (BotsManage.swift)
    var paused: [String]? = nil  // the routines archiving paused, turned back on by restore
}

enum Bots {
    /// Soft colours that read on One's dark stage. Order = the order new bots take them.
    static let colors: [(name: String, hex: UInt32)] = [
        ("amber", 0xE9B26B), ("teal", 0x6FC3B8), ("rose", 0xE58C8C), ("sage", 0xA7C58A), ("sky", 0x8DB8E8), ("lilac", 0xB9A2E0),
    ]
    static func hex(_ name: String) -> UInt32 { colors.first { $0.name == name.lowercased() }?.hex ?? colors[0].hex }
    /// The first colour no bot wears yet (they repeat after six).
    static func nextColor(used: [String]) -> String {
        colors.first { !used.contains($0.name) }?.name ?? colors[used.count % colors.count].name
    }

    // MARK: Rooms

    struct Room: Equatable {
        let name: String
        let path: String
        let isPrivate: Bool
    }
    /// Every room a bot can live in: the brain's rooms and the shared rooms (never the assistant's own folder).
    static func rooms() -> [Room] {
        var out: [Room] = []
        for u in RoomMap.roomFolders() {
            let title = RoomYaml.read(u)?.title ?? pretty(u.lastPathComponent)
            out.append(Room(name: title, path: u.path, isPrivate: RoomPrivacy.isPrivate(u)))
        }
        for p in Shared.paths {
            let u = URL(fileURLWithPath: p, isDirectory: true)
            out.append(Room(name: Shared.info(u)?.title ?? u.lastPathComponent, path: p, isPrivate: false))
        }
        return out
    }
    /// "work-room" → "Work"
    static func pretty(_ folder: String) -> String {
        let s = folder.hasSuffix("-room") ? String(folder.dropLast(5)) : folder
        return s.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
    /// A room named loosely ("co-founder", "Work room", "work-room"): its name or folder, any case.
    static func room(named n: String, in all: [Room]) -> Room? {
        func key(_ s: String) -> String {
            var k = s.lowercased().replacingOccurrences(of: "-", with: " ").trimmingCharacters(in: .whitespaces)
            if k.hasSuffix(" room") { k = String(k.dropLast(5)) }
            return k.replacingOccurrences(of: " ", with: "")
        }
        let want = key(n)
        return all.first { key($0.name) == want || key(URL(fileURLWithPath: $0.path).lastPathComponent) == want }
    }
    static func isPrivate(_ b: BotInfo) -> Bool {
        !Shared.paths.contains(b.roomPath) && RoomPrivacy.isPrivate(URL(fileURLWithPath: b.roomPath, isDirectory: true))
    }

    // MARK: Its folder and memory

    static func slug(_ name: String) -> String {
        let s = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(s).split(separator: "-").joined(separator: "-")
    }
    static func folder(_ b: BotInfo) -> URL {
        URL(fileURLWithPath: b.roomPath, isDirectory: true).appendingPathComponent("bots/\(slug(b.name))", isDirectory: true)
    }
    static func memory(_ b: BotInfo) -> URL { folder(b).appendingPathComponent("memory.md") }
    static func card(_ b: BotInfo) -> URL { folder(b).appendingPathComponent("bot.md") }

    /// How many things it keeps: the lines of its memory that start with "- ".
    static func remembered(_ b: BotInfo) -> Int {
        guard let t = try? String(contentsOf: memory(b), encoding: .utf8) else { return 0 }
        return t.components(separatedBy: "\n").filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- ") }.count
    }
    /// What it did, newest last: the last few "## YYYY-MM-DD" days of its memory with their first line.
    static func days(_ b: BotInfo, max n: Int = 4) -> [(day: String, what: String)] {
        guard let t = try? String(contentsOf: memory(b), encoding: .utf8) else { return [] }
        var out: [(String, String)] = []
        var day: String?
        for raw in t.components(separatedBy: "\n") {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("## ") {
                day = dayWord(String(l.dropFirst(3)))
            } else if let d = day, l.hasPrefix("- ") {
                out.append((d, String(l.dropFirst(2))))
                day = nil
            }
        }
        return Array(out.suffix(n))
    }
    /// "2026-11-17" → "Today", "Mon", or the date as written.
    static func dayWord(_ s: String, now: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: s.trimmingCharacters(in: .whitespaces)) else { return s }
        let cal = Calendar.current
        if cal.isDate(d, inSameDayAs: now) { return "Today" }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: y) { return "Yesterday" }
        f.dateFormat = now.timeIntervalSince(d) < 6 * 86400 ? "EEE" : "MMM d"
        return f.string(from: d)
    }
    static func checkWord(_ c: String) -> String {
        switch c {
        case "morning": return "every morning at 8"
        case "incoming": return "when something comes in"
        default: return "only when you ask"
        }
    }
    /// "Uses: Browser, Facebook · Checks in: every morning at 8 · Remembers 14 things"
    static func facts(_ b: BotInfo, remembered n: Int) -> String {
        let uses = b.uses.isEmpty ? "what you allow" : b.uses.joined(separator: ", ")
        return "Uses: \(uses) · Checks in: \(checkWord(b.checkIn)) · Remembers \(n) thing\(n == 1 ? "" : "s")"
    }

    /// Writes `bot.md` (its job, what it may use, when it checks in, its rules) and starts `memory.md`.
    static func writeCard(_ b: BotInfo, seed: String? = nil) {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder(b), withIntermediateDirectories: true)
        let card = """
            # \(b.name)

            A bot: a helper kept for one job, with its own chat. Made \(DateFormatter.localizedString(from: b.made, dateStyle: .medium, timeStyle: .none)).

            - Job: \(b.job)
            - May use: \(b.uses.isEmpty ? "only what it's given" : b.uses.joined(separator: ", "))
            - Checks in: \(checkWord(b.checkIn))
            - Always asks before sending, spending, posting or deleting.

            What it did is in [memory.md](memory.md).

            """
        try? card.write(to: self.card(b), atomically: true, encoding: .utf8)
        guard !fm.fileExists(atPath: memory(b).path) else { return }
        var mem = "# What \(b.name) did\n\n## Rules\n\n"
        if let seed, !seed.isEmpty { mem += "## \(today())\n\n- \(seed)\n" }
        try? mem.write(to: memory(b), atomically: true, encoding: .utf8)
    }
    static func today(_ d: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    // MARK: Words for the assistant

    /// "[bot: Name | colour | room | job | uses, comma separated | morning/incoming/asked]"
    static func parse(_ body: String, rooms: [Room]) -> BotInfo? {
        let p = body.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard p.count >= 4, !p[0].isEmpty, !p[3].isEmpty else { return nil }
        let room = room(named: p[2], in: rooms) ?? rooms.first { !$0.isPrivate } ?? rooms.first
        guard let room else { return nil }
        let color = colors.contains { $0.name == p[1].lowercased() } ? p[1].lowercased() : colors[0].name
        let uses = p.count > 4 ? p[4].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } : []
        let c = p.count > 5 ? p[5].lowercased() : "asked"
        let check = c.contains("morning") ? "morning" : (c.contains("incoming") || c.contains("comes in")) ? "incoming" : "asked"
        return BotInfo(name: String(p[0].prefix(30)), color: color, room: room.name, roomPath: room.path, job: p[3], uses: uses, checkIn: check)
    }

    /// The main assistant's rule for making a bot (every prompt via `Helpers.note`, and SOUL).
    static let soul = """
        Bots: a bot is a helper they keep for one job, with its own chat that stays, its own memory and only what it needs; it sits on the left of the screen, and its routines show on the Routines dial in its colour. When they ask for a bot ("make me a growth bot", "I'd like a new bot"), ask three quick questions, one per message: 1) its one job, 2) what it may use (end with [choices: Browser | Email drafts | Calendar | Files] or what fits), 3) whether it checks in on its own, ending with [choices: Every morning | When something comes in | Only when I ask]. Then show a short preview (its name, its room, its job, what it uses, when it checks in, and that it asks before sending, spending or posting) ending with [choices: Make the bot | Change something]. Only after "Make the bot", add one line exactly like [bot: Growth bot | amber | Co-Founder | Find new customers for the heating business | Browser, Email drafts | morning] (name | colour: amber, teal, rose, sage, sky or lilac | the room it lives in | its one job | what it may use | morning, incoming or asked) and say in one line it's on the left. The room is the one you're talking in; ask only if it could be two. "tell <bot> …" works like a helper: [tell-helper: <bot name> | message]. In a good morning or status report, add one line per bot on what it did (from its memory file); a bot in a private room only as a headline.
        """
    static var note: String { "\n\n(One app note, not from the user: " + soul + ")" }

    /// Every turn of a bot's own conversation.
    static func rules(_ b: BotInfo, user: String) -> String {
        let who = user.isEmpty ? "them" : user
        return """


            (One app note, not from the user: You are \(b.name), a bot \(who) keeps for one job: \(b.job). You live in the room at \(b.roomPath) and follow its rules; write only there. You may use: \(b.uses.isEmpty ? "only what they give you" : b.uses.joined(separator: ", ")); don't reach for anything else without asking. Always ask before sending, spending, posting or deleting, ending with a [choices: ...] line. Your memory is \(memory(b).path): after each piece of work add one short line under a "## \(today())" heading for today (make it if it's missing), like "- Answered 2 new leads, booked 1 visit"; lasting rules they give you go under "## Rules". Read it when you start a turn. A routine you set up with your scheduling tool belongs to you; name it "\(b.name): …", and make it only check and draft, never send, buy or delete. Reply in a few plain lines.)
            """
    }
    /// A new bot's first turn: it reads its card, sets up its check-in, and says hello in two lines.
    static func brief(_ b: BotInfo, user: String) -> String {
        let check: String
        switch b.checkIn {
        case "morning":
            check =
                "Set up one routine with your scheduling tool for every morning at 8 AM that checks and drafts for your job, named \"\(b.name): morning check\"."
        case "incoming":
            check =
                "Set up one routine with your scheduling tool that checks every 30 minutes for anything new for your job and reports only when there is something, named \"\(b.name): new things\"."
        default: check = "Don't set up any routine: you work when they ask."
        }
        return
            "You're \(b.name), just made. Your one job: \(b.job). Read \(card(b).path). \(check) Then say hello to \(user.isEmpty ? "them" : user) in two short lines: what you'll do and when you'll check in."
            + rules(b, user: user)
    }
}

// MARK: - Making, keeping and listing bots

@MainActor
extension Model {
    /// Every bot, in the order they were made.
    var bots: [Helper] { helpers.filter { $0.bot != nil } }

    /// Takes the [bot: …] lines out of a finished reply and makes each bot. Returns what's left to show.
    func makeBots(from text: String) -> String {
        let (rest, bodies) = TagLines.extract(text, tag: "bot")
        guard !bodies.isEmpty else { return text }
        let all = Bots.rooms()
        for body in bodies {
            guard var b = Bots.parse(body, rooms: all) else {
                Helpers.log("couldn't read a bot line: \(Helpers.short(body, 200))")
                continue
            }
            guard !bots.contains(where: { $0.title.lowercased() == b.name.lowercased() }) else { continue }  // the same bot twice
            if bots.contains(where: { $0.bot?.color == b.color }) { b.color = Bots.nextColor(used: bots.compactMap(\.bot?.color)) }
            makeBot(b)
        }
        return rest
    }

    /// A new bot: its card and memory in its room, then its own conversation, which starts by saying hello.
    func makeBot(_ b: BotInfo) {
        Bots.writeCard(b)
        var h = Helper(title: b.name, task: b.job, sid: nil, state: "working", line: "Getting ready…")
        h.started = Date()
        h.bot = b
        h.budgetOff = true  // a bot is kept for good: no share of the week like a one-off job (Budget.swift)
        HelperTrail.flush(h)
        helpers.append(h)
        saveHelpers()
        let id = h.id
        Task { @MainActor in
            guard let sid = await Engine.shared.openSession() else {
                self.update(id) { HelperTrail.notFinished(&$0, .cutOff) }
                self.saveTrail(id)
                self.resumeWhenReady(after: 1)
                return
            }
            self.update(id) { $0.sid = sid }
            await self.runHelper(id, Bots.brief(b, user: self.userName), images: [])
        }
    }

    /// "Keep as a bot" on a finished helper: the same conversation stays, now kept, with a name, colour and room.
    func keepAsBot(_ id: UUID, name: String, color: String, room: Bots.Room) {
        guard let h = helpers.first(where: { $0.id == id }), h.bot == nil else { return }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = BotInfo(
            name: n.isEmpty ? h.title : String(n.prefix(30)), color: color, room: room.name, roomPath: room.path, job: h.task,
            from: "helper")
        Bots.writeCard(b, seed: "Kept from the helper \"\(h.title)\": " + Helpers.summary(Choices.split(h.reply).body, 160))
        update(id) {
            $0.bot = b
            $0.title = b.name
            $0.budgetOff = true
            $0.seen = true
        }
        saveHelpers()
        Helpers.log("helper \"\(h.title)\" kept as the bot \"\(b.name)\" in \(b.room)")
    }

    /// What the main assistant is told about the bots every turn (part of `helperNews`).
    func botNews() -> String {
        guard !bots.isEmpty else { return "" }
        let lines = bots.compactMap { h -> String? in
            guard let b = h.bot else { return nil }
            if Bots.isPrivate(b) { return "- A bot in the private room \(b.room) (\(h.state == "working" ? "working" : "resting")): headline only." }
            let state =
                h.state == "working"
                ? "working (\(h.line))" : h.state == "needsYes" ? "waiting for \(userName)'s yes" : h.waiting ? "has something new" : "resting"
            return "- \(b.name) (\(b.room) room, job: \(b.job)): \(state). What it did is in \(Bots.memory(b).path)."
        }
        return "\n\n(One app note, not from the user: their bots right now. Don't repeat a bot's result; tap its orb on the left to see it.\n"
            + lines.joined(separator: "\n") + ")"
    }
}
