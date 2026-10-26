import AppKit
import SwiftUI

// MARK: - Drawing the rooms map. Each step is its own small typed function: one big Canvas closure
// takes slower Macs (CI) too long to type-check.

@MainActor
enum RoomGraphDraw {
    static let cream = RoomGraph.Tint(0xF4EFE8)
    static let warm = RoomGraph.Tint(0xFFF0E0)

    static func draw(_ ctx: inout GraphicsContext, _ g: RoomGraph) {
        guard !g.rooms.isEmpty else { return }
        roomDisks(&ctx, g)
        threads(&ctx, g)
        threadPulses(&ctx, g)
        let badges = crossed(&ctx, g)
        links(&ctx, g)
        litLinks(&ctx, g)
        glows(&ctx, g)
        cores(&ctx, g)
        marks(&ctx, g)
        orb(&ctx, g)
        RoomLabels.draw(&ctx, g, badges: badges)
    }

    static func circle(_ c: CGPoint, _ r: CGFloat) -> Path { Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)) }
    static func qpt(_ p0: CGPoint, _ c: CGPoint, _ p1: CGPoint, _ u: CGFloat) -> CGPoint {
        let a: CGFloat = (1 - u) * (1 - u)
        let b: CGFloat = 2 * (1 - u) * u
        let d: CGFloat = u * u
        return CGPoint(x: a * p0.x + b * c.x + d * p1.x, y: a * p0.y + b * c.y + d * p1.y)
    }
    static func bendCtl(_ a: CGPoint, _ b: CGPoint, _ bend: CGFloat) -> CGPoint {
        let dx: CGFloat = b.x - a.x
        let dy: CGFloat = b.y - a.y
        return CGPoint(x: (a.x + b.x) / 2 - dy * bend, y: (a.y + b.y) / 2 + dx * bend)
    }

    /// Each room: a soft glow filling its circle and a faint ring around it.
    static func roomDisks(_ ctx: inout GraphicsContext, _ g: RoomGraph) {
        for i in g.rooms.indices {
            let d = g.disp[i]
            let tint = g.rooms[i].tint
            let hl = Double(g.roomHL[i])
            let mini = Double(d.mini)
            let ring: CGFloat = g.rooms[i].R * 1.12 * d.s
            let grad = Gradient(stops: [
                .init(color: tint.color(0.075 + hl * 0.07 + mini * 0.06), location: 0),
                .init(color: tint.color(0.03 + hl * 0.03), location: 0.7),
                .init(color: tint.color(0), location: 1),
            ])
            ctx.fill(circle(d.p, ring * 1.15), with: .radialGradient(grad, center: d.p, startRadius: 0, endRadius: ring * 1.15))
            ctx.stroke(circle(d.p, ring), with: .color(tint.color(0.1 + hl * 0.2 + mini * 0.18)), lineWidth: 1)
        }
    }

    /// The thread from the orb to room `i`: start, control, end.
    static func thread(_ g: RoomGraph, _ i: Int) -> (CGPoint, CGPoint, CGPoint) {
        let d = g.disp[i]
        let o = g.orb
        let dx: CGFloat = d.p.x - o.p.x
        let dy: CGFloat = d.p.y - o.p.y
        let L: CGFloat = max(hypot(dx, dy), 1)
        let ux: CGFloat = dx / L
        let uy: CGFloat = dy / L
        let p0 = CGPoint(x: o.p.x + ux * 82 * o.s, y: o.p.y + uy * 82 * o.s)
        let rr: CGFloat = g.rooms[i].R * 1.12 * d.s
        let p1 = CGPoint(x: d.p.x - ux * rr, y: d.p.y - uy * rr)
        let b: CGFloat = (i % 2 == 1 ? 1 : -1) * 0.07 * L
        let c = CGPoint(x: (p0.x + p1.x) / 2 - uy * b, y: (p0.y + p1.y) / 2 + ux * b)
        return (p0, c, p1)
    }
    static func threads(_ ctx: inout GraphicsContext, _ g: RoomGraph) {
        for i in g.rooms.indices {
            let (p0, c, p1) = thread(g, i)
            let hl = Double(g.roomHL[i])
            var path = Path()
            path.move(to: p0)
            path.addQuadCurve(to: p1, control: c)
            let grad = Gradient(colors: [warm.color(0.2 + hl * 0.15), g.rooms[i].tint.color(0.22 + hl * 0.25)])
            ctx.stroke(path, with: .linearGradient(grad, startPoint: p0, endPoint: p1), lineWidth: 1 + CGFloat(hl) * 0.4)
        }
    }
    /// A small light running from the orb to a room when the assistant writes something there.
    static func threadPulses(_ ctx: inout GraphicsContext, _ g: RoomGraph) {
        guard let orbSprite = g.orbSprite else { return }
        var c2 = ctx
        c2.blendMode = .plusLighter
        let img = c2.resolve(Image(nsImage: orbSprite))
        for pu in g.pulses {
            let el = g.clock - pu.t0
            guard el < 1.5, g.rooms.indices.contains(pu.room) else { continue }
            let u = el / 1.5
            let e: Double = u < 0.5 ? 2 * u * u : 1 - pow(-2 * u + 2, 2) / 2
            let (p0, c, p1) = thread(g, pu.room)
            let p = qpt(p0, c, p1, CGFloat(e))
            c2.opacity = sin(u * .pi) * 0.9 + 0.1
            c2.draw(img, in: CGRect(x: p.x - 14, y: p.y - 14, width: 28, height: 28))
        }
    }

    struct Badge {
        let text: String
        let p0: CGPoint
        let c: CGPoint
        let p1: CGPoint
        let mul: CGFloat
    }
    /// Dashed arcs between rooms that share facts; the count goes in a small pill on the arc.
    static func crossed(_ ctx: inout GraphicsContext, _ g: RoomGraph) -> [Badge] {
        let ca: CGFloat = 1 - g.fe
        guard ca > 0.01 else { return [] }
        var out: [Badge] = []
        for x in g.cross {
            guard let arc = crossArc(g, x) else { continue }
            var path = Path()
            path.move(to: arc.0)
            path.addQuadCurve(to: arc.2, control: arc.1)
            let style = StrokeStyle(lineWidth: 1, dash: [3, 5], dashPhase: CGFloat(-g.clock * 4))
            ctx.stroke(path, with: .color(cream.color(0.24 * Double(ca))), style: style)
            let text = x.n == 1 ? "1 fact crossed" : "\(x.n) facts crossed"
            out.append(Badge(text: text, p0: arc.0, c: arc.1, p1: arc.2, mul: ca))
        }
        return out
    }
    static func crossArc(_ g: RoomGraph, _ x: RoomGraph.Cross) -> (CGPoint, CGPoint, CGPoint)? {
        guard g.disp.indices.contains(x.a), g.disp.indices.contains(x.b) else { return nil }
        let A = g.disp[x.a]
        let B = g.disp[x.b]
        let ra: CGFloat = g.rooms[x.a].R * 1.12 * A.s
        let rb: CGFloat = g.rooms[x.b].R * 1.12 * B.s
        let L: CGFloat = max(hypot(B.p.x - A.p.x, B.p.y - A.p.y), 1)
        let m = CGPoint(x: (A.p.x + B.p.x) / 2, y: (A.p.y + B.p.y) / 2)
        let ox: CGFloat = m.x - g.orb.p.x
        let oy: CGFloat = m.y - g.orb.p.y
        let ol: CGFloat = max(hypot(ox, oy), 1)
        var best: (CGPoint, CGPoint, CGPoint)?
        // Bend the arc further out until it no longer runs through another room.
        for bend: CGFloat in [0.2, 0.32, 0.45, 0.6, 0.8] {
            let c = CGPoint(x: m.x + ox / ol * L * bend, y: m.y + oy / ol * L * bend)
            let a0 = atan2(c.y - A.p.y, c.x - A.p.x)
            let a1 = atan2(c.y - B.p.y, c.x - B.p.x)
            let p0 = CGPoint(x: A.p.x + cos(a0) * (ra + 6), y: A.p.y + sin(a0) * (ra + 6))
            let p1 = CGPoint(x: B.p.x + cos(a1) * (rb + 6), y: B.p.y + sin(a1) * (rb + 6))
            if best == nil { best = (p0, c, p1) }
            if !arcHitsRoom(g, p0, c, p1, skip: [x.a, x.b]) { return (p0, c, p1) }
        }
        return best
    }
    static func arcHitsRoom(_ g: RoomGraph, _ p0: CGPoint, _ c: CGPoint, _ p1: CGPoint, skip: [Int]) -> Bool {
        for j in g.rooms.indices where !skip.contains(j) {
            let d = g.disp[j]
            let rad: CGFloat = g.rooms[j].R * 1.12 * d.s + 14
            for k in 1..<20 {
                let p = qpt(p0, c, p1, CGFloat(k) / 20)
                if hypot(p.x - d.p.x, p.y - d.p.y) < rad { return true }
            }
        }
        return false
    }

    /// Curved threads between linked notes, one stroke per room.
    static func links(_ ctx: inout GraphicsContext, _ g: RoomGraph) {
        let dim: CGFloat = 1 - g.dimA * 0.7
        for ri in g.rooms.indices {
            let d = g.disp[ri]
            let base: CGFloat = (d.mini > 0.5 ? 0.12 : 0.085 + g.roomHL[ri] * 0.08) * dim
            var path = Path()
            for l in g.links where g.nodes[l.s].room == ri {
                if let a = g.activeId, l.s == a || l.t == a { continue }
                let A = g.nodes[l.s].s
                let B = g.nodes[l.t].s
                path.move(to: A)
                path.addQuadCurve(to: B, control: bendCtl(A, B, l.bend))
            }
            ctx.stroke(path, with: .color(g.rooms[ri].tint.color(Double(base))), lineWidth: 0.7)
        }
    }
    /// The hovered or open note's threads light up, with a small light travelling along each.
    static func litLinks(_ ctx: inout GraphicsContext, _ g: RoomGraph) {
        guard let act = g.activeId, g.nodes.indices.contains(act) else { return }
        let lit = g.links.filter { $0.s == act || $0.t == act }
        guard !lit.isEmpty else { return }
        let tint = g.rooms[g.nodes[act].room].tint
        var path = Path()
        for l in lit {
            path.move(to: g.nodes[l.s].s)
            path.addQuadCurve(to: g.nodes[l.t].s, control: bendCtl(g.nodes[l.s].s, g.nodes[l.t].s, l.bend))
        }
        ctx.stroke(path, with: .color(tint.color(Double(0.15 + 0.5 * g.dimA))), lineWidth: 1.1)
        var c2 = ctx
        c2.blendMode = .plusLighter
        let img = c2.resolve(Image(nsImage: g.sprites[g.nodes[act].room]))
        for (i, l) in lit.enumerated() {
            let A = g.nodes[l.s].s
            let B = g.nodes[l.t].s
            var u: Double = (g.clock * 0.55 + Double(i) * 0.137).truncatingRemainder(dividingBy: 1)
            if l.t == act { u = 1 - u }
            let p = qpt(A, bendCtl(A, B, l.bend), B, CGFloat(u))
            let s: Double = l.t == act ? 1 - u : u
            c2.opacity = Double(g.dimA) * sin(s * .pi) * 0.95
            c2.draw(img, in: CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18))
            c2.fill(circle(p, 1.3), with: .color(Color(hex: 0xFFF8F0)))
        }
    }

    static func alphaOf(_ g: RoomGraph, _ i: Int) -> CGFloat {
        var a: CGFloat = 1
        if let act = g.activeId, i != act, !g.nb.contains(i) { a = 1 - g.dimA * 0.8 }
        let mini = g.disp[g.nodes[i].room].mini
        if mini > 0 { a *= 1 - mini * 0.35 }
        return a
    }
    static func onScreen(_ g: RoomGraph, _ p: CGPoint, _ pad: CGFloat) -> Bool {
        p.x > -pad && p.x < g.size.width + pad && p.y > -pad && p.y < g.size.height + pad
    }
    static func isOn(_ g: RoomGraph, _ i: Int) -> Bool { i == g.activeId || g.nb.contains(i) }
    /// Soft light around every note (added, so overlapping glows brighten).
    static func glows(_ ctx: inout GraphicsContext, _ g: RoomGraph) {
        var c2 = ctx
        c2.blendMode = .plusLighter
        let imgs = g.sprites.map { c2.resolve(Image(nsImage: $0)) }
        for i in g.nodes.indices where onScreen(g, g.nodes[i].s, 40) {
            let n = g.nodes[i]
            let on = isOn(g, i)
            let gs: CGFloat = n.sr * (n.big ? 9 : 6.5) * (on ? 1.2 : 1)
            let boost: CGFloat = on && g.dimA > 0.1 ? 1.6 : 1
            let op: CGFloat = (n.big ? 0.5 : 0.2) * alphaOf(g, i) * (1 + g.roomHL[n.room] * 0.5) * boost
            c2.opacity = Double(min(1, max(0, op)))
            c2.draw(imgs[n.room], in: CGRect(x: n.s.x - gs / 2, y: n.s.y - gs / 2, width: gs, height: gs))
        }
    }
    static func cores(_ ctx: inout GraphicsContext, _ g: RoomGraph) {
        for i in g.nodes.indices where onScreen(g, g.nodes[i].s, 20) {
            let n = g.nodes[i]
            let w: Double = n.big ? 0.7 : 0.35
            let a: Double = (n.big ? 1 : 0.82) * Double(alphaOf(g, i))
            ctx.fill(circle(n.s, max(0.6, n.sr)), with: .color(g.rooms[n.room].tint.light(w, a)))
        }
    }
    /// A ring around the open note, and a ripple on the note the assistant just wrote.
    static func marks(_ ctx: inout GraphicsContext, _ g: RoomGraph) {
        if let s = g.selected, g.nodes.indices.contains(s) {
            let n = g.nodes[s]
            ctx.stroke(circle(n.s, n.sr + 5), with: .color(g.rooms[n.room].tint.color(0.7)), lineWidth: 1.2)
        }
        for pu in g.pulses where g.nodes.indices.contains(pu.node) {
            let el = g.clock - pu.t0 - 1.4
            guard el >= 0, el <= 1.6 else { continue }
            let n = g.nodes[pu.node]
            let e: Double = el / 1.6
            let tint = g.rooms[n.room].tint
            ctx.stroke(circle(n.s, n.sr + 2 + CGFloat(e) * 16), with: .color(tint.color((1 - e) * 0.7)), lineWidth: 1)
            var c2 = ctx
            c2.blendMode = .plusLighter
            c2.opacity = (1 - e) * 0.9
            let gs: CGFloat = n.sr * 12
            c2.draw(c2.resolve(Image(nsImage: g.sprites[n.room])), in: CGRect(x: n.s.x - gs / 2, y: n.s.y - gs / 2, width: gs, height: gs))
        }
    }
    /// The assistant's own orb (the same `Presence` as everywhere else), breathing in the middle.
    static func orb(_ ctx: inout GraphicsContext, _ g: RoomGraph) {
        let s: CGFloat = g.orb.s
        var c2 = ctx
        c2.translateBy(x: g.orb.p.x - 150 * s, y: g.orb.p.y - 150 * s)
        c2.scaleBy(x: s, y: s)
        let en: Double = g.energy * (0.6 + 0.4 * abs(sin(g.clock * 7)))
        Presence.draw(&c2, CGSize(width: 300, height: 300), t: g.clock, lean: .zero, voice: 0, energy: en, line: 1.1 / max(0.6, s))
    }
}
