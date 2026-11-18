import Foundation

/// Part of `One --test-helpers` (preflight), after BotsCheck: a bot's things go to the bot (BotRoute.swift).
/// Its files show in its own chat and under Ready for you, tagged with it; its asks (a sign-in, a code, a passkey,
/// its routine's choices) show only in its chat with a badge on its orb, and the answer reaches it; an ask from one of
/// the assistant's own helpers still shows in the assistant's chat. Omar, Nov 18 2026: "If a bot is doing something
/// I want to be talking to the bot." Test-only data: a scratch room under the test world's One folder.
enum BotRouteCheck {
    @MainActor static func run(_ check: (String, Bool) -> Void) {
        let m = Model.shared
        let fm = FileManager.default
        let keep = (m.helpers, m.humanSteps, m.openHelper, m.shelf, m.bubbles.count, m.outbox)
        let base = Env.support.appendingPathComponent("bots-route", isDirectory: true)
        try? fm.removeItem(at: base)
        let room = base.appendingPathComponent("work-room", isDirectory: true)
        let secret = base.appendingPathComponent("nyx-room", isDirectory: true)
        try? fm.createDirectory(at: room, withIntermediateDirectories: true)
        try? fm.createDirectory(at: secret, withIntermediateDirectories: true)
        try? "title: Work\nprivate: false\n".write(to: room.appendingPathComponent("room.yaml"), atomically: true, encoding: .utf8)

        let info = BotInfo(name: "Work Finder", color: "teal", room: "Work", roomPath: room.path, job: "Find part-time work")
        var bot = Helper(title: "Work Finder", task: info.job, sid: "local-bot", state: "done", line: "")
        bot.bot = info
        let shy = BotInfo(name: "Diary", color: "rose", room: "Nyx", roomPath: secret.path, job: "Listen")
        var hidden = Helper(title: "Diary", task: shy.job, sid: "local-diary", state: "done", line: "")
        hidden.bot = shy
        let helper = Helper(title: "Flights", task: "Find a flight", sid: "local-helper", state: "working", line: "")
        m.helpers = [bot, hidden, helper]
        m.openHelper = nil

        print("1. a bot's file shows in its chat and under Ready for you")
        Bots.writeCard(info)
        Bots.writeCard(shy)
        let drafts = Bots.folder(info).appendingPathComponent("drafts", isDirectory: true)
        try? fm.createDirectory(at: drafts, withIntermediateDirectories: true)
        let file = drafts.appendingPathComponent("2026-11-18.md")
        try? "# Drafts, 2026-11-18\n\nNothing here is sent.\n".write(to: file, atomically: true, encoding: .utf8)
        try? "# Diary\n\nprivate\n".write(to: Bots.folder(shy).appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        let found = BotRoute.adopt([], bots: m.helpers)
        let mine = found.first { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath() == file.resolvingSymlinksInPath() }
        check("the file it saved in its folder is picked up", mine != nil)
        check("tagged with the bot", mine?.bot == bot.id && mine?.from == "Work Finder")
        check("titled from its heading", mine?.title == "Drafts, 2026-11-18")
        check(
            "its card and memory are never shown as files",
            !found.contains { $0.path.hasSuffix("/bot.md") || $0.path.hasSuffix("/memory.md") })
        m.shelf = found
        check("it shows under Ready for you", BotRoute.shown(m.shelf, bots: m.helpers).contains { $0.path == mine?.path })
        check("and in the bot's own chat", BotRoute.chatFiles(m.shelf, bot: bot.id).contains { $0.path == mine?.path })
        let diary = found.first { $0.bot == hidden.id }
        check("a private room's bot keeps its file in its own chat", diary != nil && BotRoute.chatFiles(m.shelf, bot: hidden.id).count == 1)
        check("but never under Ready for you", !BotRoute.shown(m.shelf, bots: m.helpers).contains { $0.bot == hidden.id })
        check("a file already on the shelf isn't added twice", BotRoute.adopt(m.shelf, bots: m.helpers).isEmpty)
        let rules = Bots.rules(info, user: "Omar")
        check(
            "the bot is told where its files go and where they show",
            rules.contains(Bots.folder(info).path) && rules.contains("Ready for you") && rules.contains("your chat"))

        print("2. a bot's sign-in ask shows only in its chat, and the answer reaches it")
        try? fm.removeItem(at: HumanStep.dir)
        func ask(_ id: String, session: String) {
            let j: [String: Any] = [
                "id": id, "created": Date().timeIntervalSince1970, "site": "login.example.com", "kind": "sign_in", "port": 9224,
                "target_id": "T-\(id)", "url": "https://login.example.com", "session": session, "ask": true,
            ]
            try? fm.createDirectory(at: HumanStep.dir, withIntermediateDirectories: true)
            if let d = try? JSONSerialization.data(withJSONObject: j) { try? d.write(to: HumanStep.dir.appendingPathComponent("\(id).request.json")) }
        }
        ask("botask", session: "local-bot")
        ask("helperask", session: "local-helper")
        ask("mainask", session: "")
        m.humanSteps = HumanStep.pending()
        check("three asks are waiting", m.humanSteps.count == 3)
        m.openHelper = nil
        let main = Set(m.stepsHere.map(\.id))
        check("the assistant's chat doesn't show the bot's ask", !main.contains("botask"))
        check("an ask from one of her helpers still shows in her chat", main.contains("helperask"))
        check("and so does her own", main.contains("mainask"))
        check("the bot's orb shows it needs you", m.stepWaiting(bot) && BotsColumn.line(bot, waiting: true) == "Needs your yes")
        check("another bot's orb doesn't", !m.stepWaiting(hidden))
        m.openHelper = bot.id
        check("the bot's chat shows its own ask and only that", m.stepsHere.map(\.id) == ["botask"])
        m.openHelper = helper.id
        check("a helper's chat isn't handed the bot's ask", !m.stepsHere.contains { $0.id == "botask" })
        m.openHelper = nil
        check(
            "a yes typed in the assistant's chat never answers the bot's ask",
            BotRoute.askFor(helper: nil, steps: m.humanSteps, in: m.helpers, helperFor: [:])?.id != "botask")
        check(
            "a yes in the bot's chat finds its ask",
            BotRoute.askFor(helper: bot.id, steps: m.humanSteps, in: m.helpers, helperFor: [:])?.id == "botask")
        m.answerHumanStep("botask", "done")
        let answer = (try? Data(contentsOf: HumanStep.dir.appendingPathComponent("botask.answer.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        check("Done in the bot's chat goes back to the bot's waiting step", answer?["answer"] as? String == "done")
        check("and the ask leaves its chat", !m.humanSteps.contains { $0.id == "botask" } && !m.stepWaiting(bot))
        try? fm.removeItem(at: HumanStep.dir)
        m.humanSteps = []

        print("3. a bot's routine reports to the bot, and its answer reaches the bot")
        check(
            "a routine named after the bot is the bot's",
            BotRoute.routineBot(title: "Work Finder: morning check", origin: nil, in: m.helpers)?.id == bot.id)
        check("so is one its own conversation made", BotRoute.routineBot(title: "Leads", origin: "local-bot", in: m.helpers)?.id == bot.id)
        check("anyone else's stays with the assistant", BotRoute.routineBot(title: "Morning brief", origin: "local-main", in: m.helpers) == nil)
        let bubbles = m.bubbles.count
        let outbox = m.outbox.count
        m.deliverToBot(bot.id, title: "Work Finder: morning check", body: "3 new leads. Drafts ready.\n\n[choices: Show me the drafts | Not now]")
        let after = m.helpers.first { $0.id == bot.id }
        check("the report is in the bot's chat", after?.log?.last?.contains("3 new leads") == true)
        check(
            "its choices wait there, with the badge",
            after?.state == "needsYes" && Choices.split(after?.reply ?? "").choices == ["Show me the drafts", "Not now"])
        check(
            "nothing about it lands in the assistant's chat",
            m.bubbles.count == bubbles && !m.outbox.dropFirst(outbox).contains { BotRoute.showsInChat($0) })
        let told = m.takeRoutineNews(bot.id)
        check("their answer carries the report to the bot", told.contains("3 new leads") && told.contains("Work Finder: morning check"))
        check("once", m.takeRoutineNews(bot.id).isEmpty)

        print("4. a bot waiting on its yes is a badge on the left, not a line in the assistant's chat")
        var waiting = bot
        waiting.state = "needsYes"
        waiting.seen = false
        waiting.toldState = nil
        m.helpers = [waiting, helper]
        let before = m.outbox.count
        m.queueDoneNote(waiting.id)
        check("no \"needs your yes\" line in the assistant's chat", m.outbox.count == before)
        check("never on her While you were gone card", !BotRoute.awayCard(waiting, away: true, open: nil))
        var done = helper
        done.state = "needsYes"
        check("a helper still is", BotRoute.awayCard(done, away: true, open: nil))

        (m.helpers, m.humanSteps, m.openHelper, m.shelf) = (keep.0, keep.1, keep.2, keep.3)
        if m.bubbles.count > keep.4 { m.bubbles.removeLast(m.bubbles.count - keep.4) }
        m.outbox = keep.5
        try? fm.removeItem(at: base)
    }
}
