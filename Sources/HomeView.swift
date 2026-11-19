import Quartz
import SwiftUI
import AppKit
import AVFoundation
import Speech
import PDFKit
import Carbon
import EventKit
import CoreAudio
import UniformTypeIdentifiers

struct HomeView: View {
    @ObservedObject var m: Model
    /// Renders: no live text field (ImageRenderer can't draw it) and no motion.
    nonisolated(unsafe) static var still = false
    /// Renders only: a desktop picture to draw the glass over (`--render-world home-glass`).
    nonisolated(unsafe) static var stillDesk: NSImage?
    /// Renders only: the galaxy is drawn behind the whole fake window (title row included), not inside home.
    nonisolated(unsafe) static var outerStars = false
    /// Renders only: a draft to show in the ask box, and whether the writing panel is open.
    nonisolated(unsafe) static var stillDraft = ""
    nonisolated(unsafe) static var stillWriting = false
    /// Renders only: the helper shown as if pointed at.
    nonisolated(unsafe) static var stillPointed: UUID?
    /// What is being typed lives outside this view, so a keystroke redraws only the ask box (AskBox.swift).
    @State var ask = AskDraft(HomeView.stillDraft)
    @State var windowHeight: CGFloat = 760
    @AppStorage("shelfCollapsed") var shelfCollapsed = false
    @AppStorage("voiceMuted") var voiceOff = false
    @State var dropping = false
    @State var typing = false
    /// Earlier messages, a page at a time (ChatPager.swift); the day pill's Find panel; where the page is.
    @ObservedObject var pager = ChatPager.shared
    @State var finding = HomeView.stillFinding
    /// Renders only: the Find panel shown open.
    nonisolated(unsafe) static var stillFinding = false
    @State var chatHeight: CGFloat = 600
    @State var dayNow = "Today"
    /// Renders only: Message history shown open.
    nonisolated(unsafe) static var stillHistory = false
    /// Renders only: the page shown scrolled to its end (the newest messages), not its top.
    nonisolated(unsafe) static var stillBottom = false
    var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 12 ? "Good morning" : (h < 17 ? "Good afternoon" : "Good evening")
    }
    var lastAsk: Bubble? { m.bubbles.last(where: { $0.fromMe }) }
    var lastReply: Bubble? { m.bubbles.last.flatMap { $0.fromMe ? nil : $0 } }
    /// Everything said since their last message, in order: a reply stays on screen when a "by the way" line or a
    /// routine result comes after it (only the last one showed before, so the reply vanished under the notice).
    var sinceAsk: [Bubble] {
        let k = m.bubbles.lastIndex(where: { $0.fromMe }).map { $0 + 1 } ?? 0
        return Array(m.bubbles[k...].filter { !$0.text.isEmpty }.suffix(6))
    }
    /// Turns before the current exchange, oldest first: hidden by default, revealed by `HistoryStrip`.
    var olderTurns: [Bubble] {
        guard let cutoff = m.bubbles.lastIndex(where: { $0.fromMe }) else { return [] }
        return m.bubbles[..<cutoff].filter { !$0.text.isEmpty }
    }
    /// Earlier messages are showing (renders: `stillHistory`, with the last page of `olderTurns`).
    var historyShown: Bool { HomeView.still ? HomeView.stillHistory : pager.open }
    var historyRows: [Bubble] { HomeView.still ? Array(olderTurns.suffix(ChatPager.page)) : pager.rows }
    var historyBinding: Binding<Bool> {
        Binding(get: { historyShown }, set: { $0 ? pager.openNow() : pager.close() })
    }
    var body: some View {
        HStack(spacing: 0) {
            BotsColumn(m: m).transition(.move(edge: .leading))  // the bots on the left (BotsColumn.swift)
            VStack(spacing: 0) {
                // Pinned above the scrolling part, so the greeting can never slide up under the title row.
                if historyShown && m.openHelper == nil {
                    // Going back: the greeting steps aside for the day you're looking at (+ Find), and the orb with it.
                    DayPill(day: HomeView.still ? ChatPager.longDay(historyRows.first?.date ?? Date()) : dayNow, finding: $finding)
                        .starCalm(feather: 20).padding(.top, 18).padding(.bottom, 10).frame(height: 66)
                } else {
                    Text("\(greeting), \(m.userName).").font(.system(size: 26, weight: .semibold)).tracking(-0.5)
                        .foregroundStyle(WorldLook.cream).lineLimit(1).starCalm(feather: 30, floor: 0.25).padding(.top, 18).padding(.bottom, 12)
                }
                ScrollViewReader { proxy in
                    StillScroll(bottom: HomeView.stillBottom) {
                        VStack(spacing: 12) {
                            // Extra room above the orb only: its own halo/aura is bigger than its component frame
                            // (by design, elsewhere in the app too), and this is the one place the halo can sit at
                            // the very top of a scrolling column. Without this gap the ScrollView's own clip
                            // boundary cuts a flat edge straight through the circular halo the moment there's
                            // nothing above it to scroll past (Omar, 2026-10-29: "we cannot desecrate the halo").
                            // The orb/HelperConstellation themselves are untouched — this is only breathing room.
                            Color.clear.frame(height: historyShown && m.openHelper == nil ? 4 : 64).id("page-top")
                                .background(
                                    GeometryReader { g in Color.clear.onChange(of: g.frame(in: .named("chat")).minY) { _, y in pager.pageTop = y } })
                            if m.openedHelper?.bot != nil {
                                IrisHome(m: m)  // a bot's chat is open: the assistant waits small and dim above it (BotsColumn.swift)
                            } else if !(historyShown && m.openHelper == nil) {
                                HelperConstellation(m: m, still: HomeView.still, pointed: HomeView.stillPointed)
                                WeekLine(m: m)  // the plan's week, under the orbs (Budget.swift)
                            }
                            if m.openHelper == nil && !historyShown { HealthLine().starCalm(floor: 0.2) }  // the Mac's health (HealthView.swift)
                            if m.isReady && m.thinking && m.openHelper == nil && !historyShown {
                                StepLine(text: m.working ?? "Working on it…").foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(2)
                                    .starCalm(floor: 0.2).transition(.opacity)
                            }
                            if m.openHelper == nil && !historyShown, let g = m.goals["main"], g.active {
                                GoalLine(g: g) { m.stopGoal(nil) }.starCalm(floor: 0.2).transition(.opacity)  // a standing goal at work (Goals.swift)
                            }
                            if !HomeView.still { UpdateCard().starCalm() }  // also inside an opened helper, so an update is never missed
                            if m.openHelper == nil, let inv = m.roomInvites.first, let info = Shared.info(inv) {
                                VStack(alignment: .leading, spacing: 12) {
                                    Label("\(info.createdBy) invited you into a room", systemImage: "person.2.fill").font(.headline)
                                    Text(
                                        "\"\(info.title)\": a room you both add to, each with your own assistant. It stays in sync through iCloud. Nothing from your other rooms goes in without your OK."
                                    )
                                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                    HStack(spacing: 8) {
                                        Button("Add it to my brain") { m.joinRoom(inv) }
                                            .buttonStyle(.borderedProminent).tint(Color(hex: 0xF4EFE8)).foregroundStyle(Color(hex: 0x141416))
                                        Button("Not now") {
                                            Shared.leave(inv)
                                            m.roomInvites.removeAll { $0 == inv }
                                        }.buttonStyle(.bordered)
                                    }
                                }
                                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial)).starCalm()
                            }
                            if m.openHelper == nil && !m.interviewOffered && !m.thinking && Brain.exists {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("Want me to get to know you?").font(.headline)
                                    Text(
                                        "A few questions, one at a time, so I know what your personal room is for and how to help. You can skip any question, or stop whenever you like."
                                    )
                                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                    HStack(spacing: 8) {
                                        Button("Let's start") {
                                            guard m.isReady else { return }
                                            m.interviewOffered = true
                                            Task { await m.send("Let's do the welcome interview. Get to know me.", toNova: true) }
                                        }
                                        .buttonStyle(.borderedProminent).tint(Color(hex: 0xF4EFE8)).foregroundStyle(Color(hex: 0x141416))
                                        Button("Maybe later") {
                                            m.interviewOffered = true
                                            m.bubbles.append(Bubble(fromMe: false, text: "Any time. Just say \"get to know me\"."))
                                        }.buttonStyle(.bordered)
                                    }
                                }
                                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial)).starCalm()
                            }
                            if OffsiteCard.shows(m) { OffsiteCard(m: m).starCalm() }  // the locked copy in iCloud, offered once
                            if let n = m.limitNotice {
                                LimitNoticeCard(n: n, keep: { Task { await m.keepLimitSwitch() } }, dismiss: { m.dismissLimitNotice() })
                                    .starCalm().transition(.opacity)
                            }
                            if m.openHelper == nil, case let away = m.helpers.filter({ $0.finishedAway && $0.bot == nil }), !away.isEmpty {
                                AwayCard(m: m, hs: away).starCalm().transition(.opacity)
                            }
                            ForEach(m.stepsHere) { a in HumanStepCard(a: a) { m.answerHumanStep(a.id, $0) }.starCalm() }
                            ForEach(m.folderAsks) { a in FolderAskCard(a: a) { m.answerFolderAsk(a.id, approved: $0) }.starCalm() }
                            if !m.asks.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("NEEDS YOUR YES").font(.caption.bold()).foregroundStyle(.orange)
                                    ForEach(m.asks) { a in AskCard(a: a) { m.answer(a, $0) } }
                                }.starCalm()
                            }
                            if let h = m.openedHelper {
                                HelperCard(m: m, h: h).disabled(!m.isReady || m.asleep(h)).opacity(m.isReady ? 1 : 0.55).starCalm()
                                    .transition(.opacity.combined(with: .offset(y: 8)))
                                FollowUpList(m: m, helper: h.id).starCalm()
                            } else if let ask = lastAsk {
                                if historyShown {
                                    VStack(spacing: 0) {
                                        EarlierEdge(more: HomeView.still || pager.moreAbove)
                                            .background(
                                                GeometryReader { g in
                                                    Color.clear.onChange(of: g.frame(in: .named("chat")).maxY) { _, y in topSeen(y) }
                                                })
                                        HistoryStrip(m: m, turns: historyRows, open: historyBinding, lit: pager.lit).equatable()
                                        if !HomeView.still && !pager.atNow {
                                            EarlierEdge(more: true).id("newer-edge")
                                                .background(
                                                    GeometryReader { g in
                                                        Color.clear.onChange(of: g.frame(in: .named("chat")).minY) { _, y in bottomSeen(y) }
                                                    })
                                        }
                                    }
                                }
                                if !historyShown || HomeView.still || pager.atNow {
                                    VStack(spacing: 8) {
                                        if !historyShown { HistoryStrip(m: m, turns: Array(olderTurns.suffix(1)), open: historyBinding) }
                                        Color.clear.frame(height: 0).id("now")
                                        LongFoldText(text: ask.text, key: LongFold.key(ask), size: ChatText.callout, plain: true, center: true)
                                            .opacity(0.55)
                                            .frame(maxWidth: .infinity)
                                        // What they sent while this was being worked on, each tagged "Sent to …" or "Next up".
                                        FollowUpList(m: m, helper: nil, sent: m.bubbles.last.map { $0.fromMe ? [] : $0.followUps } ?? [])
                                        ForEach(sinceAsk) { r in
                                            let parts = Choices.split(Helpers.strip(r.text))
                                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                                MiniOrb().alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                                                LongFoldText(
                                                    text: parts.body, key: LongFold.key(r), size: 15, live: m.thinking && r.id == lastReply?.id
                                                )
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                            }
                                            .frame(maxWidth: 620).padding(.horizontal, 4)
                                            .id(r.id).transition(.opacity.combined(with: .offset(y: 10)))
                                            if r.id == lastReply?.id && !parts.choices.isEmpty && !m.thinking {
                                                ChoiceRow(choices: parts.choices, disabled: m.paused || !m.isReady) { c in
                                                    Task { await m.choose(c) }
                                                } onOther: {
                                                    typing = true
                                                }
                                                .transition(.opacity)
                                            }
                                        }
                                    }.starCalm(feather: 26, floor: 0.2).animation(.easeOut(duration: 0.9), value: lastReply?.text.isEmpty)
                                }
                            }
                        }.padding(.horizontal, 28).padding(.bottom, 8)
                    }
                    .coordinateSpace(name: "chat")
                    .background(
                        GeometryReader { g in
                            Color.clear.onAppear { chatHeight = g.size.height }.onChange(of: g.size.height) { _, h in chatHeight = h }
                        }
                    )
                    .onPreferenceChange(DayMarkKey.self) { marks in
                        if let d = (marks.last { $0.y <= 70 } ?? marks.first)?.label, d != dayNow { dayNow = d }
                    }
                    .onChange(of: pager.scroll) { _, s in
                        guard let s else { return }
                        Task { @MainActor in
                            await Task.yield()
                            proxy.scrollTo(s.target, anchor: s.anchor)
                        }
                    }
                    .frame(minHeight: 0, maxHeight: .infinity, alignment: .top).clipped()
                    .overlay(alignment: .bottom) {
                        if historyShown && m.openHelper == nil && !HomeView.still {
                            BackToNow { pager.close() }.padding(.bottom, 10).transition(.opacity)
                        }
                    }
                    .onePopup(
                        finding && historyShown, close: { finding = false }, align: .top,
                        inset: EdgeInsets(top: 6, leading: 0, bottom: 0, trailing: 0)
                    ) { _ in
                        FindPanel(pager: pager) { finding = false }
                    }
                    .healthPopup()  // the watchdog's list, from the line under the orb (HealthView.swift)
                }
                // Pinned under the scrolling part, so a long message can never push the box out of view.
                AskBox(m: m, ask: ask, typing: $typing, windowHeight: windowHeight).starCalm().padding(.horizontal, 28).padding(.top, 4).padding(
                    .bottom, 20
                ).layoutPriority(1)
            }
            if !m.shelf.isEmpty {
                if shelfCollapsed {
                    Button {
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { shelfCollapsed = false }
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                            Image(systemName: "tray.full").font(.system(size: 13))
                            let fresh = m.shelf.filter(\.fresh).count
                            if fresh > 0 {
                                Text("\(fresh)").font(.system(size: 10, weight: .bold)).foregroundStyle(Color(hex: 0x141416)).padding(4).background(
                                    Circle().fill(Color(hex: 0xFFE2C2)))
                            }
                        }.foregroundStyle(.secondary).frame(width: 30).frame(maxHeight: .infinity).contentShape(Rectangle())
                    }.buttonStyle(.plain).starCalm(pad: 0, feather: 18).help("Show Ready for you").transition(.move(edge: .trailing))
                } else {
                    ShelfPanel(m: m) {
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { shelfCollapsed = true }
                    }
                    .starCalm(pad: 0, feather: 18)
                    .transition(.move(edge: .trailing))
                }
            }
        }
        .overlayPreferenceValue(BotAnchors.self) { a in GeometryReader { g in BotThreads(m: m, points: a.mapValues { g[$0] }) } }
        .overlayPreferenceValue(BotAnchors.self) { a in GeometryReader { g in BotMenuLayer(m: m, points: a.mapValues { g[$0] }) } }
        .modifier(BotPopups(m: m))  // a bot's sheet and the archived bots (BotSheet.swift)
        .modifier(HomeStars())
        .background(HomeBackdrop())
        .frame(minWidth: (m.shelf.isEmpty || shelfCollapsed ? 560 : 830) + (m.bots.isEmpty ? 0 : 160))
        .animation(.spring(response: 0.6, dampingFraction: 0.85), value: m.shelf.isEmpty)
        .overlay {
            if let id = m.openedShelf, let it = m.shelf.first(where: { $0.id == id }) {
                ShelfOpened(m: m, item: it).transition(.opacity)
            }
        }
        .overlay {
            if m.routinesOpen {
                RoutinesPanel(m: m, sel: m.routinesPick?.routine, picked: m.routinesPick != nil, onlyBot: m.routinesPick?.bot).transition(.opacity)
            }
        }
        .overlay { if let u = m.viewing { FileViewer(m: m, url: u).transition(.opacity) } }
        .overlay {
            if m.writingPanel || (HomeView.still && HomeView.stillWriting) {
                WritingPanelHost(
                    m: m, ask: ask,
                    close: {
                        m.writingPanel = false
                        typing = true
                    },
                    send: {
                        m.writingPanel = false
                        go()
                    }
                ).transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: m.writingPanel)
        .pasteAsk(m)  // a long paste: as a file or as text? On top of the writing panel too (LongPaste.swift)
        .background(
            GeometryReader { g in Color.clear.onAppear { windowHeight = g.size.height }.onChange(of: g.size.height) { _, h in windowHeight = h } }
        )
        .environment(
            \.openURL,
            OpenURLAction { u in
                var f: URL? = u.isFileURL ? u : nil
                if f == nil, u.scheme == nil, u.path.hasPrefix("/") { f = URL(fileURLWithPath: u.path) }
                if let f, FileViewer.readable.contains(f.pathExtension.lowercased()) {
                    m.viewing = f
                    return .handled
                }
                if let f {
                    NSWorkspace.shared.activateFileViewerSelecting([f])
                    return .handled
                }
                return .systemAction
            }
        )
        .onAppear {
            pager.sync(live: olderTurns)
            ScrollUpOpener.install(
                ready: {
                    let p = ChatPager.shared
                    let m = Model.shared
                    return !p.open && m.openHelper == nil && m.openedShelf == nil && m.viewing == nil && p.pageTop >= -2
                },
                open: { ChatPager.shared.openNow() })
        }
        .onChange(of: olderTurns.count) { _, _ in pager.sync(live: olderTurns) }
        .onChange(of: m.openHelper) { _, h in if h != nil, pager.open { pager.close() } }
        .onChange(of: m.draftSeed) { _, v in
            if let v {
                if !v.isEmpty { ask.text = v }
                m.draftSeed = nil
                typing = true
            }
        }
        .safeAreaInset(edge: .bottom) {
            if m.paused {
                Text("Stopped. I won't do anything until you turn me back on.")
                    .font(.callout).padding(8).frame(maxWidth: .infinity).background(Color.red.opacity(0.15))
            }
        }
        .overlay {
            // Getting ready: the glass card over the whole window (ReadyLayer.swift); fades away once One opens.
            if !m.isReady && !ReadyLayerLook.hidden { ReadyLayer(m: m).transition(.opacity) }
        }
        .animation(.easeOut(duration: ReadyLayerLook.fade), value: m.isReady)
        .modifier(
            HomeTitleRow(m: m, voiceOff: $voiceOff, dropping: $dropping)
        )
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 18).strokeBorder(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .overlay(
                        Text("Drop pictures or files here").font(.title3.weight(.medium)).padding(12).background(Capsule().fill(.ultraThinMaterial))
                    )
                    .padding(10).allowsHitTesting(false)
            }
        }
    }
    /// The top edge of earlier messages came into view: 20 more above, the first row kept where it is.
    func topSeen(_ y: CGFloat) {
        guard pager.open, y > -40, y < chatHeight, Date().timeIntervalSince(pager.movedAt) > 0.6 else { return }
        pager.older(keepAt: y / max(chatHeight, 1))
    }
    /// After a jump, the bottom edge came into view: 20 newer below.
    func bottomSeen(_ y: CGFloat) {
        guard pager.open, y < chatHeight + 80, Date().timeIntervalSince(pager.movedAt) > 0.6 else { return }
        pager.newer()
    }
    func go() { ask.send(m) }
}

/// The assistant's suggested answers as buttons, plus a way to just say something else.
struct ChoiceRow: View {
    let choices: [String]
    var disabled = false
    let pick: (String) -> Void
    var onOther: () -> Void = {}
    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(choices.enumerated()), id: \.offset) { i, c in
                Button {
                    pick(c)
                } label: {
                    Text(c).font(.callout.weight(i == 0 ? .semibold : .regular))
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .foregroundStyle(i == 0 ? WorldLook.bg : .primary)
                        .background(Capsule().fill(i == 0 ? WorldLook.cream : Color.white.opacity(0.08)))
                        .overlay(Capsule().stroke(Color.white.opacity(i == 0 ? 0 : 0.16)))
                }.buttonStyle(.plain)
            }
            Button(action: onOther) {
                Text("Something else…").font(.callout).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 9)
            }.buttonStyle(.plain)
            Spacer(minLength: 0)
        }.disabled(disabled)
    }
}

struct AskCard: View {
    let a: Ask
    let answer: (String?) -> Void
    func isNo(_ id: String) -> Bool { id.hasPrefix("deny") || id.hasPrefix("reject") }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(a.question).font(.headline)
            HStack {
                ForEach(a.options, id: \.0) { o in
                    Button(o.0 == "allow_once" ? "Yes" : (isNo(o.0) ? "No" : o.1)) { answer(o.0) }
                        .buttonStyle(.borderedProminent).tint(isNo(o.0) ? .gray : .accentColor)
                }
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.orange.opacity(0.12)))
    }
}
