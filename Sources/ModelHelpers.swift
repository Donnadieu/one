import Foundation

// MARK: - A finished helper: orange until it's opened, and one "by the way" line once the current reply is over.
// Routines (good morning / status report) instead get one combined report when all their helpers are back.

@MainActor
extension Model {
    /// A helper finished: its orb turns orange and holds the result. The assistant never relays it or asks its question;
    /// once its current reply is over (never in the middle of one), it adds one "By the way, <title> is done" line.
    /// Helpers that finish during the same reply share one line. Nothing goes out for a helper they already opened.
    func queueDoneNote(_ id: UUID) {
        if !doneQueue.contains(id) { doneQueue.append(id) }
        guard !doneNoteWaiting else { return }
        doneNoteWaiting = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))  // helpers finishing together go in one line
            // Wait for the reply (and its voice) to end, and let anything they sent first go first.
            while thinking || paused || voicePlaying || followUps.contains(where: { $0.helper == nil }) {
                try? await Task.sleep(for: .milliseconds(500))
            }
            doneNoteWaiting = false
            let ready = doneQueue.compactMap { q in helpers.first { $0.id == q && $0.waiting && $0.routine == nil } }
            doneQueue = []
            guard !ready.isEmpty else { return }
            await send(Helpers.doneNote(ready, user: userName), toNova: true, hidden: true)
        }
    }

    /// Good morning / afternoon / evening or a status report: its helpers report together. Once every helper from
    /// that message is back, the assistant gives one combined report with the real content, in the chat and out loud.
    func deliverRoutine(_ batch: UUID) async {
        let mine = { self.helpers.filter { $0.routine == batch } }
        guard !mine().isEmpty, !mine().contains(where: { $0.state == "working" || $0.resumeQueued == true }) else { return }
        guard !routinesTold.contains(batch) else { return }
        routinesTold.insert(batch)
        while thinking || paused || voicePlaying { try? await Task.sleep(for: .milliseconds(500)) }
        var parts: [String] = []
        for h in mine() {
            var r = Choices.split(h.reply).body.trimmingCharacters(in: .whitespacesAndNewlines)
            if r.count > 2500 { r = String(r.prefix(2500)) + "…" }
            let what = h.state == "needsYes" ? "waiting for their yes" : h.state == "stopped" ? "stopped before finishing" : "done"
            parts.append("- \(h.title) (\(what)):\n\(r.isEmpty ? "(no text)" : r)")
            update(h.id) { $0.toldNova = true }
        }
        let asks = mine().contains { $0.state == "needsYes" } ? " If one needs their yes, say exactly what for and offer the choices." : ""
        await send(
            "(One app note, not from the user: all the helpers you sent for that are back. Give \(userName) ONE combined report now, "
                + "in your own words: the real content (the numbers, names, times, what changed), short and complete. "
                + "Never just say you have the update or that it's ready.\(asks) Their results:\n" + parts.joined(separator: "\n") + ")",
            toNova: true, hidden: true)
    }

    /// What the assistant should know about her helpers every turn: who's still working and who's done.
    /// Never the results of regular helpers: those wait under their orange orb for the person to open.
    func helperNews() -> String {
        guard !helpers.isEmpty else { return "" }
        var lines: [String] = []
        for k in helpers.indices {
            let h = helpers[k]
            switch h.state {
            case "working":
                if let n = h.restartNews {
                    lines.append("- \(h.title): still working. A restart cut it off and One picked it back up by itself; they were told: \"\(n)\"")
                    helpers[k].restartNews = nil
                } else {
                    lines.append("- \(h.title): still working (\(h.line)).")
                }
            case "stopped":
                lines.append(
                    h.resumeQueued == true
                        ? "- \(h.title): cut off by a restart; One picks it back up by itself in a moment."
                        : "- \(h.title): stopped, not finished (\(h.line)).")
            default:
                let what = h.state == "needsYes" ? "is waiting for \(userName)'s yes" : "is done"
                if h.routine != nil {
                    lines.append(
                        "- \(h.title): \(what). "
                            + (h.toldNova == true
                                ? "You were already given its result." : "Part of a report; One gives you all the results together."))
                } else {
                    let file =
                        h.shelfID.flatMap { s in shelf.first { $0.id == s }?.path }.map { " If they ask about it, its full result is in \($0)." }
                        ?? ""
                    lines.append(
                        "- \(h.title): \(what), "
                            + (h.seen == false ? "waiting for \(userName) to open it (its orb is orange)." : "and \(userName) has opened it.")
                            + " Don't repeat its result or ask its question.\(file)")
                }
            }
        }
        return "\n\n(One app note, not from the user: status of your helpers right now. Trust this over anything said earlier.\n"
            + lines.joined(separator: "\n") + ")"
    }
}
