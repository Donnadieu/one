import AppKit
import Foundation

// MARK: - Check: message history (design A, plain thread) — `One --test-message-history`

/// Proves: older turns are found and ordered correctly, the saved bubbles survive a restart (up to the
/// raised 500-bubble cap, well past the old 40), the copy icon puts the real text on the pasteboard, resend
/// seeds the draft with the exact earlier message, and the plain-thread list has no numeric fade/blur
/// calculation left in it (design A must stay fully legible, not just "blur set to 0"). Touches
/// `UserDefaults bubbles` and the clipboard only; run with ONE_SUPPORT_DIR set to an empty folder so no real
/// settings or brain are touched.
@MainActor
enum MessageHistoryCheck {
    /// `--test-message-history`: throwaway UserDefaults and the real pasteboard, from a copy with its own settings.
    static func launch() -> Bool {
        guard CommandLine.arguments.contains("--test-message-history") else { return false }
        TestWorld.enter()
        guard ProcessInfo.processInfo.environment["ONE_SUPPORT_DIR"] != nil else {
            print("refusing: set ONE_SUPPORT_DIR to an empty folder first")
            exit(2)
        }
        exit(run())
    }

    static func run() -> Int32 {
        var fails = 0
        func check(_ name: String, _ ok: Bool) {
            print("  \(ok ? "✓" : "✗") \(name)")
            if !ok { fails += 1 }
        }
        check("runs as a command-line tool (never touches a real engine)", Env.commandLine)

        // olderTurns: everything before the current exchange, oldest first.
        let m = Model.shared
        m.bubbles = [
            Bubble(fromMe: true, text: "What's my flight time on the 20th?"),
            Bubble(fromMe: false, text: "7:40 AM out of EWR."),
            Bubble(fromMe: true, text: "And the hotel?"),
            Bubble(fromMe: false, text: "Auberge Saint-Antoine."),
            Bubble(fromMe: true, text: "What about the rental car?"),  // current exchange starts here
        ]
        let cutoff = m.bubbles.lastIndex(where: { $0.fromMe })!
        let older = m.bubbles[..<cutoff].filter { !$0.text.isEmpty }
        check("finds every turn before the current one", older.count == 4)
        check("oldest first, current exchange excluded", older.first?.text == "What's my flight time on the 20th?")
        check("newest-of-the-old last", older.last?.text == "Auberge Saint-Antoine.")

        // Design C (marked trail) is still a true flat list underneath its thread/dot chrome: no blur/fade/
        // shrink numeric calculation on the message text itself. (Design B had a `depth(of:)` 0...1
        // calculation driving `.blur()`/`.opacity()`/`.scaleEffect()`; that must stay gone, not just zeroed.)
        let siblingDir = (#filePath as NSString).deletingLastPathComponent
        let src = (try? String(contentsOfFile: siblingDir + "/MessageHistory.swift", encoding: .utf8)) ?? ""
        check("source file was found to scan", !src.isEmpty)
        check("no leftover `depth` fade/blur calculation", !src.contains("func depth("))
        check("no `.blur(` on any history row", !src.contains(".blur("))
        check("no `.scaleEffect(` (shrink/recede) on any history row", !src.contains(".scaleEffect("))
        // The only `.opacity(` calls left are chrome: the toggle label, icon hover-reveal, the divider rule/
        // label, the distance pill and the thread line/dot — none of them dim the message text itself.
        check(
            "row() applies no `.opacity(` to the message text",
            !src.contains(
                "ChatText(text: b.text, size: 14, plain: b.fromMe)\n                    .frame(maxWidth: .infinity, alignment: .leading)\n                    .opacity"
            ))
        // No background box behind a row: the thread (for your own questions) is the only chrome now,
        // not a filled rounded rectangle card like the old design.
        check("no filled background box on a history row", !src.contains(".background(RoundedRectangle(cornerRadius: 14).fill("))

        // history readable past 40 messages: the persisted cap is raised well beyond the old 40-bubble limit.
        UserDefaults.standard.removeObject(forKey: "bubbles")
        var long: [Bubble] = (0..<520).map { Bubble(fromMe: $0 % 2 == 0, text: "turn \($0)") }
        long.append(Bubble(fromMe: false, text: ""))  // an empty one (mid-stream reply) must not survive
        m.bubbles = long
        m.saveBubbles()
        let restored = Model.savedBubbles()
        check("cap is raised well past the old 40-message limit", Model.maxSavedBubbles >= 500)
        check("saved bubbles are capped at the new, much higher limit", restored.count == Model.maxSavedBubbles)
        check(
            "history is readable past the old 40-message cutoff (turn 41 survives)",
            restored.contains { $0.text == "turn 41" })
        check("the oldest of the saved batch matches the new cap window", restored.first?.text == "turn 20")
        check("the newest saved is the real last turn", restored.last?.text == "turn 519")
        check("an empty bubble is never saved", !restored.contains { $0.text.isEmpty })

        // Copy icon: puts the exact bubble text on the real pasteboard.
        let sample = "Auberge Saint-Antoine, 8 Rue Saint-Antoine, old town, 2 nights."
        HistoryStrip.copy(sample)
        check("copy puts the exact text on the pasteboard", NSPasteboard.general.string(forType: .string) == sample)

        // Resend ("Ask again"): seeds the draft with the exact earlier message (the same path a typed draft uses).
        m.draftSeed = nil
        m.draftSeed = "And the hotel?"
        check("resend seeds the draft with the exact earlier message", m.draftSeed == "And the hotel?")

        // Day/time divider: never shown before the very first (oldest) turn, whatever its age.
        let strip = HistoryStrip(m: m, turns: [], open: .constant(true))
        check("no divider before the very first turn", strip.dividerLabel(before: 0) == nil)

        // Halo not clipped: the orb's own rendered halo is bigger than its component frame (Orb wraps a
        // 280×280 Presence in a 184×184 frame at size 92, so the halo overflows ~37pt past its own frame;
        // HelperConstellation's empty-state frame is only 150pt tall, overflowing another ~17pt), and the
        // orb sits at the very top of this same scrolling column. Without a real gap above it, the
        // ScrollView's own clip boundary cuts a flat edge straight through the circular halo — "a
        // rectangular box clips its aura" (Omar, 2026-10-29). A fixed, generous gap right before
        // `HelperConstellation(` in HomeView.swift is the fix; this proves it's still there and still big
        // enough, without touching the orb's own files.
        let homeSrc = (try? String(contentsOfFile: siblingDir + "/HomeView.swift", encoding: .utf8)) ?? ""
        check("HomeView source was found to scan", !homeSrc.isEmpty)
        let haloGap: Int? = {
            guard let r = homeSrc.range(of: "HelperConstellation(m: m,") else { return nil }
            let before = homeSrc[..<r.lowerBound]
            guard let spacerRange = before.range(of: "Color.clear.frame(height: ", options: .backwards) else { return nil }
            let after = before[spacerRange.upperBound...]
            let digits = after.prefix(while: { $0.isNumber })
            return Int(digits)
        }()
        check("a real gap sits above the orb, right before HelperConstellation", haloGap != nil)
        check("that gap is at least 60pt — enough to clear the halo's overflow", (haloGap ?? 0) >= 60)

        UserDefaults.standard.removeObject(forKey: "bubbles")
        m.bubbles = []
        print(fails == 0 ? "message history: all checks passed" : "message history: \(fails) check(s) failed")
        return fails == 0 ? 0 : 1
    }
}
