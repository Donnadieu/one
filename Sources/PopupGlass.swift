import AppKit
import SwiftUI

// MARK: - Every pop-up's look (Claude Design "Popup Glass", A · Smoked glass, picked by Omar 2026-10-28).
// One glass for the window and every pop-up: the home recipe (blur 40, saturate 1.4, #1C1C20 at the See-through
// level, 70% by default, plus the soft lift), corner 20, a cream edge at 10%, a faint top highlight, a deep shadow,
// a 30% dim behind that closes on a click, the X at the top right with "Esc to close", and Esc.
// A new pop-up gets all of it with one line: `PopupStage(close:) { … }` or `.onePopup(shown, close:) { … }`.
// one-lint's `popup-glass` rule flags any `.sheet`, `.popover`, `.alert` or hand-made dim that skips it.

enum PopupLook {
    static let corner: CGFloat = 20
    /// The dim over the window behind the pop-up (design: rgba(0,0,0,0.30)).
    static let dim = 0.30
    /// The pop-up's edge: 1px cream at 10%.
    static let edge = 0.10
    /// Inner cards and rows: cream at 4%, with a cream 8% hairline.
    static let card = 0.04
    static let cardEdge = 0.08
    /// Renders: the named space the stage draws in, so the glass can blur the right part of the still behind it.
    static let space = "onePopupStage"
    /// Renders only: a still of what's behind the pop-up (home), which the glass blurs the way the real window does.
    nonisolated(unsafe) static var behind: NSImage?
    /// Renders only: where the stage starts inside that still (below the fake title row).
    nonisolated(unsafe) static var behindAt = CGPoint.zero
    /// How many pop-ups are on screen. Esc belongs to them while any is open, not to "stop talking".
    nonisolated(unsafe) static var open = 0
}

/// The panel's fill: the window's own smoked glass, so a pop-up and home read as one material.
struct PopupGlass: View {
    @AppStorage(Glass.key) var solid = Glass.standard
    var body: some View {
        GeometryReader { g in
            ZStack {
                if HomeView.still {
                    still(g)
                } else {
                    InWindowGlass()
                }
                Color(hex: 0x1C1C20).opacity(Glass.clamp(solid))
                RadialGradient(
                    colors: [Color(hex: 0x2C2C32, 0.4), .clear], center: UnitPoint(x: 0.38, y: 0.46), startRadius: 0,
                    endRadius: max(g.size.width, g.size.height) * 0.3575)
            }
        }
    }
    /// Renders: the still behind, blurred and saturated like the design's CSS, lined up with where the panel sits.
    @ViewBuilder func still(_ g: GeometryProxy) -> some View {
        if let b = PopupLook.behind {
            let f = g.frame(in: .named(PopupLook.space))
            Image(nsImage: b).resizable().frame(width: b.size.width, height: b.size.height)
                .blur(radius: Glass.blur, opaque: true).saturation(Glass.saturation)
                .offset(x: -f.minX - PopupLook.behindAt.x, y: -f.minY - PopupLook.behindAt.y)
                .frame(width: g.size.width, height: g.size.height, alignment: .topLeading).clipped()
        } else {
            WorldLook.bg
        }
    }
}

/// Blurs what's under the pop-up inside One's window. AppKit's material adds its own grey and tint on top of the
/// blur; `Glass.clearMaterial` leaves only the blur, set to the design's numbers (the tint is drawn by `PopupGlass`).
struct InWindowGlass: NSViewRepresentable {
    final class Host: NSVisualEffectView {
        override func layout() {
            super.layout()
            if let l = layer { Glass.clearMaterial(l) }
        }
        override func updateLayer() {
            super.updateLayer()
            if let l = layer { Glass.clearMaterial(l) }
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            if let w = window {
                for n in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                    NotificationCenter.default.addObserver(self, selector: #selector(reclear), name: n, object: w)
                }
            }
            reclear()
        }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            reclear()
        }
        // AppKit rebuilds the material's layers on some changes (key window, appearance, size): clear them again.
        @objc func reclear() {
            if let l = layer { Glass.clearMaterial(l) }
            DispatchQueue.main.async { [weak self] in if let l = self?.layer { Glass.clearMaterial(l) } }
        }
    }
    func makeNSView(context: Context) -> Host { Self.host() }
    static func host() -> Host {
        let v = Host()
        v.material = .hudWindow
        v.blendingMode = .withinWindow
        v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)
        return v
    }
    func updateNSView(_ v: Host, context: Context) {}
}

/// "Esc to close" and the round X, top right of every pop-up. The X answers Esc.
struct PopupClose: View {
    let close: () -> Void
    var hint = true
    @State var hover = false
    var body: some View {
        HStack(spacing: 10) {
            if hint { Text("Esc to close").font(.system(size: 11.5)).foregroundStyle(WorldLook.cream.opacity(0.6)) }
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 10.5, weight: .bold)).foregroundStyle(WorldLook.cream.opacity(0.85))
                    .frame(width: 28, height: 28).background(Circle().fill(WorldLook.cream.opacity(hover ? 0.14 : 0.08)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain).keyboardShortcut(.cancelAction).help("Close").accessibilityLabel("Close")
            .onHover { hover = $0 }
        }
    }
}

extension View {
    /// The pop-up glass on a panel: fill, edge, top highlight, shadow, and (with `close`) the X + "Esc to close".
    func popupGlass(close: (() -> Void)?, hint: Bool = true) -> some View {
        let shape = RoundedRectangle(cornerRadius: PopupLook.corner, style: .continuous)
        return
            self
            .background(PopupGlass().clipShape(shape))
            .overlay(shape.strokeBorder(WorldLook.cream.opacity(PopupLook.edge)))
            .overlay(
                shape.inset(by: 1).strokeBorder(
                    LinearGradient(
                        stops: [.init(color: .white.opacity(0.06), location: 0), .init(color: .clear, location: 0.04)], startPoint: .top,
                        endPoint: .bottom),
                    lineWidth: 1)
            )
            .overlay(alignment: .topTrailing) {
                if let close { PopupClose(close: close, hint: hint).padding(.top, 16).padding(.trailing, 16) }
            }
            .shadow(color: .black.opacity(0.55), radius: 40, y: 30)
    }

    /// An inner card or row group on a pop-up: cream 4% with a cream 8% hairline.
    func popupCard(_ corner: CGFloat = 12) -> some View {
        background(RoundedRectangle(cornerRadius: corner, style: .continuous).fill(WorldLook.cream.opacity(PopupLook.card)))
            .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(WorldLook.cream.opacity(PopupLook.cardEdge)))
    }

    /// Shows `panel` as a pop-up while `shown` is true; the X, a click outside and Esc set it back to false.
    func onePopup<P: View>(
        _ shown: Binding<Bool>, align: Alignment = .center, inset: EdgeInsets = EdgeInsets(), @ViewBuilder panel: @escaping (CGSize) -> P
    ) -> some View {
        onePopup(shown.wrappedValue, close: { shown.wrappedValue = false }, align: align, inset: inset, panel: panel)
    }

    /// Shows `panel` as a pop-up over this view while `shown` is true.
    func onePopup<P: View>(
        _ shown: Bool, close: @escaping () -> Void, align: Alignment = .center, inset: EdgeInsets = EdgeInsets(),
        @ViewBuilder panel: @escaping (CGSize) -> P
    ) -> some View {
        overlay {
            if shown { PopupStage(close: close, align: align, inset: inset, panel: panel).transition(.opacity) }
        }
        .animation(.easeOut(duration: 0.18), value: shown)
    }
}

/// The dim (a click closes), and the panel on the pop-up glass with its X. `panel` gets the room it has.
struct PopupStage<Panel: View>: View {
    let close: () -> Void
    var align: Alignment = .center
    var inset = EdgeInsets()
    /// False when the panel draws its own X (none do today; kept for odd shapes).
    var closeButton = true
    @ViewBuilder let panel: (CGSize) -> Panel
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: align) {
                Color.black.opacity(PopupLook.dim).ignoresSafeArea().contentShape(Rectangle()).onTapGesture(perform: close)
                panel(g.size).popupGlass(close: closeButton ? close : nil).padding(inset)
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .coordinateSpace(name: PopupLook.space)
        .environment(\.colorScheme, .dark)
        .onAppear { PopupLook.open += 1 }
        .onDisappear { PopupLook.open = max(0, PopupLook.open - 1) }
    }
}
