import AppKit
import SwiftUI

// MARK: - Names on the rooms map. Every name tries a few spots around its dot and takes the first one
// that covers nothing already placed (header, footer, orb, other rooms, other names). No spot = no name;
// zooming in frees space, so more names appear. Names fade in and out instead of popping.

@MainActor
enum RoomLabels {
    enum Kind {
        case text(hub: Bool)
        case pill(meta: String, tint: RoomGraph.Tint)
        case room(sub: String, tint: RoomGraph.Tint)
        case badge
    }
    struct Label {
        let key: String
        let text: String
        let kind: Kind
        let w: CGFloat
        let h: CGFloat
        var mul: CGFloat = 1
        var node: Int?
        var off = CGPoint.zero
        var c = CGPoint.zero
        var rect = CGRect.zero
    }
    struct Memory {
        var a: CGFloat
        var label: Label
    }
    struct Placer {
        var occ: [CGRect]
        var placed: [Label] = []
        let bounds: CGRect
        mutating func place(_ l: Label, _ spots: [CGPoint], avoid: [CGRect] = [], rings: [(CGPoint, CGFloat)] = []) -> Bool {
            for c in spots {
                let r = CGRect(x: c.x - l.w / 2 - 5, y: c.y - l.h / 2 - 3, width: l.w + 10, height: l.h + 6)
                if !bounds.contains(r) || occ.contains(where: { $0.intersects(r) }) { continue }
                if avoid.contains(where: { $0.intersects(r) }) { continue }
                if rings.contains(where: { RoomLabels.hits(r, $0.0, $0.1) }) { continue }
                occ.append(r)
                var m = l
                m.c = c
                m.rect = r
                placed.append(m)
                return true
            }
            return false
        }
    }

    static let fNode = Font.system(size: 11.5, weight: .medium)
    static let fHub = Font.system(size: 12, weight: .semibold)
    static let fPill = Font.system(size: 12.5, weight: .semibold)
    static let fMeta = Font.system(size: 11.5)
    static let fRoom = Font.system(size: 15, weight: .semibold)
    static let fSub = Font.system(size: 11.5)
    static let fBadge = Font.system(size: 10.5, weight: .medium)
    static var widths: [String: CGFloat] = [:]

    static func width(_ ctx: GraphicsContext, _ font: Font, _ tag: String, _ s: String) -> CGFloat {
        let key = tag + "|" + s
        if let w = widths[key] { return w }
        let w = ctx.resolve(Text(s).font(font)).measure(in: CGSize(width: 2000, height: 40)).width
        widths[key] = w
        return w
    }
    static func short(_ s: String) -> String {
        guard s.count > 30 else { return s }
        var cut = String(s.prefix(29))
        if let sp = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: sp) > 14 { cut = String(cut[..<sp]) }
        return cut.trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;-")) + "…"
    }

    static func draw(_ ctx: inout GraphicsContext, _ g: RoomGraph, badges: [RoomGraphDraw.Badge]) {
        var P = Placer(occ: fixedAreas(g), bounds: CGRect(origin: .zero, size: g.size).insetBy(dx: 6, dy: 6))
        activePill(ctx, g, &P)
        roomNames(ctx, g, &P)
        for (i, b) in badges.enumerated() {
            var l = Label(key: "badge\(i)", text: b.text, kind: .badge, w: width(ctx, fBadge, "b", b.text) + 16, h: 18)
            l.mul = b.mul
            let spots = [0.5, 0.4, 0.6, 0.3, 0.7, 0.22, 0.78].map { RoomGraphDraw.qpt(b.p0, b.c, b.p1, CGFloat($0)) }
            _ = P.place(l, spots, rings: g.rooms.indices.map { ring(g, $0) })
        }
        noteNames(ctx, g, &P)
        fade(&ctx, g, P.placed)
    }
    /// Header, footer, the orb, and the reader (when open) never get names on them.
    static func fixedAreas(_ g: RoomGraph) -> [CGRect] {
        let W = g.size.width
        let H = g.size.height
        let o = g.orb
        var occ = [
            CGRect(x: 0, y: 0, width: W, height: 70),
            CGRect(x: 0, y: H - 58, width: W, height: 58),
            CGRect(x: o.p.x - 64 * o.s, y: o.p.y - 64 * o.s, width: 128 * o.s, height: 128 * o.s),
        ]
        if g.readerOpen { occ.append(CGRect(x: W - 396, y: 70, width: 396, height: H)) }
        return occ
    }
    static func activePill(_ ctx: GraphicsContext, _ g: RoomGraph, _ P: inout Placer) {
        guard let act = g.activeId, g.nodes.indices.contains(act) else { return }
        let n = g.nodes[act]
        let meta = n.deg == 1 ? "1 link" : "\(n.deg) links"
        let name = short(n.name)
        let w = width(ctx, fPill, "p", name) + width(ctx, fMeta, "m", meta) + 32
        let l = Label(key: "pill", text: name, kind: .pill(meta: meta, tint: g.rooms[n.room].tint), w: w, h: 26)
        let s = n.s
        let r = n.sr
        _ = P.place(
            l,
            [
                CGPoint(x: s.x, y: s.y - r - 22), CGPoint(x: s.x, y: s.y + r + 22), CGPoint(x: s.x + r + 14 + w / 2, y: s.y),
                CGPoint(x: s.x - r - 14 - w / 2, y: s.y),
            ])
        P.occ.append(CGRect(x: s.x - r - 3, y: s.y - r - 3, width: r * 2 + 6, height: r * 2 + 6))
    }
    nonisolated static func hits(_ r: CGRect, _ c: CGPoint, _ rad: CGFloat) -> Bool {
        let x = min(max(c.x, r.minX), r.maxX)
        let y = min(max(c.y, r.minY), r.maxY)
        return hypot(x - c.x, y - c.y) < rad
    }
    static func ring(_ g: RoomGraph, _ j: Int) -> (CGPoint, CGFloat) {
        let d = g.disp[j]
        return (d.p, d.mini > 0.5 ? 34 : g.rooms[j].R * 1.12 * d.s)
    }
    static func ringRect(_ g: RoomGraph, _ j: Int) -> CGRect {
        let d = g.disp[j]
        let rad: CGFloat = d.mini > 0.5 ? 34 : g.rooms[j].R * 1.12 * d.s
        return CGRect(x: d.p.x - rad, y: d.p.y - rad, width: rad * 2, height: rad * 2)
    }
    /// Room names go outside their own circle and never on another room's circle.
    static func roomNames(_ ctx: GraphicsContext, _ g: RoomGraph, _ P: inout Placer) {
        let rings = g.rooms.indices.map { ring(g, $0) }
        for i in g.rooms.indices {
            let d = g.disp[i]
            let r = g.rooms[i]
            if i == g.focus && g.fe > 0.15 { continue }
            let others = rings.enumerated().filter { $0.offset != i }.map { ($0.element.0, $0.element.1 + 4) }
            if d.mini > 0.5 {
                let l = Label(key: "room\(i)", text: r.name, kind: .room(sub: "", tint: r.tint), w: width(ctx, fRoom, "r", r.name), h: 20)
                _ = P.place(l, miniSpots(g, d.p, l.w), rings: others)
            } else {
                let ring: CGFloat = r.R * 1.12 * d.s
                let w = max(width(ctx, fRoom, "r", r.name), width(ctx, fSub, "s", r.sub))
                let l = Label(key: "room\(i)", text: r.name, kind: .room(sub: r.sub, tint: r.tint), w: w, h: 38)
                _ = P.place(
                    l,
                    [
                        CGPoint(x: d.p.x, y: d.p.y - ring - 26), CGPoint(x: d.p.x, y: d.p.y + ring + 26), CGPoint(x: d.p.x, y: d.p.y - ring - 52),
                        CGPoint(x: d.p.x, y: d.p.y + ring + 52), CGPoint(x: d.p.x - ring - 14 - w / 2, y: d.p.y),
                        CGPoint(x: d.p.x + ring + 14 + w / 2, y: d.p.y),
                    ], rings: others)
            }
        }
    }
    /// A small room's name goes on its outer side first (away from the room you're in).
    static func miniSpots(_ g: RoomGraph, _ p: CGPoint, _ w: CGFloat) -> [CGPoint] {
        let below = CGPoint(x: p.x, y: p.y + 44)
        let above = CGPoint(x: p.x, y: p.y - 44)
        let left = CGPoint(x: p.x - 42 - w / 2, y: p.y)
        let right = CGPoint(x: p.x + 42 + w / 2, y: p.y)
        guard let f = g.focus, g.disp.indices.contains(f) else { return [below, above, left, right] }
        let dx = p.x - g.disp[f].p.x
        let dy = p.y - g.disp[f].p.y
        if abs(dx) > abs(dy) { return dx > 0 ? [right, below, above, left] : [left, below, above, right] }
        return dy > 0 ? [below, right, left, above] : [above, right, left, below]
    }
    static func nodeLabel(_ ctx: GraphicsContext, _ n: RoomGraph.Node, _ i: Int) -> Label {
        let name = short(n.name)
        let w = width(ctx, n.big ? fHub : fNode, n.big ? "h" : "n", name)
        var l = Label(key: "n\(i)", text: name, kind: .text(hub: n.big), w: w + 8, h: 16)
        l.node = i
        return l
    }
    static func spots(_ n: RoomGraph.Node, _ l: Label) -> [CGPoint] {
        let s = n.s
        let r = n.sr
        return [
            CGPoint(x: s.x, y: s.y + r + 4 + l.h / 2), CGPoint(x: s.x, y: s.y - r - 4 - l.h / 2), CGPoint(x: s.x + r + 6 + l.w / 2, y: s.y),
            CGPoint(x: s.x - r - 6 - l.w / 2, y: s.y),
        ]
    }
    static func wasShown(_ g: RoomGraph, _ i: Int) -> Bool { (g.labels["n\(i)"]?.a ?? 0) > 0.5 }
    /// Note names: the hovered note's neighbours, or else the busiest notes; more as you zoom in.
    static func noteNames(_ ctx: GraphicsContext, _ g: RoomGraph, _ P: inout Placer) {
        var cand: [Int]
        if g.activeId != nil {
            cand = g.nb.filter { g.disp[g.nodes[$0].room].mini < 0.5 }
            cand.sort { a, b in
                let pa = wasShown(g, a)
                let pb = wasShown(g, b)
                return pa != pb ? pa : g.nodes[a].deg > g.nodes[b].deg
            }
            cand = Array(cand.prefix(14))
        } else {
            let k = g.cam.k
            let kk: CGFloat = g.flying ? min(k, g.tgt.k) : k
            let zoomBudget: CGFloat = kk < 0.75 ? 1 : kk < 1.1 ? 2 : 2 + (kk - 1.1) * 9
            let budget: Int = Int(zoomBudget.rounded())
            let inside: Int = Int((zoomBudget + g.fe * 40).rounded())
            let view = CGRect(origin: .zero, size: g.size)
            cand = g.nodes.indices.filter { i in
                let n = g.nodes[i]
                return g.disp[n.room].mini < 0.5 && view.contains(n.s) && (n.rank < (n.room == g.focus ? inside : budget) || g.roomHL[n.room] > 0.4)
            }
            cand.sort { a, b in
                let pa = wasShown(g, a)
                let pb = wasShown(g, b)
                if pa != pb { return pa }
                if g.nodes[a].big != g.nodes[b].big { return g.nodes[a].big }
                return g.nodes[a].deg > g.nodes[b].deg
            }
            cand = Array(cand.prefix(140))
        }
        let rings = g.rooms.indices.map { ring(g, $0) }
        // Bright notes stay uncovered: a name never sits on another note's light.
        let bright: [(CGPoint, CGFloat)] = g.nodes.indices.compactMap { j in
            let n = g.nodes[j]
            return n.big && g.disp[n.room].mini < 0.5 ? (n.s, n.sr + 3) : nil
        }
        for i in cand {
            let l = nodeLabel(ctx, g.nodes[i], i)
            let room = g.nodes[i].room
            var avoid = rings.enumerated().filter { $0.offset != room }.map { ($0.element.0, $0.element.1 + 4) }
            avoid += bright.filter { hypot($0.0.x - g.nodes[i].s.x, $0.0.y - g.nodes[i].s.y) > 0.5 }
            _ = P.place(l, spots(g.nodes[i], l), rings: avoid)
        }
    }

    /// Fades names in and out, then draws them.
    static func fade(_ ctx: inout GraphicsContext, _ g: RoomGraph, _ placed: [Label]) {
        let dt: CGFloat = g.frozen ? 1 : CGFloat(g.lastDt)
        var on = Set<String>()
        for var l in placed {
            if let i = l.node, g.nodes.indices.contains(i) { l.off = CGPoint(x: l.c.x - g.nodes[i].s.x, y: l.c.y - g.nodes[i].s.y) }
            on.insert(l.key)
            if g.labels[l.key] != nil { g.labels[l.key]?.label = l } else { g.labels[l.key] = Memory(a: g.frozen ? 1 : 0, label: l) }
        }
        for key in Array(g.labels.keys) {
            guard var m = g.labels[key] else { continue }
            let shown = on.contains(key)
            if !shown && placed.contains(where: { $0.rect.intersects(m.label.rect) }) { m.a = min(m.a, 0.4) * 0.6 }
            // While the camera flies, old names leave fast so none trail behind the moving rooms.
            let leaving: CGFloat = g.flying || g.fe > 0.02 && g.fe < 0.98 ? 24 : 9
            m.a += ((shown ? 1 : 0) - m.a) * min(1, dt * (shown ? 7 : leaving))
            if !shown && m.a < 0.02 {
                g.labels[key] = nil
                continue
            }
            if !shown, let i = m.label.node, g.nodes.indices.contains(i) {
                // A fading name keeps following its note (it may be flying to the edge).
                m.label.c = CGPoint(x: g.nodes[i].s.x + m.label.off.x, y: g.nodes[i].s.y + m.label.off.y)
            }
            g.labels[key] = m
            paint(&ctx, m.label, Double(m.a * m.label.mul))
        }
    }
    static func paint(_ ctx: inout GraphicsContext, _ l: Label, _ a: Double) {
        switch l.kind {
        case .text(let hub): text(&ctx, l, hub, a)
        case .pill(let meta, let tint): pill(&ctx, l, meta, tint, a)
        case .room(let sub, let tint): room(&ctx, l, sub, tint, a)
        case .badge: badge(&ctx, l, a)
        }
    }
    static let ink = RoomGraph.Tint(0x141416)
    /// Note names sit on a dark pill so they stay readable over bright dots.
    static func text(_ ctx: inout GraphicsContext, _ l: Label, _ hub: Bool, _ a: Double) {
        let r = CGRect(x: l.c.x - l.w / 2, y: l.c.y - l.h / 2, width: l.w, height: l.h)
        ctx.fill(Path(roundedRect: r, cornerRadius: l.h / 2), with: .color(ink.color(0.9 * a)))
        let col = hub ? RoomGraph.Tint(0xFFFAF4).color(0.95 * a) : RoomGraphDraw.cream.color(0.8 * a)
        ctx.draw(Text(l.text).font(hub ? fHub : fNode).foregroundColor(col), at: l.c)
    }
    static func pill(_ ctx: inout GraphicsContext, _ l: Label, _ meta: String, _ tint: RoomGraph.Tint, _ a: Double) {
        let r = CGRect(x: l.c.x - l.w / 2, y: l.c.y - l.h / 2, width: l.w, height: l.h)
        let p = Path(roundedRect: r, cornerRadius: l.h / 2)
        ctx.fill(p, with: .color(RoomGraph.Tint(0x1E1D21).color(0.96 * a)))
        ctx.stroke(p, with: .color(tint.color(0.35 * a)), lineWidth: 1)
        let t =
            Text(l.text).font(fPill).foregroundColor(.white.opacity(a))
            + Text("  " + meta).font(fMeta).foregroundColor(RoomGraphDraw.cream.color(0.5 * a))
        ctx.draw(t, at: CGPoint(x: r.minX + 13, y: l.c.y), anchor: .leading)
    }
    static func room(_ ctx: inout GraphicsContext, _ l: Label, _ sub: String, _ tint: RoomGraph.Tint, _ a: Double) {
        let y1: CGFloat = sub.isEmpty ? l.c.y : l.c.y - 8
        halo(&ctx, Text(l.text).font(fRoom), CGPoint(x: l.c.x, y: y1), a)
        ctx.draw(Text(l.text).font(fRoom).foregroundColor(tint.color(a)), at: CGPoint(x: l.c.x, y: y1))
        if !sub.isEmpty {
            halo(&ctx, Text(sub).font(fSub), CGPoint(x: l.c.x, y: l.c.y + 11), a)
            ctx.draw(Text(sub).font(fSub).foregroundColor(RoomGraphDraw.cream.color(0.55 * a)), at: CGPoint(x: l.c.x, y: l.c.y + 11))
        }
    }
    /// A soft dark edge behind room names (the design's text stroke).
    static func halo(_ ctx: inout GraphicsContext, _ t: Text, _ at: CGPoint, _ a: Double) {
        let dark = t.foregroundColor(ink.color(0.55 * a))
        for (dx, dy) in [(-1.5, 0.0), (1.5, 0.0), (0.0, -1.5), (0.0, 1.5)] {
            ctx.draw(dark, at: CGPoint(x: at.x + dx, y: at.y + dy))
        }
    }
    static func badge(_ ctx: inout GraphicsContext, _ l: Label, _ a: Double) {
        let r = CGRect(x: l.c.x - l.w / 2, y: l.c.y - l.h / 2, width: l.w, height: l.h)
        let p = Path(roundedRect: r, cornerRadius: l.h / 2)
        ctx.fill(p, with: .color(RoomGraph.Tint(0x161619).color(0.95 * a)))
        ctx.stroke(p, with: .color(RoomGraphDraw.cream.color(0.14 * a)), lineWidth: 1)
        ctx.draw(Text(l.text).font(fBadge).foregroundColor(RoomGraphDraw.cream.color(0.6 * a)), at: l.c)
    }
}
