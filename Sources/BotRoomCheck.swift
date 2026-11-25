import Foundation

/// Part of `One --test-helpers` (via BotsCheck): the room is a bot's only source of truth (BotRoom.swift, Omar
/// Nov 25 2026). A room line tagged with the bot's name reaches its start context; untagged lines and other bots'
/// lines don't; its memory file gives only its Rules and Working state (never the archived history); and a new fact
/// lands in the room's memory with its tag, never in its memory file.
enum BotRoomCheck {
    static func run(_ check: (String, Bool) -> Void) {
        let fm = FileManager.default
        let room = Env.support.appendingPathComponent("bot-room-check/work-room", isDirectory: true)
        try? fm.removeItem(at: room)
        let now = Date()
        let today = Bots.today(now)
        let old = Bots.today(Calendar.current.date(byAdding: .day, value: -60, to: now) ?? now)
        func write(_ rel: String, _ text: String) {
            let u = room.appendingPathComponent(rel)
            try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: u, atomically: true, encoding: .utf8)
        }
        let b = BotInfo(name: "Ascend", color: "sky", room: "Work", roomPath: room.path, job: "Be Omar's partner on Ascend")
        Bots.writeCard(b)
        write(
            "memory/\(today).md",
            """
            # \(today)

            - [Ascend] Decided: X
            - Decided: an untagged line nobody owns
            - [Part-time Work Finder] Decided: another bot's line
              - [Ascend] Owe: send Jon the README
            - Learned: a line that only mentions [Ascend] later on

            """)
        write("memory/\(old).md", "# \(old)\n\n- [Ascend] Decided: something from long ago\n")
        write("vault/projects/ascend.md", "# Ascend\n\n- [Ascend] Open: which client goes first\n- [Business Picker] Open: not Ascend's\n")
        write("confidential/secret.md", "- [Ascend] Decided: a locked drawer line\n")
        write(
            "bots/ascend/memory.md",
            """
            # How Ascend works

            ## Rules
            - One commit per skill in a PR (Omar, Nov 20).

            ## Working state
            - Waiting on John's Mac mini.

            ## Archive (before 2026-11-25; new facts go to the room)

            ## 2026-11-19
            - An archived history line.

            """)

        let lines = BotRoom.lines(b, now: now)
        check("a room line tagged [Ascend] is one of Ascend's lines", lines.contains { $0.text == "- [Ascend] Decided: X" })
        check("an indented tagged line counts too", lines.contains { $0.text == "- [Ascend] Owe: send Jon the README" })
        check("a tagged line in the room's notes counts too", lines.contains { $0.text.contains("[Ascend] Open: which client goes first") })
        check("an untagged line doesn't", !lines.contains { $0.text.contains("untagged line") || $0.text.contains("only mentions") })
        check("another bot's line doesn't", !lines.contains { $0.text.contains("another bot") || $0.text.contains("Business Picker") })
        check("the locked drawer is never read", !lines.contains { $0.text.contains("locked drawer") })
        check("old days stay out of the start context", !lines.contains { $0.text.contains("long ago") })

        let rules = Bots.rules(b, user: "Omar")
        check("Ascend's start context carries its tagged room line", rules.contains("[Ascend] Decided: X"))
        check("and its room note line", rules.contains("[Ascend] Open: which client goes first"))
        check("but not untagged lines or other bots' lines", !rules.contains("untagged line") && !rules.contains("another bot's line"))
        check("its Rules and Working state are in it", rules.contains("One commit per skill") && rules.contains("Waiting on John's Mac mini"))
        check("its archived history is not", !rules.contains("An archived history line"))
        check(
            "it is told to write new facts to the room with its tag, never to its memory file",
            rules.contains(BotRoom.memoryFile(b, now: now).path) && rules.contains("[Ascend]") && rules.contains("never in \(Bots.memory(b).path)"))

        let memBefore = (try? String(contentsOf: Bots.memory(b), encoding: .utf8)) ?? ""
        BotRoom.record(b, "Done: drafted the Jon reply", now: now)
        let roomToday = (try? String(contentsOf: room.appendingPathComponent("memory/\(today).md"), encoding: .utf8)) ?? ""
        let memAfter = (try? String(contentsOf: Bots.memory(b), encoding: .utf8)) ?? ""
        check("a new fact from a bot run lands in the room with its tag", roomToday.contains("- [Ascend] Done: drafted the Jon reply"))
        check("and the room's earlier lines are kept", roomToday.contains("- [Ascend] Decided: X") && roomToday.contains("untagged line"))
        check("and never in its memory file", memAfter == memBefore && !memAfter.contains("drafted the Jon reply"))
        check("and it shows in its own context next time", Bots.rules(b, user: "Omar").contains("[Ascend] Done: drafted the Jon reply"))

        let fresh = BotInfo(name: "Standup notes", color: "teal", room: "Work", roomPath: room.path, job: "Write my standup")
        Bots.writeCard(fresh, seed: "Kept from the helper \"Standup\": wrote Monday's notes")
        let seeded = (try? String(contentsOf: room.appendingPathComponent("memory/\(today).md"), encoding: .utf8)) ?? ""
        let freshMem = (try? String(contentsOf: Bots.memory(fresh), encoding: .utf8)) ?? ""
        check("a kept helper's first line goes to the room, tagged", seeded.contains("- [Standup notes] Kept from the helper"))
        check(
            "and a new bot's memory file holds only Rules and Working state",
            freshMem.contains("## Rules") && freshMem.contains("## Working state") && !freshMem.contains("wrote Monday's notes"))
        check(
            "what it did reads back by day from the room",
            Bots.days(fresh).last?.day == "Today" && Bots.days(fresh).last?.what.contains("wrote Monday's notes") == true)
        try? fm.removeItem(at: room.deletingLastPathComponent())
    }
}
