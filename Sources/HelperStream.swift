import AppKit

// MARK: - A working helper's words, a few times a second
//
// The engine streams a helper's reply in small pieces, often dozens a second across several helpers. Each piece used to
// change `helpers` on its own: every view on the home screen redrew and all helpers (their whole logs, ~100 KB on Omar's
// Mac) were written to the settings again, on the main thread, for every piece. Typing and the orbs stuttered while
// helpers worked (Nov 18 2026). Now the pieces are gathered and put in together every `every` seconds, which looks the
// same, and the settings are written once things settle (`saveLater`) or at the next real change of a helper.

@MainActor
extension Model {
    static let streamEvery = 0.12
    static let saveAfter = 2.0

    /// A piece of a working helper's reply, as the engine streams it (`--test-smooth` sends these too).
    func helperStreamed(_ id: UUID, _ s: String) {
        streamed[id, default: ""] += s
        guard streamFlush == nil else { return }
        streamFlush = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Model.streamEvery))
            self.flushStreamed()
        }
    }

    /// Puts every gathered piece in now (also right before a helper's turn is wrapped up).
    func flushStreamed() {
        streamFlush?.cancel()
        streamFlush = nil
        let all = streamed
        streamed = [:]
        guard !all.isEmpty else { return }
        // One change to `helpers` and one to `pulses` for all of them: the screen redraws once for the lot.
        var hs = helpers
        var ps = pulses
        for (id, s) in all {
            helperUnderway(id)
            if let k = hs.firstIndex(where: { $0.id == id }) { hs[k].reply += s }
            if var p = ps[id] {
                HelperPulse.add(s, to: &p)
                ps[id] = p
            }
        }
        streamingWords = true
        helpers = hs
        streamingWords = false
        pulses = ps
        for id in all.keys { saveTrail(id, force: false) }
        saveLater()
    }

    /// `applicationShouldTerminate`: the last streamed words are written, then quit now or once routines finish (QuitHold).
    func quitting() -> NSApplication.TerminateReply {
        saveStreamedNow()
        return QuitHold.reply()
    }

    /// Quitting: everything gathered goes in and is written now.
    func saveStreamedNow() {
        flushStreamed()
        if helpersUnsaved { saveHelpers() }
    }

    /// The settings copy of the helpers, written once the words settle (any other change writes it at once).
    func saveLater() {
        guard helpersUnsaved, helpersSaveLater == nil else { return }
        helpersSaveLater = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Model.saveAfter))
            self.helpersSaveLater = nil
            if self.helpersUnsaved { self.saveHelpers() }
        }
    }
}

extension HelperPulse {
    /// What it said lately, kept short (the last 2,000 characters once it passes 4,000).
    static func add(_ s: String, to p: inout HelperPulse) {
        p.said += s
        if p.said.count > 4000 { p.said = String(p.said.suffix(2000)) }
    }
}
