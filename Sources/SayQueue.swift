import Foundation

// MARK: - One line for everything the assistant says
//
// Omar's rule: everything the main assistant says goes through ONE first-in, first-out line. A reply in progress
// (its words on screen AND its voice) is never cut off by a helper notice, a routine result or anything else
// One makes up itself. Those wait at the back and go one at a time, each only once the one before has fully
// finished: the turn is over, its words are on screen and the last sentence has been spoken. A message the
// person sends while the assistant is busy waits in the same line (shown as Next up, still changeable) and is
// never lost; Stop is the only way to cut in. Helper notices: one per helper per change of state, never the
// same title and state twice, and a notice still waiting always says the helper's newest state.
//
// Before this, six separate waits each guessed "is she free?" from `thinking` and a voice check that read false
// between two sentences (the next one still being made) or once the 6 s fallback showed the words, and every
// new reply or spoken line began with `Speaker.stop()`, which dropped the rest of the reply being spoken.

enum Outgoing: Equatable {
    /// A message the person sent (a `FollowUp` shown as Next up until its turn).
    case message(UUID)
    /// A hidden app note for the assistant (a good-morning report, carry on after a restart, save a skill…).
    case note(String)
    /// "<title> is done / needs your yes" (one line for every helper waiting): built when its turn comes, from their state then.
    case helperNews(UUID)
    /// A line One says itself (no turn): shown as a message if `bubble` is set, and read aloud if they're idle (`Idle`).
    case line(bubble: String?, spoken: String)
}

@MainActor
extension Model {
    /// Nothing is being said or worked on in the main chat, and the person isn't talking or holding Stop.
    var sayFree: Bool {
        !thinking && !paused && pendingReveal == nil && !Speaker.shared.busy && !talkingInApp
    }

    /// Puts something at the back of the line and makes sure the line is moving.
    func enqueue(_ o: Outgoing) {
        if case .helperNews = o, outbox.contains(o) { return }  // already waiting: it will say the newest state
        outbox.append(o)
        pumpOutbox()
    }

    /// One at a time, oldest first, each only when the one before is completely over (text and voice).
    func pumpOutbox() {
        guard !outboxRunning else { return }
        outboxRunning = true
        Task { @MainActor in
            while !self.outbox.isEmpty {
                if !self.sayFree || self.headBeingEdited || (!self.isReady && self.headNeedsEngine) {
                    try? await Task.sleep(for: .milliseconds(120))
                    continue
                }
                let next = self.outbox.removeFirst()
                await self.perform(next)
                // A turn hands its words to the voice before it returns; give the voice a beat to take them.
                try? await Task.sleep(for: .milliseconds(60))
            }
            self.outboxRunning = false
        }
    }

    /// The front of the line needs the engine: while One is getting ready (StartupGate.swift) it waits; a plain line doesn't.
    private var headNeedsEngine: Bool {
        if case .line = outbox.first { return false }
        return outbox.first != nil
    }

    /// The person is changing the message at the front of the line: it waits for them (never skipped).
    private var headBeingEdited: Bool {
        if case .message(let id) = outbox.first { return editingFollowUp == id }
        return false
    }

    private func perform(_ o: Outgoing) async {
        switch o {
        case .message(let first):
            // Their messages next to each other in the line go together, as one turn, in the order sent.
            var ids = [first]
            while case .message(let id) = outbox.first, editingFollowUp != id {
                ids.append(id)
                outbox.removeFirst()
            }
            let batch = ids.compactMap { id in followUps.first { $0.id == id } }  // a taken-back one is gone
            followUps.removeAll { f in ids.contains(f.id) }
            guard !batch.isEmpty else { return }
            let shown = batch.map(\.display).joined(separator: "\n")
            let c = Composed(display: shown, engine: batch.map(\.engine).joined(separator: "\n\n"), images: batch.flatMap(\.c.images), typed: shown)
            thinking = true
            await runTurn(c, hidden: false)
        case .note(let text):
            thinking = true
            await runTurn(Composed(display: "", engine: text, images: [], typed: ""), hidden: true)
        case .helperNews(let first):
            // Helpers finishing close together get ONE quiet line from One itself (no extra turn for the assistant):
            // wait a moment for the others, then take every helper notice still waiting.
            // (Never makes a message of theirs wait: with one in line, it goes now.)
            if !outbox.contains(where: { if case .message = $0 { return true } else { return false } }) {
                try? await Task.sleep(for: .seconds(Helpers.gatherSecs))
            }
            var ids = [first]
            for o in outbox { if case .helperNews(let id) = o, !ids.contains(id) { ids.append(id) } }
            outbox.removeAll { if case .helperNews = $0 { return true } else { return false } }
            let hs = ids.compactMap { id in helpers.first { $0.id == id } }.filter { $0.waiting && $0.routine == nil && $0.toldState != $0.state }
            guard !hs.isEmpty else { return }
            for h in hs { update(h.id) { $0.toldState = h.state } }
            saveHelpers()
            for h in hs { Helpers.log("notice: \(h.title) \(h.state)") }
            let line = Helpers.doneLine(hs)
            bubbles.removeAll { $0.text == line }
            bubbles.append(Bubble(fromMe: false, text: line))
            saveBubbles()
            if Idle.now { Speaker.shared.read(line) }  // spoken only when they're not in the middle of something (silent when muted)
        case .line(let bubble, let spoken):
            if let b = bubble {
                bubbles.removeAll { $0.text == b }
                bubbles.append(Bubble(fromMe: false, text: b))
                saveBubbles()
            }
            // Read aloud only when they haven't sent or said anything for a while; silent when muted.
            if !spoken.isEmpty && Idle.now { Speaker.shared.read(spoken) }
        }
    }
}

/// Have they done anything lately? A notice is read aloud only when they haven't sent or said anything for a while.
@MainActor
enum Idle {
    static var last = Date.distantPast
    static let after: TimeInterval = 90
    static func mark() { last = Date() }
    static var now: Bool { Date().timeIntervalSince(last) >= after }
}
