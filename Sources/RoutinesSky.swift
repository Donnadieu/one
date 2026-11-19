import SwiftUI

// MARK: - The routines as constellations (Claude Design "One Routines Redesign", Option 1, picked by Omar Nov 18 2026:
// "It feels like it's just popping out at me … square, rectangle, rectangle"). No list box, no pop-up card: each group
// (the assistant, each room, each bot, outside One, looks done, finished) is a small star figure with its count; one
// opens at a time and its routines hang in one column on a thread a slow light travels down, like the old dot bands.
// A picked routine opens in place under its own star, and a thread joins it to its mark on the dial.

enum Sky {
    /// The routines' place on the stage (the old list's, a little wider); the skills' stars sit under it.
    static var area: CGRect { Dial.listBox }
    static let colW: CGFloat = 116  // one figure
    static let figH: CGFloat = 46  // a row of figures
    static let figTop: CGFloat = 30  // under the Who it's for / How often switch
    static let rowH: CGFloat = 36  // one routine: its name and its status
    static let starY: CGFloat = 10  // a routine's star, from its row's top
    static let speed = 38.0  // the travelling light, points a second

    static func figuresHeight(_ groups: Int) -> CGFloat { CGFloat((groups + 2) / 3) * figH }
    static func figOrigin(_ i: Int) -> CGPoint { CGPoint(x: CGFloat(i % 3) * colW, y: CGFloat(i / 3) * figH) }

    /// 0…1, the same for the same routine every time (FNV-1a), so the stars never jump.
    static func hash(_ s: String, _ k: Int) -> Double {
        var h: UInt64 = 1_469_598_103_934_665_603 &+ UInt64(k) &* 7919
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 1_099_511_628_211
        }
        return Double((h >> 17) & 0xFFFF) / 65535
    }

    /// The open group: the picked routine's, else the one tapped, else one with something that needs a look, else the first.
    static func open(_ gs: [RoutineList.Group], sel: String?, chosen: String?) -> String? {
        if let sel, let g = gs.first(where: { $0.rows.contains { $0.id == sel } }) { return g.id }
        if let chosen, gs.contains(where: { $0.id == chosen }) { return chosen }
        return (gs.first { $0.rows.contains(where: \.needsLook) } ?? gs.first { !$0.clearable } ?? gs.first)?.id
    }

    /// Each row's top in the open group's column; the picked row leaves room under it for its details.
    static func rowTops(_ n: Int, picked: Int?, details: CGFloat) -> [CGFloat] {
        (0..<n).map { i in CGFloat(i) * rowH + (picked.map { i > $0 } == true ? details : 0) }
    }

    /// A routine's star in the column: a gentle wave down the thread, never a straight ruled line.
    static func starX(_ i: Int, _ id: String) -> CGFloat { 11 + CGFloat(sin(Double(i) * 1.7)) * 3.5 + CGFloat(hash(id, 3) - 0.5) * 3 }

    /// Where the travelling light is along a path at time `t` (loops), or nil with fewer than two points.
    static func light(_ pts: [CGPoint], t: Double, speed: Double = speed) -> CGPoint? {
        guard pts.count > 1 else { return nil }
        let segs = zip(pts, pts.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        let total = segs.reduce(0, +)
        guard total > 0 else { return pts[0] }
        var s = CGFloat((t * speed).truncatingRemainder(dividingBy: Double(total)))
        for (k, d) in segs.enumerated() {
            if s <= d {
                let u = d > 0 ? s / d : 0
                return CGPoint(x: pts[k].x + (pts[k + 1].x - pts[k].x) * u, y: pts[k].y + (pts[k + 1].y - pts[k].y) * u)
            }
            s -= d
        }
        return pts.last
    }

    /// The light fades in at the top of its thread and out at the bottom, so it never jumps back.
    static func ease(_ pts: [CGPoint], t: Double) -> Double {
        let total = Double(zip(pts, pts.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }.reduce(0, +))
        guard total > 0 else { return 0 }
        let f = (t * speed).truncatingRemainder(dividingBy: total) / total
        return min(1, f * 8, (1 - f) * 8)
    }

    /// The dial's own mark for a routine's last result, so the list and the dial speak the same language.
    static func kind(_ r: Routine) -> Dial.Kind {
        switch r.state {
        case .worked, .finished: return .done
        case .failed: return r.needsLook ? .failed : .partly
        case .never: return .next
        case .running: return .running
        case .paused: return .paused
        }
    }

    /// A point on a quadratic curve (`u` 0…1).
    static func bezier(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, _ u: CGFloat) -> CGPoint {
        let v: CGFloat = 1 - u
        let x: CGFloat = v * v * a.x + 2 * v * u * c.x + u * u * b.x
        let y: CGFloat = v * v * a.y + 2 * v * u * c.y + u * u * b.y
        return CGPoint(x: x, y: y)
    }

    static func glow(_ ctx: inout GraphicsContext, _ p: CGPoint, _ r: CGFloat, _ col: Color, _ a: Double) {
        guard a > 0.005 else { return }
        ctx.fill(Dial.dot(p, r), with: .radialGradient(Gradient(colors: [col.opacity(a), col.opacity(0)]), center: p, startRadius: 0, endRadius: r))
    }

    /// A group's small figure: its routines as tiny stars joined by a faint line (at most 16, so a big group stays a figure).
    static func drawFigure(_ ctx: inout GraphicsContext, _ g: RoutineList.Group, at o: CGPoint, open: Bool, t: Double) {
        let col = g.tint.map { Color(hex: $0) } ?? Dial.cream
        let pts = g.rows.prefix(16).map { r in
            (r, CGPoint(x: o.x + 6 + CGFloat(hash(r.id, 1)) * (colW - 34), y: o.y + 3 + CGFloat(hash(r.id, 2)) * 13))
        }.sorted { $0.1.x < $1.1.x }
        var line = Path()
        for (k, p) in pts.enumerated() { if k == 0 { line.move(to: p.1) } else { line.addLine(to: p.1) } }
        ctx.stroke(line, with: .color(col.opacity(open ? 0.3 : 0.16)), lineWidth: 0.7)
        for (r, p) in pts {
            let tw = 0.7 + 0.3 * sin(t * (1 + hash(r.id, 5)) + hash(r.id, 6) * 6)
            let c = r.needsLook ? Dial.orange : col
            if r.needsLook { glow(&ctx, p, 6, Dial.orange, 0.35 * tw) }
            ctx.fill(Dial.dot(p, open ? 1.6 : 1.4), with: .color(c.opacity((r.state == .finished ? 0.35 : 0.85) * tw)))
        }
    }

    /// The open group's column: the thread through its stars with its travelling light, each star with its halo and
    /// the dial's mark, and the picked one's own thread down its details.
    static func drawColumn(
        _ ctx: inout GraphicsContext, _ rows: [Routine], tops: [CGFloat], picked: Int?, details: CGFloat, hover: String?, t: Double,
        tint: (Routine) -> UInt32?
    ) {
        let pts = rows.indices.map { CGPoint(x: starX($0, rows[$0].id), y: tops[$0] + starY) }
        var thread = Path()
        for (k, p) in pts.enumerated() { if k == 0 { thread.move(to: p) } else { thread.addLine(to: p) } }
        ctx.stroke(thread, with: .color(Dial.cream.opacity(0.1)), lineWidth: 0.7)
        if let p = light(pts, t: t) { glow(&ctx, p, 9, Dial.cream, 0.32 * ease(pts, t: t)) }
        for (i, r) in rows.enumerated() {
            let p = pts[i]
            let hl = i == picked ? 1.0 : r.id == hover ? 0.7 : 0
            let tw = 0.75 + 0.25 * sin(t * (0.8 + hash(r.id, 5)) + hash(r.id, 6) * 6)
            let halo = r.needsLook ? Dial.orange : tint(r).map { Color(hex: $0) } ?? Dial.cream
            glow(&ctx, p, 11 + 6 * hl, halo, (0.1 + 0.25 * hl + (r.needsLook ? 0.15 : 0)) * tw)
            var m = ctx
            m.translateBy(x: p.x, y: p.y)
            m.scaleBy(x: 0.75, y: 0.75)
            m.opacity = r.state == .finished ? 0.6 : 1
            Dial.mark(&m, Dial.Mark(rid: r.id, minute: 0, kind: kind(r), at: .zero, tint: tint(r)), pulse: 0.5 + 0.5 * sin(t * 2.2))
            if r.state == .running { glow(&ctx, CGPoint(x: p.x + 9 * CGFloat(cos(t * 3)), y: p.y + 9 * CGFloat(sin(t * 3))), 5, Dial.cream, 0.8) }
        }
        // The picked one: a thread from its star down the side of its details, a light easing along it.
        if let i = picked, details > 0 {
            let a = CGPoint(x: pts[i].x, y: pts[i].y + 6)
            let y1 = tops[i] + rowH + details - 14
            var d = Path()
            d.move(to: a)
            d.addQuadCurve(to: CGPoint(x: 15, y: tops[i] + rowH + 2), control: CGPoint(x: a.x, y: tops[i] + rowH))
            d.addLine(to: CGPoint(x: 15, y: y1))
            ctx.stroke(d, with: .color(Dial.cream.opacity(0.28)), lineWidth: 0.8)
            let u = (t * 0.5).truncatingRemainder(dividingBy: 1)
            glow(&ctx, CGPoint(x: 15, y: tops[i] + rowH + (y1 - tops[i] - rowH) * CGFloat(u)), 6, Dial.cream, 0.5 * sin(u * .pi))
        }
    }
}

/// The picked routine's star, in the stage's own space (for the thread to its mark on the dial).
struct SkyStarKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGPoint? = nil
    static func reduce(value: inout CGPoint?, nextValue: () -> CGPoint?) { value = value ?? nextValue() }
}

/// How tall the picked routine's details are, so the stars below make room for them.
struct SkyDetailsKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

extension RoutinesPanel {
    /// A clock for the sky's motion: still in renders and with Reduce Motion, 20 frames a second otherwise.
    @ViewBuilder func skyTime<V: View>(@ViewBuilder _ draw: @escaping (Double) -> V) -> some View {
        if HomeView.still || Stars.reduceMotion {
            draw(Stars.stillT)
        } else {
            TimelineView(pace.every(pace.front ? 1 / 20 : Pace.calmBack)) { tl in
                draw(tl.date.timeIntervalSince(WorldLook.start))
            }
        }
    }

    @ViewBuilder func routineSky(_ s: RoutinesSnapshot) -> some View {
        let gs = listGroups(s)
        let openID = Sky.open(gs, sel: sel, chosen: openGroup ?? (finishedOpen ? RoutineList.finishedID : nil))
        let A = Sky.area
        let figH = Sky.figuresHeight(gs.count)
        ZStack(alignment: .topLeading) {
            skySwitch.frame(width: A.width, alignment: .trailing)
            figures(gs, open: openID).frame(width: A.width, height: figH, alignment: .topLeading).routineZone("sky-groups").offset(y: Sky.figTop)
            if let g = gs.first(where: { $0.id == openID }) {
                openGroupView(g, now: s.now).frame(width: A.width, height: A.height - Sky.figTop - figH - 12, alignment: .topLeading)
                    .routineZone("sky-open").offset(y: Sky.figTop + figH + 12)
            } else {
                Text("No routines here yet").font(.system(size: 10.5)).foregroundStyle(WorldLook.cream.opacity(0.45)).offset(y: Sky.figTop + 6)
            }
        }
        .frame(width: A.width, height: A.height, alignment: .topLeading)
        .offset(x: A.minX, y: A.minY)
        .onChange(of: sel) { _, new in
            if let new, let g = gs.first(where: { $0.rows.contains { $0.id == new } }) { openGroup = g.id }
        }
    }

    /// "Who it's for · How often": two quiet words, the chosen one underlined.
    var skySwitch: some View {
        HStack(spacing: 14) {
            ForEach(RoutineList.By.allCases, id: \.self) { b in
                let on = listBy == b
                Button {
                    withAnimation(.easeOut(duration: 0.3)) {
                        listBy = b
                        openGroup = nil
                    }
                } label: {
                    Text(b == .who ? "Who it's for" : "How often").font(.system(size: 11, weight: on ? .semibold : .regular))
                        .foregroundStyle(WorldLook.cream.opacity(on ? 0.95 : 0.45))
                        .padding(.bottom, 3)
                        .overlay(alignment: .bottom) { Rectangle().fill(WorldLook.cream.opacity(on ? 0.5 : 0)).frame(height: 1) }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).help(b == .who ? "Group by who it's for: \(m.name), a room or a bot" : "Group by how often it runs")
            }
        }
        .starCalm(pad: 4, feather: 14, floor: 0.15)
    }

    func figures(_ gs: [RoutineList.Group], open: String?) -> some View {
        ZStack(alignment: .topLeading) {
            skyTime { t in
                Canvas { ctx, _ in
                    for (i, g) in gs.enumerated() { Sky.drawFigure(&ctx, g, at: Sky.figOrigin(i), open: g.id == open, t: t) }
                    // The open group's name: a faint line under it, a soft light gliding along.
                    if let i = gs.firstIndex(where: { $0.id == open }) {
                        let o = Sky.figOrigin(i)
                        let w = min(Sky.colW - 24, CGFloat(gs[i].title.count) * 6.2)
                        let col = gs[i].tint.map { Color(hex: $0) } ?? Dial.cream
                        ctx.fill(Path(CGRect(x: o.x + 2, y: o.y + 38, width: w, height: 1)), with: .color(col.opacity(0.14)))
                        let u = (t * 0.25).truncatingRemainder(dividingBy: 1)
                        Sky.glow(&ctx, CGPoint(x: o.x + 2 + w * CGFloat(u), y: o.y + 38.5), 10, col, 0.5 * sin(u * .pi))
                    }
                }
            }
            .allowsHitTesting(false)
            ForEach(Array(gs.enumerated()), id: \.element.id) { i, g in
                figureLabel(g, open: g.id == open).offset(x: Sky.figOrigin(i).x, y: Sky.figOrigin(i).y + 18)
            }
        }
    }

    func figureLabel(_ g: RoutineList.Group, open: Bool) -> some View {
        let looks = g.rows.contains(where: \.needsLook)
        let col = g.tint.map { Color(hex: $0) } ?? WorldLook.cream
        return Button {
            withAnimation(.easeInOut(duration: 0.45)) {
                openGroup = g.id
                sel = nil
                picked = true
                removeAsk = nil
            }
        } label: {
            HStack(spacing: 5) {
                Text(g.title).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(col.opacity(open ? 1 : g.clearable ? 0.45 : 0.62))
                    .lineLimit(1)
                Text("\(g.rows.count)").font(.system(size: 10)).foregroundStyle(looks ? Dial.orange : WorldLook.cream.opacity(open ? 0.5 : 0.35))
            }
            .frame(width: Sky.colW - 10, height: 18, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(open ? g.title : "Show \(g.title)'s routines")
        .starCalm(pad: 3, feather: 12, floor: 0.15)
    }

    func openGroupView(_ g: RoutineList.Group, now: Date) -> some View {
        let n = g.rows.count
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Text(g.title).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(WorldLook.cream.opacity(0.62)).lineLimit(1)
                Text("\(n) routine\(n == 1 ? "" : "s")").font(.system(size: 10)).foregroundStyle(WorldLook.cream.opacity(0.36))
                Spacer(minLength: 4)
                if g.clearable && removeAsk != "group:" + g.id {
                    skyAction("Clear all \(n)") {
                        note = nil
                        removeAsk = "group:" + g.id
                    }
                    .help("Remove every routine here (asks first)")
                }
            }
            .starCalm(pad: 3, feather: 12, floor: 0.15)
            if removeAsk == "group:" + g.id { clearAsk(g) }
            if let note, sel == nil { Text(note).font(.system(size: 10.5)).foregroundStyle(WorldLook.cream.opacity(0.6)) }
            column(g, now: now)
        }
    }

    @ViewBuilder func column(_ g: RoutineList.Group, now: Date) -> some View {
        let rows = g.rows
        let pi = rows.firstIndex { $0.id == sel }
        let tops = Sky.rowTops(rows.count, picked: pi, details: detailsH)
        let content = ZStack(alignment: .topLeading) {
            skyTime { t in
                Canvas { ctx, _ in
                    Sky.drawColumn(&ctx, rows, tops: tops, picked: pi, details: detailsH, hover: hoverRow, t: t) { r in
                        owner(r)?.bot.map { Bots.hex($0.color) }
                    }
                }
            }
            .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                    skyRow(r, i, now: now, tint: g.tint, quiet: g.clearable).id(r.id)
                    if i == pi {
                        skyDetails(r, now: now).padding(.leading, 26).padding(.top, 2).padding(.bottom, 14)
                            .background(GeometryReader { p in Color.clear.preference(key: SkyDetailsKey.self, value: p.size.height) })
                    }
                }
            }
        }
        .frame(height: (tops.last ?? 0) + Sky.rowH + (pi == rows.count - 1 ? detailsH : 0), alignment: .topLeading)
        .onPreferenceChange(SkyDetailsKey.self) { h in if abs(h - detailsH) > 0.5 { detailsH = h } }
        let fade = LinearGradient(
            stops: [
                .init(color: .clear, location: 0), .init(color: .black, location: 0.03), .init(color: .black, location: 0.93),
                .init(color: .clear, location: 1),
            ],
            startPoint: .top, endPoint: .bottom)
        Group {
            if RoutinesPanel.flatList {
                // Renders draw a scroll view blank: lay it out flat, scrolled so the picked one shows.
                content.offset(y: -max(0, (pi.map { tops[$0] } ?? 0) - 40)).frame(maxHeight: .infinity, alignment: .top).clipped()
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) { content.padding(.top, 4) }
                        .onChange(of: sel) { _, new in reveal(new, proxy) }
                        .onAppear { reveal(sel, proxy) }
                }
            }
        }
        .mask(fade)
    }

    /// Picked on the dial (or open at first): bring its star into view.
    func reveal(_ id: String?, _ proxy: ScrollViewProxy) {
        guard let id else { return }
        DispatchQueue.main.async {
            if HomeView.still {
                proxy.scrollTo(id, anchor: .top)
            } else {
                withAnimation(.easeInOut(duration: 0.5)) { proxy.scrollTo(id, anchor: .top) }
            }
        }
    }

    func skyRow(_ r: Routine, _ i: Int, now: Date, tint: UInt32?, quiet: Bool) -> some View {
        let look = r.needsLook
        let on = sel == r.id
        let status = r.leftover != nil ? "Looks done · " + RoutineList.status(r, now: now) : RoutineList.status(r, now: now)
        return Button {
            pick(r.id)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(r.name).font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(
                        look ? Color(hex: 0xF6B46E) : tint.map { Color(hex: $0) } ?? WorldLook.cream.opacity(on ? 1 : quiet ? 0.6 : 0.88)
                    )
                    .lineLimit(1)
                Text(status).font(.system(size: 10)).foregroundStyle(look ? Color(hex: 0xF6B46E, 0.8) : WorldLook.cream.opacity(0.42)).lineLimit(1)
            }
            .padding(.leading, 26).padding(.top, 3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(r.line)
        .frame(height: Sky.rowH)
        .onHover { h in hoverRow = h ? r.id : hoverRow == r.id ? nil : hoverRow }
        .starCalm(pad: 2, feather: 12, floor: 0.15)
        .background {
            if on {
                GeometryReader { p in
                    let f = p.frame(in: .named(RoutineZones.space))
                    Color.clear.preference(key: SkyStarKey.self, value: CGPoint(x: f.minX + Sky.starX(i, r.id), y: f.minY + Sky.starY))
                }
            }
        }
        .modifier(PickedZone(on: on))
    }

    /// A quiet word you can press: no pill, no box. `strong` = the one that does the thing.
    func skyAction(_ title: String, strong: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(WorldLook.cream.opacity(strong ? 1 : 0.82))
                .shadow(color: Dial.cream.opacity(strong ? 0.35 : 0), radius: 6).padding(.vertical, 2).contentShape(Rectangle())
        }
        .buttonStyle(.plain).fixedSize().disabled(busy).opacity(busy ? 0.5 : 1)
    }

    /// The thread between a picked routine's mark on the dial and its star in the list, a light travelling along it.
    @ViewBuilder func skyThread(_ L: Dial.Layout) -> some View {
        let from = L.marks.first { $0.rid == sel }?.at ?? L.labels.first { $0.rid == sel }?.from  // a mark, even when its label made room
        if let from, let to = selStar, Sky.area.insetBy(dx: -2, dy: -2).contains(to) {
            let c = CGPoint(x: (from.x + to.x) / 2, y: min(from.y, to.y) - 40)
            skyTime { t in
                Canvas { ctx, _ in
                    var p = Path()
                    p.move(to: from)
                    p.addQuadCurve(to: to, control: c)
                    ctx.stroke(p, with: .color(Dial.cream.opacity(0.22)), style: StrokeStyle(lineWidth: 0.8, dash: [2, 3]))
                    let u = CGFloat((t * 0.35).truncatingRemainder(dividingBy: 1))
                    let q = Sky.bezier(from, c, to, u)
                    Sky.glow(&ctx, q, 7, Dial.cream, 0.55 * sin(Double(u) * .pi))
                }
            }
            .allowsHitTesting(false)
            Color.clear.frame(width: abs(to.x - from.x), height: max(1, abs(to.y - from.y))).routineZone("thread").allowsHitTesting(false)
                .position(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
        }
    }
}

/// Tags the picked routine's row for the list check (RoutinesListCheck.swift).
struct PickedZone: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.routineZone("picked") } else { content }
    }
}
