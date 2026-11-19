import AppKit
import SwiftUI

// MARK: - Render-only (`--render-world <prefix>`, from a test copy with ONE_SUPPORT_DIR set): today's chats with a
// long, made-up history, for the bot chat redesign: a bot's chat, the assistant's chat (closed and with earlier
// messages open) and a helper's chat. Everything here is invented; bots' rooms and memory go under ONE_SUPPORT_DIR.

enum ChatTodayRender {
    static let names = ["chat-today-bot", "chat-today-bot-end", "chat-today-iris", "chat-today-iris-history", "chat-today-helper"]

    /// Draws `name` into `<path>`; false when the name isn't one of these.
    @MainActor static func draw(_ name: String, _ dir: String, _ path: String) -> Bool {
        guard names.contains(name) else { return false }
        let m = Model.shared
        let v = BotsRender.home("bots-chat", dir)  // the home with four bots, Growth bot open
        m.assistantName = "Iris"
        HomeView.stillHistory = false
        switch name {
        case "chat-today-bot", "chat-today-bot-end":
            if let i = m.helpers.firstIndex(where: { $0.bot?.name == "Growth bot" }) { m.helpers[i].log = botLog }
            HomeView.stillBottom = name == "chat-today-bot-end"
        case "chat-today-helper":
            var h = Helper(title: "Business playbook", task: "Find a playbook that makes $1,000 a month", sid: "render-help", state: "done", line: "")
            h.asked = report[0].0
            h.reply = report[0].1
            h.log = report.map { "**You:** \($0.0)\n\n\($0.1)" }
            h.seen = true
            m.helpers.insert(h, at: 0)
            m.openHelper = h.id
            HomeView.stillBottom = true
        default:
            m.openHelper = nil
            m.bubbles = irisTurns
            HomeView.stillBottom = true
            HomeView.stillHistory = name == "chat-today-iris-history"
        }
        HomeRender.png(v, path, height: 900)
        HomeView.stillHistory = false
        return true
    }

    /// Long research answers like the ones in Omar's screenshot (made up for the render).
    static let report: [(String, String)] = [
        (
            "Remember our goal? Something that brings about $1,000 in profit a month and that we can repeat 10 times, or 1,000 times",
            "Yes: one playbook that reliably makes about $1,000 a month in profit, then the same playbook 10 times. Here's what the research found:\n\n**Closest match: a portfolio of small mobile apps.**\n\n- One developer runs 30+ apps from one shared codebase and makes about $22,000 a month.\n- Another runs a portfolio at $60,000 a month.\n- Buyers find apps through App Store search, so nobody has to sell.\n- The catch: only about 1 in 6 apps reaches $1,000 a month within 2 years.\n\n**Also real, but they need money:**\n\n- **Billboards:** one build costs $20,000 and nets about $733 a month.\n- **Micro markets in offices:** good sites net about $1,300 a month.\n- **Laundromats:** about $7,500 a month, but $40,000 to $50,000 for each $1,000 of profit.\n\nMy recommendation is to test the app portfolio first. Should I check the two portfolio claims and bring 3 app ideas?"
        ),
        (
            "We have to go back to the drawing board and start with the goal",
            "Starting over from the goal. Three rounds of research taught us what makes a copy work:\n\n- Copies fail when someone has to sell each one.\n- Copies fail when a platform sees them as clones.\n- Copies work when the unit already exists thousands of times.\n\n**The new idea:** look for problems that repeat in thousands of separate places (3,143 counties, 19,000 cities). Each county becomes one copy, the deadline brings the customers, and \"pay only if it works\" removes most of the selling."
        ),
        (
            "Go deeper on the county idea",
            "Here are 5 county-level problems with a deadline and money already owed: property tax appeals, unclaimed funds, permit renewals, small-claims filings and business license renewals. Property tax appeals look strongest."
        ),
    ]

    /// A bot's kept chat: 40 exchanges over two weeks, long reports among short ones.
    static let botLog: [String] = (0..<40).map { i in
        let r = report[i % report.count]
        return i % 4 == 0
            ? "Morning check done. Your Facebook ads brought \(4 + i % 5) clicks yesterday, \(i % 3) from Oak Park. 2 posts are waiting for your yes."
            : "**You:** \(r.0)\n\n\(r.1)"
    }

    /// The assistant's chat: 120 turns over five days (routine reports, long answers, short asks).
    static let irisTurns: [Bubble] = {
        var out: [Bubble] = []
        for i in 0..<60 {
            let day = Calendar.current.date(byAdding: .minute, value: -(60 - i) * 110, to: Date()) ?? Date()
            let r = report[i % report.count]
            if i % 5 == 0 {
                out.append(Bubble(fromMe: true, text: "Good morning", date: day))
                out.append(
                    Bubble(
                        fromMe: false,
                        text:
                            "**Morning brief**\n\n3 things need you today: the dentist moved you to Thursday, the car shop wants a time, and 2 posts from Growth bot wait for your yes.",
                        date: day))
            } else {
                out.append(Bubble(fromMe: true, text: r.0, date: day))
                out.append(Bubble(fromMe: false, text: r.1, date: day))
            }
        }
        return out
    }()
}
