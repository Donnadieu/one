import AppKit
import SwiftUI

// MARK: - Around a star path chat: the summary card, the header (with search), the day dial, Back to now, scrolling.

/// The card on top: what it did and what's waiting on you, one line until tapped. Opened, it pushes the chat down.
struct StarSummaryCard: View {
    let summary: StarSummary
    let speaker: StarSpeaker
    @ObservedObject var state: StarState
    var answer: ((String) -> Void)?
    var openHelper: ((UUID) -> Void)?
    var body: some View {
        if !summary.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) { state.summaryOpen.toggle() }
                } label: {
                    folded
                }
                .buttonStyle(.plain).help(state.summaryOpen ? "Fold the summary" : "What it did and what's waiting on you")
                if state.summaryOpen {
                    HStack(alignment: .top, spacing: 26) {
                        did.frame(maxWidth: .infinity, alignment: .leading)
                        waiting.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 14).padding(.bottom, 12).padding(.top, 2)
                    .transition(.opacity.combined(with: .offset(y: -6)))
                }
            }
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(speaker.tint.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(speaker.tint.opacity(0.22)))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .starProbe { StarProbe.Row(kind: "summary", id: "summary", frame: $0, hex: speaker.hex, folded: !state.summaryOpen) }
        }
    }

    var folded: some View {
        HStack(spacing: 8) {
            StarOrb(speaker: speaker, size: 15)
            Text(summary.didTitle).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(speaker.tint)
            Text("· \(summary.did.count)").font(.system(size: 12)).foregroundStyle(WorldLook.cream.opacity(0.45))
            Text(summary.waitTitle).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(WorldLook.cream.opacity(0.88)).padding(.leading, 14)
            if !summary.waiting.isEmpty {
                Text("\(summary.waiting.count)").font(.system(size: 11, weight: .bold)).foregroundStyle(speaker.tint)
                    .padding(.horizontal, 7).padding(.vertical, 1).background(Capsule().fill(speaker.tint.opacity(0.2)))
            }
            Spacer(minLength: 8)
            Text(state.summaryOpen ? "Fold" : "Open").font(.system(size: 12)).foregroundStyle(WorldLook.cream.opacity(0.42))
            Image(systemName: state.summaryOpen ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .semibold))
                .foregroundStyle(WorldLook.cream.opacity(0.42))
        }
        .padding(.horizontal, 14).frame(height: 36).contentShape(Rectangle())
    }

    static func caption(_ t: String) -> some View {
        Text(t.uppercased()).font(.system(size: 9.5, weight: .semibold)).tracking(1.1).foregroundStyle(WorldLook.cream.opacity(0.36))
    }

    var did: some View {
        VStack(alignment: .leading, spacing: 8) {
            StarSummaryCard.caption(summary.didTitle)
            if summary.did.isEmpty { Text("Nothing yet").font(.system(size: 12.5)).foregroundStyle(.secondary) }
            ForEach(summary.did.indices, id: \.self) { i in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(summary.did[i].when).font(.system(size: 11, weight: .medium)).foregroundStyle(speaker.tint).fixedSize()
                        .frame(minWidth: 58, alignment: .leading)
                    Text(summary.did[i].what).font(.system(size: 12.5)).foregroundStyle(WorldLook.cream.opacity(0.85)).lineLimit(2)
                }
            }
        }
    }

    var waiting: some View {
        VStack(alignment: .leading, spacing: 8) {
            StarSummaryCard.caption(summary.waitTitle)
            if summary.waiting.isEmpty { Text("Nothing right now").font(.system(size: 12.5)).foregroundStyle(.secondary) }
            ForEach(summary.waiting.indices, id: \.self) { i in
                let w = summary.waiting[i]
                HStack(spacing: 8) {
                    Text(w.what).font(.system(size: 12.5)).foregroundStyle(WorldLook.cream.opacity(0.85)).lineLimit(2)
                    Spacer(minLength: 6)
                    ForEach(w.choices.prefix(3), id: \.self) { c in
                        chip(c, first: c == w.choices.first) { answer?(c) }
                    }
                    if let id = w.helper { chip("Open", first: true) { openHelper?(id) } }
                }
            }
        }
    }

    func chip(_ t: String, first: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(t).font(.system(size: 12, weight: .semibold)).foregroundStyle(first ? Color(hex: 0x141416) : WorldLook.cream.opacity(0.9))
                .padding(.horizontal, 11).padding(.vertical, 5)
                .background(Capsule().fill(first ? speaker.tint : WorldLook.cream.opacity(0.07)))
                .overlay(Capsule().strokeBorder(first ? Color.clear : WorldLook.cream.opacity(0.16)))
                .fixedSize()
        }
        .buttonStyle(.plain)
    }
}

/// Search this chat, in its header: matches light up, Return steps to the next one (⇧Return the one before).
struct StarSearchField: View {
    let speaker: StarSpeaker
    @ObservedObject var state: StarState
    @FocusState var focused: Bool
    var body: some View {
        let hits = state.hits
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(WorldLook.cream.opacity(0.5))
            if HomeView.still {
                Text(state.query).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("Search this chat", text: $state.query).textFieldStyle(.plain).font(.system(size: 13)).focused($focused)
                    .onSubmit { state.step(NSEvent.modifierFlags.contains(.shift) ? -1 : 1) }
            }
            if state.query.count >= 2 {
                Text(StarPath.found(hits.count, days: StarPath.dayMatches(state.days, hits).count)).font(.system(size: 11))
                    .foregroundStyle(WorldLook.cream.opacity(0.5)).fixedSize()
                if !hits.isEmpty {
                    arrow("chevron.up", "Previous match") { state.step(-1) }
                    arrow("chevron.down", "Next match") { state.step(1) }
                }
            }
            arrow("xmark", "Close search") {
                withAnimation(.easeOut(duration: 0.25)) {
                    state.searching = false
                    state.query = ""
                }
            }
        }
        .padding(.horizontal, 12).frame(maxWidth: .infinity).frame(height: 30)
        .background(Capsule().fill(WorldLook.cream.opacity(0.06)))
        .overlay(Capsule().strokeBorder(speaker.tint.opacity(0.5)))
        .onAppear { focused = true }
        .onExitCommand { state.searching = false }
    }
    func arrow(_ icon: String, _ help: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: icon).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(WorldLook.cream.opacity(0.6)).frame(
                width: 16, height: 16
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help)
    }
}

/// The slim day dial on the right of a chat: one dot per day, bigger for busier days. Click or drag to fly to a day;
/// the magnifier on top opens search, and matching days light up.
struct StarDial: View {
    let speaker: StarSpeaker
    let days: [StarDay]
    @ObservedObject var state: StarState
    var body: some View {
        if days.count > 1 {
            let hits = state.hits
            let counts = StarPath.dayMatches(days, hits)
            let lit = state.hit.flatMap { h in days.first { d in d.lines.contains { $0.id == h } }?.id } ?? state.lastJump ?? days.last?.id
            VStack(spacing: 6) {
                Button {
                    withAnimation(.easeOut(duration: 0.25)) {
                        state.searching.toggle()
                        if !state.searching { state.query = "" }
                    }
                } label: {
                    Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(WorldLook.cream.opacity(0.75))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(state.searching ? speaker.tint.opacity(0.28) : WorldLook.cream.opacity(0.07)))
                }
                .buttonStyle(.plain).help("Search this chat")
                GeometryReader { g in
                    let top = days.map(\.count).max() ?? 1
                    ZStack(alignment: .top) {
                        Rectangle().fill(WorldLook.cream.opacity(0.1)).frame(width: 1).frame(maxHeight: .infinity)
                        ForEach(days.indices, id: \.self) { i in
                            dot(
                                days[i], y: StarDial.y(i, days.count, g.size.height), w: g.size.width, top: top, lit: days[i].id == lit,
                                match: counts[days[i].id] != nil)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0).onChanged { v in
                            let i = StarDial.index(v.location.y, days.count, g.size.height)
                            if days[i].id != state.lastJump { withAnimation(.easeInOut(duration: 0.35)) { state.jump(days[i].id) } }
                        })
                }
                .padding(.vertical, 6)
            }
            .frame(width: 30)
            .transition(.opacity)
        }
    }
    func dot(_ d: StarDay, y: CGFloat, w: CGFloat, top: Int, lit: Bool, match: Bool) -> some View {
        let s = StarPath.dot(d.count, max: top)
        return Circle().fill(lit || match ? speaker.tint : WorldLook.cream.opacity(0.3)).frame(width: s, height: s)
            .shadow(color: speaker.tint.opacity(lit || match ? 0.7 : 0), radius: 5)
            .position(x: w / 2, y: y)
            .help("\(d.label) · \(d.count) message\(d.count == 1 ? "" : "s")")
    }
    static func y(_ i: Int, _ n: Int, _ h: CGFloat) -> CGFloat { n < 2 ? 7 : 7 + CGFloat(i) / CGFloat(n - 1) * max(0, h - 14) }
    static func index(_ y: CGFloat, _ n: Int, _ h: CGFloat) -> Int {
        guard n > 1, h > 14 else { return 0 }
        return min(n - 1, max(0, Int(((y - 7) / (h - 14) * CGFloat(n - 1)).rounded())))
    }
}

/// Scrolls home's chat to whatever the star path asks for (a day, a match, the newest message).
struct StarScroller: View {
    @ObservedObject var state: StarState
    let proxy: ScrollViewProxy
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onChange(of: state.target) { _, t in
                guard let t else { return }
                Task { @MainActor in
                    await Task.yield()  // the day it opens is laid out first
                    withAnimation(.easeInOut(duration: 0.45)) { proxy.scrollTo(t, anchor: t == StarState.end ? .bottom : .top) }
                    state.target = nil
                }
            }
    }
}

/// "Back to now", while an earlier day or a search is showing.
struct StarBackToNow: View {
    @ObservedObject var state: StarState
    var body: some View {
        if state.away {
            BackToNow { withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) { state.backToNow() } }.transition(.opacity)
        }
    }
}
