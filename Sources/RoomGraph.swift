import AppKit
import SwiftUI

// MARK: - Your rooms as a living map (Claude Design "Rooms Map"): the assistant's orb in the middle,
// each room a soft glowing circle threaded to it, notes as small lights joined by curved threads.
// Notes spread themselves out, drag to move them, click a room to fly in, scroll or pinch to zoom.

@MainActor
final class RoomGraph: ObservableObject {
    struct Tint {
        let r: Double
        let g: Double
        let b: Double
        init(_ hex: UInt32) {
            r = Double((hex >> 16) & 0xFF) / 255
            g = Double((hex >> 8) & 0xFF) / 255
            b = Double(hex & 0xFF) / 255
        }
        func color(_ a: Double) -> Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
        /// Mixed toward warm white by `w` (0 = room colour, 1 = white).
        func light(_ w: Double, _ a: Double) -> Color {
            Color(.sRGB, red: r + (1 - r) * w, green: g + (0.98 - g) * w, blue: b + (0.957 - b) * w, opacity: a)
        }
    }
    struct Room {
        let name: String
        let sub: String
        let tint: Tint
        let shared: String?
        var R: CGFloat
        var b: CGPoint
    }
    struct Node {
        let id: String
        let name: String
        let room: Int
        let hub: Bool
        let ph: Double
        var deg = 0
        var rank = 0
        var big = false
        var p: CGPoint
        var v = CGVector.zero
        var r: CGFloat = 2
        var s = CGPoint.zero
        var sr: CGFloat = 1
    }
    struct Link {
        let s: Int
        let t: Int
        let bend: CGFloat
    }
    struct Cross {
        let a: Int
        let b: Int
        let n: Int
    }
    struct Disp {
        var p = CGPoint.zero
        var s: CGFloat = 1
        var mini: CGFloat = 0
    }
    struct Pulse {
        let room: Int
        let node: Int
        let t0: Double
    }

    // What SwiftUI needs to know about (header, reader).
    @Published var focus: Int?
    @Published var selected: Int?
    @Published var zoomTick = 0

    var infos: [RoomInfo] = []
    var rooms: [Room] = []
    var nodes: [Node] = []
    var links: [Link] = []
    var adj: [[Int]] = []
    var byRoom: [[Int]] = []
    var cross: [Cross] = []
    var sprites: [NSImage] = []
    var orbSprite: NSImage?
    var ralpha: [CGFloat] = []

    // Camera: world point `w` sits at the viewport centre `vc`, `k` = zoom.
    var cam = (k: CGFloat(1), w: CGPoint.zero)
    var tgt = (k: CGFloat(1), w: CGPoint.zero)
    var vc = CGPoint.zero
    var flying = false
    var inited = false
    var size = CGSize(width: 1, height: 1)
    var frameInWindow = CGRect.zero

    // Per-frame state.
    var clock: Double = 0
    var lastDt: Double = 1.0 / 60
    var last: Double?
    var frozen = false
    var fa: CGFloat = 0
    var lastFocus: Int?
    var disp: [Disp] = []
    var orb = Disp()
    var dimA: CGFloat = 0
    var activeId: Int?
    var nb = Set<Int>()
    var roomHL: [CGFloat] = []
    var energy: Double = 0
    var pulses: [Pulse] = []
    var nextPulse: Double = 2.5
    var labels: [String: RoomLabels.Memory] = [:]

    // Pointer.
    var ptr = CGPoint(x: -1e4, y: -1e4)
    var ptrInside = false
    var hoverNode: Int?
    var hoverRoom: Int?
    var hoverOrb = false
    var dragNode: Int?
    var panning = false
    private var seed: UInt32 = 20_261_026

    func rnd() -> Double {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        return Double(seed) / 4_294_967_296
    }

    // MARK: Building the map from the brain

    static func tint(_ info: RoomInfo, _ i: Int) -> UInt32 {
        if info.shared != nil || info.id.hasPrefix("cofounder") { return 0xEEA89C }
        if info.id == "personal-room" { return 0xF5D0AC }
        if info.id == "work-room" { return 0xE9C784 }
        let extra: [UInt32] = [0xD6C8EC, 0x9FC9B0, 0xA9C1E8, 0xE6A9C4]
        return extra[i % extra.count]
    }
    static func shortName(_ title: String) -> String {
        title.lowercased().hasSuffix(" room") && title.count > 5 ? String(title.dropLast(5)) : title
    }

    func load(_ infos: [RoomInfo]) {
        self.infos = infos
        seed = 20_261_026
        var rs: [Room] = []
        var ns: [Node] = []
        var index: [String: Int] = [:]
        for (ri, info) in infos.enumerated() {
            let real = info.notes.filter { !$0.id.hasPrefix("room:") }
            let sub = (real.count == 1 ? "1 note" : "\(real.count) notes") + (info.shared.map { " · " + $0 } ?? "")
            let R = 12.5 * CGFloat(Double(max(real.count, 1)).squareRoot()) + 8
            rs.append(
                Room(name: RoomGraph.shortName(info.title), sub: sub, tint: Tint(RoomGraph.tint(info, ri)), shared: info.shared, R: R, b: .zero))
            for n in real where index[n.id] == nil {
                index[n.id] = ns.count
                ns.append(Node(id: n.id, name: n.title, room: ri, hub: n.hub, ph: rnd() * 6.28, p: .zero))
            }
        }
        rooms = rs
        placeRooms()
        nodes = ns
        buildLinks(infos, index)
        seedPositions()
        byRoom = rooms.indices.map { ri in nodes.indices.filter { nodes[$0].room == ri } }
        ranks()
        cross = RoomGraph.crossings(infos)
        sprites = rooms.map { RoomSprite.make($0.tint) }
        orbSprite = RoomSprite.make(Tint(0xFFECD6))
        ralpha = rooms.map { _ in 1 }
        disp = rooms.map { _ in Disp() }
        roomHL = rooms.map { _ in 0 }
        settle()
        inited = false
    }
    private func buildLinks(_ infos: [RoomInfo], _ index: [String: Int]) {
        var seen = Set<Int>()
        var ls: [Link] = []
        for info in infos {
            for n in info.notes {
                guard let a = index[n.id] else { continue }
                for t in n.links {
                    guard let b = index[t], a != b, nodes[a].room == nodes[b].room else { continue }
                    let key = min(a, b) * 100_000 + max(a, b)
                    if seen.contains(key) { continue }
                    seen.insert(key)
                    let bend = CGFloat((rnd() < 0.5 ? -1 : 1) * (0.1 + rnd() * 0.14))
                    ls.append(Link(s: a, t: b, bend: bend))
                    nodes[a].deg += 1
                    nodes[b].deg += 1
                }
            }
        }
        links = ls
        adj = nodes.map { _ in [] }
        for l in ls {
            adj[l.s].append(l.t)
            adj[l.t].append(l.s)
        }
    }
    private func seedPositions() {
        for i in nodes.indices {
            let r = rooms[nodes[i].room]
            let a = rnd() * 6.28
            let d = nodes[i].hub ? 0 : CGFloat(0.25 + rnd() * 0.6) * r.R
            nodes[i].p = CGPoint(x: r.b.x + CGFloat(cos(a)) * d, y: r.b.y + CGFloat(sin(a)) * d)
            nodes[i].r = 1.6 + CGFloat(Double(nodes[i].deg).squareRoot()) * 1.1 + (nodes[i].hub ? 1 : 0)
        }
    }
    /// Most-linked notes first in each room: they get their names shown first.
    private func ranks() {
        for ids in byRoom {
            let sorted = ids.sorted { a, b in
                nodes[a].hub != nodes[b].hub ? nodes[a].hub : nodes[a].deg > nodes[b].deg
            }
            let bigCut = max(6, sorted.count > 10 ? nodes[sorted[min(sorted.count - 1, sorted.count / 12)]].deg : 6)
            for (k, i) in sorted.enumerated() {
                nodes[i].rank = k
                nodes[i].big = nodes[i].hub || nodes[i].deg >= bigCut
            }
        }
    }
    static func crossings(_ infos: [RoomInfo]) -> [Cross] {
        var out: [Cross] = []
        for i in infos.indices {
            for j in infos.indices where j > i {
                let n = (infos[i].crossed[j] ?? 0) + (infos[j].crossed[i] ?? 0)
                if n > 0 { out.append(Cross(a: i, b: j, n: n)) }
            }
        }
        return out
    }
    /// Rooms sit around the orb (like the design: personal up right, work down right, shared left),
    /// then get pushed apart until no two circles (and their names) come close.
    func placeRooms() {
        // Known rooms take the design's spots first; any other room goes to the emptiest direction left.
        var angle: [Int: Double] = [:]
        for i in rooms.indices {
            let info = infos[i]
            if info.shared != nil || info.id.hasPrefix("cofounder") {
                angle[i] = 180
            } else if info.id == "personal-room" {
                angle[i] = -62
            } else if info.id == "work-room" {
                angle[i] = 52
            }
            if let a = angle[i], angle.contains(where: { $0.key != i && abs($0.value - a) < 1 }) { angle[i] = nil }
        }
        let pairs = RoomGraph.crossings(infos)
        for i in rooms.indices where angle[i] == nil {
            let arcs = pairs.compactMap { p -> (Double, Double)? in
                guard let a = angle[p.a], let b = angle[p.b] else { return nil }
                return (a, b)
            }
            angle[i] = RoomGraph.freeAngle(Array(angle.values), arcs)
        }
        for i in rooms.indices {
            let ang = angle[i] ?? 0
            let D = 150 + rooms[i].R
            rooms[i].b = CGPoint(x: CGFloat(cos(ang * .pi / 180)) * D, y: CGFloat(sin(ang * .pi / 180)) * D)
        }
        spreadRooms()
    }
    static func angleGap(_ a: Double, _ b: Double) -> Double {
        let d = abs((a - b).truncatingRemainder(dividingBy: 360))
        return min(d, 360 - d)
    }
    /// The emptiest direction around the orb that no "facts crossed" arc runs through.
    static func freeAngle(_ used: [Double], _ arcs: [(Double, Double)]) -> Double {
        var best = 118.0
        var bestScore = -Double.infinity
        for k in 0..<24 {
            let c = Double(k) * 15 - 180
            var score = used.map { angleGap($0, c) }.min() ?? 180
            for (a, b) in arcs where angleGap(a, c) + angleGap(c, b) <= angleGap(a, b) + 0.5 { score -= 1000 }
            if score > bestScore {
                bestScore = score
                best = c
            }
        }
        return best
    }
    private func spreadRooms() {
        let gap: CGFloat = 96
        for _ in 0..<300 {
            var moved = false
            for i in rooms.indices {
                // Keep clear of the orb.
                let d0 = max(hypot(rooms[i].b.x, rooms[i].b.y), 0.1)
                let need0 = 112 + rooms[i].R * 1.12
                if d0 < need0 {
                    rooms[i].b = CGPoint(x: rooms[i].b.x / d0 * need0, y: rooms[i].b.y / d0 * need0)
                    moved = true
                }
                for j in rooms.indices where j > i {
                    if push(i, j, gap) { moved = true }
                }
            }
            if !moved { break }
        }
    }
    private func push(_ i: Int, _ j: Int, _ gap: CGFloat) -> Bool {
        let dx = rooms[j].b.x - rooms[i].b.x
        let dy = rooms[j].b.y - rooms[i].b.y
        let d = max(hypot(dx, dy), 0.1)
        let need = (rooms[i].R + rooms[j].R) * 1.12 + gap
        guard d < need else { return false }
        let m = (need - d) / 2 / d
        let wi = rooms[j].R / (rooms[i].R + rooms[j].R)
        let wj = 1 - wi
        rooms[i].b.x -= dx * m * 2 * wi
        rooms[i].b.y -= dy * m * 2 * wi
        rooms[j].b.x += dx * m * 2 * wj
        rooms[j].b.y += dy * m * 2 * wj
        return true
    }

    // MARK: Moving the notes (same forces as the design)

    func settle() {
        for i in 0..<320 {
            for r in ralpha.indices { ralpha[r] = 1 - CGFloat(i) / 400 }
            tick()
        }
        for r in ralpha.indices { ralpha[r] = 0.05 }
    }
    func tick() {
        for ri in rooms.indices { repel(ri) }
        springs()
        for i in nodes.indices {
            if dragNode == i {
                nodes[i].v = .zero
                continue
            }
            nodes[i].v.dx *= 0.62
            nodes[i].v.dy *= 0.62
            nodes[i].p.x += min(8, max(-8, nodes[i].v.dx))
            nodes[i].p.y += min(8, max(-8, nodes[i].v.dy))
        }
    }
    private func repel(_ ri: Int) {
        let a = ralpha[ri]
        let arr = byRoom[ri]
        let rm = rooms[ri]
        for x in arr.indices {
            let i = arr[x]
            for y in (x + 1)..<arr.count {
                let j = arr[y]
                var dx: CGFloat = nodes[i].p.x - nodes[j].p.x
                var dy: CGFloat = nodes[i].p.y - nodes[j].p.y
                var d2: CGFloat = dx * dx + dy * dy
                if d2 > 4900 { continue }
                if d2 < 1 {
                    dx = CGFloat(rnd() - 0.5)
                    dy = CGFloat(rnd() - 0.5)
                    d2 = 1
                }
                let inv: CGFloat = 150 * a / (d2 * d2.squareRoot())
                nodes[i].v.dx += dx * inv
                nodes[i].v.dy += dy * inv
                nodes[j].v.dx -= dx * inv
                nodes[j].v.dy -= dy * inv
            }
            let cx: CGFloat = nodes[i].p.x - rm.b.x
            let cy: CGFloat = nodes[i].p.y - rm.b.y
            let cd: CGFloat = max(hypot(cx, cy), 1)
            let pull: CGFloat = 0.0025 * a + (cd > rm.R ? (cd - rm.R) * 0.06 / cd : 0)
            nodes[i].v.dx -= cx * pull
            nodes[i].v.dy -= cy * pull
        }
    }
    private func springs() {
        for l in links {
            let a = ralpha[nodes[l.s].room]
            let dx: CGFloat = nodes[l.t].p.x - nodes[l.s].p.x
            let dy: CGFloat = nodes[l.t].p.y - nodes[l.s].p.y
            let d: CGFloat = max(hypot(dx, dy), 1)
            let f: CGFloat = (d - 24) * 0.035 * a / d
            nodes[l.s].v.dx += dx * f
            nodes[l.s].v.dy += dy * f
            nodes[l.t].v.dx -= dx * f
            nodes[l.t].v.dy -= dy * f
        }
    }

    // MARK: Looking around

    var readerOpen: Bool { selected != nil }
    var viewport: CGRect {
        let r: CGFloat = size.width - (readerOpen ? 400 : 40)
        return CGRect(x: 40, y: 96, width: max(r - 40, 10), height: max(size.height - 84 - 96, 10))
    }
    func fit() {
        let vp = viewport
        if let f = focus, rooms.indices.contains(f) {
            let r = rooms[f]
            let e = r.R * 1.16
            tgt.k = min(3.2, max(0.6, min((vp.width - 150) / (2 * e), (vp.height - 10) / (2 * e))))
            tgt.w = CGPoint(x: r.b.x, y: r.b.y)
        } else {
            var x0: CGFloat = -110
            var x1: CGFloat = 110
            var y0: CGFloat = -110
            var y1: CGFloat = 110
            for r in rooms {
                let e = r.R * 1.14
                x0 = min(x0, r.b.x - e)
                x1 = max(x1, r.b.x + e)
                y0 = min(y0, r.b.y - e - 44)
                y1 = max(y1, r.b.y + e + 30)
            }
            tgt.k = min(1.6, max(0.35, min(vp.width / (x1 - x0), vp.height / (y1 - y0))))
            tgt.w = CGPoint(x: (x0 + x1) / 2, y: (y0 + y1) / 2)
        }
        flying = true
    }
    func zoomAt(_ p: CGPoint, _ f: CGFloat) {
        let k2 = min(4.5, max(0.3, cam.k * f))
        let wx = cam.w.x + (p.x - vc.x) / cam.k
        let wy = cam.w.y + (p.y - vc.y) / cam.k
        cam.w = CGPoint(x: wx - (p.x - vc.x) / k2, y: wy - (p.y - vc.y) / k2)
        cam.k = k2
        tgt = cam
        flying = false
    }
    func zoomButton(_ f: CGFloat) {
        tgt = cam
        flying = false
        let vp = viewport
        zoomAt(CGPoint(x: vp.midX, y: vp.midY), f)
    }
    func pan(by d: CGSize) {
        cam.w = CGPoint(x: cam.w.x - d.width / cam.k, y: cam.w.y - d.height / cam.k)
        tgt = cam
        flying = false
    }
    func setSize(_ s: CGSize) {
        guard s.width > 50, s.height > 50, s != size || !inited else { return }
        size = s
        if !inited {
            vc = CGPoint(x: viewport.midX, y: viewport.midY)
            fit()
            cam = tgt
            fa = focus == nil ? 0 : 1
            lastFocus = focus
            flying = false
            inited = true
        } else {
            fit()
        }
    }
    func go(room: Int?) {
        if let s = selected, room != nil, nodes[s].room != room { selected = nil }
        if room == nil { selected = nil }
        focus = room
        fit()
    }
    func select(_ i: Int?) {
        selected = i
        fit()
    }
    func note(_ i: Int) -> RoomNote? {
        guard nodes.indices.contains(i) else { return nil }
        let id = nodes[i].id
        return infos.lazy.flatMap(\.notes).first { $0.id == id }
    }
    /// Renders only: open the map inside a room (by name) and optionally with a note open (by title, or the room's main note).
    func start(room: String?, note: String? = nil, mainNote: Bool = false) {
        focus = room.flatMap { r in rooms.firstIndex { $0.name.lowercased() == r.lowercased() } }
        guard let f = focus ?? (note != nil || mainNote ? 0 : nil) else { return }
        if let t = note {
            selected = nodes.indices.first { nodes[$0].name == t }
        } else if mainNote {
            selected = byRoom[f].first { nodes[$0].hub } ?? byRoom[f].max { nodes[$0].deg < nodes[$1].deg }
        }
    }
    /// Renders only: run the clock until the camera has landed, with names shown at once.
    func prepareStill(_ s: CGSize) {
        frozen = true
        setSize(s)
        for _ in 0..<150 { step(1.0 / 30) }
    }
    func screen(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: vc.x + (x - cam.w.x) * cam.k, y: vc.y + (y - cam.w.y) * cam.k) }
}

// MARK: - Soft glow sprite per room colour (drawn once, reused for every note)

enum RoomSprite {
    static func make(_ c: RoomGraph.Tint) -> NSImage {
        let side = 64
        let img = NSImage(size: NSSize(width: side, height: side))
        img.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            let comps: [CGFloat] = [
                c.r, c.g, c.b, 1, c.r, c.g, c.b, 0.5, c.r, c.g, c.b, 0.12, c.r, c.g, c.b, 0,
            ].map { CGFloat($0) }
            let locs: [CGFloat] = [0, 0.16, 0.45, 1]
            if let g = CGGradient(colorSpace: cs, colorComponents: comps, locations: locs, count: 4) {
                let mid = CGPoint(x: 32, y: 32)
                ctx.drawRadialGradient(g, startCenter: mid, startRadius: 0, endCenter: mid, endRadius: 32, options: [])
            }
        }
        img.unlockFocus()
        return img
    }
}
