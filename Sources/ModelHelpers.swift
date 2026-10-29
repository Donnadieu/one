import Foundation

// MARK: - A finished helper: orange until it's opened, and one short line from One once the current reply is over.
// Routines (good morning / status report) instead get one combined report when all their helpers are back.

@MainActor
extension Model {
    /// A helper finished: its orb turns orange and holds the result. The assistant never relays it or asks its question;
    /// One adds one short line itself ("<title> is done. Tap it to take a look."), at the back of the one line everything
    /// is said through (SayQueue.swift): never in the middle of a reply or its voice; helpers finishing close together
    /// share one line ("3 helpers are done: …"). Read aloud only when they're idle.
    /// One per change of state: a helper that ends several turns the same way (picked back up, carried on after a
    /// check) gets one notice, and a notice still waiting says its newest state. None for a helper they opened.
    func queueDoneNote(_ id: UUID) {
        guard let h = helpers.first(where: { $0.id == id }), h.waiting, h.routine == nil, h.toldState != h.state else { return }
        enqueue(.helperNews(id))
    }

    /// Good morning / afternoon / evening or a status report: its helpers report together. Once every helper from
    /// that message is back, the assistant gives one combined report with the real content, in the chat and out loud.
    func deliverRoutine(_ batch: UUID) async {
        let mine = { self.helpers.filter { $0.routine == batch } }
        guard !mine().isEmpty, !mine().contains(where: { $0.state == "working" || $0.resumeQueued == true }) else { return }
        guard !routinesTold.contains(batch) else { return }
        routinesTold.insert(batch)
        var parts: [String] = []
        for h in mine() {
            var r = Choices.split(h.reply).body.trimmingCharacters(in: .whitespacesAndNewlines)
            if r.count > 2500 { r = String(r.prefix(2500)) + "…" }
            let what = h.state == "needsYes" ? "waiting for their yes" : h.state == "stopped" ? "stopped before finishing" : "done"
            parts.append("- \(h.title) (\(what)):\n\(r.isEmpty ? "(no text)" : r)")
            update(h.id) { $0.toldNova = true }
        }
        let asks = mine().contains { $0.state == "needsYes" } ? " If one needs their yes, say exactly what for and offer the choices." : ""
        enqueue(
            .note(
                "(One app note, not from the user: all the helpers you sent for that are back. Give \(userName) ONE combined report now, "
                    + "in your own words: the real content (the numbers, names, times, what changed), short and complete. "
                    + "Never just say you have the update or that it's ready.\(asks) Their results:\n" + parts.joined(separator: "\n") + ")"))
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
                    let quiet = seemsStuck(h, now: Date()) ? ", no progress for a while; \(userName) can nudge or stop it from its orb" : ""
                    lines.append("- \(h.title): still working (\(progressLine(h, now: Date()))\(quiet)).")
                }
            case "stopped":
                lines.append(
                    h.resumeQueued == true
                        ? "- \(h.title): \(h.updatePaused == true ? "paused for \(h.pausedFor ?? "an update")" : "cut off by a restart"); One picks it back up by itself in a moment."
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
