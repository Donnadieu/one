import SwiftUI

// MARK: - The galaxy behind every screen (Claude Design "Galaxy Stars", Subtle, picked by Omar on Oct 28).
// One shared starfield: about 330 stars in three depths (230 tiny dim far ones, 85 medium, 14 near ones with a soft
// glow, 3 of them with four-point glints), mostly cream with a few warm and cool tints, a faint diagonal milky band,
// a slow twinkle and an almost still drift. Numbers come straight from the design's live mockup (`LOOK.subtle`).
// It sits above the smoked-glass tint and below all content. Words, cards, the orb and the shelf mark themselves
// with `.starCalm(…)`, and the stars under and around them fade, so nothing competes with what you read.
// Reduce Motion (or a render) holds one still frame. Redrawn at most 12 times a second; nothing else moves.

enum Stars {
    /// The design's window: star positions are laid out on it and stretched to the real size.
    static let ref = CGSize(width: 1180, height: 760)
    /// Same seed as the design's home page, so every screen shows the same sky.
    static let seed: UInt64 = 1302
    static let fps: Double = 12
    /// The frozen moment renders and Reduce Motion show (the design's default `t`).
    static let stillT: Double = 21.7
    /// Checks only (`--stars-live`): act as if the Mac's Reduce Motion were on.
    nonisolated(unsafe) static var reduceMotion = false

    enum Layer { case far, mid, near }
    struct Star {
        let layer: Layer
        let p: CGPoint  // 0…1 of the window
        let r: CGFloat
        let a: Double
        let tint: (Double, Double, Double)
        let per: Double  // seconds per twinkle
        let amp: Double
        let ph: Double
        let vx: Double  // points per second
    }
    /// count, radius min/max, brightness min/max, drift: the design's `subtle` look.
    static let layers: [(Layer, Int, CGFloat, CGFloat, Double, Double, Double)] = [
        (.far, 230, 0.55, 0.85, 0.20, 0.34, 0.06),
        (.mid, 85, 0.85, 1.15, 0.36, 0.52, 0.14),
        (.near, 14, 1.25, 1.6, 0.58, 0.78, 0.3),
    ]
    static let glow = 0.10
    static let band = 0.022
    static let glints = 3
    static let tints: [(Double, Double, Double)] = [
        (255, 244, 232), (255, 244, 232), (255, 244, 232), (255, 236, 214), (226, 232, 255), (255, 222, 186),
    ]
    /// The milky river: centre, angle, length and width on the design's window.
    static let bandC = CGPoint(x: 0.52, y: 0.48)
    static let bandAngle = -0.42
    static let bandLen = 0.75  // of the width
    static let bandWid = 0.16  // of the height

    static let pool = 4
    static let all: [Star] = make()
    static let counts: [Layer: Int] = Dictionary(uniqueKeysWithValues: layers.map { ($0.0, $0.1) })

    static func make() -> [Star] {
        var s = seed
        func r() -> Double {
            s = (s &* 16807) % 2_147_483_647
            return Double(s) / 2_147_483_647
        }
        func gauss() -> Double { (r() + r() + r() + r() - 2) / 2 }
        let W = Double(ref.width)
        let H = Double(ref.height)
        let len = W * bandLen
        let wid = H * bandWid
        var out: [Star] = []
        for (layer, n, r0, r1, a0, a1, drift) in layers {
            var made = 0
            var tries = 0
            // A pool four times the count, in order: each screen shows the first `n` of a layer that fall outside its
            // calm zones (the design re-draws a star that lands on words). Taken in order, a zone that appears hides
            // only the stars under it and brings in the next few, so the rest of the sky never jumps.
            while made < n * pool && tries < n * pool * 40 {
                tries += 1
                var x: Double
                var y: Double
                if layer == .far && r() < 0.45 {
                    let u = (r() - 0.5) * 2 * len / 2
                    let v = gauss() * wid
                    x = W * bandC.x + u * cos(bandAngle) - v * sin(bandAngle)
                    y = H * bandC.y + u * sin(bandAngle) + v * cos(bandAngle)
                } else {
                    x = r() * W
                    y = r() * H
                }
                if x < 0 || y < 0 || x > W || y > H { continue }
                let a = a0 + r() * (a1 - a0)
                let tint = tints[min(tints.count - 1, Int(r() * Double(tints.count)))]
                let rad = r0 + CGFloat(r()) * (r1 - r0)
                let per = layer == .far ? 5 + r() * 7 : layer == .mid ? 4 + r() * 5 : 6 + r() * 6
                let amp = layer == .far ? 0.35 : layer == .mid ? 0.45 : 0.4
                let ph = r() * 6.283
                let vx = drift * (0.6 + r() * 0.4)
                out.append(
                    Star(
                        layer: layer, p: CGPoint(x: x / W, y: y / H), r: rad, a: a, tint: tint, per: per, amp: amp, ph: ph, vx: vx))
                made += 1
            }
        }
        return out
    }

    /// A place the stars stay away from: a box (a card, a line of words) or a circle (the orb).
    struct Zone: Equatable {
        let rect: CGRect
        let calm: StarCalm
        /// Snapped to a 6 pt grid, so a helper orb's slow float doesn't redraw the sky on every frame.
        static func snapped(_ r: CGRect, _ calm: StarCalm) -> Zone {
            func s(_ v: CGFloat) -> CGFloat { (v / 6).rounded() * 6 }
            return Zone(rect: CGRect(x: s(r.minX), y: s(r.minY), width: s(r.width), height: s(r.height)), calm: calm)
        }
        func quiet(_ p: CGPoint) -> Double {
            let d: CGFloat
            if let rad = calm.radius {
                d = max(0, hypot(p.x - rect.midX, p.y - rect.midY) - rad)
            } else {
                let b = rect.insetBy(dx: -calm.pad, dy: -calm.pad)
                let dx = max(b.minX - p.x, 0, p.x - b.maxX)
                let dy = max(b.minY - p.y, 0, p.y - b.maxY)
                d = hypot(dx, dy)
            }
            if d <= 0 { return calm.floor }
            if d >= calm.feather { return 1 }
            return calm.floor + (1 - calm.floor) * Double(d / calm.feather)
        }
    }

    static func quiet(_ p: CGPoint, _ zones: [Zone]) -> Double {
        var q = 1.0
        for z in zones {
            q = min(q, z.quiet(p))
            if q <= 0 { return 0 }
        }
        return q
    }

    static func color(_ t: (Double, Double, Double), _ a: Double) -> Color {
        Color(.sRGB, red: t.0 / 255, green: t.1 / 255, blue: t.2 / 255, opacity: max(0, min(1, a)))
    }

    static func draw(_ ctx: inout GraphicsContext, size: CGSize, t: Double, zones: [Zone]) {
        drawBand(&ctx, size: size)
        var shown: [Layer: Int] = [:]
        for s in all {
            let n = shown[s.layer, default: 0]
            guard n < counts[s.layer, default: 0] else { continue }
            // Picked by where the star sits, not where it has drifted to, so the pick only changes when the screen does.
            if quiet(CGPoint(x: s.p.x * size.width, y: s.p.y * size.height), zones) <= 0 { continue }
            shown[s.layer] = n + 1
            drawStar(&ctx, s, size: size, t: t, zones: zones, glint: s.layer == .near && n < glints)
        }
    }

    /// The faint milky river behind the stars.
    static func drawBand(_ ctx: inout GraphicsContext, size: CGSize) {
        let len = size.width * bandLen
        let wid = size.height * bandWid
        let rad = len * 0.62
        var g = ctx
        g.translateBy(x: size.width * bandC.x, y: size.height * bandC.y)
        g.rotate(by: .radians(bandAngle))
        g.scaleBy(x: 1, y: wid * 2.2 / len)
        let stops = Gradient(stops: [
            .init(color: color((236, 226, 255), band), location: 0),
            .init(color: color((255, 236, 214), band * 0.55), location: 0.45),
            .init(color: .clear, location: 1),
        ])
        g.fill(
            Path(ellipseIn: CGRect(x: -rad, y: -rad, width: rad * 2, height: rad * 2)),
            with: .radialGradient(stops, center: .zero, startRadius: 0, endRadius: rad))
    }

    static func drawStar(_ ctx: inout GraphicsContext, _ s: Star, size: CGSize, t: Double, zones: [Zone], glint: Bool) {
        let w = size.width
        var x = (s.p.x * w + CGFloat(s.vx * t)).truncatingRemainder(dividingBy: w)
        if x < 0 { x += w }
        let p = CGPoint(x: x, y: s.p.y * size.height)
        let q = quiet(p, zones)
        if q <= 0.01 { return }
        let tw = 1 - s.amp + s.amp * (0.5 + 0.5 * sin(6.283 * t / s.per + s.ph))
        let a = s.a * tw * q
        if s.layer == .near {
            let gr = s.r * 5
            ctx.fill(
                Path(ellipseIn: CGRect(x: p.x - gr, y: p.y - gr, width: gr * 2, height: gr * 2)),
                with: .radialGradient(
                    Gradient(colors: [color(s.tint, glow * tw * 1.6 * q), color(s.tint, 0)]), center: p, startRadius: 0, endRadius: gr))
            if glint {
                // four soft spikes that breathe with the twinkle
                let k = max(0, tw - 0.55) / 0.45
                let l = s.r * CGFloat(3 + 4 * k)
                var spikes = Path()
                spikes.move(to: CGPoint(x: p.x - l, y: p.y))
                spikes.addLine(to: CGPoint(x: p.x + l, y: p.y))
                spikes.move(to: CGPoint(x: p.x, y: p.y - l))
                spikes.addLine(to: CGPoint(x: p.x, y: p.y + l))
                ctx.stroke(spikes, with: .color(color(s.tint, a * 0.5 * k)), lineWidth: 0.6)
            }
        }
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - s.r, y: p.y - s.r, width: s.r * 2, height: s.r * 2)), with: .color(color(s.tint, a)))
    }
}

/// How a piece of the screen keeps the stars off it. `radius` = a circle around its centre (the orb), else its box
/// grown by `pad`. Inside, stars show at `floor` (0 = none); they come back fully over `feather` points.
struct StarCalm: Equatable {
    var radius: CGFloat? = nil
    var pad: CGFloat = 6
    var feather: CGFloat = 22
    var floor: Double = 0
}

struct StarCalmKey: PreferenceKey {
    struct Item {
        let anchor: Anchor<CGRect>
        let calm: StarCalm
    }
    static let defaultValue: [Item] = []
    static func reduce(value: inout [Item], nextValue: () -> [Item]) { value.append(contentsOf: nextValue()) }
}

extension View {
    /// Keep the galaxy off this view (see `StarCalm`).
    func starCalm(radius: CGFloat? = nil, pad: CGFloat = 6, feather: CGFloat = 22, floor: Double = 0) -> some View {
        anchorPreference(key: StarCalmKey.self, value: .bounds) {
            [StarCalmKey.Item(anchor: $0, calm: StarCalm(radius: radius, pad: pad, feather: feather, floor: floor))]
        }
    }

    /// Put the galaxy behind this view (and `under` behind the galaxy), out to the window's edges.
    /// `top`: the title row's height, where stars show at 35% so the buttons stay clean.
    func withStars<U: View>(top: CGFloat = 0, @ViewBuilder under: @escaping () -> U) -> some View {
        backgroundPreferenceValue(StarCalmKey.self) { items in
            GeometryReader { g in
                let zones = items.map { Stars.Zone.snapped(g[$0.anchor], $0.calm) }
                ZStack {
                    under()
                    Starfield(zones: zones, top: top).equatable()
                }
            }
            .ignoresSafeArea()
        }
    }

    func withStars(top: CGFloat = 0) -> some View { withStars(top: top) { EmptyView() } }
}

/// Home's galaxy (also the helper view): under the title row too, where it shows at 35%. Home renders draw it once
/// behind their whole fake window instead (`HomeView.outerStars`), title row included.
struct HomeStars: ViewModifier {
    func body(content: Content) -> some View {
        if HomeView.outerStars { content } else { content.withStars(top: 52) }
    }
}

/// The galaxy itself. Use `withStars()` rather than placing it by hand, so the calm zones line up.
struct Starfield: View, Equatable {
    var zones: [Stars.Zone] = []
    var top: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.colorScheme) var scheme
    nonisolated static func == (a: Starfield, b: Starfield) -> Bool { a.zones == b.zones && a.top == b.top }
    func sky(t: Double) -> some View {
        Canvas { ctx, size in
            var zs = zones
            if top > 0 {
                zs.append(
                    Stars.Zone(
                        rect: CGRect(x: -100, y: -100, width: size.width + 200, height: top + 100), calm: StarCalm(pad: 0, feather: 1, floor: 0.35)))
            }
            Stars.draw(&ctx, size: size, t: t, zones: zs)
        }
    }
    var body: some View {
        let still = HomeView.still || reduceMotion || Stars.reduceMotion
        Group {
            if scheme == .light {
                Color.clear  // cream stars on a light setup screen would read as dirt
            } else if still {
                sky(t: Stars.stillT)  // Reduce Motion or a render: one still frame, nothing ticking
            } else {
                // A plain 12-a-second clock, not the display's animation clock (that one woke the window every frame).
                TimelineView(.periodic(from: WorldLook.start, by: 1 / Stars.fps)) { tl in
                    sky(t: tl.date.timeIntervalSince(WorldLook.start) + Stars.stillT)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
