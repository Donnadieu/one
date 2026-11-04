import AppKit
import SwiftUI

// MARK: - Typing-lag measurement: `One --test-message-typing` (not pass/fail — prints real numbers).
//
// Omar, 2026-10-29: "typing in the chat box lags" with the new message trail. His own diagnosis: the
// ask box's text binding (`draft`) lives on `HomeView` itself, the same view whose body also builds
// `HistoryStrip` (markdown + real AppKit text layout per row via `ChatTextBox`). Every keystroke
// invalidates `HomeView.body`, which reconstructs `HistoryStrip` fresh; without `.equatable()` SwiftUI
// re-runs that whole subtree (and its real NSTextView layout work) even though typing never touches
// `turns`/`open`. The fix: `HistoryStrip: Equatable` (Bubble: Equatable too) + `.equatable()` at the call
// site in HomeView — this measures the real difference it makes with 45 history rows, both ways, in the
// same live on-screen window (not a synthetic microbenchmark).
@MainActor
enum MessageTypingPerfCheck {
    static func launch() -> Bool {
        guard CommandLine.arguments.contains("--test-message-typing") else { return false }
        TestWorld.enter()
        guard ProcessInfo.processInfo.environment["ONE_SUPPORT_DIR"] != nil else {
            print("refusing: set ONE_SUPPORT_DIR to an empty folder first")
            exit(2)
        }
        run()
        return true
    }

    static func pump() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.001))
    }

    /// 45 bubbles (well past the "40+ messages" Omar asked to measure with), alternating turns.
    static func sampleTurns(_ n: Int) -> [Bubble] {
        (0..<n).map { i in
            Bubble(
                fromMe: i % 2 == 0,
                text: i % 2 == 0
                    ? "What's turn \(i) about, in a bit more detail than usual?"
                    : "Here's turn \(i): a reply with enough words to need real text layout, not just a short line.")
        }
    }

    /// Simulates `HomeView`'s exact shape above the ask box: a page ScrollView holding the history
    /// (`.equatable()` or not, per `useEquatable`) plus some other content, with a text field whose
    /// binding lives in the SAME host view as the history — just like `HomeView.draft` does today.
    struct Host: View {
        @State var draft = ""
        let turns: [Bubble]
        let useEquatable: Bool
        var body: some View {
            VStack(spacing: 12) {
                ScrollView {
                    VStack(spacing: 12) {
                        Color.clear.frame(height: 40)
                        let strip = HistoryStrip(m: Model.shared, turns: turns, open: .constant(true))
                        if useEquatable { AnyView(strip.equatable()) } else { AnyView(strip) }
                    }
                    .padding(.horizontal, 28)
                }
                .frame(maxHeight: 500)
                TextField("Or say it your way…", text: $draft).textFieldStyle(.plain).padding(8).frame(width: 600)
            }
            .frame(width: 760, height: 620).background(Color.black).environment(\.colorScheme, .dark)
        }
    }

    /// Opens a window hosting `Host`, then simulates 40 keystrokes by mutating `draft` directly (the same
    /// state change a real keystroke causes) and timing how long each state-change-to-settled-frame
    /// round trip takes. Returns (total seconds, per-keystroke ms).
    static func measure(useEquatable: Bool, turns: [Bubble]) -> (total: Double, perKeystroke: Double) {
        var draftBox = ""
        let window = NSWindow(
            contentRect: NSRect(x: 60, y: 60, width: 760, height: 620), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let host = Host(turns: turns, useEquatable: useEquatable)
        let hosting = NSHostingView(rootView: host)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        pump()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))  // let it settle once before timing.

        let text = "the quick brown fox jumps over"  // 30 keystrokes, like a short typed message.
        let start = CFAbsoluteTimeGetCurrent()
        for ch in text {
            draftBox.append(ch)
            // Push the same "draft changed" edit into the live view the way a real keystroke does: mutate
            // the hosted root view's own @State (NSHostingView keeps its state across this, same as
            // SwiftUI keeps HomeView's @State across a real keystroke).
            hosting.rootView.draft = draftBox
            pump()
        }
        let total = CFAbsoluteTimeGetCurrent() - start
        window.close()
        return (total, (total / Double(text.count)) * 1000)
    }

    static func run() {
        let turns = sampleTurns(45)
        // Warm up once (first-run JIT/layout cache effects shouldn't count against either side).
        _ = measure(useEquatable: true, turns: Array(turns.prefix(4)))

        let without = measure(useEquatable: false, turns: turns)
        let with = measure(useEquatable: true, turns: turns)

        print("message history typing-lag measurement (45 history rows, 30 simulated keystrokes):")
        print(String(format: "  without .equatable() (old shape): %.1f ms total, %.2f ms/keystroke", without.total * 1000, without.perKeystroke))
        print(String(format: "  with    .equatable() (this fix):  %.1f ms total, %.2f ms/keystroke", with.total * 1000, with.perKeystroke))
        if with.perKeystroke < without.perKeystroke {
            let pct = (1 - with.perKeystroke / without.perKeystroke) * 100
            print(String(format: "  → %.0f%% less time per keystroke with the fix", pct))
        } else {
            print("  → no improvement measured in this run (see note in the report: environment-dependent)")
        }
        exit(0)
    }
}
