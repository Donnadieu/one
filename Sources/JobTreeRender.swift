import SwiftUI

/// Render-only (`--render-world <prefix>`, from a test copy): stop means stop, Claude Design "One Safety Features"
/// Direction A (Omar's pick, Nov 9 2026): `helper-stop-tree` = a helper closing its tree, one whose program won't close
/// (orange, Force stop in its card) and one fully closed, next to a working one.
struct StopTreeScene: View {
    static func helper(_ title: String, _ state: String, _ line: String, stopping: Bool? = nil, left: [String]? = nil) -> Helper {
        var h = Helper(title: title, task: "", sid: nil, state: state, line: line)
        h.stoppedByYou = state == "stopped" ? true : nil
        h.stopping = stopping
        h.leftovers = left
        h.seen = true
        return h
    }
    var body: some View {
        let names = ["NotArc test app", "2 test runs"]
        let hs = [
            Self.helper("Canvas price options", "working", "Reading the price pages…"),
            Self.helper("Finish NotArc", "stopped", HelperTrail.stoppingLine(names), stopping: true),
            Self.helper("NotArc self-test", "stopped", HelperTrail.wontClose(["NotArc test app"]), stopping: true, left: ["NotArc test app"]),
            Self.helper("Fix the build", "stopped", HelperTrail.closedLine),
        ]
        HStack(alignment: .top, spacing: 30) {
            VStack(spacing: 10) {
                ForEach(Array(hs.enumerated()), id: \.offset) { i, h in
                    VStack(spacing: -10) {
                        HelperOrb(state: h.viewState, t: 21.7 + Double(i) * 3.1, size: 42)
                        HelperTag(
                            title: h.title, line: HelperRings.status(h), look: HelperRings.Look(orb: 42, label: 240, title: 13, line: 11),
                            warm: h.viewState == .needsYes, opened: h.viewState == .done)
                    }
                }
            }.frame(width: 250)
            HelperCard(m: Model.shared, h: hs[2]).frame(width: 440)
        }
        .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity).background(WorldLook.bg).environment(\.colorScheme, .dark)
    }
    @MainActor static var renders: [(String, AnyView)] { [("helper-stop-tree", AnyView(Self()))] }
}
