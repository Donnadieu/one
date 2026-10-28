import AppKit
import SwiftUI

// MARK: - Helpers around the assistant, with no limit (Claude Design "Helper View Options", option A, picked by Omar)
// Every helper, working or finished, is an orb you can see and tap. As more arrive the orbs get smaller and
// wrap into more rings around the assistant's orb. Orange first (needs your yes, done and not opened yet),
// then working, then done. Never a fixed number of spots and never a "+N more" line.

/// Where each helper sits: orbits (ellipses) around the assistant, in design points (orb centre = 0,0).
/// Checkpoints from the design (handoff/PROMPT.md): 1–4, 5–8, 9–10, 11–15; past 15 one more orbit per ten helpers.
enum HelperRings {
    struct Look {
        let orb: CGFloat  // orb size on the inner orbits
        let label: CGFloat  // label width before it shortens with "…"
        let title: CGFloat  // title font size
        let line: CGFloat  // status line font size
    }
    struct Ring {
        let rx: CGFloat
        let ry: CGFloat
        let angles: [Double]  // degrees, 0 = right, clockwise (90 = down)
        var orb: CGFloat? = nil  // smaller orbs on deep outer orbits
        var fade: Double = 1  // and a little dimmer, for depth
    }
    struct Spot {
        let at: CGPoint
        let orb: CGFloat
        let fade: Double
    }
    struct Layout {
        let look: Look
        let rings: [Ring]
        let spots: [Spot]  // one per helper, in the order given
        var reachX: CGFloat { (rings.map(\.rx).max() ?? 0) + look.label / 2 }
        /// How far helpers reach above or below the assistant (orb on top, its words under it).
        var reachY: CGFloat {
            let up = spots.map { -$0.at.y + $0.orb / 2 }.max() ?? 0
            let down = spots.map { $0.at.y + $0.orb / 2 + 40 }.max() ?? 0
            return max(up, down)
        }
    }

    static func layout(count n: Int) -> Layout {
        var look: Look
        var rings: [Ring]
        if n <= 4 {
            look = Look(orb: 42, label: 132, title: 12, line: 10.5)
            rings = [Ring(rx: 260, ry: 100, angles: [-30, 30, 150, 210])]
        } else if n <= 8 {
            look = Look(orb: 36, label: 122, title: 12, line: 10.5)
            rings = [Ring(rx: 180, ry: 135, angles: [-45, 45, 135, 225]), Ring(rx: 360, ry: 200, angles: [-15, 15, 165, 195])]
        } else if n <= 10 {
            look = Look(orb: 32, label: 150, title: 11.5, line: 10)
            rings = [Ring(rx: 180, ry: 135, angles: [-45, 45, 135, 225]), Ring(rx: 375, ry: 205, angles: [-32, 0, 32, 148, 180, 212])]
        } else {
            // Past 15: one more orbit per ten helpers; every orb shrinks 2 points per extra orbit (never under 22).
            var extra = 0
            var room = 15
            while n > room {
                room += extra % 2 == 0 ? 10 : 8
                extra += 1
            }
            let shrink = CGFloat(2 * extra)
            look = Look(orb: max(22, 28 - shrink), label: 92, title: 11, line: 10)
            rings = [
                Ring(rx: 160, ry: 120, angles: [-45, 45, 135, 225]),
                Ring(rx: 250, ry: 170, angles: [-90, -30, 30, 150, 210]),
                Ring(rx: 400, ry: 250, angles: [-30, 0, 30, 150, 180, 210], orb: max(22, 24 - shrink), fade: 0.8),
            ]
            // Outer orbits sit above and below the third one's side spots, alternating spots so words never meet.
            for k in 0..<extra {
                let even = k % 2 == 0
                let a: [Double] = even ? [-45, 45, 135, 225, -70, 70, 110, 250, -90, 90] : [-57, 57, 123, 237, -80, 80, 100, 260]
                rings.append(Ring(rx: 420, ry: 335 + 110 * CGFloat(k), angles: a, orb: 22, fade: max(0.5, 0.7 - 0.1 * Double(k))))
            }
        }
        var spots: [Spot] = []
        var used: [Ring] = []
        for r in rings where spots.count < n {
            for d in r.angles where spots.count < n {
                let rad = d * .pi / 180
                spots.append(Spot(at: CGPoint(x: r.rx * cos(rad), y: r.ry * sin(rad)), orb: r.orb ?? look.orb, fade: r.fade))
            }
            used.append(r)
        }
        return Layout(look: look, rings: used, spots: spots)
    }

    /// Needs your yes, then done and not opened, then working, then done (stable: oldest first within each).
    static func rank(_ h: Helper) -> Int {
        if h.state == "needsYes" { return 0 }
        if h.waiting { return 1 }
        if h.state == "working" { return 2 }
        return 3
    }
    static func sorted(_ hs: [Helper]) -> [Helper] {
        hs.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }
    static func orbTime(_ t: Double, _ i: Int) -> Double { t + Double(i) * 3.1 }
    /// What the line under a helper says.
    static func status(_ h: Helper) -> String {
        if h.state == "needsYes" { return "Needs your yes" }
        if h.waiting { return "Done · tap to take a look" }
        if h.state == "done" { return "Done" }
        return h.line
    }
}

/// About 44 faint specks of dust around the assistant, denser near it, never under the orb or a helper's label.
enum HelperDust {
    struct Speck {
        let p: CGPoint
        let r: CGFloat
        let base: Double
        let ph: Double
        let f: Double
    }
    static func make(_ n: Int, spots: [HelperRings.Spot], label: CGFloat, k: CGFloat) -> [Speck] {
        var seed: UInt64 = 7 + UInt64(n) * 131
        func rnd() -> Double {
            seed = (seed &* 16807) % 2_147_483_647
            return Double(seed) / 2_147_483_647
        }
        var out: [Speck] = []
        var guardN = 0
        while out.count < 44 && guardN < 800 {
            guardN += 1
            let a = rnd() * 6.283
            let r = pow(rnd(), 0.8)
            let p = CGPoint(x: cos(a) * r * 450 * k, y: sin(a) * r * 245)
            if hypot(p.x, p.y) < 82 { continue }
            let hit = spots.contains { s in
                let x = s.at.x * k
                return abs(p.x - x) < label / 2 + 6 && p.y > s.at.y - s.orb / 2 - 8 && p.y < s.at.y + s.orb / 2 + 40
            }
            if hit { continue }
            out.append(Speck(p: p, r: 0.5 + rnd() * 0.6, base: 0.05 + 0.1 * (1 - r), ph: rnd() * 6.28, f: 0.3 + rnd() * 0.7))
        }
        return out
    }
}

/// The assistant in the middle and every helper around it, on faint dashed orbits. No limit.
struct HelperConstellation: View {
    @ObservedObject var m: Model
    var still = false  // renders: no motion
    /// A long press on a working helper's orb asks "Stop this helper?" in a pop-up over the window (`HomePopups`).
    var stopAsk: UUID? {
        get { m.stopAsk }
        nonmutating set { m.stopAsk = newValue }
    }
    @State var hover: UUID?
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    var body: some View {
        let hs = HelperRings.sorted(m.helpers)
        let lay = HelperRings.layout(count: hs.count)
        let calm = still || reduceMotion
        GeometryReader { g in
            // A narrow window pulls the orbits in to fit; orbs and words keep their size.
            let k = hs.isEmpty ? 1 : min(1, max(0.55, (g.size.width - 16) / (2 * lay.reachX)))
            let dust = HelperDust.make(hs.count, spots: lay.spots, label: lay.look.label, k: k)
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: calm || m.helpers.isEmpty)) { tl in
                let t = calm ? 21.7 : tl.date.timeIntervalSince(WorldLook.start)
                ZStack {
                    if !hs.isEmpty {
                        Canvas { ctx, size in
                            let c = CGPoint(x: size.width / 2, y: size.height / 2)
                            for r in lay.rings {
                                let e = CGRect(x: c.x - r.rx * k, y: c.y - r.ry, width: r.rx * 2 * k, height: r.ry * 2)
                                ctx.stroke(
                                    Path(ellipseIn: e), with: .color(WorldLook.cream.opacity(0.075)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            }
                            for d in dust {
                                let tw = 0.5 + 0.5 * sin(t * d.f + d.ph)
                                let a = d.base * (0.4 + tw)
                                ctx.fill(
                                    Path(ellipseIn: CGRect(x: c.x + d.p.x - d.r, y: c.y + d.p.y - d.r, width: d.r * 2, height: d.r * 2)),
                                    with: .color(Color(hex: 0xFFF4E8, a)))
                            }
                        }
                        .allowsHitTesting(false)
                    }
                    Orb(size: 92, active: m.thinking)  // the assistant's own orb: unchanged (Omar)
                        .opacity(m.openHelper == nil ? 1 : 0.5)
                        .contentShape(Circle())
                        .onTapGesture { if m.openHelper != nil { withAnimation(.easeOut(duration: 0.3)) { m.openHelper = nil } } }
                        .help(m.openHelper == nil ? "" : "Back to \(m.name)")
                        .onHover { inside in if m.openHelper != nil { inside ? NSCursor.pointingHand.push() : NSCursor.pop() } }
                    ForEach(Array(hs.enumerated()), id: \.element.id) { i, h in
                        let s = lay.spots[i]
                        spot(h, i: i, t: t, calm: calm, look: lay.look, spot: s, at: CGPoint(x: s.at.x * k, y: s.at.y))
                    }
                }
                .frame(width: g.size.width, height: g.size.height)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: hs.isEmpty ? 150 : max(470, lay.reachY * 2 + 20))
        .animation(.spring(response: 0.7, dampingFraction: 0.8), value: m.helpers.map(\.id))
    }

    func spot(_ h: Helper, i: Int, t: Double, calm: Bool, look: HelperRings.Look, spot: HelperRings.Spot, at p: CGPoint) -> some View {
        let on = hover == h.id
        let warm = h.state == "needsYes" || h.waiting
        let opened = h.state == "done" && !h.waiting
        let line = HelperRings.status(h)
        let seed = Double(i)
        let drift = calm ? CGSize.zero : CGSize(width: sin(t * 0.23 + seed * 1.9) * 3, height: cos(t * 0.19 + seed * 2.7) * 3)
        let gap: CGFloat = spot.orb >= 40 ? 7 : 5
        let tagH: CGFloat = look.title * 1.25 + look.line * 1.25 + 7
        let dy: CGFloat = p.y + drift.height + (gap + tagH) / 2  // centre the orb (not orb + label) on its spot
        let dx: CGFloat = p.x + drift.width
        let dimmed: Bool = m.openHelper != nil && m.openHelper != h.id
        let alpha: Double = dimmed ? 0.5 : (on ? 1 : spot.fade)
        let face = HelperFace(
            state: h.viewState, t: calm ? 0.9 : HelperRings.orbTime(t, i), orb: spot.orb, gap: gap, opened: opened,
            tag: HelperTag(title: h.title, line: line, look: look, warm: warm, opened: opened, full: on))
        return Button {
            if stopAsk == h.id { return }  // the long press already asked; this is its release
            m.focusHelper(h.id)
        } label: {
            face
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(h.title), \(line)")
        .onHover { inside in hover = inside ? h.id : (hover == h.id ? nil : hover) }
        .contextMenu { if h.state == "working" { Button("Stop") { m.stopHelper(h.id) } } }
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.6).onEnded { _ in if h.state == "working" { stopAsk = h.id } })
        .offset(x: dx, y: dy)
        .zIndex(on ? 5 : 1)
        .opacity(alpha)
        .transition(
            .asymmetric(
                insertion: .scale(scale: 0.2).combined(with: .opacity),
                removal: .offset(x: -p.x, y: -p.y).combined(with: .scale(scale: 0.1)).combined(with: .opacity)))
    }
}

/// A helper's orb with its check (if opened) and its words under it.
struct HelperFace: View {
    let state: HelperState
    let t: Double
    let orb: CGFloat
    let gap: CGFloat
    let opened: Bool
    let tag: HelperTag
    var body: some View {
        VStack(spacing: gap) {
            ZStack(alignment: .bottomTrailing) {
                // Reduce Motion: the orange pulse holds still as a ring (a fixed moment of the pulse).
                HelperOrb(state: state, t: t, size: orb, check: false).frame(width: orb, height: orb)
                if opened { HelperTick(size: orb >= 40 ? 15 : orb >= 34 ? 13 : 11).offset(x: 3, y: 3) }
            }
            tag
        }
        .contentShape(Rectangle())
    }
}

/// A helper's title and status under its orb. Long titles end in "…"; pointing at one shows it in full.
struct HelperTag: View {
    let title: String
    let line: String
    let look: HelperRings.Look
    var warm = false
    var opened = false
    var full = false
    var body: some View {
        VStack(spacing: 1) {
            Text(title).font(.system(size: look.title, weight: .semibold))
                .foregroundStyle(warm ? Color(hex: 0xF6B46E) : WorldLook.cream.opacity(opened ? 0.62 : 1))
            Text(line).font(.system(size: look.line))
                .foregroundStyle(warm ? Color(hex: 0xF6B46E, 0.8) : WorldLook.cream.opacity(opened ? 0.36 : 0.52))
        }
        .lineLimit(1).truncationMode(.tail).multilineTextAlignment(.center)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .frame(maxWidth: full ? nil : look.label)
        .fixedSize(horizontal: full, vertical: true)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(hex: 0x232326, full ? 1 : 0)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(WorldLook.cream.opacity(full ? 0.08 : 0)))
        .shadow(color: .black.opacity(full ? 0.5 : 0), radius: 10, y: 6)
    }
}

/// The small cream check on a finished helper you've already opened.
struct HelperTick: View {
    let size: CGFloat
    var body: some View {
        Circle().fill(WorldLook.cream).frame(width: size, height: size)
            .overlay(Image(systemName: "checkmark").font(.system(size: size * 0.55, weight: .heavy)).foregroundStyle(WorldLook.bg))
            .overlay(Circle().strokeBorder(WorldLook.bg, lineWidth: 2).padding(-2))
    }
}

/// A tiny still orb: next to the assistant's name and in front of its last reply.
struct MiniOrb: View {
    var size: CGFloat = 14
    var body: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [Color(hex: 0x4A4845), Color(hex: 0x1C1C1E)], center: UnitPoint(x: 0.4, y: 0.38), startRadius: 0, endRadius: size * 0.6)
            )
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(WorldLook.cream.opacity(0.55), lineWidth: 1.5))
            .shadow(color: Color(hex: 0xFFECD6, 0.25), radius: 4)
    }
}

/// The older helper label (title and status), still used by the render-only helper scenes.
struct HelperLabel: View {
    let title: String
    let line: String
    var warm = false
    var body: some View {
        VStack(spacing: 2) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(warm ? Color(hex: 0xF6B46E) : WorldLook.cream.opacity(0.92))
            Text(line).font(.system(size: 10.5)).foregroundStyle(WorldLook.cream.opacity(warm ? 0.8 : 0.66))
        }.multilineTextAlignment(.center).fixedSize()
    }
}
