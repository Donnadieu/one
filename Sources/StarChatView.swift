import AppKit
import SwiftUI

// MARK: - Star path chat views (Claude Design "Chosen Star path with summary", Omar's pick, Nov 19 2026)
// The speaker's words hang off a faint thread in its colour; yours sit on the right in a cream capsule. Earlier days
// fold into one star each, long replies show 3 lines then "Read all". State lives in `StarState` (StarState.swift).

extension StarSpeaker {
    var tint: Color { Color(hex: hex) }
}

/// The speaker's orb: a bot's moon, the assistant's orb, a helper's small orb.
struct StarOrb: View {
    let speaker: StarSpeaker
    var size: CGFloat = 18
    var needsYes = false
    var body: some View {
        switch speaker.kind {
        case .bot: BotMoon(hex: speaker.hex, size: size, t: 21.7, needsYes: needsYes)
        case .assistant: MiniOrb(size: size * 0.8)
        case .helper: MiniOrb(size: size * 0.66)
        }
    }
}

/// A chat's messages as a star path: earlier days folded into one star each, the newest day open.
struct StarChat: View {
    let speaker: StarSpeaker
    let lines: [StarLine]
    @ObservedObject var state: StarState
    /// The reply being written right now never folds under the reader's eyes.
    var live: String?
    var body: some View {
        let days = state.days(lines)
        let hits = Set(state.hits)
        let counts = state.searching ? StarPath.dayMatches(days, Array(hits)) : [:]
        VStack(alignment: .leading, spacing: 16) {
            ForEach(days) { d in
                let newest = d.id == days.last?.id
                if newest {
                    if days.count > 1 { StarTodayLabel(day: d, speaker: speaker).id("day-\(d.id)") }
                } else {
                    StarDayRow(day: d, speaker: speaker, open: state.isOpen(d), matches: counts[d.id] ?? 0) {
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) { state.toggle(d.id) }
                    }
                    .id("day-\(d.id)")
                }
                if state.isOpen(d) {
                    ForEach(d.lines.indices, id: \.self) { i in
                        let l = d.lines[i]
                        StarRow(
                            line: l, speaker: speaker, named: !l.me && (i == 0 || d.lines[i - 1].me), halo: hits.contains(l.id),
                            lit: state.hit == l.id, live: l.id == live
                        )
                        .id(l.id)
                        .transition(.opacity.combined(with: .offset(y: -6)))
                    }
                }
            }
            Color.clear.frame(height: 1).id(StarState.end)
        }
        .background(alignment: .leading) { Rectangle().fill(speaker.tint.opacity(0.16)).frame(width: 1).padding(.leading, 10.5) }
    }
}

/// One message: yours on the right in a capsule, the speaker's on the left with its star (its orb and name to start a run).
struct StarRow: View {
    let line: StarLine
    let speaker: StarSpeaker
    let named: Bool
    var halo = false
    var lit = false
    var live = false
    var key: String { "star|\(speaker.name)|\(line.id)" }
    var body: some View {
        if line.me { mine } else { theirs }
    }

    var time: String? { line.date.map { StarPath.clock.string(from: $0) } }

    var mine: some View {
        HStack(alignment: .top, spacing: 0) {
            // A faint ring on the thread, a short line toward the capsule.
            ZStack(alignment: .leading) {
                Rectangle().fill(WorldLook.cream.opacity(0.09)).frame(width: 64, height: 1).offset(x: 11)
                Circle().strokeBorder(WorldLook.cream.opacity(0.32), lineWidth: 1).frame(width: 7, height: 7).offset(x: 7.5)
            }
            .frame(width: 22, height: 36, alignment: .leading)
            Spacer(minLength: 110)
            VStack(alignment: .trailing, spacing: 4) {
                StarFold(text: line.text, key: key, size: 14, tint: speaker.tint, mine: true)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(WorldLook.cream.opacity(halo ? 0.13 : 0.085)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(
                            halo ? speaker.tint.opacity(lit ? 0.85 : 0.5) : WorldLook.cream.opacity(0.14), lineWidth: lit ? 1.4 : 1)
                    )
                    .frame(maxWidth: 520, alignment: .trailing)
                    .starProbe { StarProbe.Row(kind: "me", id: line.id, frame: $0, hex: StarSpeaker.cream, halo: halo) }
                if let time { Text(time).font(.system(size: 10.5)).foregroundStyle(WorldLook.cream.opacity(0.32)) }
            }
        }
    }

    var theirs: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if named {
                    StarOrb(speaker: speaker, size: 18)
                } else {
                    Circle().fill(speaker.tint.opacity(0.5)).frame(width: 5, height: 5).padding(.top, 8)
                }
            }
            .frame(width: 22)
            VStack(alignment: .leading, spacing: 5) {
                if named {
                    HStack(spacing: 6) {
                        Text(speaker.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(speaker.tint)
                        if let time { Text(time).font(.system(size: 10.5)).foregroundStyle(WorldLook.cream.opacity(0.32)) }
                    }
                }
                StarFold(text: line.text, key: key, size: 14.5, tint: speaker.tint, live: live)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(speaker.tint.opacity(halo ? 0.07 : 0))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(
                            speaker.tint.opacity(halo ? (lit ? 0.8 : 0.42) : 0), lineWidth: lit ? 1.4 : 1))
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .starProbe { f in
                StarProbe.Row(
                    kind: "them", id: line.id, frame: f, hex: speaker.hex, named: named, halo: halo,
                    folded: !live && StarPath.folds(line.text) && !LongFold.isOpen(key, in: UserDefaults.standard.string(forKey: LongFold.key) ?? ""))
            }
            Spacer(minLength: 24)
        }
        .animation(.easeOut(duration: 0.35), value: halo)
    }
}

/// A message that shows 3 lines then "Read all" when it's long. Open is remembered per message.
struct StarFold: View {
    let text: String
    let key: String
    var size: CGFloat = 14.5
    var tint: Color = WorldLook.cream
    var mine = false
    var live = false
    @AppStorage(LongFold.key) var raw = ""
    var body: some View {
        let folds = !live && StarPath.folds(text)
        let open = LongFold.isOpen(key, in: raw)
        VStack(alignment: .leading, spacing: 6) {
            if folds && !open {
                ChatText(text: StarPath.head(text), size: size, plain: mine, copy: text)
                    .frame(height: StarFold.height(size), alignment: .top).clipped()
                    .mask(
                        VStack(spacing: 0) {
                            Color.black
                            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: size * 1.6)
                        })
            } else {
                ChatText(text: text, size: size, plain: mine, hug: mine)
            }
            if folds {
                Button {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.88)) { raw = LongFold.set(key, open: !open, in: raw) }
                } label: {
                    Text(open ? "Fold" : "Read all").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(tint)
                }
                .buttonStyle(.plain).help(open ? "Fold this message" : "Show the whole message")
            }
        }
    }
    static func height(_ size: CGFloat) -> CGFloat {
        (NSLayoutManager().defaultLineHeight(for: NSFont.systemFont(ofSize: size)) + 1.5) * CGFloat(StarPath.keep)
    }
}

/// An earlier day, folded into its star: "Mon Nov 16 · 7 messages · Back to the goal" … Open / Fold.
struct StarDayRow: View {
    let day: StarDay
    let speaker: StarSpeaker
    let open: Bool
    var matches = 0
    let toggle: () -> Void
    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                StarDayStar(tint: speaker.tint, bright: open || matches > 0)
                Text(day.label).font(.system(size: 13, weight: .semibold)).foregroundStyle(WorldLook.cream.opacity(0.88)).fixedSize()
                Text("· \(day.count) message\(day.count == 1 ? "" : "s")").font(.system(size: 12)).foregroundStyle(WorldLook.cream.opacity(0.42))
                    .fixedSize()
                Text(day.title).font(.system(size: 12)).foregroundStyle(WorldLook.cream.opacity(0.42)).lineLimit(1)
                Spacer(minLength: 8)
                if matches > 0 {
                    Text("\(matches) match\(matches == 1 ? "" : "es")").font(.system(size: 11, weight: .semibold)).foregroundStyle(speaker.tint)
                        .padding(.horizontal, 8).padding(.vertical, 2).background(Capsule().fill(speaker.tint.opacity(0.16))).fixedSize()
                }
                Text(open ? "Fold" : "Open").font(.system(size: 12)).foregroundStyle(WorldLook.cream.opacity(0.42)).fixedSize()
            }
            .frame(height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(open ? "Fold \(day.label)" : "Open \(day.label)")
        .starProbe { StarProbe.Row(kind: "day", id: day.id, frame: $0, hex: speaker.hex, folded: !open, matches: matches) }
    }
}

/// The newest day's star (only when there are earlier days): it's always open.
struct StarTodayLabel: View {
    let day: StarDay
    let speaker: StarSpeaker
    var body: some View {
        HStack(spacing: 10) {
            StarDayStar(tint: speaker.tint, bright: true)
            Text(day.label).font(.system(size: 13, weight: .semibold)).foregroundStyle(WorldLook.cream.opacity(0.88))
            Text("· \(day.count) message\(day.count == 1 ? "" : "s")").font(.system(size: 12)).foregroundStyle(WorldLook.cream.opacity(0.42))
        }
        .frame(height: 24)
    }
}

/// A day's star on the thread: a soft glow around a small bright dot.
struct StarDayStar: View {
    let tint: Color
    let bright: Bool
    var body: some View {
        ZStack {
            Circle().fill(tint.opacity(bright ? 0.28 : 0.12)).frame(width: 18, height: 18).blur(radius: 3)
            Circle().fill(tint.opacity(bright ? 0.95 : 0.55)).frame(width: 9, height: 9)
        }
        .frame(width: 22)
    }
}
