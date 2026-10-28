import AppKit
import SwiftUI

// MARK: - Home's top row (Claude Design "Helper View Options"): the assistant's name on the left, plain
// icon-and-word buttons on the right, Stop outlined. Lives in the window's own title row; renders draw the
// same pieces in a fake title row (ImageRenderer can't draw a window toolbar).

/// One button in the top row: an icon only (its name shows when you point at it). Stop keeps its word, outlined.
struct TopBarButton: View {
    let title: String
    let symbol: String
    var help = ""
    var outlined = false
    var tint: Color = WorldLook.cream
    let action: () -> Void
    @State var hover = false
    var body: some View {
        Button(action: action) {
            Group {
                if outlined {
                    HStack(spacing: 6) {
                        Image(systemName: symbol).font(.system(size: 9.5, weight: .medium))
                        Text(title).font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 11).frame(height: 28)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(tint.opacity(0.18)))
                } else {
                    Image(systemName: symbol).font(.system(size: 15, weight: .regular)).frame(width: 32, height: 32)
                }
            }
            .foregroundStyle(outlined || hover ? tint : WorldLook.cream.opacity(0.68))
            .background(RoundedRectangle(cornerRadius: outlined ? 8 : 9, style: .continuous).fill(WorldLook.cream.opacity(hover ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).fixedSize()
        .onHover { hover = $0 }
        .help(outlined ? help : title)
        .accessibilityLabel(title)
        .animation(.easeOut(duration: 0.15), value: hover)
    }
}

/// The assistant's name with its little orb; tap for its brain and voice.
struct NamePill: View {
    let name: String
    let action: () -> Void
    @State var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                MiniOrb()
                Text(name).font(.system(size: 13, weight: .semibold)).foregroundStyle(WorldLook.cream)
                Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .bold)).foregroundStyle(WorldLook.cream.opacity(0.5))
            }
            .padding(.leading, 8).padding(.trailing, 10).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(WorldLook.cream.opacity(hover ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).fixedSize()
        .onHover { hover = $0 }
        .help("\(name)'s brain and voice")
    }
}

/// Voice, Rooms, Connections, Push to talk, Folders, Switch AI, Stop.
struct TopBarButtons: View {
    let name: String
    let voiceOff: Bool
    let paused: Bool
    var voice: () -> Void = {}
    var rooms: () -> Void = {}
    var connections: () -> Void = {}
    var talkKey: () -> Void = {}
    var folders: () -> Void = {}
    var switchAI: () -> Void = {}
    var stop: () -> Void = {}
    var body: some View {
        HStack(spacing: 2) {
            TopBarButton(
                title: voiceOff ? "Voice off" : "Voice", symbol: voiceOff ? "speaker.slash" : "waveform",
                help: voiceOff ? "Let \(name) talk" : "Stop \(name) from talking", action: voice)
            TopBarButton(title: "Rooms", symbol: "square.grid.2x2", help: "See your rooms", action: rooms)
            TopBarButton(title: "Connections", symbol: "point.3.connected.trianglepath.dotted", help: "What \(name) can reach", action: connections)
            TopBarButton(title: "Push to talk", symbol: "mic", help: "Choose a push-to-talk key", action: talkKey)
            TopBarButton(title: "Folders", symbol: "folder", help: "Folders \(name) can open", action: folders)
            TopBarButton(title: "Switch AI", symbol: "arrow.left.arrow.right", help: "Use a different AI", action: switchAI)
            TopBarButton(
                title: paused ? "Turn on" : "Stop", symbol: paused ? "play.fill" : "stop.fill",
                help: paused ? "Let \(name) work again" : "Stop everything \(name) is doing", outlined: true,
                tint: paused ? Color(hex: 0x9BD7A0) : WorldLook.cream, action: stop
            )
            .padding(.leading, 6)
        }
    }
}

/// The window's title row: no grey bar, the buttons sit straight on One's background (no glass pills on macOS 26).
struct QuietTitleRow: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            content.toolbarBackground(.hidden, for: .windowToolbar)
        }
    }
}

extension ToolbarContent {
    /// macOS 26 puts a glass pill behind toolbar items; the design has none.
    @ToolbarContentBuilder func noPill() -> some ToolbarContent {
        if #available(macOS 26.0, *) {
            self.sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}

/// A scroll view, except in renders (ImageRenderer draws scroll views blank): there the content is drawn as is.
struct StillScroll<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        if HomeView.still {
            VStack(spacing: 0) {
                content
                Spacer(minLength: 0)
            }
        } else {
            ScrollView { content }
        }
    }
}

/// Home's title row in the real window (the name on the left, the buttons on the right). Renders skip it:
/// ImageRenderer can't draw a window toolbar, so they draw the same pieces in a row of their own.
struct HomeTitleRow: ViewModifier {
    @ObservedObject var m: Model
    @Binding var voiceOff: Bool
    @Binding var meCard: Bool
    @Binding var connectionsSheet: Bool
    @Binding var talkKeySheet: Bool
    @Binding var folderSheet: Bool
    @Binding var dropping: Bool
    func body(content: Content) -> some View {
        if HomeView.still {
            content
        } else {
            content.toolbar {
                ToolbarItem(placement: .navigation) { NamePill(name: m.name) { meCard = true } }.noPill()
                ToolbarItem(placement: .primaryAction) {
                    TopBarButtons(
                        name: m.name, voiceOff: voiceOff, paused: m.paused,
                        voice: {
                            voiceOff.toggle()
                            if voiceOff {
                                Speaker.shared.stop()
                                Voice.shared.stop()
                            }
                        },
                        rooms: { RoomsWindow.show(m) }, connections: { connectionsSheet = true }, talkKey: { talkKeySheet = true },
                        folders: { folderSheet = true }, switchAI: { m.switchingAI = true }, stop: { m.toggleStop() })
                }.noPill()
            }
            .modifier(QuietTitleRow())
            .navigationTitle("")
            .sheet(isPresented: $folderSheet) { FolderSheet(m: m) { folderSheet = false } }
            .sheet(isPresented: $talkKeySheet) { TalkKeySheet { talkKeySheet = false } }
            .sheet(isPresented: $connectionsSheet) { ConnectionsWorld(m: m) { connectionsSheet = false }.frame(width: 720, height: 680) }
            .popover(isPresented: $meCard, arrowEdge: .bottom) { MeCard(m: m) { meCard = false } }
            .onDrop(of: [.fileURL, .image], isTargeted: $dropping) { PictureIn.drop($0) }
            .task { await m.ensureEngine() }
            .task { await ConnectionsWorld.prefetch() }  // so Connections opens already complete, with no wait while it slides in
        }
    }
}

/// Home's background: One's dark with a very soft lift behind the assistant (design: #1B1B1F at 38% / 46%).
struct HomeBackdrop: View {
    var body: some View {
        GeometryReader { g in
            ZStack {
                WorldLook.bg
                RadialGradient(
                    colors: [Color(hex: 0x1B1B1F), WorldLook.bg], center: UnitPoint(x: 0.38, y: 0.46), startRadius: 0,
                    endRadius: max(g.size.width, g.size.height) * 0.55 * 0.65)
            }
        }
        .ignoresSafeArea()
    }
}
