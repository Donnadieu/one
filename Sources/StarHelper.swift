import AppKit
import SwiftUI

// MARK: - A bot's or helper's chat as a star path: its messages, its header (pinned above the chat), its day dial.

enum StarLines {
    /// Its messages, oldest first: a bot's whole kept chat (BotChat.swift), a helper's log. A question still being
    /// worked on comes last; a finished turn that never made it into the log (it stopped with an error) too.
    @MainActor static func of(_ h: Helper) -> [StarLine] {
        var out =
            h.bot != nil ? BotChat.lines(h) : StarPath.lines(log: h.log ?? [], at: Array(repeating: h.started ?? Date(), count: (h.log ?? []).count))
        let reply = Choices.split(Helpers.strip(h.reply)).body.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.state != "working", !reply.isEmpty,
            !(out.last.map { !$0.me && $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == reply } ?? false),
            !(h.log ?? []).contains(where: { $0.hasSuffix(reply) })
        {
            out.append(StarLine(id: "reply-\(h.reply.count)", me: false, text: reply, date: h.lastStepAt ?? h.started ?? Date()))
        }
        if h.state == "working", let a = h.asked, !a.isEmpty { out.append(StarLine(id: "asked-\(a.count)", me: true, text: a, date: Date())) }
        return out
    }
}

/// The top of a bot's or helper's chat, pinned above it: back to the assistant, its orb and name, how much it has
/// said, search, and the summary card (folded to one line).
struct StarHeader: View {
    @ObservedObject var m: Model
    let h: Helper
    @ObservedObject var state = StarState.shared
    var body: some View {
        let sp = StarSpeaker.of(h)
        let waiting = h.state == "needsYes" || m.stepWaiting(h)
        let lines = StarLines.of(h)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    withAnimation(.easeOut(duration: 0.3)) { m.openHelper = nil }
                } label: {
                    Label(m.name, systemImage: "chevron.left")
                }
                .buttonStyle(.bordered).controlSize(.small).help("Back to \(m.name)")
                StarOrb(speaker: sp, size: 30, needsYes: waiting)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(sp.name).font(.headline).foregroundStyle(h.bot != nil ? sp.tint : WorldLook.cream).lineLimit(1).layoutPriority(1)
                        Text("· " + status(waiting)).font(.callout).foregroundStyle(waiting ? Color.orange : Color.secondary).lineLimit(1)
                    }
                    Text(StarPath.since(lines) + (h.bot.map { " · \($0.room) room" } ?? "")).font(.system(size: 11.5))
                        .foregroundStyle(WorldLook.cream.opacity(0.42)).lineLimit(1)
                }
                Spacer(minLength: 8)
                if !state.searching, state.days(lines).count < 2, lines.count > 4 {  // with more days, the dial's magnifier opens it
                    Button {
                        withAnimation(.easeOut(duration: 0.25)) { state.searching = true }
                    } label: {
                        Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold)).frame(width: 26, height: 26)
                            .background(Circle().fill(WorldLook.cream.opacity(0.07)))
                    }
                    .buttonStyle(.plain).help("Search this chat").keyboardShortcut("f", modifiers: .command)
                }
                if h.bot != nil && HomeView.still {
                    Image(systemName: "ellipsis").foregroundStyle(.secondary)  // renders can't draw a menu
                } else if h.bot != nil {
                    Menu {
                        BotMenuItems(m: m, h: h)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("About, edit, archive or delete \(sp.name)")
                }
            }
            if state.searching { StarSearchField(speaker: sp, state: state).transition(.opacity.combined(with: .offset(y: -4))) }  // its own row
            StarSummaryCard(summary: summary, speaker: sp, state: state, answer: { c in Task { await m.choose(c) } }, openHelper: nil)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color(hex: 0xF0A04B, h.state == "needsYes" ? 0.55 : 0), lineWidth: 1.2))
    }
    /// A chat opened: everything folded, no search, at its newest message.
    @MainActor static func opened(_ h: Helper) {
        let st = StarState.shared
        st.reset(for: h.id.uuidString)
        st.target = StarState.end
    }
    func status(_ waiting: Bool) -> String {
        h.bot != nil ? BotsColumn.line(h, waiting: waiting) : (RepoQueue.word(h) ?? HelperStop.word(h))
    }
    var summary: StarSummary {
        if let b = h.bot {
            let steps = m.stepsHere.filter { $0.session == h.sid }.map { "Sign in to \($0.site)" }
            return .bot(h, days: Bots.days(b), steps: steps)
        }
        return .helper(h)
    }
}

/// The day dial at the right edge of an open bot's or helper's chat (only with more than one day).
struct StarDialLayer: View {
    @ObservedObject var m: Model
    @ObservedObject var state = StarState.shared
    var body: some View {
        if let h = m.openedHelper { StarDial(speaker: .of(h), days: state.days(StarLines.of(h)), state: state) }
    }
}

/// Your own words in the assistant's chat: on the right, in the same cream capsule as in a bot's chat.
struct StarMine: View {
    let text: String
    let key: String?
    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 110)
            LongFoldText(text: text, key: key, size: ChatText.callout, plain: true, hug: true)
                .padding(.horizontal, 16).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(WorldLook.cream.opacity(0.085)))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(WorldLook.cream.opacity(0.14)))
        }
    }
}

/// The speaker's name and the time, at the start of its words.
struct StarName: View {
    let name: String
    var date: Date?
    var tint: Color = WorldLook.cream
    var body: some View {
        HStack(spacing: 6) {
            Text(name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(tint)
            if let date { Text(StarPath.clock.string(from: date)).font(.system(size: 10.5)).foregroundStyle(WorldLook.cream.opacity(0.32)) }
        }
    }
}

/// The assistant's summary card under its orb: helpers it finished today and what's waiting on you. One line until tapped.
struct IrisSummary: View {
    @ObservedObject var m: Model
    var body: some View {
        let asks = m.asks.map(\.question) + m.stepsHere.map(\.line) + m.folderAsks.map { "Folder: \(($0.path as NSString).lastPathComponent)" }
        StarSummaryCard(
            summary: .assistant(m.helpers, asks: asks), speaker: .assistant(m.name), state: StarState.assistant, answer: nil,
            openHelper: { id in withAnimation(.easeOut(duration: 0.3)) { m.focusHelper(id) } })
    }
}
