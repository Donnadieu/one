import SwiftUI

// MARK: - A helper's orb stays until they're done with it (Omar, Oct 28: "a helper orb must NEVER go away on its own",
// and later the same day, after losing one to a stray click on its X: "never removed straight from the orb").
// Not when it finishes, not when it's opened or read, not when a new helper starts, not after a restart, an update or
// a crash, and no cap on how many. Nothing on the orb itself takes it away (no X, no right-click item, no swipe, no
// key). The only two ways off the screen: "Got it" inside its thread, or asking the assistant ([done-helper: …], or
// the older [close-helper: …]). A helper still at work or waiting for their yes stays until it's stopped first.
// Proven by `make helpers-check` (HelperStress.swift). Omar dislikes the word "close": none of this says it to him.

enum HelperClose {
    /// Told to the assistant on every prompt and in SOUL (with the stop rule).
    static let rule =
        "To take a helper's orb off the screen, when they say \"I'm done with <name>\", \"got it\" (about a helper), \"clear <name>\", \"remove <name>\" or \"clear them all\", add a line exactly like [done-helper: <its exact title>] or [done-helper: all] and confirm in one short line, like \"Done, Flight to Quebec is off your screen.\" \"all\" clears every helper that's finished or stopped. A helper still working or waiting for their yes stays on the screen until it's stopped: if they ask to clear one of those, say so and ask if you should stop it first; only after they say yes, add [stop-helper: <its exact title>] and then [done-helper: <its exact title>]. An orb never goes away on its own: it stays until they tap Got it inside it or ask you."
    /// The lines the assistant can write to take an orb off the screen: the new one, and the old one still read.
    static let tags = ["done-helper", "close-helper"]

    /// Still busy: at work, waiting to pick back up, or waiting for their yes. Never taken off the screen.
    static func busy(_ h: Helper) -> Bool { h.state == "working" || h.state == "needsYes" || h.resumeQueued == true }

    /// Which helpers a done line means: the exact title (any case, the most recently sent on ties), or "all" =
    /// every one that's finished or stopped (a busy one is never taken, even by name, until it's stopped).
    static func match(_ name: String, in hs: [Helper]) -> [UUID] {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'“”‘’"))).lowercased()
        if n == "all" { return hs.filter { !busy($0) }.map(\.id) }
        let same = hs.enumerated().filter { $0.element.title.lowercased() == n }
        let pick = same.max { a, b in (a.element.started ?? .distantPast, a.offset) < (b.element.started ?? .distantPast, b.offset) }
        return pick.map { [$0.element.id] } ?? []
    }
    static func notFound(_ name: String) -> String { "I couldn't find a helper called \"\(name)\"." }
    /// Asked to clear one that's still busy: it stays, and this says why.
    static func stillBusy(_ h: Helper) -> String {
        h.state == "needsYes"
            ? "\(h.title) is waiting for your yes, so it stays on your screen. Answer it, or ask me to stop it first."
            : "\(h.title) is still working, so it stays on your screen. Ask me to stop it first if you want it gone."
    }

    /// The saved helpers, read back. One unreadable entry never costs the rest: each is read on its own, and
    /// anything that can't be read is set aside under `helpersUnreadable` instead of being written over.
    static func decode(_ d: Data) -> [Helper] {
        if let hs = try? JSONDecoder().decode([Helper].self, from: d) { return hs }
        guard let raw = (try? JSONSerialization.jsonObject(with: d)) as? [Any] else {
            UserDefaults.standard.set(d, forKey: "helpersUnreadable")
            Helpers.log("saved helpers couldn't be read; kept aside under helpersUnreadable")
            return []
        }
        var out: [Helper] = []
        var bad: [Any] = []
        for item in raw {
            if let one = try? JSONSerialization.data(withJSONObject: item), let h = try? JSONDecoder().decode(Helper.self, from: one) {
                out.append(h)
            } else {
                bad.append(item)
            }
        }
        if !bad.isEmpty, let keep = try? JSONSerialization.data(withJSONObject: bad) {
            UserDefaults.standard.set(keep, forKey: "helpersUnreadable")
            Helpers.log("\(bad.count) saved helper(s) couldn't be read; kept aside under helpersUnreadable")
        }
        return out
    }
}

extension Model {
    /// They're done with this helper ("Got it" in its thread, or by asking). The one and only way an orb leaves the
    /// screen. A helper still at work or waiting for their yes is never taken: it has to be stopped first.
    @discardableResult func closeHelper(_ id: UUID) -> Bool {
        guard let h = helpers.first(where: { $0.id == id }), !HelperClose.busy(h) else { return false }
        if openHelper == id { openHelper = nil }
        doneQueue.removeAll { $0 == id }
        Helpers.log("helper \"\(h.title)\" taken off the screen by you (\(h.state))")
        withAnimation(.easeIn(duration: 0.6)) { helpers.removeAll { $0.id == id } }
        return true
    }

    /// The assistant wrote "[done-helper: …]" (or the older "[close-helper: …]"): take the match off the screen.
    /// Returns a plain line if nothing matched, or if the match is still busy.
    func closeHelpers(named name: String) -> String? {
        let ids = HelperClose.match(name, in: helpers)
        if ids.isEmpty { return name.lowercased().trimmingCharacters(in: .whitespaces) == "all" ? nil : HelperClose.notFound(name) }
        var said: [String] = []
        for id in ids where !closeHelper(id) {
            if let h = helpers.first(where: { $0.id == id }) { said.append(HelperClose.stillBusy(h)) }
        }
        return said.isEmpty ? nil : said.joined(separator: "\n")
    }

    /// "Start again" on a stopped helper: the same orb goes back to work on its original job, from the start.
    /// (It used to be taken off the screen and a new one sent in its place.)
    func startAgain(_ id: UUID) {
        guard let h = helpers.first(where: { $0.id == id }), h.state == "stopped", h.resumeQueued != true else { return }
        update(id) {
            $0.state = "working"
            $0.line = "Getting started…"
            $0.stoppedByYou = nil
            $0.sid = nil
            $0.started = Date()
            HelperTrail.add("Started again by you", to: &$0)
        }
        saveTrail(id)
        Task { @MainActor in
            guard let sid = await Engine.shared.openSession() else {
                self.update(id) { HelperTrail.notFinished(&$0, .cutOff) }
                self.saveTrail(id)
                self.resumeWhenReady(after: 1)
                return
            }
            self.update(id) { $0.sid = sid }
            await self.runHelper(id, Helpers.brief(assistant: self.assistantName, user: self.userName, task: h.task), images: [])
        }
    }
}
