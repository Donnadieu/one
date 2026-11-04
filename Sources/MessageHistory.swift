import AppKit
import SwiftUI

/// Message history (design C — marked trail), approved by Omar 2026-10-29, built from the exact "C ·
/// Marked trail" option in Claude Design (Message History.dc.html): a thread runs up from the orb through
/// every exchange, a small dot and time beside each of your questions, and a pill at the top shows how far
/// back you've scrolled ("6:40 PM · 1 h 34 m ago"). Every turn renders at full opacity, no blur, no shrink —
/// fully legible and selectable the whole way back. No background box behind any row: text sits directly on
/// the window's own background. The orb itself is never touched by this file; this only draws the thread
/// and rows BELOW where the orb already sits, so it never boxes in or overlaps the orb's halo.
struct HistoryStrip: View {
    @ObservedObject var m: Model
    let turns: [Bubble]
    @Binding var open: Bool
    @State var hovered: UUID?
    /// Renders: no hover state, no motion — matches other `--render-world` stills.
    nonisolated(unsafe) static var still = false

    /// Width of the thread's own gutter (line + dot), left of the text column.
    static let threadGutter: CGFloat = 22

    var body: some View {
        VStack(spacing: 10) {
            if open {
                if let pill = distancePill {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up").font(.system(size: 9, weight: .semibold))
                        Text(pill).font(.caption2)
                    }
                    .foregroundStyle(WorldLook.cream.opacity(0.6))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.06)))
                }
                // ImageRenderer draws ScrollView contents blank, so `--render-world` stills skip the
                // ScrollView and lay the same rows out directly; the live app always uses the real one.
                //
                // FIX (Omar, 2026-10-29: can't click copy/resend icons): this used to be its own
                // ScrollView, nested inside the home page's own outer ScrollView (same axis, both
                // vertical). A real on-screen click test (`--test-message-click`) proved that nested
                // same-axis ScrollView made the icon buttons genuinely unreachable — not just a small hit
                // area, absent from hit-testing AND the Accessibility tree entirely, with the icons at
                // full opacity. The page already scrolls (`StillScroll`/`ScrollView` in HomeView); this
                // list doesn't need its own separate scroll container, so it draws the same way stills do.
                list

            }
            if !turns.isEmpty {
                Button {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { open.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: open ? "chevron.down" : "chevron.up").font(.system(size: 11, weight: .semibold))
                        Text(open ? "Back to now" : "Scroll up for earlier").font(.caption)
                    }.foregroundStyle(WorldLook.cream.opacity(0.75))
                }.buttonStyle(.plain)
            }
        }
    }

    /// The pill shown above the thread while open: the oldest revealed turn's time and how long ago, e.g.
    /// "6:40 PM · 1 h 34 m ago". Nil when there's nothing to measure against.
    var distancePill: String? {
        guard let oldest = turns.first?.date else { return nil }
        let df = DateFormatter()
        df.dateFormat = "h:mm a"
        let mins = max(0, Int(Date().timeIntervalSince(oldest) / 60))
        let ago: String
        if mins < 1 {
            ago = "just now"
        } else if mins < 60 {
            ago = "\(mins) m ago"
        } else {
            ago = "\(mins / 60) h \(mins % 60) m ago"
        }
        return "\(df.string(from: oldest)) · \(ago)"
    }

    var list: some View {
        // A single hairline thread runs behind every row, continuous from the first dot to the last; each of
        // your own questions gets a dot and a time on it. Replies have no dot — the thread marks your turns.
        VStack(spacing: 0) {
            ForEach(Array(turns.enumerated()), id: \.element.id) { i, b in
                if let label = dividerLabel(before: i) {
                    HistoryDivider(label: label)
                }
                row(b, isFirst: i == 0, isLast: i == turns.count - 1)
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

    /// Every row renders the message at full legibility: no opacity/blur/scale modifier on the text itself,
    /// and no background box — the thread (for your own questions) is the only chrome. The copy/resend
    /// icons may fade in on hover; that's chrome too, not content.
    @ViewBuilder func row(_ b: Bubble, isFirst: Bool, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            // The thread gutter: a hairline through the row, a dot and time only on your own questions.
            ZStack(alignment: .top) {
                Rectangle().fill(WorldLook.cream.opacity(0.14)).frame(width: 1)
                    .padding(.top, isFirst ? 8 : 0).padding(.bottom, isLast ? 8 : 0)
                    .frame(maxHeight: .infinity)
                if b.fromMe {
                    Circle().fill(WorldLook.cream.opacity(0.8)).frame(width: 6, height: 6)
                        .padding(.top, 5)
                }
            }
            .frame(width: HistoryStrip.threadGutter)
            VStack(alignment: .leading, spacing: 2) {
                if b.fromMe {
                    Text(timeLabel(b.date)).font(.caption2).foregroundStyle(WorldLook.cream.opacity(0.4))
                }
                ChatText(text: b.text, size: 14, plain: b.fromMe)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(spacing: 6) {
                Button {
                    HistoryStrip.copy(b.text)
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 11))
                }
                .buttonStyle(.plain).help("Copy")
                .frame(width: 28, height: 28).contentShape(Rectangle())
                if b.fromMe {
                    Button {
                        m.draftSeed = b.text
                    } label: {
                        Image(systemName: "arrow.uturn.up").font(.system(size: 11))
                    }
                    .buttonStyle(.plain).help("Ask again")
                    .frame(width: 28, height: 28).contentShape(Rectangle())
                }
            }
            .foregroundStyle(WorldLook.cream.opacity(0.75))
            .opacity(HistoryStrip.still ? 1 : (hovered == b.id ? 1 : 0.0001))
        }
        .padding(.vertical, 8)
        .frame(maxWidth: 620)
        .onHover { hovered = $0 ? b.id : nil }
        .id(b.id)
    }

    func timeLabel(_ d: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "h:mm a"
        return df.string(from: d)
    }

    static func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

/// Lets HomeView wrap `HistoryStrip(...)` in `.equatable()`: skips re-running this view's whole body (and
/// the real AppKit text layout/markdown work every row does) on every keystroke in the ask box, since
/// typing changes `HomeView`'s own `draft` state but never touches `turns`/`open` (Omar, 2026-10-29:
/// "typing in the chat box lags"). `m` is always the one `Model.shared` singleton and `hovered` is
/// transient hover UI state, neither affects what should be drawn for a given `turns`/`open`, so both are
/// left out of equality on purpose — leaving them in would make this always report "changed".
extension HistoryStrip: Equatable {
    static func == (l: HistoryStrip, r: HistoryStrip) -> Bool {
        l.turns == r.turns && l.open == r.open
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
        .padding(.leading, HistoryStrip.threadGutter + 10)
    }
}

/// Render-only (`--render-world message-history` / `message-history-closed`): a sample conversation, a
/// couple of turns back plus one clearly older day, to check the marked-trail list reads at full legibility
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
