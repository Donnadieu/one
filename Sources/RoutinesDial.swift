import AppKit
import Foundation
import SwiftUI

// MARK: - The day dial (Claude Design "Routines View Options", B): a 24-hour ring around the assistant's orb.
// Midnight at the top, noon at the bottom, a "now" hand. Each run today is a mark at its time (filled = done, or made up
// later; half filled = partly done; hollow = still to come; orange = didn't run or did nothing it can show; see
// RoutineRuns.swift for how a run's real outcome is read), the every-few-minutes routines are dotted bands, and every
// mark has a label pushed apart so none overlap. Pure layout, in design points (1152 × 676), so renders and
// the live panel draw the same thing.

enum Dial {
    static let size = CGSize(width: 1152, height: 676)
    static let center = CGPoint(x: 470, y: 366)
    static let r0: CGFloat = 180  // the ring
    static let rl: CGFloat = 228  // where labels start

    enum Kind { case done, partly, failed, running, next, missed, paused }
    /// The legend under the dial. Keep it in step with `mark` below.
    static let legend = "Done · Partly · Didn't run"
    struct Mark: Identifiable {
        var id: String { "\(rid)-\(minute)" }
        let rid: String
        let minute: Int
        let kind: Kind
        let at: CGPoint
    }
    struct Band: Identifiable {
        var id: String { rid }
        let rid: String
        let radius: CGFloat
        let every: Int
        let failed: Bool
    }
    struct Label: Identifiable {
        var id: String { "\(rid)-\(key)" }
        let rid: String
        let key: Int
        let title: String
        let sub: String
        let orange: Bool
        let from: CGPoint  // the mark
        var at: CGPoint  // where the words start (right side) or end (left side)
        let right: Bool
    }
    struct Layout {
        var marks: [Mark] = []
        var bands: [Band] = []
        var labels: [Label] = []
        var later: [Routine] = []  // not today: weekly, once on another day, never ran
        var outside: [Routine] = []
        var nowMinute = 0
    }

    static func point(_ minute: Double, _ r: CGFloat) -> CGPoint {
        let th = minute / 1440 * 2 * .pi
        return CGPoint(x: center.x + r * CGFloat(sin(th)), y: center.y - r * CGFloat(cos(th)))
    }

    static func layout(_ s: RoutinesSnapshot) -> Layout {
        var L = Layout()
        let now = Routines.minutes(s.now)
        L.nowMinute = now
        var bandIndex = 0
        for r in s.routines {
            if r.outside {
                L.outside.append(r)
                continue
            }
            if let every = r.every {
                let deg = 28.0 + 16 * Double(bandIndex)
                let rad = r0 + 10 + 7 * CGFloat(bandIndex)
                bandIndex += 1
                L.bands.append(Band(rid: r.id, radius: rad, every: every, failed: r.needsLook))
                let m = deg / 360 * 1440
                var sub = Routines.every(every).replacingOccurrences(of: "Every ", with: "Every ").replacingOccurrences(of: " minutes", with: " min")
                if let l = r.lastRun { sub += " · " + Routines.clock(Routines.minutes(l)) }
                sub += " " + word(r)
                L.labels.append(
                    Label(
                        rid: r.id, key: -1, title: r.title, sub: sub, orange: r.needsLook, from: point(m, rad), at: point(m, rl), right: true))
                continue
            }
            if r.today.isEmpty {
                if r.state != .finished || (r.lastRun.map { Routines.sameDay($0, s.now) } ?? false) { L.later.append(r) }
                continue
            }
            let past = r.today.filter { $0 <= now }
            let lastMin = r.lastRun.flatMap { Routines.sameDay($0, s.now) ? Routines.minutes($0) : nil }
            let lastRanSlot = lastMin.flatMap { lm in r.today.filter { $0 <= lm }.max() }
            for t in r.today {
                var k: Kind
                var sub = Routines.clock(t)
                if r.state == .paused {
                    k = .paused
                    sub += " · paused"
                } else if t <= now {
                    if r.state == .running && t == past.max() {
                        k = .running
                        sub += " · running now"
                    } else if let lm = lastMin, lm >= t {
                        k = .done
                        if t == lastRanSlot && r.state == .failed { k = r.miss == .partly ? .partly : .failed }
                        sub += " · " + (k == .done ? "done" : Routines.missWord(r))
                    } else {
                        k = .missed
                        sub += " · didn't run"
                    }
                } else {
                    k = .next
                }
                let p = point(Double(t), r0)
                L.marks.append(Mark(rid: r.id, minute: t, kind: k, at: p))
                let th = Double(t) / 1440 * 2 * .pi
                L.labels.append(
                    Label(
                        rid: r.id, key: t, title: r.title, sub: sub, orange: [.failed, .missed].contains(k), from: p,
                        at: point(Double(t), rl), right: sin(th) >= -0.01))
            }
        }
        L.later.sort { ($0.next ?? .distantFuture) < ($1.next ?? .distantFuture) }
        L.labels = spread(L.labels)
        return L
    }

    static func word(_ r: Routine) -> String {
        switch r.state {
        case .worked, .finished: return "done"  // made up later counts as done; its card says when
        case .failed: return Routines.missWord(r)
        case .running: return "running now"
        case .never: return "not run yet"
        case .paused: return "paused"
        }
    }

    /// Pushes labels apart on each side so none overlap (the design's rule: 30 points apart on the right,
    /// working up from the bottom; 32 apart on the left, working down from the top).
    static func spread(_ all: [Label]) -> [Label] {
        var out: [Label] = []
        for side in [true, false] {
            var arr = all.filter { $0.right == side }.sorted { $0.at.y < $1.at.y }
            if arr.count > 1 {
                if side {
                    for i in stride(from: arr.count - 2, through: 0, by: -1) where arr[i].at.y > arr[i + 1].at.y - 30 {
                        arr[i].at.y = arr[i + 1].at.y - 30
                    }
                } else {
                    for i in 1..<arr.count where arr[i].at.y < arr[i - 1].at.y + 32 { arr[i].at.y = arr[i - 1].at.y + 32 }
                }
            }
            out += arr
        }
        return out
    }

    // MARK: Drawing (the ring, ticks, bands, leader lines, marks and the now hand)

    static let orange = Color(hex: 0xF0A04B)
    static let cream = Color(hex: 0xF4EFE8)

    static func draw(_ ctx: inout GraphicsContext, _ L: Layout, pulse: Double) {
        let c = center
        let ring = Path(ellipseIn: CGRect(x: c.x - r0, y: c.y - r0, width: r0 * 2, height: r0 * 2))
        ctx.stroke(ring, with: .color(cream.opacity(0.16)), lineWidth: 1)
        let nowTh = Double(L.nowMinute) / 1440 * 2 * .pi
        var arc = Path()
        arc.addArc(center: c, radius: r0, startAngle: .radians(-.pi / 2), endAngle: .radians(-.pi / 2 + nowTh), clockwise: false)
        ctx.stroke(arc, with: .color(cream.opacity(0.45)), lineWidth: 1.6)
        for hr in 0..<24 {
            let th = Double(hr) / 24 * 2 * .pi
            let l: CGFloat = hr % 6 == 0 ? 7 : 4
            var p = Path()
            p.move(to: CGPoint(x: c.x + (r0 - l) * CGFloat(sin(th)), y: c.y - (r0 - l) * CGFloat(cos(th))))
            p.addLine(to: CGPoint(x: c.x + r0 * CGFloat(sin(th)), y: c.y - r0 * CGFloat(cos(th))))
            ctx.stroke(p, with: .color(cream.opacity(hr % 6 == 0 ? 0.3 : 0.14)), lineWidth: 1)
        }
        for b in L.bands {
            let n = max(1, 1440 / max(1, b.every))
            for i in 0..<n {
                let th = Double(i) / Double(n) * 2 * .pi
                let past = th <= nowTh
                let rr: CGFloat = b.every >= 20 ? 1.3 : 0.9
                let p = CGPoint(x: c.x + b.radius * CGFloat(sin(th)), y: c.y - b.radius * CGFloat(cos(th)))
                let col = b.failed ? orange : cream
                ctx.fill(
                    Path(ellipseIn: CGRect(x: p.x - rr, y: p.y - rr, width: rr * 2, height: rr * 2)), with: .color(col.opacity(past ? 0.42 : 0.14)))
            }
        }
        for l in L.labels {
            var p = Path()
            p.move(to: l.from)
            p.addLine(to: CGPoint(x: l.at.x + (l.right ? 3 : -3), y: l.at.y))
            ctx.stroke(p, with: .color(l.orange ? orange.opacity(0.3) : cream.opacity(0.14)), lineWidth: 0.8)
        }
        for m in L.marks { mark(&ctx, m, pulse: pulse) }
        let hs = CGFloat(sin(nowTh))
        let hc = CGFloat(-cos(nowTh))
        var hand = Path()
        hand.move(to: CGPoint(x: c.x + hs * 80, y: c.y + hc * 80))
        hand.addLine(to: CGPoint(x: c.x + hs * (r0 + 6), y: c.y + hc * (r0 + 6)))
        ctx.stroke(hand, with: .color(Color(hex: 0xFFF4E8, 0.85)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        let tip = CGPoint(x: c.x + hs * (r0 + 6), y: c.y + hc * (r0 + 6))
        ctx.fill(Path(ellipseIn: CGRect(x: tip.x - 2.4, y: tip.y - 2.4, width: 4.8, height: 4.8)), with: .color(Color(hex: 0xFFF6EC)))
    }

    static func dot(_ p: CGPoint, _ r: CGFloat) -> Path { Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)) }

    static func glow(_ ctx: inout GraphicsContext, _ p: CGPoint, _ col: Color, _ a: Double) {
        ctx.fill(dot(p, 14), with: .radialGradient(Gradient(colors: [col.opacity(a), col.opacity(0)]), center: p, startRadius: 0, endRadius: 14))
    }

    static func mark(_ ctx: inout GraphicsContext, _ m: Mark, pulse: Double) {
        let p = m.at
        switch m.kind {
        case .done:
            ctx.fill(dot(p, 6), with: .color(cream))
            var tick = Path()
            tick.move(to: CGPoint(x: p.x - 2.6, y: p.y + 0.2))
            tick.addLine(to: CGPoint(x: p.x - 0.7, y: p.y + 2.1))
            tick.addLine(to: CGPoint(x: p.x + 2.8, y: p.y - 1.9))
            ctx.stroke(tick, with: .color(WorldLook.bg), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        case .failed, .missed:  // didn't run: one look
            glow(&ctx, p, orange, 0.35)
            ctx.fill(dot(p, 6), with: .color(orange))
            var x = Path()
            x.move(to: CGPoint(x: p.x - 2, y: p.y - 2))
            x.addLine(to: CGPoint(x: p.x + 2, y: p.y + 2))
            x.move(to: CGPoint(x: p.x + 2, y: p.y - 2))
            x.addLine(to: CGPoint(x: p.x - 2, y: p.y + 2))
            ctx.stroke(x, with: .color(WorldLook.bg), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        case .partly:
            // Half filled, calm cream (not orange): some of it worked.
            ctx.fill(dot(p, 6), with: .color(WorldLook.bg))
            var half = Path()
            half.addArc(center: p, radius: 6, startAngle: .degrees(90), endAngle: .degrees(270), clockwise: false)
            half.closeSubpath()
            ctx.fill(half, with: .color(cream))
            ctx.stroke(dot(p, 5.4), with: .color(cream.opacity(0.9)), lineWidth: 1.2)
        case .running:
            glow(&ctx, p, Color(hex: 0xFFF0E0), 0.35 + 0.25 * pulse)
            ctx.fill(dot(p, 4.5), with: .color(Color(hex: 0xFFF6EC)))
        case .next:
            ctx.fill(dot(p, 5), with: .color(WorldLook.bg))
            ctx.stroke(dot(p, 5), with: .color(cream.opacity(0.65)), lineWidth: 1.3)
        case .paused:
            ctx.fill(dot(p, 5), with: .color(WorldLook.bg))
            ctx.stroke(dot(p, 5), with: .color(cream.opacity(0.25)), style: StrokeStyle(lineWidth: 1.2, dash: [2, 2]))
        }
    }

    // MARK: Skills as stars (every one, no cap): a cluster on the right; the ones made for you shine brighter.

    struct Star {
        let index: Int
        let at: CGPoint
        let r: CGFloat
        let a: Double
    }

    static func stars(_ skills: [SkillStar], center c: CGPoint, radius: CGFloat) -> [Star] {
        skills.enumerated().map { i, s in
            var h: UInt64 = 1_469_598_103_934_665_603
            for b in s.path.utf8 {
                h ^= UInt64(b)
                h = h &* 1_099_511_628_211
            }
            let u1 = Double(h & 0xFFFF) / 65535
            let u2 = Double((h >> 16) & 0xFFFF) / 65535
            let u3 = Double((h >> 32) & 0xFFFF) / 65535
            let ang = u1 * 2 * .pi
            let rad = (s.mine ? 0.55 : 1.0) * sqrt(u2) * Double(radius)
            let at = CGPoint(x: c.x + CGFloat(cos(ang) * rad), y: c.y + CGFloat(sin(ang) * rad * 0.92))
            return Star(index: i, at: at, r: s.mine ? 1.9 : 0.8 + CGFloat(u3) * 0.6, a: s.mine ? 0.95 : 0.3 + u3 * 0.3)
        }
    }
}

// MARK: - Render-only (`One --render-routines <png>`, from a test copy): the panel over today's real routines
// and skills (read only), with one made-up "want me to save…?" question so that moment shows.
enum RoutinesRender {
    static func cli(_ args: [String]) {
        guard let k = args.firstIndex(of: "--render-routines"), k + 1 < args.count else { return }
        MainActor.assumeIsolated { png(args[k + 1]) }
        exit(0)
    }
    @MainActor static func png(_ path: String) {
        HomeView.still = true
        let m = Model.shared
        m.assistantName = "Elias"
        let h = Helper(title: "Canvas price options", task: "", state: "done", line: "")
        m.helpers = [h]
        m.learning.offers = [LearnOffer(kind: "ask", job: UUID(), helper: h.id, line: Learning.askLine)]
        let real = TestWorld.realSupport.appendingPathComponent("hermes/cron")
        var s = RoutinesSnapshot(now: Date())
        s.routines = Routines.jobs(at: real, now: s.now)
        s.skills = Routines.skills()
        // ONE_RENDER_PICK=<title>: open that routine's card instead of the first one that needs a look.
        let pick = ProcessInfo.processInfo.environment["ONE_RENDER_PICK"].flatMap { t in s.routines.first { $0.title == t }?.id }
        let v = RoutinesPanel(m: m, fixed: s, sel: pick, picked: pick != nil).frame(width: 1200, height: 740).background(WorldLook.bg)
        let r = ImageRenderer(content: v)
        r.scale = 2
        if let img = r.nsImage, let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t),
            let d = rep.representation(using: .png, properties: [:])
        {
            try? d.write(to: URL(fileURLWithPath: path))
            print("wrote \(path)")
        }
    }
}
