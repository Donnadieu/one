import Foundation

/// Part of `One --test-helpers` (preflight): bots (Bots.swift). A [bot: …] line is read whole and hidden while it
/// streams; rooms match loosely; a bot survives a restart, is never cleared by "all" and keeps its memory file;
/// its turns carry its job, room, memory and the ask-first rule; its routines wear its colour on the dial.
enum BotsCheck {
    @MainActor static func run(_ check: (String, Bool) -> Void) {
        let rooms = [
            Bots.Room(name: "Personal", path: "/b/personal-room", isPrivate: true), Bots.Room(name: "Work", path: "/b/work-room", isPrivate: false),
            Bots.Room(name: "Co-Founder", path: "/c/Co-Founder", isPrivate: false),
        ]
        let line = "Growth bot | teal | co-founder | Find new customers | Browser, Email drafts | Every morning"
        let b = Bots.parse(line, rooms: rooms)
        check(
            "a bot line is read: name, colour, room, job",
            b?.name == "Growth bot" && b?.color == "teal" && b?.room == "Co-Founder" && b?.job == "Find new customers")
        check("and what it uses and when it checks in", b?.uses == ["Browser", "Email drafts"] && b?.checkIn == "morning")
        check(
            "a room by its folder or with \"room\" after it",
            Bots.room(named: "Work room", in: rooms)?.path == "/b/work-room" && Bots.room(named: "personal-room", in: rooms)?.isPrivate == true)
        check("an unknown colour falls back to the first", Bots.parse("A | purple | Work | job", rooms: rooms)?.color == Bots.colors[0].name)
        check("a line with no job makes nothing", Bots.parse("A | teal | Work |  ", rooms: rooms) == nil)
        check("a new bot takes a colour nobody wears", Bots.nextColor(used: ["amber", "teal"]) == "rose")

        let reply = "It's on the left.\n[bot: Intake bot | sky | Work | Answer new leads | Calendar | incoming]"
        let (rest, bodies) = TagLines.extract(reply, tag: "bot")
        check(
            "the bot line comes out of the reply whole",
            rest.trimmingCharacters(in: .whitespacesAndNewlines) == "It's on the left." && bodies.count == 1)
        check("and is hidden while it streams in", !Helpers.strip("Making it.\n[bot: Intake bot | sky | Wo").contains("[bot"))

        var h = Helper(title: "Growth bot", task: "Find new customers", sid: "s-1", state: "done", line: "")
        h.bot = b
        let back = (try? JSONEncoder().encode([h])).flatMap { try? JSONDecoder().decode([Helper].self, from: $0) }
        check("a bot is saved and read back after a restart", back?.first?.bot == b)
        let plain = Helper(title: "Flight", task: "x", sid: nil, state: "done", line: "")
        check("\"clear them all\" never takes a bot", HelperClose.match("all", in: [h, plain]) == [plain.id])
        check("but asking for it by name does", HelperClose.match("growth bot", in: [h, plain]) == [h.id])
        check("its notice says it has something new", Helpers.doneLine([h]).contains("has something new"))

        let room = Env.support.appendingPathComponent("bots-check/work-room", isDirectory: true)
        let mine = BotInfo(name: "Standup notes", color: "sky", room: "Work", roomPath: room.path, job: "Write my standup")
        Bots.writeCard(mine, seed: "Wrote Monday's notes")
        check("its card and memory are made in its room", FileManager.default.fileExists(atPath: Bots.card(mine).path) && Bots.remembered(mine) == 1)
        check("what it did reads back by day", Bots.days(mine).first?.day == "Today" && Bots.days(mine).first?.what == "Wrote Monday's notes")
        check("the facts line", Bots.facts(mine, remembered: 1) == "Uses: what you allow · Checks in: only when you ask · Remembers 1 thing")
        let rules = Bots.rules(mine, user: "Omar")
        check(
            "every bot turn carries its job, room, memory and the ask-first rule",
            rules.contains("Write my standup") && rules.contains(room.path) && rules.contains(Bots.memory(mine).path)
                && rules.contains("Always ask before sending, spending, posting or deleting"))
        check("a morning bot's first turn sets up its routine", Bots.brief(b!, user: "Omar").contains("every morning at 8 AM"))
        try? FileManager.default.removeItem(at: room.deletingLastPathComponent())

        var r = Routine(
            id: "r1", title: "Growth bot: morning check", what: "", often: "", today: [480], every: nil, lastRun: nil, next: nil, state: .never,
            reason: nil)
        r.owner = "s-1"
        let L = Dial.layout(RoutinesSnapshot(routines: [r], skills: [], now: Date()), tints: ["r1": Bots.hex("teal")])
        check("a bot's routine wears its colour on the dial", L.marks.first?.tint == Bots.hex("teal") && L.labels.first?.tint == Bots.hex("teal"))
        BotsManageCheck.run(check)  // view, edit, archive, delete (BotsManage.swift)
        BotRouteCheck.run(check)  // its files and asks go to the bot (BotRoute.swift)
    }
}
