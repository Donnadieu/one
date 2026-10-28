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

/// Home's background: smoked glass (Omar picked it in Claude Design "Home Transparency"). The desktop shows
/// through a dark tint (#1C1C20) at `Glass.solid` (70% unless moved with the See-through slider in the name card),
/// with the soft lift behind the assistant on top.
struct HomeBackdrop: View {
    @AppStorage(Glass.key) var solid = Glass.standard
    var body: some View {
        GeometryReader { g in
            ZStack {
                if HomeView.still { WorldLook.bg } else { WindowGlass() }
                Color(hex: 0x1C1C20).opacity(Glass.clamp(solid))
                RadialGradient(
                    colors: [Color(hex: 0x24242A, 0.55), .clear], center: UnitPoint(x: 0.38, y: 0.46), startRadius: 0,
                    endRadius: max(g.size.width, g.size.height) * 0.36)
            }
        }
        .ignoresSafeArea()
    }
}

/// How solid the window is: 1 = no desktop showing, lower = more see-through.
enum Glass {
    static let key = "windowSolid"
    static let standard = 0.70
    static let range = 0.40...1.0
    static func clamp(_ v: Double) -> Double { min(range.upperBound, max(range.lowerBound, v)) }
    /// Very see-through: the shelf and the ask box get a darker base so their words stay readable.
    static func thin(_ v: Double) -> Bool { clamp(v) < 0.62 }
}

/// The blurred desktop behind One's window. Makes the window itself clear while home is on screen, and puts it
/// back the way it was when home goes away (setup screens stay solid).
struct WindowGlass: NSViewRepresentable {
    final class Host: NSVisualEffectView {
        weak var held: NSWindow?
        var wasOpaque = true
        var wasColor: NSColor?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let w = window {
                held = w
                wasOpaque = w.isOpaque
                wasColor = w.backgroundColor
                w.isOpaque = false
                w.backgroundColor = .clear
            }
        }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil, let w = held {
                w.isOpaque = wasOpaque
                w.backgroundColor = wasColor
                held = nil
            }
            super.viewWillMove(toWindow: newWindow)
        }
    }
    func makeNSView(context: Context) -> Host {
        let v = Host()
        v.material = .underWindowBackground
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)
        return v
    }
    func updateNSView(_ v: Host, context: Context) {}
}

/// The name card's "See-through" row: how much of the desktop shows through home (Solid 100% to Glass 40%).
struct SeeThroughRow: View {
    @AppStorage(Glass.key) var solid = Glass.standard
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("SEE-THROUGH").font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(WorldLook.cream.opacity(0.5))
                Spacer()
                Text("\(Int((Glass.clamp(solid) * 100).rounded()))%").font(.system(size: 11.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(WorldLook.cream.opacity(0.75))
            }
            GlassSlider(solid: $solid)
            HStack {
                Text("Solid")
                Spacer()
                Text("Glass")
            }
            .font(.system(size: 10.5)).foregroundStyle(WorldLook.cream.opacity(0.45))
        }
    }
}

/// A slim cream slider: left = solid, right = glass. Moving it changes the window on the spot.
struct GlassSlider: View {
    @Binding var solid: Double
    var body: some View {
        GeometryReader { g in
            let lo = Glass.range.lowerBound
            let hi = Glass.range.upperBound
            let f = (hi - Glass.clamp(solid)) / (hi - lo)  // 0 at Solid, 1 at Glass
            let w = g.size.width - 16
            ZStack(alignment: .leading) {
                Capsule().fill(WorldLook.cream.opacity(0.14)).frame(height: 3).padding(.horizontal, 8)
                Capsule().fill(WorldLook.cream.opacity(0.7)).frame(width: max(0, w * f), height: 3).padding(.leading, 8)
                Circle().fill(WorldLook.cream).frame(width: 16, height: 16).shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                    .offset(x: w * f)
            }
            .frame(height: 20).contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { v in
                    let k = min(1, max(0, (v.location.x - 8) / w))
                    solid = ((hi - k * (hi - lo)) * 100).rounded() / 100
                })
        }
        .frame(height: 20)
        .accessibilityElement().accessibilityLabel("See-through")
        .accessibilityValue("\(Int((Glass.clamp(solid) * 100).rounded())) percent solid")
        .accessibilityAdjustableAction { d in
            solid = Glass.clamp(solid + (d == .increment ? -0.05 : 0.05))
        }
    }
}
