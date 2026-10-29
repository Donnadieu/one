import AppKit
import SwiftUI

// MARK: - The getting-ready layer (option B "glass card", picked by Omar on Oct 28 over full cover and orbit).
//
// Whenever One isn't ready (launch, update, crash, wake, any engine restart such as a folder change), a smoked layer
// covers the whole window: the app behind is blurred and darkened, so nothing underneath looks tappable, and the
// title row's buttons step aside. Centred on it, a glass card (the pop-up glass) with the breathing orb, a big
// "Getting ready…", the real progress ("Picking up your helpers · 2 of 4 back", then "Opening your chat…") and each
// helper being picked back up, with a check once it's back. No time estimate. If it stalls, the same card says
// "This is taking longer than usual" with Try again. When One opens, the layer fades away in half a second.
// The state itself (`Model.gate`) lives in StartupGate.swift.

enum ReadyLayerLook {
    /// The dim over the blurred app (the approved render: #141416 at 35%).
    static let tint = 0.35
    static let fade = 0.5
    /// Helpers listed by name; more than this shows "and N more".
    static let rows = 6
    /// Renders only: a still of the window behind the layer (ImageRenderer can't draw the live blur).
    nonisolated(unsafe) static var behind: NSImage?
    /// Renders only: draw the window without the layer (to make `behind`).
    nonisolated(unsafe) static var hidden = false
}

enum ReadyWords {
    static let title = "Getting ready…"
    static let chat = "Opening your chat…"
    static let safe = "Your helpers and your chat are safe."
    static let again = "Try again"
    static func helpers(_ back: Int, of total: Int) -> String { "Picking up your helpers · \(back) of \(total) back" }
    static func more(_ n: Int) -> String { "and \(n) more" }
}

@MainActor
extension Model {
    /// The helpers of this get-ready, in their order on screen, and whether each is back.
    var gateRows: [(id: UUID, title: String, back: Bool)] {
        let ids = Set(gateRoster).union(helpers.filter { asleep($0) }.map(\.id))
        return helpers.filter { ids.contains($0.id) }.map { ($0.id, $0.title, !asleep($0)) }
    }

    /// Remembers every helper that sleeps during this get-ready, so it stays listed (with its check) once it's back.
    func noteGateRoster(_ ids: [UUID]) {
        for id in ids where !gateRoster.contains(id) { gateRoster.append(id) }
    }
}

/// Over the whole window while One isn't ready. Put it as the last overlay of home.
struct ReadyLayer: View {
    @ObservedObject var m: Model
    var body: some View {
        ZStack {
            backdrop
            Color(hex: 0x141416).opacity(ReadyLayerLook.tint)
            ReadyCard(m: m).frame(width: 470).popupGlass(close: nil)
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture {}  // nothing under it can be tapped
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder var backdrop: some View {
        if HomeView.still {
            if let b = ReadyLayerLook.behind {
                GeometryReader { g in
                    Image(nsImage: b).resizable().frame(width: g.size.width, height: g.size.height)
                        .blur(radius: 18, opaque: true).saturation(Glass.saturation).clipped()
                }
            } else {
                WorldLook.bg
            }
        } else {
            InWindowGlass()
        }
    }
}

/// The card: orb, the big line, the progress, the helpers coming back; or the slow line with Try again.
struct ReadyCard: View {
    @ObservedObject var m: Model
    var body: some View {
        VStack(spacing: 0) {
            Orb(size: 76, active: m.gate == .gettingReady).frame(width: 152, height: 152)
            switch m.gate {
            case .stuck(let why):
                Text(why).font(.system(size: 23, weight: .semibold)).multilineTextAlignment(.center)
                Text(ReadyWords.safe).font(.system(size: 15)).foregroundStyle(WorldLook.cream.opacity(0.6)).padding(.top, 10)
                    .multilineTextAlignment(.center)
                Button {
                    m.tryGettingReadyAgain()
                } label: {
                    Text(ReadyWords.again).font(.system(size: 15, weight: .semibold)).foregroundStyle(WorldLook.bg)
                        .padding(.horizontal, 26).padding(.vertical, 10).background(Capsule().fill(WorldLook.cream))
                }
                .buttonStyle(.plain).keyboardShortcut(.defaultAction).padding(.top, 22)
            default:
                let c = m.gateCounts
                Text(ReadyWords.title).font(.system(size: 28, weight: .semibold))
                Text(c.total > 0 && c.back < c.total ? ReadyWords.helpers(c.back, of: c.total) : ReadyWords.chat)
                    .font(.system(size: 16)).foregroundStyle(WorldLook.cream.opacity(0.62)).padding(.top, 10)
                    .contentTransition(.numericText()).animation(.easeOut(duration: 0.3), value: c.back)
                rows.padding(.top, 24)
            }
        }
        .foregroundStyle(WorldLook.cream)
        .padding(.vertical, 40).padding(.horizontal, 56)
    }

    @ViewBuilder var rows: some View {
        let all = m.gateRows
        if !all.isEmpty {
            VStack(alignment: .leading, spacing: 11) {
                ForEach(all.prefix(ReadyLayerLook.rows), id: \.id) { r in
                    HStack(spacing: 12) {
                        ReadyCheck(back: r.back)
                        Text(r.title).font(.system(size: 14.5)).foregroundStyle(WorldLook.cream.opacity(r.back ? 0.85 : 0.45)).lineLimit(1)
                    }
                    .animation(.easeOut(duration: 0.3), value: r.back)
                }
                if all.count > ReadyLayerLook.rows {
                    Text(ReadyWords.more(all.count - ReadyLayerLook.rows)).font(.system(size: 13)).foregroundStyle(WorldLook.cream.opacity(0.45))
                        .padding(.leading, 30)
                }
            }
        }
    }
}

/// A small check once a helper is back; a dashed ring while it's still being picked up.
struct ReadyCheck: View {
    let back: Bool
    var body: some View {
        ZStack {
            if back {
                Circle().fill(WorldLook.cream.opacity(0.14))
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(WorldLook.cream)
            } else {
                Circle().stroke(WorldLook.cream.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [2.5, 3]))
            }
        }
        .frame(width: 18, height: 18).transition(.opacity)
    }
}

/// The title row's buttons step aside while One is getting ready (they're back when it's slow, so Switch AI or
/// Stop stay in reach), so the layer reads as covering the whole window.
struct ReadyAside: ViewModifier {
    @ObservedObject var m: Model
    func body(content: Content) -> some View {
        let away = m.gate == .gettingReady
        content.opacity(away ? 0 : 1).allowsHitTesting(!away).animation(.easeOut(duration: ReadyLayerLook.fade), value: away)
    }
}
