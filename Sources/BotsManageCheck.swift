import Foundation

/// Part of `One --test-helpers` (preflight), after BotsCheck: managing a bot once it's made (BotsManage.swift).
/// View its info; edit its name, colour, job, uses and check-in (kept after a restart, memory and routines kept
/// with it); archive (hidden, kept, routines paused) and restore; delete (saved entry, folder and its own routines
/// gone, nobody else's); the chat lines Iris writes for each, never shown or read aloud; and no delete from chat
/// without a yes to "Delete <bot>?". Files go under ONE_SUPPORT_DIR, never a real room.
enum BotsManageCheck {
    @MainActor static func run(_ check: (String, Bool) -> Void) {
        let fm = FileManager.default
        let root = Env.support.appendingPathComponent("bots-manage-check", isDirectory: true)
        let room = root.appendingPathComponent("co-room", isDirectory: true)
        try? fm.removeItem(at: root)
        func bot(_ name: String, _ color: String, sid: String, uses: [String], check c: String) -> Helper {
            let b = BotInfo(name: name, color: color, room: "Co-Founder", roomPath: room.path, job: "Find new customers", uses: uses, checkIn: c)
            Bots.writeCard(b, seed: "Drafted 3 posts")
            var h = Helper(title: name, task: b.job, sid: sid, state: "done", line: "")
            h.bot = b
            h.log = ["Morning check done."]
            return h
        }
        func routine(_ id: String, _ title: String, owner: String?, _ st: Routine.State = .worked) -> Routine {
            var r = Routine(
                id: id, title: title, what: "", often: "Every day at 8:00 AM", today: [480], every: nil, lastRun: nil, next: nil, state: st,
                reason: nil)
            r.owner = owner
            return r
        }
        let growth = bot("Growth bot", "amber", sid: "s-g", uses: ["Browser", "Facebook"], check: "morning")
        let intake = bot("Intake bot", "teal", sid: "s-i", uses: ["Email drafts"], check: "incoming")
        let routines = [
            routine("r1", "Growth bot: morning check", owner: "s-g"), routine("r2", "Growth bot: weekly ad check", owner: nil),
            routine("r3", "Morning brief", owner: nil), routine("r4", "Intake bot: new leads", owner: "s-i"),
            routine("r5", "Growth bot: old one", owner: "s-g", .paused),
        ]

        // View: everything about it in one place.
        let about = BotAbout.make(growth, routines: routines)
        check(
            "its info: name, colour, room, job, what it uses, when it checks in",
            about?.name == "Growth bot" && about?.color == "Amber" && about?.room == "Co-Founder" && about?.job == "Find new customers"
                && about?.uses == ["Browser", "Facebook"] && about?.checksIn == "Every morning at 8")
        check(
            "its routines (its own and the ones named after it) and its memory file",
            about?.routines.map(\.id) == ["r1", "r2", "r5"] && about?.memory == Bots.memory(growth.bot!).path && about?.remembered == 1)

        // Edit from chat: the line Iris writes.
        let e1 = BotTags.edit("Growth bot | name: Leads bot | colour: Rose")
        check("\"rename Growth bot to Leads bot\" is read", e1?.0 == "Growth bot" && e1?.1.name == "Leads bot" && e1?.1.color == "rose")
        let e2 = BotTags.edit("Growth bot | add uses: Email drafts")
        check(
            "\"let Growth bot use email drafts\" adds to what it uses",
            e2.map { BotEdit.uses(growth.bot!.uses, $0.1) } == ["Browser", "Facebook", "Email drafts"])
        let e3 = BotTags.edit("Growth bot | remove uses: facebook | check-in: only when I ask | job: Find leads")
        check(
            "taking a use away, the check-in and the job are read",
            e3.map { BotEdit.uses(growth.bot!.uses, $0.1) } == ["Browser"] && e3?.1.checkIn == "asked" && e3?.1.job == "Find leads")
        check("a line with nothing to change does nothing", BotTags.edit("Growth bot | ") == nil && BotTags.edit(" | name: X") == nil)

        // Edit applied: kept, memory kept, routines follow the new name, the link stays.
        var hs = [growth, intake]
        let oldFolder = Bots.folder(growth.bot!)
        let edit = BotEdit(name: "Leads bot", color: "rose", job: "Find leads", uses: ["Browser", "Email drafts"], checkIn: "incoming")
        let done = BotStore.edit(&hs, at: 0, edit, routines: routines)
        let nb = hs[0].bot
        check(
            "edit: the name, colour, job, uses and check-in change",
            done.miss == nil && hs[0].title == "Leads bot" && nb?.name == "Leads bot" && nb?.color == "rose" && nb?.job == "Find leads"
                && nb?.uses == ["Browser", "Email drafts"] && nb?.checkIn == "incoming")
        let back = (try? JSONEncoder().encode(hs)).flatMap { try? JSONDecoder().decode([Helper].self, from: $0) }
        check("and they're kept after One restarts", back?.first?.bot == nb && back?.first?.title == "Leads bot")
        let memText = nb.flatMap { try? String(contentsOf: Bots.memory($0), encoding: .utf8) } ?? ""
        check(
            "rename keeps its memory (moved with its folder)",
            memText.contains("Drafted 3 posts") && !fm.fileExists(atPath: oldFolder.path) && nb.map { Bots.remembered($0) } == 1)
        let card = nb.flatMap { try? String(contentsOf: Bots.card($0), encoding: .utf8) } ?? ""
        check("its card has the new name and job", card.contains("# Leads bot") && card.contains("Find leads"))
        check(
            "its routines named \"Growth bot: …\" take the new name",
            done.steps.contains(["cron", "edit", "r1", "--name", "Leads bot: morning check"])
                && done.steps.contains(["cron", "edit", "r2", "--name", "Leads bot: weekly ad check"])
                && !done.steps.contains { $0.contains("r3") || $0.contains("r4") })
        let renamed = [
            routine("r1", "Leads bot: morning check", owner: "s-g"), routine("r2", "Leads bot: weekly ad check", owner: nil),
            routine("r3", "Morning brief", owner: nil), routine("r4", "Intake bot: new leads", owner: "s-i"),
            routine("r5", "Leads bot: old one", owner: "s-g", .paused),
        ]
        check(
            "and stay its own on the Routines dial (same conversation)",
            hs[0].sid == "s-g" && BotStore.owned(hs[0], in: renamed).map(\.id) == ["r1", "r2", "r5"])
        check(
            "its next turn knows its new name and job",
            Bots.rules(nb!, user: "Omar").contains("You are Leads bot, a bot Omar keeps for one job: Find leads"))
        check("a changed check-in is passed on to the bot", done.tell?.contains("when something comes in") == true)
        let taken = BotStore.edit(&hs, at: 0, BotEdit(name: "intake bot"), routines: renamed)
        check("a name another bot has is refused", taken.miss != nil && hs[0].title == "Leads bot")
        check("moving rooms isn't offered (the room stays)", nb?.roomPath == room.path)

        // Archive and restore.
        let paused = BotStore.archive(&hs, at: 0, routines: renamed)
        let id = hs[0].id
        check(
            "archive hides it from the left",
            !Bots.active(hs).contains { $0.id == id } && Bots.archived(hs).contains { $0.id == id } && hs[0].bot?.archived != nil)
        check(
            "but keeps its memory and chat",
            fm.fileExists(atPath: Bots.memory(hs[0].bot!).path) && hs[0].sid == "s-g" && hs[0].log == ["Morning check done."])
        check("and pauses its routines that were on", paused == [["cron", "pause", "r1"], ["cron", "pause", "r2"]])
        check("\"clear them all\" still never takes it", HelperClose.match("all", in: hs).isEmpty)
        let resumed = BotStore.restore(&hs, at: 0)
        check(
            "restore shows it again and turns those routines back on",
            Bots.active(hs).contains { $0.id == id } && hs[0].bot?.archived == nil
                && resumed == [["cron", "resume", "r1"], ["cron", "resume", "r2"]])

        // Delete: the saved entry, its folder and its own routines; nobody else's.
        let folder = Bots.folder(hs[0].bot!)
        let gone = BotStore.delete(&hs, at: 0, routines: renamed)
        check("delete removes it from the saved list", !hs.contains { $0.id == id } && hs.count == 1)
        check("and its folder (memory and card)", !fm.fileExists(atPath: folder.path))
        check(
            "and its routines, never anyone else's",
            Set(gone) == Set([["cron", "remove", "r1"], ["cron", "remove", "r2"], ["cron", "remove", "r5"]]))
        check("the other bot is untouched", hs.first?.title == "Intake bot" && fm.fileExists(atPath: Bots.memory(intake.bot!).path))

        // The chat lines: read, never shown, never read aloud.
        let reply =
            "Done, it's Leads bot now.\n[edit-bot: Growth bot | name: Leads bot]\n[archive-bot: Intake bot]\n[restore-bot: Old intake test]\n[delete-bot: Forge bot]"
        let t = BotTags.read(reply)
        check(
            "the edit, archive, restore and delete lines are read",
            t.edits.first?.0 == "Growth bot" && t.archives == ["Intake bot"] && t.restores == ["Old intake test"] && t.deletes == ["Forge bot"])
        check(
            "and never shown",
            t.said.trimmingCharacters(in: .whitespacesAndNewlines) == "Done, it's Leads bot now."
                && Helpers.strip(reply).trimmingCharacters(in: .whitespacesAndNewlines) == "Done, it's Leads bot now.")
        check("not even half-written while it streams", !Helpers.strip("Ok.\n[delete-bot: Forg").contains("[delete"))
        let spoken = Speaker.spoken(reply).joined(separator: " ")
        check("or read aloud", !spoken.contains("Forge") && !spoken.contains("Intake") && !spoken.contains("["))

        // Never deleted from chat without a yes to the question.
        BotGate.asked = [:]
        let first = BotGate.decide(["Forge bot"], said: "", typed: "delete forge bot")
        check("a delete line with no yes first deletes nothing", first.act.isEmpty)
        check(
            "and One asks itself, with the two answers",
            first.ask.contains("Delete Forge bot? Its memory and routines go too.") && first.ask.contains("[choices: Delete it | Keep it]"))
        check("\"Keep it\" deletes nothing", BotGate.decide(["Forge bot"], said: "", typed: "Keep it").act.isEmpty)
        BotGate.asked = [:]
        _ = BotGate.decide([], said: "Delete Forge bot? Its memory and routines go too.\n[choices: Delete it | Keep it]", typed: "delete forge bot")
        let yes = BotGate.decide(["Forge bot"], said: "Deleted.", typed: "Delete it")
        check("after Iris asked and they tapped Delete it, it goes", yes.act == ["Forge bot"] && yes.ask.isEmpty)
        check("once: the same yes doesn't delete again", BotGate.decide(["Forge bot"], said: "", typed: "Delete it").act.isEmpty)
        BotGate.asked = ["forge bot": Date(timeIntervalSinceNow: -7200)]
        check("a question from hours ago doesn't count", BotGate.decide(["Forge bot"], said: "", typed: "yes").act.isEmpty)
        BotGate.asked = [:]

        check(
            "Iris knows the lines and to ask before deleting",
            Bots.soul.contains("[edit-bot:") && Bots.soul.contains("[archive-bot:") && Bots.soul.contains("[restore-bot:")
                && Bots.soul.contains("[delete-bot:") && Bots.soul.contains("[choices: Delete it | Keep it]"))
        try? fm.removeItem(at: root)
    }
}
