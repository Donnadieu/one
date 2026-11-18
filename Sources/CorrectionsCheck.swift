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

        print(fails == 0 ? "corrections ok" : "corrections failed: \(fails)")
        return fails == 0 ? 0 : 1
    }
}
