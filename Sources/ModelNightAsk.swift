import Foundation

// MARK: - The nightly review's question in the chat (ImproveAsk.swift)

extension Model {
    /// The line the ask's bubble starts with; also how its bubble is found again.
    static let nightAskLead = "From last night's review:"

    /// Every few seconds (tendLearning): shows a due ask once, in the chat and on the phone; notices an answer given
    /// elsewhere (the phone, or the assistant's own `--improve ask` after a typed yes) and takes the buttons away.
    func tendNightAsk(now: Date = Date()) {
        guard onboarded || Env.selfTest else { return }
        if let open = ImproveAsk.open() {
            // A helper with the ask's own title was sent (from the phone or a typed yes): that's a yes.
            if helpers.contains(where: { $0.title == open.title && ($0.started?.timeIntervalSince1970 ?? 0) >= (open.shown ?? 0) }) {
                ImproveAsk.answer(true, via: "helper", now: now)
                settleNightAsk(open, "Sending a helper: \(open.title).")
            }
            return
        }
        if let k = bubbles.lastIndex(where: { !$0.fromMe && $0.text.hasPrefix(Model.nightAskLead) && !Choices.split($0.text).choices.isEmpty }),
            let last = ImproveAsk.all().last, last.answer != nil
        {
            bubbles[k].text = Choices.split(bubbles[k].text).body  // answered elsewhere: no buttons left behind
            saveBubbles()
        }
        guard let a = ImproveAsk.due(now: now) else { return }
        let phone = Messenger.envValue("TELEGRAM_HOME_CHANNEL") != nil
        ImproveAsk.markShown(a, phone: phone, now: now)
        bubbles.append(Bubble(fromMe: false, text: "\(Model.nightAskLead) \(a.text)\n\n[choices: \(ImproveAsk.yes) | \(ImproveAsk.no)]"))
        saveBubbles()
        if phone { sendPhone("From last night's review: \(a.text)", to: "\(Messenger.botChat):", choices: [ImproveAsk.yes, ImproveAsk.no]) }
        writePhoneNews()
    }

    /// A tap on the ask's Yes / Not now. True when it was that ask's answer.
    func nightAskPick(_ c: String) -> Bool {
        guard c == ImproveAsk.yes || c == ImproveAsk.no, let open = ImproveAsk.open(),
            let k = bubbles.lastIndex(where: { !$0.fromMe }), bubbles[k].text.hasPrefix(Model.nightAskLead)
        else { return false }
        if c == ImproveAsk.yes {
            ImproveAsk.answer(true, via: "chat")
            settleNightAsk(open, "Sending a helper: \(open.title).")
            spawnHelper(title: open.title, task: open.job)
        } else {
            ImproveAsk.answer(false, via: "chat")
            settleNightAsk(open, "Okay, I won't ask about this for a week.")
        }
        writePhoneNews()
        return true
    }

    private func settleNightAsk(_ a: NightAsk, _ reply: String) {
        guard let k = bubbles.lastIndex(where: { !$0.fromMe && $0.text.hasPrefix(Model.nightAskLead) && $0.text.contains(a.text) }) else { return }
        bubbles[k].text = Choices.split(bubbles[k].text).body + "\n\n" + reply
        saveBubbles()
    }
}
