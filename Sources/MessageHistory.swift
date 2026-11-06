import AppKit
import SwiftUI

/// Earlier messages (Claude Design "Chat Directions", A+ · Quiet scroll + find, picked by Omar Nov 5 2026).
/// Replaces the "marked trail" (a thread, a dot and a time on every message, everything loaded at once).
/// Shows only the window `ChatPager` hands it (a page of 20, more as you scroll up), calmly:
/// - your own messages on the right in a soft cream pill; replies on the background, a small orb only on the
///   first reply of a run;
/// - a day line ("Wednesday, Nov 4") where the day changes, a time line after an hour's gap; no time on every row;
/// - a routine report ("**Email triage**" + body) is one line with Open, never a wall of text;
/// - a reply's [choices: …] line becomes "You picked: X" when your next message was one of them;
/// - Copy and Ask again appear on hover only (`.help` names kept: the click check finds them by it).
/// No ScrollView of its own: the home page is the one scroll (a nested one made the icons unclickable).
struct HistoryStrip: View {
    @ObservedObject var m: Model
    let turns: [Bubble]
    @Binding var open: Bool
    /// The message a search or a day jump landed on.
    var lit: UUID? = nil
    @State var hovered: UUID?
    @State var reportsOpen: Set<UUID> = []
    /// Renders: no hover state, no motion — matches other `--render-world` stills.
    nonisolated(unsafe) static var still = false

    var body: some View {
        if open {
            list
        } else if !turns.isEmpty {
            Button {
                withAnimation(.easeOut(duration: 0.25)) { open = true }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.up").font(.system(size: 11, weight: .semibold))
                    Text("Earlier").font(.caption)
                }.foregroundStyle(WorldLook.cream.opacity(0.75))
            }
            .buttonStyle(.plain).help("Show earlier messages (or just scroll up)")
        }
    }

    var list: some View {
        VStack(spacing: 0) {
            ForEach(Array(turns.enumerated()), id: \.element.id) { i, b in
                if let label = dividerLabel(before: i) {
                    HistoryDivider(label: label).dayMark(label: dayLabel(i))
                } else if i == 0 {
                    Color.clear.frame(height: 0).dayMark(label: dayLabel(0))
                }
                Color.clear.frame(height: 0).id("top-\(b.id)")
                row(b, i)
            }
        }
        .frame(maxWidth: 640)
    }

    func dayLabel(_ i: Int) -> String { ChatPager.longDay(turns[i].date) }

    /// A line before turn `i` when a new day starts (the day's name) or after an hour's quiet (the time).
    /// Never before the first row of the window: the floating day pill names that one.
    func dividerLabel(before i: Int) -> String? {
        guard i > 0 else { return nil }
        let prev = turns[i - 1].date
        let cur = turns[i].date
        if !Calendar.current.isDate(prev, inSameDayAs: cur) { return ChatPager.longDay(cur) }
        guard cur.timeIntervalSince(prev) > 3600 else { return nil }
        return Self.time(cur)
    }

    static func time(_ d: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "h:mm a"
        return df.string(from: d)
    }

    @ViewBuilder func row(_ b: Bubble, _ i: Int) -> some View {
        Group {
            if b.fromMe {
                HStack(alignment: .top, spacing: 8) {
                    Spacer(minLength: 90)
                    icons(b)
                    LongFoldText(text: b.text, key: LongFold.key(b), size: 14, plain: true, hug: true)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(WorldLook.cream.opacity(0.08)))
                }
            } else if let r = RoutineReport(b.text) {
                report(b, r)
            } else {
                reply(b, i)
            }
        }
        .padding(.vertical, 7).padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(WorldLook.cream.opacity(lit == b.id ? 0.07 : 0))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(WorldLook.cream.opacity(lit == b.id ? 0.3 : 0)))
        )
        .animation(.easeOut(duration: 0.6), value: lit)
        .onHover { hovered = $0 ? b.id : nil }
        .id(b.id)
    }

    func reply(_ b: Bubble, _ i: Int) -> some View {
        let parts = Choices.split(Helpers.strip(b.text))
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            if i == 0 || turns[i - 1].fromMe {
                MiniOrb(size: 12).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            } else {
                Color.clear.frame(width: 12, height: 1)
            }
            VStack(alignment: .leading, spacing: 6) {
                LongFoldText(text: parts.body, key: LongFold.key(b), size: 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let p = picked(parts.choices, after: i) {
                    Text("You picked: \(p)").font(.caption).foregroundStyle(WorldLook.cream.opacity(0.45))
                }
            }
            icons(b)
        }
    }

    /// Your answer to a reply's choices, when your next message was one of them.
    func picked(_ choices: [String], after i: Int) -> String? {
        guard !choices.isEmpty, i + 1 < turns.count, turns[i + 1].fromMe else { return nil }
        let next = turns[i + 1].text.trimmingCharacters(in: .whitespacesAndNewlines)
        return choices.first { $0.caseInsensitiveCompare(next) == .orderedSame }
    }

    func report(_ b: Bubble, _ r: RoutineReport) -> some View {
        let isOpen = reportsOpen.contains(b.id)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").font(.system(size: 11)).foregroundStyle(WorldLook.cream.opacity(0.6))
                Text(r.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(WorldLook.cream).lineLimit(1)
                Text(Self.time(b.date)).font(.system(size: 12)).foregroundStyle(WorldLook.cream.opacity(0.45))
                Text(r.gist).font(.system(size: 12)).foregroundStyle(WorldLook.cream.opacity(0.5)).lineLimit(1)
                Spacer(minLength: 8)
                Button(isOpen ? "Hide" : "Open") {
                    withAnimation(.easeOut(duration: 0.2)) {
                        if isOpen { reportsOpen.remove(b.id) } else { reportsOpen.insert(b.id) }
                    }
                }
                .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(WorldLook.cream.opacity(0.85))
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(Capsule().fill(WorldLook.cream.opacity(0.08)))
            }
            if isOpen {
                LongFoldText(text: r.body, key: LongFold.key(b), size: 14).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(WorldLook.cream.opacity(0.12)))
    }

    /// Copy (and Ask again on your own messages), shown on hover. Chrome, never content.
    func icons(_ b: Bubble) -> some View {
        HStack(spacing: 2) {
            Button {
                HistoryStrip.copy(b.text)
            } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 11))
            }
            .buttonStyle(.plain).help("Copy")
            .frame(width: 26, height: 26).contentShape(Rectangle())
            if b.fromMe {
                Button {
                    m.draftSeed = b.text
                } label: {
                    Image(systemName: "arrow.uturn.up").font(.system(size: 11))
                }
                .buttonStyle(.plain).help("Ask again")
                .frame(width: 26, height: 26).contentShape(Rectangle())
            }
        }
        .foregroundStyle(WorldLook.cream.opacity(0.7))
        .opacity(HistoryStrip.still ? 1 : (hovered == b.id ? 1 : 0.0001))
    }

    static func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

/// Lets HomeView wrap `HistoryStrip(...)` in `.equatable()`: typing in the ask box changes HomeView's own
/// `draft` and must not re-run every row's text layout (Omar, 2026-10-29: "typing in the chat box lags").
/// `m` is the one shared model and `hovered`/`reportsOpen` are this view's own state, so they're left out.
extension HistoryStrip: Equatable {
    static func == (l: HistoryStrip, r: HistoryStrip) -> Bool {
        l.turns == r.turns && l.open == r.open && l.lit == r.lit
    }
}

/// A routine's result as the chat keeps it: "**<title>**", a blank line, then the report (`Model.tendRoutines`).
struct RoutineReport {
    let title: String
    let body: String
    var gist: String {
        let first = body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        return first.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces)
    }
    /// Nil unless the message is a routine report: a bold title line naming one of the routines (or a long
    /// report under a bold title), then a blank line.
    @MainActor init?(_ text: String) {
        let lines = text.components(separatedBy: "\n")
        guard lines.count > 2, let t = lines.first?.trimmingCharacters(in: .whitespaces), t.hasPrefix("**"), t.hasSuffix("**"), t.count > 4,
            lines[1].trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        let title = String(t.dropFirst(2).dropLast(2))
        guard !title.contains("**"), RoutineReport.names().contains(title) || text.count > 700 else { return nil }
        self.title = title
        body = lines.dropFirst(2).joined(separator: "\n")
    }

    /// The routines' names (cron/jobs.json), read once a minute at most.
    @MainActor static var cached: (Date, Set<String>) = (.distantPast, [])
    @MainActor static func names() -> Set<String> {
        if Date().timeIntervalSince(cached.0) < 60 { return cached.1 }
        let url = Env.hermesHome.appendingPathComponent("cron/jobs.json")
        var out = Set<String>()
        if let d = try? Data(contentsOf: url), let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
            let jobs = j["jobs"] as? [[String: Any]]
        {
            for job in jobs { if let n = job["name"] as? String { out.insert(n) } }
        }
        cached = (Date(), out)
        return out
    }
}

/// A quiet line between two messages: a new day, or a time after an hour's gap.
struct HistoryDivider: View {
    let label: String
    var body: some View {
        Text(label).font(.caption2).foregroundStyle(WorldLook.cream.opacity(0.45))
            .frame(maxWidth: .infinity).padding(.vertical, 8)
    }
}

/// Where each day starts in the scroll, so the floating pill can name the day you're looking at.
struct DayMark: Equatable {
    let label: String
    let y: CGFloat
}
struct DayMarkKey: PreferenceKey {
    static let defaultValue: [DayMark] = []
    static func reduce(value: inout [DayMark], nextValue: () -> [DayMark]) { value.append(contentsOf: nextValue()) }
}
extension View {
    func dayMark(label: String) -> some View {
        background(
            GeometryReader { g in Color.clear.preference(key: DayMarkKey.self, value: [DayMark(label: label, y: g.frame(in: .named("chat")).minY)]) })
    }
}

/// Render-only (`--render-world message-history` / `message-history-closed`): a sample conversation across
/// two days, with a routine report and a picked choice, laid out without the real ScrollView.
enum MessageHistoryRender {
    @MainActor static func scene(open: Bool) -> AnyView {
        HistoryStrip.still = true
        let m = Model.shared
        let strip = HistoryStrip(m: m, turns: sample, open: .constant(open))
        strip.hovered = open ? sample[4].id : nil
        return AnyView(
            VStack {
                strip
            }
            .padding(24).frame(width: 680).background(WorldLook.bg).environment(\.colorScheme, .dark))
    }

    /// Made-up messages across two days: a picked choice, a routine report, a short exchange.
    static let sample: [Bubble] = {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        return [
            Bubble(fromMe: true, text: "What's my flight time on the 20th?", date: yesterday),
            Bubble(
                fromMe: false,
                text: "7:40 AM out of EWR, lands in Quebec City at 10:05. Want me to hold the seat?\n[choices: Yes, hold it | Not now]",
                date: yesterday),
            Bubble(fromMe: true, text: "Yes, hold it", date: yesterday),
            Bubble(
                fromMe: false,
                text:
                    "**Email triage (4 PM + 8 PM)**\n\n3 need you today: the dentist moved you to Thursday, the car shop wants a time, and the school form is due Friday.\n\nEverything else is filed.",
                date: yesterday),
            Bubble(fromMe: true, text: "And the hotel address?"),
            Bubble(fromMe: false, text: "Auberge Saint-Antoine, 8 Rue Saint-Antoine, old town, 2 nights."),
        ]
    }()
}
