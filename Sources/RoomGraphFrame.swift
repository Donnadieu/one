import AppKit
import SwiftUI

// MARK: - One animation frame of the rooms map: camera flight, where every room and note sits on
// screen, what the pointer is over, and the slow ambient drift. Drawing reads what this leaves behind.

extension RoomGraph {
    /// Moves everything forward by `dt` seconds (capped like the design so a stall never jumps).
    func step(_ dtIn: Double) {
        let dt = min(0.05, max(0, dtIn))
        clock += dt
        lastDt = dt
        tick()
        for i in ralpha.indices { ralpha[i] = max(0.05, ralpha[i] * 0.985) }
        let vp = viewport
        let ease = CGFloat(min(1, dt * 6))
        vc.x += (vp.midX - vc.x) * ease
        vc.y += (vp.midY - vc.y) * ease
        flyCamera(dt)
        if focus != nil { lastFocus = focus }
        fa += ((focus != nil ? 1 : 0) - fa) * CGFloat(min(1, dt * 3.4))
        placeRoomsOnScreen()
        squeezeOthers(vp)
        placeNotesOnScreen()
        hitTest()
        lightUp(dt)
        writePulses(dt)
    }
    private func flyCamera(_ dt: Double) {
        guard flying else { return }
        let e = CGFloat(min(1, dt * 4.2))
        cam.k = exp(log(cam.k) + (log(tgt.k) - log(cam.k)) * e)
        cam.w.x += (tgt.w.x - cam.w.x) * e
        cam.w.y += (tgt.w.y - cam.w.y) * e
        if abs(cam.k - tgt.k) < 0.0005 && abs(cam.w.x - tgt.w.x) < 0.2 && abs(cam.w.y - tgt.w.y) < 0.2 {
            cam = tgt
            flying = false
        }
    }
    var fe: CGFloat { fa * fa * (3 - 2 * fa) }
    private func placeRoomsOnScreen() {
        let t = clock
        for i in rooms.indices {
            let fi = Double(i)
            let x = rooms[i].b.x + CGFloat(sin(t * 0.05 + fi * 1.7)) * 7
            let y = rooms[i].b.y + CGFloat(cos(t * 0.043 + fi * 2.3)) * 6
            disp[i] = Disp(p: screen(x, y), s: cam.k, mini: 0)
        }
        orb = Disp(p: screen(0, 0), s: min(1.35, max(0.5, cam.k * 0.95)), mini: 0)
    }
    /// Inside a room, the other rooms and the orb shrink and move to a ring just outside it, each on
    /// the side it really lies toward, turned only as far as needed to stay on screen and apart.
    private func squeezeOthers(_ vp: CGRect) {
        let e = fe
        guard e > 0.001, let fi = lastFocus, rooms.indices.contains(fi) else { return }
        let fc = disp[fi].p
        let keep: CGFloat = rooms[fi].R * 1.12 * disp[fi].s + 70
        let safe = CGRect(x: 50, y: 130, width: vp.maxX - 40, height: max(10, size.height - 130 - 118))
        var items: [(i: Int, a: Double)] = []
        for i in rooms.indices where i != fi {
            items.append((i, Double(atan2(rooms[i].b.y - rooms[fi].b.y, rooms[i].b.x - rooms[fi].b.x))))
        }
        items.append((-1, Double(atan2(-rooms[fi].b.y, -rooms[fi].b.x))))
        let gap: Double = Double(130 / keep)
        var taken: [Double] = []
        for k in items.indices {
            items[k].a = RoomGraph.freeSpot(items[k].a, fc, keep, safe, taken, gap)
            taken.append(items[k].a)
        }
        for it in items {
            let p = CGPoint(x: fc.x + CGFloat(cos(it.a)) * keep, y: fc.y + CGFloat(sin(it.a)) * keep)
            if it.i == -1 {
                orb.p = RoomGraph.mix(orb.p, p, e)
                orb.s += (0.4 - orb.s) * e
            } else {
                disp[it.i].p = RoomGraph.mix(disp[it.i].p, p, e)
                disp[it.i].s += (30 / (rooms[it.i].R * 1.12) - disp[it.i].s) * e
                disp[it.i].mini = e
            }
        }
    }
    /// The angle nearest `a` whose spot on the ring is on screen and not too close to a taken one.
    static func freeSpot(_ a: Double, _ c: CGPoint, _ r: CGFloat, _ safe: CGRect, _ taken: [Double], _ gap: Double) -> Double {
        var fallback: Double?
        for step in 0..<46 {
            for sign in [1.0, -1.0] {
                let b = a + sign * Double(step) * 4 * .pi / 180
                let p = CGPoint(x: c.x + CGFloat(cos(b)) * r, y: c.y + CGFloat(sin(b)) * r)
                guard safe.contains(p) else { continue }
                if fallback == nil { fallback = b }
                let clear = taken.allSatisfy { t in
                    let d = abs(remainder(t - b, 2 * .pi))
                    return d >= gap
                }
                if clear { return b }
            }
        }
        return fallback ?? a
    }
    static func mix(_ a: CGPoint, _ b: CGPoint, _ e: CGFloat) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * e, y: a.y + (b.y - a.y) * e) }
    static func edgePoint(_ dx: CGFloat, _ dy: CGFloat, _ ins: CGRect, _ c: CGPoint) -> CGPoint {
        let d = max(hypot(dx, dy), 1)
        let ux = dx / d
        let uy = dy / d
        let tx: CGFloat = ux > 1e-3 ? (ins.maxX - c.x) / ux : ux < -1e-3 ? (ins.minX - c.x) / ux : 1e9
        let ty: CGFloat = uy > 1e-3 ? (ins.maxY - c.y) / uy : uy < -1e-3 ? (ins.minY - c.y) / uy : 1e9
        let tt = min(tx, ty)
        return CGPoint(x: c.x + ux * tt, y: c.y + uy * tt)
    }
    static func separate(_ items: inout [(i: Int, p: CGPoint)], _ ins: CGRect) {
        for _ in 0..<6 {
            for a in items.indices {
                for b in items.indices where b > a {
                    let dx = items[b].p.x - items[a].p.x
                    let dy = items[b].p.y - items[a].p.y
                    let d = max(hypot(dx, dy), 1)
                    if d < 120 {
                        let m = (120 - d) / 2 / d
                        items[a].p.x -= dx * m
                        items[a].p.y -= dy * m
                        items[b].p.x += dx * m
                        items[b].p.y += dy * m
                    }
                    items[a].p = clampPt(items[a].p, ins)
                    items[b].p = clampPt(items[b].p, ins)
                }
            }
        }
    }
    static func clampPt(_ p: CGPoint, _ r: CGRect) -> CGPoint { CGPoint(x: min(r.maxX, max(r.minX, p.x)), y: min(r.maxY, max(r.minY, p.y))) }
    private func placeNotesOnScreen() {
        let t = clock
        for i in nodes.indices {
            let d = disp[nodes[i].room]
            let rb = rooms[nodes[i].room].b
            let wx = nodes[i].p.x + CGFloat(sin(t * 0.25 + nodes[i].ph)) * 1.2 - rb.x
            let wy = nodes[i].p.y + CGFloat(cos(t * 0.21 + nodes[i].ph)) * 1.2 - rb.y
            nodes[i].s = CGPoint(x: d.p.x + wx * d.s, y: d.p.y + wy * d.s)
            nodes[i].sr = nodes[i].r * pow(d.s, 0.65)
        }
    }
    private func hitTest() {
        hoverNode = nil
        hoverRoom = nil
        hoverOrb = false
        if let d = dragNode {
            hoverNode = d
            return
        }
        guard ptrInside, !panning, ptr.y > 70, ptr.y < size.height - 72, !(readerOpen && ptr.x > size.width - 400) else { return }
        var best = CGFloat.infinity
        for i in nodes.indices where disp[nodes[i].room].mini <= 0.5 {
            let rad = max(nodes[i].sr + 4, 7)
            let dx = nodes[i].s.x - ptr.x
            let dy = nodes[i].s.y - ptr.y
            let d2 = dx * dx + dy * dy
            if d2 < rad * rad && d2 < best {
                best = d2
                hoverNode = i
            }
        }
        guard hoverNode == nil else { return }
        for i in rooms.indices {
            let d = disp[i]
            let rad = d.mini > 0.5 ? 38 : rooms[i].R * 1.15 * d.s
            if hypot(ptr.x - d.p.x, ptr.y - d.p.y) < rad { hoverRoom = i }
        }
        if hypot(ptr.x - orb.p.x, ptr.y - orb.p.y) < 70 * orb.s {
            hoverOrb = true
            hoverRoom = nil
        }
    }
    private func lightUp(_ dt: Double) {
        let act = hoverNode ?? selected
        if act != activeId {
            activeId = act
            nb = Set(act.map { adj[$0] } ?? [])
        }
        dimA += ((act != nil ? 1 : 0) - dimA) * (frozen ? 1 : CGFloat(min(1, dt * 7)))
        for i in rooms.indices {
            let on: CGFloat = hoverRoom == i && act == nil ? 1 : 0
            roomHL[i] += (on - roomHL[i]) * CGFloat(min(1, dt * 6))
        }
    }
    /// Every few seconds a light travels from the orb to a note: the assistant writing something down.
    private func writePulses(_ dt: Double) {
        energy *= exp(-dt * 1.2)
        pulses.removeAll { clock - $0.t0 > 3 }
        guard !frozen, clock > nextPulse, !nodes.isEmpty else { return }
        var ri = 0
        if let f = focus, rnd() < 0.7 {
            ri = f
        } else {
            var x = rnd() * Double(nodes.count)
            while ri < rooms.count - 1 && x > Double(byRoom[ri].count) {
                x -= Double(byRoom[ri].count)
                ri += 1
            }
        }
        guard let pick = byRoom[ri].randomElement() else { return }
        pulses.append(Pulse(room: ri, node: pick, t0: clock))
        energy = 1
        nextPulse = clock + 5.5 + rnd() * 4
    }

    // MARK: Pointer

    var cursorWants: NSCursor {
        if dragNode != nil || panning { return .closedHand }
        if hoverNode != nil { return .pointingHand }
        if let h = hoverRoom, h != focus { return .pointingHand }
        if hoverOrb && focus != nil { return .pointingHand }
        return .openHand
    }
    /// A click (no drag): a note opens, a room flies in, the orb or empty space flies back out.
    func click(at p: CGPoint) {
        ptr = p
        ptrInside = true
        hitTest()
        if let n = hoverNode {
            select(n)
        } else if let r = hoverRoom, r != focus {
            go(room: r)
        } else if hoverOrb && focus != nil {
            go(room: nil)
        } else if hoverRoom == nil && selected != nil {
            select(nil)
        }
    }
    func dragNote(_ i: Int, to p: CGPoint) {
        let d = disp[nodes[i].room]
        let rb = rooms[nodes[i].room].b
        nodes[i].p = CGPoint(x: rb.x + (p.x - d.p.x) / d.s, y: rb.y + (p.y - d.p.y) / d.s)
        ralpha[nodes[i].room] = max(ralpha[nodes[i].room], 0.45)
    }
    /// Esc: close the note first, then leave the room.
    func back() {
        if selected != nil {
            select(nil)
        } else if focus != nil {
            go(room: nil)
        }
    }
}
