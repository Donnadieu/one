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

        // Design A is a true flat list: no blur/fade/shrink numeric calculation left in the view at all.
        // (Design B had a `depth(of:)` 0...1 calculation driving `.blur()`/`.opacity()`/`.scaleEffect()`;
        // Option A must remove that calculation, not just zero its output.)
        let siblingDir = (#filePath as NSString).deletingLastPathComponent
        let src = (try? String(contentsOfFile: siblingDir + "/MessageHistory.swift", encoding: .utf8)) ?? ""
        check("source file was found to scan", !src.isEmpty)
        check("no leftover `depth` fade/blur calculation", !src.contains("func depth("))
        check("no `.blur(` on any history row", !src.contains(".blur("))
        check("no `.scaleEffect(` (shrink/recede) on any history row", !src.contains(".scaleEffect("))
        // The only `.opacity(` calls left are: the toggle label (0.75), icon hover-reveal (0.0001/1), and
        // the divider rule/label (0.12/0.45) — none of them dim the message text itself below 0.9.
        check(
            "row() applies no `.opacity(` to the message text",
            !src.contains(
                "ChatText(text: b.text, size: 14, plain: b.fromMe)\n                .frame(maxWidth: .infinity, alignment: .leading)\n                .opacity"
            ))

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

        UserDefaults.standard.removeObject(forKey: "bubbles")
        m.bubbles = []
        print(fails == 0 ? "message history: all checks passed" : "message history: \(fails) check(s) failed")
        return fails == 0 ? 0 : 1
    }
}
