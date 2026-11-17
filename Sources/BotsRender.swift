import AppKit
import SwiftUI

// MARK: - Render-only (`--render-world <prefix>`, from a test copy with ONE_SUPPORT_DIR set): the bots screens,
// to check against the Claude Design "One bots design" (B · Moons). Fills the model with made-up bots and helpers;
// their rooms and memory files are written under ONE_SUPPORT_DIR, never the brain.

enum BotsRender {
    static let names = ["bots-home", "bots-collapsed", "bots-make", "bots-keep", "bots-chat", "bots-first", "bots-routines"] + BotsManageRender.names

    /// Draws `name` into `<out>-<name>.png`; false when the name isn't one of these.
    @MainActor static func draw(_ name: String, _ out: String) -> Bool {
        guard names.contains(name) else { return false }
        guard let dir = ProcessInfo.processInfo.environment["ONE_SUPPORT_DIR"] else {
            print("skipped \(name): set ONE_SUPPORT_DIR to a scratch folder")
            return true
        }
        let path = "\(out)-\(name).png"
        if BotsManageRender.names.contains(name) { return BotsManageRender.draw(name, dir, path) }  // view, edit, archive, delete
        UserDefaults.standard.set(name == "bots-collapsed", forKey: "botsCollapsed")
        defer { UserDefaults.standard.removeObject(forKey: "botsCollapsed") }
        HelperCard.stillKeeping = false
        if name == "bots-routines" {
            routines(dir, path)
        } else {
            HomeRender.png(home(name, dir), path, height: 760)
        }
        print("wrote \(path)")
        return true
    }

    struct Fake {
        let growth: Helper
        let intake: Helper
        let standup: Helper
        let mine: Helper
    }

    /// Three rooms (Co-Founder and Work open, Personal private) and four bots with a few days of memory each.
    @MainActor static func bots(_ dir: String) -> Fake {
        let root = URL(fileURLWithPath: dir).appendingPathComponent("render-brain", isDirectory: true)
        func room(_ folder: String, _ title: String, open: Bool) -> URL {
            let u = root.appendingPathComponent(folder, isDirectory: true)
            try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
            if open {
                try? "title: \"\(title)\"\nprivate: false\n".write(to: u.appendingPathComponent("room.yaml"), atomically: true, encoding: .utf8)
            }
            return u
        }
        let co = room("co-founder-room", "Co-Founder", open: true)
        let work = room("work-room", "Work", open: true)
        let personal = room("personal-room", "Personal", open: false)
        func bot(_ name: String, _ color: String, _ r: URL, _ title: String, _ job: String, uses: [String], check: String, days: [String]) -> Helper {
            let b = BotInfo(name: name, color: color, room: title, roomPath: r.path, job: job, uses: uses, checkIn: check)
            Bots.writeCard(b)
            var mem = "# What \(name) did\n\n## Rules\n\n- Never post without a yes\n- Plain words, no hashtags\n\n"
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            for (i, d) in days.enumerated() {
                let day = Calendar.current.date(byAdding: .day, value: i - days.count + 1, to: Date()) ?? Date()
                mem += "## \(f.string(from: day))\n\n- \(d)\n- Checked the ad numbers\n\n"
            }
            try? mem.write(to: Bots.memory(b), atomically: true, encoding: .utf8)
            var h = Helper(title: name, task: job, sid: "render-\(Bots.slug(name))", state: "done", line: "")
            h.bot = b
            h.seen = true
            return h
        }
        var growth = bot(
            "Growth bot", "amber", co, "Co-Founder", "Find new customers for the heating business", uses: ["Browser", "Facebook"], check: "morning",
            days: ["3 posts drafted", "Weekly ad check", "Found 2 neighborhoods to try", "2 posts waiting for you"])
        growth.state = "needsYes"
        growth.seen = false
        growth.log = [
            "Morning check done. Your Facebook ads brought 6 clicks yesterday, 2 from Oak Park.",
            "**You:** Write two posts for this week\n\nDone. Two short posts are ready, one about fall tune-ups and one about the furnace check special.",
        ]
        growth.reply =
            "Two posts are ready. Post 1 of 2:\n\n> Fall is here. Book your furnace check before the first cold night, $89 this week only.\n\nPost it to your Facebook page?\n\n[choices: Yes, post it | Change it | Not now]"
        var intake = bot(
            "Intake bot", "teal", co, "Co-Founder", "Answer new leads fast and book the visit", uses: ["Email drafts", "Calendar"], check: "incoming",
            days: ["Answered 5 leads", "Booked 2 visits"])
        intake.state = "working"
        intake.line = "Answering 2 new leads…"
        var standup = bot(
            "Standup notes", "sky", work, "Work", "Turn yesterday's work into my standup notes", uses: ["Files"], check: "morning",
            days: ["Notes ready for 9"])
        standup.seen = false
        let mine = bot(
            "Health log", "sage", personal, "Personal", "Keep my health notes tidy", uses: ["Files"], check: "asked", days: ["Tidied the log"])
        return Fake(growth: growth, intake: intake, standup: standup, mine: mine)
    }

    @MainActor static func home(_ name: String, _ dir: String) -> AnyView {
        let m = Model.shared
        HomeView.stillBottom = name != "bots-chat"  // the chat under the orb, not the top
        m.thinking = false
        m.working = nil
        m.goals = [:]
        m.openHelper = nil
        let v = HomeRender.scene(4)
        let f = bots(dir)
        m.helpers = Array(m.helpers.prefix(name == "bots-keep" ? 0 : 3))
        if name == "bots-make" { m.helpers += [f.intake, f.standup, f.mine] }  // Growth bot isn't made yet
        if name != "bots-first" && name != "bots-make" { m.helpers += [f.growth, f.intake, f.standup, f.mine] }
        m.shelf = Array(m.shelf.prefix(3))
        m.bubbles = [
            Bubble(fromMe: true, text: "Good morning"),
            Bubble(
                fromMe: false,
                text:
                    "Morning, Omar. Your bots overnight: **Growth bot** drafted 2 posts and is waiting for your yes. **Intake bot** answered 5 leads and booked 2 visits. **Standup notes** has today's notes ready for 9."
            ),
        ]
        switch name {
        case "bots-make":
            m.bubbles = [
                Bubble(fromMe: true, text: "make me a growth bot"),
                Bubble(fromMe: false, text: "Sure. What's its one job?"),
                Bubble(fromMe: true, text: "Find new customers for the heating business"),
                Bubble(fromMe: false, text: "What may it use?\n\n[choices: Browser | Email drafts | Facebook | Calendar]"),
                Bubble(fromMe: true, text: "Browser and Facebook"),
                Bubble(
                    fromMe: false,
                    text:
                        "Here's your bot:\n\n**Growth bot** · Co-Founder room\n\nFinds new customers for the heating business. Uses Browser and Facebook. Checks in every morning at 8. Asks before posting, sending or spending.\n\n[choices: Make the bot | Change something]"
                ),
            ]
        case "bots-keep":
            var h = Helper(
                title: "Lead follow-up texts", task: "Draft follow-up texts for this week's leads", sid: "render-keep", state: "done", line: "Done")
            h.reply = "Drafted 4 follow-up texts for this week's leads. They're saved in Ready for you; nothing was sent."
            h.seen = true
            m.helpers.insert(h, at: 0)
            m.openHelper = h.id
            HelperCard.stillKeeping = true
            KeepBotCard.stillRooms = [
                Bots.Room(name: "Personal", path: "/p", isPrivate: true), Bots.Room(name: "Work", path: "/w", isPrivate: false),
                Bots.Room(name: "Co-Founder", path: "/c", isPrivate: false),
            ]
        case "bots-chat":
            m.openHelper = f.growth.id
        default:
            break
        }
        return v
    }

    @MainActor static func routines(_ dir: String, _ path: String) {
        HomeView.still = true
        let m = Model.shared
        m.assistantName = "Elias"
        let f = bots(dir)
        m.helpers = [f.growth, f.intake, f.standup]
        let now = Date()
        func r(_ id: String, _ title: String, _ at: [Int], _ owner: String?, _ st: Routine.State = .worked) -> Routine {
            var x = Routine(
                id: id, title: title, what: "Checked and drafted.", often: "Every day", today: at, every: nil, lastRun: now.addingTimeInterval(-3600),
                next: now.addingTimeInterval(20 * 3600), state: st, reason: nil)
            x.owner = owner
            return x
        }
        var s = RoutinesSnapshot(now: now)
        s.routines = [
            r("g1", "Growth bot: morning check", [8 * 60], f.growth.sid), r("g2", "Growth bot: ad numbers", [17 * 60], f.growth.sid, .never),
            r("i1", "Intake bot: new leads", [9 * 60, 13 * 60, 18 * 60], f.intake.sid),
            r("s1", "Standup notes: morning", [8 * 60 + 40], f.standup.sid),
            r("m1", "Morning brief", [7 * 60], nil), r("m2", "Email triage", [16 * 60], nil),
        ]
        let v = RoutinesPanel(m: m, fixed: s, sel: "g1", picked: true, onlyBot: f.growth.id.uuidString)
            .frame(width: 1200, height: 740).background(WorldLook.bg)
        let rr = ImageRenderer(content: v)
        rr.scale = 2
        if let img = rr.nsImage, let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t),
            let d = rep.representation(using: .png, properties: [:])
        {
            try? d.write(to: URL(fileURLWithPath: path))
        }
    }
}
