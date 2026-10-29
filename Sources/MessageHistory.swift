import AppKit
import SwiftUI

/// Message history (design A — plain thread), approved by Omar 2026-10-29. Design B (frosted depth: each
/// older turn further back, blurrier and dimmer) was rejected as still too hard to read. Option A is flat
/// and fully legible: every revealed turn renders at full opacity, no blur, no shrink — a true scrollable
/// list, oldest to newest, with a subtle day/time divider when the gap between two turns is worth marking.
/// The collapse/expand trigger (chevron + "Scroll up for earlier" / "Hide earlier") is unchanged.
struct HistoryStrip: View {
    @ObservedObject var m: Model
    let turns: [Bubble]
    @Binding var open: Bool
    @State var hovered: UUID?

    /// Renders: no hover state, no motion — matches other `--render-world` stills.
    nonisolated(unsafe) static var still = false

    /// A card this tall is comfortable to scroll in the home layout without crowding the current exchange.
    static let listHeight: CGFloat = 360

    var body: some View {
        VStack(spacing: 10) {
            if open {
                // ImageRenderer draws ScrollView contents blank, so `--render-world` stills skip the
                // ScrollView and lay the same rows out directly; the live app always uses the real one.
                if HistoryStrip.still {
                    list
                } else {
                    ScrollView { list.padding(.vertical, 4) }
                        .frame(maxHeight: HistoryStrip.listHeight)
                }
            }
            if !turns.isEmpty {
                Button {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { open.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: open ? "chevron.down" : "chevron.up").font(.system(size: 11, weight: .semibold))
                        Text(open ? "Hide earlier" : "Scroll up for earlier").font(.caption)
                    }.foregroundStyle(WorldLook.cream.opacity(0.75))
                }.buttonStyle(.plain)
            }
        }
    }

    var list: some View {
        VStack(spacing: 10) {
            ForEach(Array(turns.enumerated()), id: \.element.id) { i, b in
                if let label = dividerLabel(before: i) {
                    HistoryDivider(label: label)
                }
                row(b)
            }
        }
    }

    /// A divider before turn `i` when it starts a new calendar day from the one before it, or there's at
    /// least an hour's gap between them. Never shown before the very first (oldest) turn.
    func dividerLabel(before i: Int) -> String? {
        guard i > 0 else { return nil }
        let prev = turns[i - 1].date
        let cur = turns[i].date
        let cal = Calendar.current
        guard !cal.isDate(prev, inSameDayAs: cur) || cur.timeIntervalSince(prev) > 3600 else { return nil }
        let df = DateFormatter()
        if cal.isDateInToday(cur) {
            df.dateFormat = "h:mm a"
        } else if cal.isDateInYesterday(cur) {
            df.dateFormat = "'Yesterday,' h:mm a"
        } else {
            df.dateFormat = "MMM d, h:mm a"
        }
        return df.string(from: cur)
    }

    /// Every row renders the message at full legibility: no opacity/blur/scale modifier on the text itself.
    /// The copy/resend icons may fade in on hover (same as before); that's chrome, not content.
    @ViewBuilder func row(_ b: Bubble) -> some View {
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
                    .buttonStyle(.plain).help("Ask again")
                }
            }
            .foregroundStyle(WorldLook.cream.opacity(0.75))
            .opacity(HistoryStrip.still ? 1 : (hovered == b.id ? 1 : 0.0001))
        }
        .padding(10)
        .frame(maxWidth: 620)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(hex: 0x1C1C1F)))
        .onHover { hovered = $0 ? b.id : nil }
        .id(b.id)
    }

    static func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

/// A subtle rule + label between two turns, marking a day change or a real time gap. Never as dim as the
/// message text next to it — it's chrome, meant to orient, not to be read closely.
struct HistoryDivider: View {
    let label: String
    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(WorldLook.cream.opacity(0.12)).frame(height: 1)
            Text(label).font(.caption2).foregroundStyle(WorldLook.cream.opacity(0.45))
            Rectangle().fill(WorldLook.cream.opacity(0.12)).frame(height: 1)
        }
        .frame(maxWidth: 620)
        .padding(.vertical, 2)
    }
}

/// Render-only (`--render-world message-history` / `message-history-closed`): a sample conversation, a
/// couple of turns back plus one clearly older day, to check the plain-thread list reads at full legibility
/// with a divider. Drawn without the real ScrollView (ImageRenderer draws ScrollView contents blank), so the
/// list is laid out directly for the still.
enum MessageHistoryRender {
    @MainActor static func scene(open: Bool) -> AnyView {
        HistoryStrip.still = true
        let m = Model.shared
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        let sample: [Bubble] = [
            Bubble(fromMe: true, text: "What's my flight time on the 20th?", date: yesterday),
            Bubble(fromMe: false, text: "7:40 AM out of EWR, lands in Quebec City at 10:05.", date: yesterday),
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
