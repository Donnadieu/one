import AppKit
import SwiftUI

// MARK: - Render-only (`--render-world <prefix>`, from a test copy with ONE_SUPPORT_DIR set): managing a bot, to
// check against the Claude Design "Bots manage B - Glass sheet" at its two window sizes (1180×760 and 900×640).
// The menu, the About sheet, the edit sheet mid-rename, the delete question, and the archived bots. Fake bots,
// rooms and memory under ONE_SUPPORT_DIR (BotsRender.bots), never the brain.

enum BotsManageRender {
    static let steps = ["menu", "about", "edit", "delete", "archived"]
    static let names = steps.flatMap { ["bots-\($0)", "bots-\($0)-small"] }

    @MainActor static func draw(_ name: String, _ dir: String, _ path: String) -> Bool {
        let small = name.hasSuffix("-small")
        let step = name.replacingOccurrences(of: "bots-", with: "").replacingOccurrences(of: "-small", with: "")
        let size = small ? CGSize(width: 900, height: 640) : CGSize(width: 1180, height: 760)
        let m = Model.shared
        _ = HomeRender.scene(4)  // the still home: names, shelf, stars
        HomeView.stillBottom = true
        m.thinking = false
        m.working = nil
        m.goals = [:]
        m.openHelper = nil
        UserDefaults.standard.set(false, forKey: "botsCollapsed")
        UserDefaults.standard.set(small, forKey: "shelfCollapsed")  // a small window: Ready for you folded to its strip
        let f = BotsRender.bots(dir)
        func away(_ n: String, _ c: String) -> Helper {
            var h = Helper(title: n, task: "Old job", sid: "render-\(Bots.slug(n))", state: "done", line: "")
            h.bot = BotInfo(name: n, color: c, room: "Co-Founder", roomPath: f.growth.bot!.roomPath, job: "Old job", archived: Date())
            h.seen = true
            return h
        }
        m.helpers = Array(m.helpers.prefix(3)) + [f.growth, f.intake, f.standup, f.mine, away("Old intake test", "lilac"), away("Forge bot", "sage")]
        m.shelf = Array(m.shelf.prefix(3))
        m.bubbles = [
            Bubble(fromMe: true, text: "Good morning"),
            Bubble(
                fromMe: false,
                text:
                    "Morning, Omar. Your bots overnight: **Growth bot** drafted 2 posts and is waiting for your yes. **Intake bot** answered 5 leads and booked 2 visits. **Standup notes** has today's notes ready for 9."
            ),
        ]
        func r(_ id: String, _ title: String, _ often: String) -> Routine {
            var x = Routine(
                id: id, title: title, what: "", often: often, today: [480], every: nil, lastRun: nil, next: nil, state: .worked, reason: nil)
            x.owner = f.growth.sid
            return x
        }
        BotSheet.stillRoutines = [r("g1", "Growth bot: morning check", "8:00 AM daily"), r("g2", "Growth bot: weekly ad check", "Mon 9:00 AM")]
        BotSheet.stillEdit = step == "edit" ? ("Leads bot", "rose") : nil
        defer {
            m.botMenu = nil
            m.botSheet = nil
            m.botsArchive = false
            BotsColumn.stillHover = nil
            BotMenuItem.stillHover = nil
            BotSheet.stillEdit = nil
            BotSheet.stillRoutines = []
            PopupLook.behind = nil
            HomeView.stillBottom = false
            UserDefaults.standard.removeObject(forKey: "shelfCollapsed")
        }
        let id = f.growth.id
        if step != "menu" {
            // The pop-up glass blurs what's behind it, like the real window: draw home once without it first.
            PopupLook.behind = LongRender.image(LongRender.window(size, history: false), size)
            PopupLook.behindAt = CGPoint(x: 0, y: 52)
        }
        switch step {
        case "menu":
            BotsColumn.stillHover = id
            BotMenuItem.stillHover = "About Growth bot"
            m.botMenu = id
        case "about": m.botSheet = BotSheetAsk(id: id, mode: .about)
        case "edit": m.botSheet = BotSheetAsk(id: id, mode: .edit)
        case "delete": m.botSheet = BotSheetAsk(id: id, mode: .confirm)
        default: m.botsArchive = true
        }
        guard let img = LongRender.image(LongRender.window(size, history: false), size), let tiff = img.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff), let data = rep.representation(using: .png, properties: [:])
        else { return true }
        try? data.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
        return true
    }
}
