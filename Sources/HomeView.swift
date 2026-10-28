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
    @State var draft = ""
    @State var folderSheet = false
    @State var talkKeySheet = false
    @State var connectionsSheet = false
    @State var meCard = false
    @AppStorage("shelfCollapsed") var shelfCollapsed = false
    @AppStorage("voiceMuted") var voiceOff = false
    @ObservedObject var l = Listener.shared
    @State var micDownAt: Date?
    @State var micLatched = false
    @State var dropping = false
    @FocusState var typing: Bool
    var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 12 ? "Good morning" : (h < 17 ? "Good afternoon" : "Good evening")
    }
    var lastAsk: Bubble? { m.bubbles.last(where: { $0.fromMe }) }
    var lastReply: Bubble? { m.bubbles.last.flatMap { $0.fromMe ? nil : $0 } }
    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                StillScroll {
                    VStack(spacing: 12) {
                        Text("\(greeting), \(m.userName).").font(.system(size: 26, weight: .semibold)).tracking(-0.5)
                            .foregroundStyle(WorldLook.cream).padding(.top, 18)
                        HelperConstellation(m: m, still: HomeView.still)
                        if m.thinking && m.openHelper == nil {
                            StepLine(text: m.working ?? "Working on it…").foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(2)
                                .transition(.opacity)
                        }
                        if !HomeView.still { UpdateCard() }  // also inside an opened helper, so an update is never missed
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
                            .background(RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial))
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
                            .background(RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial))
                        }
                        if m.openHelper == nil, case let away = m.helpers.filter({ $0.finishedAway }), !away.isEmpty {
                            AwayCard(m: m, hs: away).transition(.opacity)
                        }
                        ForEach(m.humanSteps) { a in HumanStepCard(a: a) { m.answerHumanStep(a.id, $0) } }
                        if !m.asks.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("NEEDS YOUR YES").font(.caption.bold()).foregroundStyle(.orange)
                                ForEach(m.asks) { a in AskCard(a: a) { m.answer(a, $0) } }
                            }
                        }
                        if let h = m.openedHelper {
                            HelperCard(m: m, h: h).transition(.opacity.combined(with: .offset(y: 8)))
                            FollowUpList(m: m, helper: h.id)
                        } else if let ask = lastAsk {
                            VStack(spacing: 8) {
                                ChatText(text: ask.text, size: ChatText.callout, plain: true, center: true).opacity(0.55)
                                    .frame(maxWidth: .infinity)
                                // What they sent while this was being worked on, each tagged "Sent to …" or "Next up".
                                FollowUpList(m: m, helper: nil, sent: m.bubbles.last.map { $0.fromMe ? [] : $0.followUps } ?? [])
                                if let r = lastReply, !r.text.isEmpty {
                                    let parts = Choices.split(Helpers.strip(r.text))
                                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                                        MiniOrb().alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                                        ChatText(text: parts.body, size: 15).frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .frame(maxWidth: 620).padding(.horizontal, 4)
                                    .id(r.id).transition(.opacity.combined(with: .offset(y: 10)))
                                    if !parts.choices.isEmpty && !m.thinking {
                                        ChoiceRow(choices: parts.choices, disabled: m.paused) { c in
                                            Task { await m.choose(c) }
                                        } onOther: {
                                            typing = true
                                        }
                                        .transition(.opacity)
                                    }
                                }
                            }.animation(.easeOut(duration: 0.9), value: lastReply?.text.isEmpty)
                        }
                        askBox.padding(.top, 4)
                    }.padding(.horizontal, 28).padding(.bottom, 20)
                }
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
                    }.buttonStyle(.plain).help("Show Ready for you").transition(.move(edge: .trailing))
                } else {
                    ShelfPanel(m: m) {
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { shelfCollapsed = true }
                    }
                    .transition(.move(edge: .trailing))
                }
            }
        }
        .background(HomeBackdrop())
        .frame(minWidth: m.shelf.isEmpty || shelfCollapsed ? 560 : 830)
        .animation(.spring(response: 0.6, dampingFraction: 0.85), value: m.shelf.isEmpty)
        .overlay {
            if let id = m.openedShelf, let it = m.shelf.first(where: { $0.id == id }) {
                ShelfOpened(m: m, item: it).transition(.opacity)
            }
        }
        .overlay { if let u = m.viewing { FileViewer(m: m, url: u).transition(.opacity) } }
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
        .onChange(of: m.draftSeed) { _, v in
            if let v {
                if !v.isEmpty { draft = v }
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
        .modifier(
            HomeTitleRow(
                m: m, voiceOff: $voiceOff, meCard: $meCard, connectionsSheet: $connectionsSheet, talkKeySheet: $talkKeySheet,
                folderSheet: $folderSheet, dropping: $dropping)
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
    /// Hold the mic to talk (let go to send), or click once to start and again to send.
    var micButton: some View {
        let on = m.talkingInApp
        return ZStack {
            if on { Circle().fill(Color(hex: 0xFFE2C2, 0.18)).frame(width: 40 + 14 * l.level, height: 40 + 14 * l.level) }
            Circle().fill(WorldLook.cream.opacity(on ? 0.16 : 0.08)).frame(width: 36, height: 36)
            Image(systemName: on ? "mic.fill" : "mic").font(.system(size: 15, weight: .regular))
                .foregroundStyle(on ? Color(hex: 0xFFE2C2) : WorldLook.cream.opacity(0.85))
        }
        .frame(width: 36, height: 36).contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard micDownAt == nil else { return }
                    micDownAt = Date()
                    if micLatched { return }
                    m.talkBegin()
                }
                .onEnded { _ in
                    let held = Date().timeIntervalSince(micDownAt ?? Date())
                    micDownAt = nil
                    if micLatched {
                        micLatched = false
                        m.talkEnd()
                        return
                    }
                    if held < 0.35 && m.talkingInApp {
                        micLatched = true
                        return
                    }  // a click: keep listening until the next click
                    m.talkEnd()
                }
        )
        .help("Hold to talk, or click to start and click again to send")
        .animation(.easeOut(duration: 0.12), value: l.level)
    }
    @ViewBuilder var talkLine: some View {
        if m.talkingInApp {
            HStack(spacing: 8) {
                Image(systemName: "waveform").foregroundStyle(Color(hex: 0xFFE2C2))
                Text(l.text.isEmpty ? "I'm listening…" : l.text).lineLimit(3)
                Spacer()
                Text(micLatched ? "Click the mic to send" : "Let go to send").font(.callout).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.ultraThinMaterial))
            .transition(.opacity)
        } else if let n = l.problem ?? m.talkNote {
            Text(n).font(.callout).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
                .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 6) { if m.talkNote == n { m.talkNote = nil } } }
        }
    }
    var askBox: some View {
        VStack(spacing: 8) {
            talkLine
            PictureStrip(m: m)
            HStack(spacing: 8) {
                Menu {
                    Button("File…") { PictureIn.pick() }
                    Button("Photo…") { PictureIn.pickPhoto() }
                    Button("Screenshot") { PictureIn.screenshot() }
                    Button("Folder…") { folderSheet = true }
                } label: {
                    Image(systemName: "plus").font(.system(size: 16, weight: .regular)).foregroundStyle(WorldLook.cream.opacity(0.6))
                        .frame(width: 36, height: 36).contentShape(Circle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .help("Add a file or photo (or drag it in, or paste it)")
                let hint =
                    m.about != nil
                    ? "What do you want to know? Or just press send."
                    : m.openedHelper.map { "Talk to \($0.title)…" } ?? (lastAsk == nil ? "Tell \(m.name) what you need…" : "Or say it your way…")
                if HomeView.still {
                    Text(hint).font(.system(size: 14)).foregroundStyle(WorldLook.cream.opacity(0.4)).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField(hint, text: $draft).textFieldStyle(.plain).font(.system(size: 14)).focused($typing).onSubmit(go)
                }
                if !(draft.isEmpty && m.pictures.isEmpty && m.files.isEmpty && m.about == nil) {
                    // Never locked while busy: a message sent now goes into the running turn, or next up.
                    Button(action: go) {
                        Image(systemName: "arrow.up").font(.system(size: 14, weight: .semibold)).foregroundStyle(WorldLook.bg)
                            .frame(width: 36, height: 36).background(Circle().fill(WorldLook.cream))
                    }
                    .buttonStyle(.plain).help("Send").transition(.scale.combined(with: .opacity))
                }
                micButton
            }
            .padding(.horizontal, 8).frame(height: 52)
            .background(Capsule().fill(WorldLook.cream.opacity(0.05)))
            .overlay(Capsule().strokeBorder(WorldLook.cream.opacity(typing ? 0.2 : 0.09)))
            .frame(maxWidth: 620)
            .animation(.easeOut(duration: 0.15), value: draft.isEmpty)
        }
    }
    func go() {
        let t = draft
        draft = ""
        Task { await m.send(t) }
    }
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
