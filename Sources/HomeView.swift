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

struct TryItem: Hashable {
    let symbol: String
    let tag: String
    let text: String
}

let tryItems: [TryItem] = [
    TryItem(symbol: "folder", tag: "Files", text: "Tidy my Downloads into folders that make sense"),
    TryItem(symbol: "doc.text.magnifyingglass", tag: "Files", text: "Find every receipt from this year and add them up"),
    TryItem(symbol: "safari", tag: "Browser", text: "Log in to a site for me and check my account"),
    TryItem(symbol: "airplane", tag: "Watch", text: "Watch a flight price and tell me when it drops"),
    TryItem(symbol: "sunrise", tag: "Every day", text: "Every morning at 7, send me my day on my phone"),
    TryItem(symbol: "hammer", tag: "Research", text: "Compare 3 contractors near me and save it to my Desktop"),
    TryItem(symbol: "envelope", tag: "Email", text: "Read my last 50 emails and tell me who's waiting on me"),
    TryItem(symbol: "brain", tag: "Memory", text: "Remember what I like, then plan my weekend around it"),
]

struct HomeView: View {
    @ObservedObject var m: Model
    @State var draft = ""
    @State var folderSheet = false
    @State var talkKeySheet = false
    @State var connectionsSheet = false
    @State var roomsSheet = false
    @State var meCard = false
    @AppStorage("shelfCollapsed") var shelfCollapsed = false
    @AppStorage("tryHidden") var tryHidden = false
    @AppStorage("firstHome") var firstHome: Double = 0
    var tryShown: Bool { !tryHidden && (firstHome == 0 || Date().timeIntervalSince1970 - firstHome < 3 * 86400) }
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
                Mist()
                ScrollView {
                    VStack(spacing: 18) {
                        Text("\(greeting), \(m.userName).").font(.system(size: 26, weight: .semibold)).padding(.top, 18)
                            .onAppear { if firstHome == 0 { firstHome = Date().timeIntervalSince1970 } }
                        NovaWithHelpers(m: m)
                        if m.thinking && m.openHelper == nil {
                            Text(m.working ?? "Working on it…").foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(2).transition(
                                .opacity)
                        }
                        if m.openHelper == nil { UpdateCard() }
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
                        if !m.asks.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("NEEDS YOUR YES").font(.caption.bold()).foregroundStyle(.orange)
                                ForEach(m.asks) { a in AskCard(a: a) { m.answer(a, $0) } }
                            }
                        }
                        if let h = m.openedHelper {
                            HelperCard(m: m, h: h).transition(.opacity.combined(with: .offset(y: 8)))
                        } else if let ask = lastAsk {
                            VStack(spacing: 12) {
                                Text(ask.text).font(.callout).foregroundStyle(Color.accentColor).multilineTextAlignment(.center)
                                if let r = lastReply, !r.text.isEmpty {
                                    let parts = Choices.split(Helpers.strip(r.text))
                                    MarkdownText(text: parts.body, size: 16)
                                        .frame(maxWidth: .infinity, alignment: .leading).padding(18)
                                        .background(RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial))
                                        .id(r.id).transition(.opacity.combined(with: .offset(y: 10)))
                                    if !parts.choices.isEmpty && !m.thinking {
                                        ChoiceRow(choices: parts.choices, disabled: m.paused) { c in
                                            Task { await m.send(c) }
                                        } onOther: {
                                            typing = true
                                        }
                                        .transition(.opacity)
                                    }
                                }
                            }.animation(.easeOut(duration: 0.9), value: lastReply?.text.isEmpty)
                        }
                        askBox.padding(.top, 4)
                        if !tryShown {
                            Button {
                                tryHidden = false
                                firstHome = Date().timeIntervalSince1970
                            } label: {
                                Label("Ideas to try", systemImage: "lightbulb")
                            }
                            .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text(lastAsk == nil ? "THINGS ONLY I CAN DO FROM YOUR MAC" : "TRY SOMETHING ELSE")
                                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    Spacer()
                                    Button {
                                        withAnimation { tryHidden = true }
                                    } label: {
                                        Image(systemName: "xmark").font(.caption.weight(.semibold))
                                    }
                                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Hide these. Bring them back with Ideas to try.")
                                }
                                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                                    ForEach(tryItems, id: \.self) { it in
                                        Button {
                                            Task { await m.send(it.text) }
                                        } label: {
                                            VStack(alignment: .leading, spacing: 8) {
                                                HStack(spacing: 6) {
                                                    Image(systemName: it.symbol).font(.system(size: 14, weight: .light))
                                                    Text(it.tag.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                                                }
                                                Text(it.text).font(.callout).multilineTextAlignment(.leading).foregroundStyle(.primary)
                                            }
                                            .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading).padding(12)
                                            .background(RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial))
                                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.12)))
                                        }.buttonStyle(.plain).disabled(m.thinking || m.paused)
                                    }
                                }
                            }
                        }
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
                    }.buttonStyle(.plain).background(Mist()).help("Show Ready for you").transition(.move(edge: .trailing))
                } else {
                    ShelfPanel(m: m).background(Mist()).overlay(alignment: .topTrailing) {
                        Button {
                            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { shelfCollapsed = true }
                        } label: {
                            Image(systemName: "sidebar.right").font(.system(size: 12))
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary).padding(.top, 14).padding(.trailing, 14).help("Hide Ready for you")
                    }.transition(.move(edge: .trailing))
                }
            }
        }
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
        .toolbar {
            ToolbarItem {
                Button {
                    voiceOff.toggle()
                    if voiceOff {
                        Speaker.shared.stop()
                        Voice.shared.stop()
                    }
                } label: {
                    Label(voiceOff ? "Voice off" : "Voice on", systemImage: voiceOff ? "speaker.slash" : "speaker.wave.2")
                }.help(voiceOff ? "Let \(m.name) talk" : "Stop \(m.name) from talking")
            }
            ToolbarItem(placement: .navigation) {
                Button {
                    meCard = true
                } label: {
                    Text(m.name).font(.headline)
                }.buttonStyle(.plain).help("\(m.name)'s brain and voice")
            }
            ToolbarItem {
                Button {
                    roomsSheet = true
                } label: {
                    Label("Rooms", systemImage: "circle.hexagongrid")
                }.help("See your rooms")
            }
            ToolbarItem {
                Button {
                    connectionsSheet = true
                } label: {
                    Label("Connections", systemImage: "point.3.connected.trianglepath.dotted")
                }.help("What \(m.name) can reach")
            }
            ToolbarItem {
                Button {
                    talkKeySheet = true
                } label: {
                    Label("Push to talk", systemImage: "mic")
                }.help("Choose a push-to-talk key")
            }
            ToolbarItem {
                Button {
                    folderSheet = true
                } label: {
                    Label("Folders", systemImage: "folder")
                }
            }
            ToolbarItem {
                Button {
                    m.switchingAI = true
                } label: {
                    Label("Switch AI", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            ToolbarItem {
                Button {
                    m.toggleStop()
                } label: {
                    Label(m.paused ? "Turn on" : "Stop", systemImage: m.paused ? "play.circle" : "stop.circle")
                }.tint(m.paused ? .green : .red)
            }
        }
        .navigationTitle("")
        .sheet(isPresented: $folderSheet) { FolderSheet(m: m) { folderSheet = false } }
        .sheet(isPresented: $talkKeySheet) { TalkKeySheet { talkKeySheet = false } }
        .sheet(isPresented: $roomsSheet) { RoomsView(m: m) { roomsSheet = false } }
        .sheet(isPresented: $connectionsSheet) { ConnectionsWorld(m: m) { connectionsSheet = false }.frame(width: 720, height: 680) }
        .popover(isPresented: $meCard, arrowEdge: .bottom) { MeCard(m: m) { meCard = false } }
        .onDrop(of: [.fileURL, .image], isTargeted: $dropping) { PictureIn.drop($0) }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 18).strokeBorder(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .overlay(
                        Text("Drop pictures or files here").font(.title3.weight(.medium)).padding(12).background(Capsule().fill(.ultraThinMaterial))
                    )
                    .padding(10).allowsHitTesting(false)
            }
        }
        .task { await m.ensureEngine() }
    }
    /// Hold the mic to talk (let go to send), or click once to start and again to send.
    var micButton: some View {
        let on = m.talkingInApp
        return ZStack {
            if on { Circle().fill(Color(hex: 0xFFE2C2, 0.18)).frame(width: 40 + 14 * l.level, height: 40 + 14 * l.level) }
            Image(systemName: on ? "mic.fill" : "mic").font(.system(size: 20, weight: on ? .regular : .light))
                .foregroundStyle(on ? Color(hex: 0xFFE2C2) : Color.primary)
        }
        .frame(width: 34, height: 34).contentShape(Circle())
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
        .disabled(m.paused)
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
            HStack(spacing: 12) {
                Button {
                    PictureIn.pick()
                } label: {
                    Image(systemName: "paperclip").font(.system(size: 20, weight: .light))
                }
                .buttonStyle(.plain).help("Add a picture or file (or drag it in, or paste it)").disabled(m.paused)
                TextField(
                    m.about != nil
                        ? "What do you want to know? Or just press send."
                        : m.openedHelper.map { "Talk to \($0.title)…" } ?? (lastAsk == nil ? "Tell \(m.name) what you need…" : "Or say it your way…"),
                    text: $draft
                )
                .textFieldStyle(.plain).font(.title3).focused($typing)
                .padding(12).padding(.horizontal, 4).background(Capsule().fill(.ultraThinMaterial))
                .overlay(Capsule().stroke(Color.white.opacity(typing ? 0.28 : 0.1)))
                .onSubmit(go).disabled(m.paused)
                micButton
                Button(action: go) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 32, weight: .light)) }
                    .buttonStyle(.plain).disabled(
                        m.paused || m.busyHere || (draft.isEmpty && m.pictures.isEmpty && m.files.isEmpty && m.about == nil))
            }
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
