import AppKit
import SwiftUI

/// Message history (design B — frosted depth), approved by Omar 2026-10-29.
/// The one ongoing conversation keeps scrolling back further: each older turn sits a little further back,
/// more blurred and dimmer than the one below it, like looking back through frosted glass. The default home
/// screen stays calm (collapsed) until you tap the pull tab or hit the chevron.
struct HistoryStrip: View {
    @ObservedObject var m: Model
    let turns: [Bubble]
    @Binding var open: Bool
    @State var hovered: UUID?

    /// Renders: no hover state, no motion — matches other `--render-world` stills.
    nonisolated(unsafe) static var still = false

    var body: some View {
        VStack(spacing: 10) {
            if open {
                ForEach(Array(turns.enumerated()), id: \.element.id) { i, b in
                    row(b, depth: depth(of: i))
                }
            }
            if !turns.isEmpty {
                Button {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { open.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: open ? "chevron.down" : "chevron.up").font(.system(size: 11, weight: .semibold))
                        Text(open ? "Hide earlier" : "Scroll up for earlier").font(.caption)
                    }.foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
        }
    }

    /// 0 = just above the current exchange (sharpest), 1 = the oldest shown (softest, furthest back).
    func depth(of i: Int) -> Double {
        guard turns.count > 1 else { return 0 }
        return Double(turns.count - 1 - i) / Double(turns.count - 1)
    }

    @ViewBuilder func row(_ b: Bubble, depth: Double) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ChatText(text: b.text, size: 14, plain: b.fromMe)
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 6) {
                Button {
                    HistoryStrip.copy(b.text)
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 11))
                }
                .buttonStyle(.plain).help("Copy")
                if b.fromMe {
                    Button {
                        m.draftSeed = b.text
                    } label: {
                        Image(systemName: "arrow.uturn.up").font(.system(size: 11))
                    }
                    .buttonStyle(.plain).help("Resend")
                }
            }
            .foregroundStyle(.secondary)
            .opacity(HistoryStrip.still ? 1 : (hovered == b.id ? 1 : 0.0001))
        }
        .padding(10)
        .frame(maxWidth: 620)
        .background(RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial))
        .blur(radius: HistoryStrip.still ? 0 : depth * 2.4)
        .opacity(1 - depth * 0.55)
        .scaleEffect(1 - depth * 0.05, anchor: .bottom)
        .onHover { hovered = $0 ? b.id : nil }
        .id(b.id)
    }

    static func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

/// Render-only (`--render-world message-history` / `message-history-closed`): a sample conversation, several
/// turns back, to check the frosted-depth fade. Drawn without the real ScrollView (ImageRenderer draws
/// ScrollView contents blank), so the depth/blur can actually be seen in the still.
enum MessageHistoryRender {
    @MainActor static func scene(open: Bool) -> AnyView {
        HistoryStrip.still = true
        let m = Model.shared
        let sample: [Bubble] = [
            Bubble(fromMe: true, text: "What's my flight time on the 20th?"),
            Bubble(fromMe: false, text: "7:40 AM out of EWR, lands in Quebec City at 10:05."),
            Bubble(fromMe: true, text: "And the hotel address?"),
            Bubble(fromMe: false, text: "Auberge Saint-Antoine, 8 Rue Saint-Antoine, old town, 2 nights."),
            Bubble(fromMe: true, text: "Can you also check if the rental car needs winter tires?"),
            Bubble(fromMe: false, text: "Yes, Quebec law requires winter tires Dec 1 to Mar 15. I asked the rental desk to confirm."),
        ]
        var strip = HistoryStrip(m: m, turns: sample, open: .constant(open))
        strip.hovered = open ? sample[2].id : nil
        return AnyView(
            VStack {
                strip
            }
            .padding(24).frame(width: 680).background(WorldLook.bg).environment(\.colorScheme, .dark))
    }
}
