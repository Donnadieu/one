import AppKit
import Foundation

/// `One --test-helpers-stress corrections` (tools/corrections-check.sh, in preflight; CI only). Omar's corrections
/// about One, each as the scenario that broke, run against the stand-in engine (tools/fake-engine.py). Every row of
/// tests/corrections/README.md names the check that guards it; these are the ones that live here.
///   2026-11-17 main-chat-answers  A main-chat turn that takes 24 s and 4 steps ends in its own full answer: never
///                                 "Your request was not processed", never a canned "I'm free to talk" line, never a
///                                 helper named from his first words ("How is our YouTube"). Red on 0.9.116 to
///                                 0.9.125 (the turn was cut at ~20 s or 3 steps), green from 0.9.126.
///   2026-11-18 night-ask          The nightly review's question shows once in the chat with Yes / Not now; Yes sends
///                                 a helper with the ask's own title and job; Not now holds that topic for 7 days; an
///                                 ask already answered is never shown again. Red before 0.9.128 (no ask in the chat).
extension HelperStress {
    @MainActor
    static func correctionsCheck(_ m: Model) async -> Int32 {
        m.helpers = []
        m.bubbles = []
        let fm = FileManager.default

        // 2026-11-17 main-chat-answers
        print("2026-11-17 main-chat-answers: a 24 s, 4-step turn in the main chat")
        let t0 = Date()
        await m.send("How is our YouTube channel doing? STRESSSLOWMAIN C1 steps=4 secs=24")
        _ = await wait(60) { !m.thinking && m.bubbles.last.map { !$0.fromMe && $0.text.contains("ANSWER C1") } == true }
        let took = Date().timeIntervalSince(t0)
        let mine = m.bubbles.filter { !$0.fromMe }.map(\.text).joined(separator: "\n")
        check("the turn ends in its own full answer (after \(Int(took)) s)", m.bubbles.last?.text.contains("ANSWER C1") == true)
        check("never \"Your request was not processed\"", !mine.contains("not processed"))
        check("never a canned \"free to talk\" line", !mine.lowercased().contains("free to talk") && !mine.contains("more than a conversation"))
        check("no helper was sent for it (\(m.helpers.map(\.title)))", m.helpers.isEmpty)
        check("and none named from the first words", !m.helpers.contains { $0.title.hasPrefix("How is our") })
        let evs = events()
        check(
            "the engine's turn ran to its end, never cancelled",
            evs.contains { $0.ev == "main-end" } && !evs.contains { $0.ev == "cancelled" && $0.job == "C1" })

        // 2026-11-18 night-ask
        print("2026-11-18 night-ask: last night's question in the chat")
        m.helpers = []
        try? fm.removeItem(at: ImproveAsk.file)
        let cal = Calendar.current
        let morning = cal.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
        let today = Improve.dayKey(morning)
        let yesterday = Improve.dayKey(cal.date(byAdding: .day, value: -1, to: morning) ?? morning)
        func review(_ date: String, _ ask: [String: Any]) {
            try? fm.createDirectory(at: ImproveNight.reviewDir, withIntermediateDirectories: true)
            let j: [String: Any] = ["date": date, "mode": "edit", "lessons": [], "ask": ask]
            try? JSONSerialization.data(withJSONObject: j).write(to: ImproveNight.reviewFile(date))
        }
        review(
            today,
            [
                "key": "engine-restart-drops-answer", "text": "Should a helper make One keep your answer through a restart?",
                "title": "Keep answers on restart", "job": "STRESSJOB NA1 secs=1 Make One keep the person's answer through a restart.",
            ])
        let early = cal.date(bySettingHour: 6, minute: 30, second: 0, of: morning) ?? morning
        m.tendNightAsk(now: early)
        check("not before 7 AM", !m.bubbles.contains { $0.text.hasPrefix(Model.nightAskLead) })
        m.tendNightAsk(now: morning)
        m.tendNightAsk(now: morning.addingTimeInterval(60))
        let shown = m.bubbles.filter { $0.text.hasPrefix(Model.nightAskLead) }
        check(
            "shown once in the chat, with Yes / Not now", shown.count == 1 && Choices.split(shown[0].text).choices == [ImproveAsk.yes, ImproveAsk.no])
        check(
            "while it waits, a typed yes works too: the chat knows its helper line", SessionNotes.main.contains("[helper: Keep answers on restart |"))
        check("Yes is that ask's answer", m.nightAskPick(ImproveAsk.yes))
        check(
            "Yes sends a helper with the ask's own title",
            m.helpers.contains { $0.title == "Keep answers on restart" && $0.task.contains("STRESSJOB NA1") })
        check("the answer is kept (yes, from the chat)", ImproveAsk.all().last.map { $0.answer == "yes" && $0.via == "chat" } == true)
        check(
            "its buttons go, and it says what it did",
            m.bubbles.last { $0.text.hasPrefix(Model.nightAskLead) }.map {
                Choices.split($0.text).choices.isEmpty && $0.text.contains("Sending a helper")
            } == true)
        check("the chat isn't told about it anymore", !SessionNotes.main.contains("Keep answers on restart"))
        review(today, ["key": "engine-restart-drops-answer", "text": "Same thing, asked again?", "title": "Again", "job": "x"])
        try? fm.removeItem(at: ImproveNight.reviewFile(yesterday))
        m.tendNightAsk(now: morning.addingTimeInterval(120))
        check("an answered topic is never asked again", !m.bubbles.contains { $0.text.contains("Same thing, asked again?") })
        review(
            yesterday,
            [
                "key": "split-big-recipe", "text": "Can I split the One recipe so lessons fit?", "title": "Split One recipe",
                "job": "STRESSJOB NA2 secs=1",
            ])
        m.tendNightAsk(now: morning.addingTimeInterval(180))
        check(
            "the night before's ask still shows (any day of the week: the morning brief only runs Monday to Friday)",
            m.bubbles.contains { $0.text.contains("Can I split the One recipe") })
        check("Not now is that ask's answer", m.nightAskPick(ImproveAsk.no))
        check("Not now sends nothing", !m.helpers.contains { $0.title == "Split One recipe" })
        let list = ImproveAsk.all()
        check("Not now holds the topic for 7 days", !ImproveAsk.allowed("split-big-recipe", list, now: morning.addingTimeInterval(6 * 86400)))
        check("and lets it come back after", ImproveAsk.allowed("split-big-recipe", list, now: morning.addingTimeInterval(8 * 86400)))
        check(
            "the review is told every ask it made and the answer",
            ImproveAsk.section().contains("engine-restart-drops-answer") && ImproveAsk.section().contains("not now"))
        check("a tap on another reply's Yes is left alone", !m.nightAskPick(ImproveAsk.yes))
        _ = await wait(15) { m.helpers.allSatisfy { $0.state != "working" } }

        print(fails == 0 ? "corrections ok" : "corrections failed: \(fails)")
        return fails == 0 ? 0 : 1
    }
}
