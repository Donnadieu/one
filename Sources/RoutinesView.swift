import AppKit
import SwiftUI

// MARK: - Routines panel (top row › Routines). Claude Design "Routines View Options", B · Day dial, picked by Omar:
// every routine the assistant runs for you on a 24-hour dial around its orb, every skill as a star, a tapped one
// opens as a floating card (Run now / Pause / Ask), the "want me to save how I did …?" question and the "I learned
// something new" notice sit by the orb. Closes with X, a click outside, or Esc.

struct RoutinesPanel: View {
    @ObservedObject var m: Model
    var fixed: RoutinesSnapshot? = nil  // renders: a made-up snapshot, nothing read from disk
    @State var snap = RoutinesSnapshot()
    @State var sel: String?  // a routine id, or "skill:<path>"
    @State var hoverStar: Int?
    @State var note: String?
    @State var busy = false
    @State var noticeGone = false
    @State var picked = false

    var body: some View {
        let s = fixed ?? snap
        PopupStage(close: close) { g in
            let k = min((g.width - 32) / Dial.size.width, (g.height - 32) / Dial.size.height)
            stage(s)
                .frame(width: Dial.size.width, height: Dial.size.height)
                .clipShape(RoundedRectangle(cornerRadius: PopupLook.corner / k, style: .continuous))
                .scaleEffect(k)
                .frame(width: Dial.size.width * k, height: Dial.size.height * k)
        }
        .foregroundStyle(WorldLook.cream)
        .environment(\.colorScheme, .dark)
        .task {
            guard fixed == nil else { return }
            while !Task.isCancelled {
                let fresh = await Task.detached { Routines.load() }.value
                snap = fresh
                if !picked { sel = fresh.routines.first { $0.state == .failed && !$0.outside }?.id }
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
        .onAppear { if let f = fixed, !picked { sel = f.routines.first { $0.state == .failed }?.id } }
    }

    func close() { withAnimation(.easeOut(duration: 0.2)) { m.routinesOpen = false } }

    // MARK: The stage (design points)

    @ViewBuilder func stage(_ s: RoutinesSnapshot) -> some View {
        let L = Dial.layout(s)
        let starTop = max(200, 120 + CGFloat(L.later.count) * 44)
        let starC = CGPoint(x: 1025, y: starTop + 70)
        let stars = Dial.stars(s.skills, center: starC, radius: 62)
        ZStack(alignment: .topLeading) {
            pulseCanvas(L, stars: stars, skills: s.skills)
            // The skills' own stars stay a cluster of their own: the galaxy keeps clear of them.
            Color.clear.frame(width: 124, height: 124).starCalm(radius: 62, feather: 30).position(starC).allowsHitTesting(false)
            orb.starCalm(radius: 88, feather: 40).position(Dial.center)
            Text("6 AM").dialHour().position(x: Dial.center.x + Dial.r0 - 26, y: Dial.center.y)
            Text("Noon").dialHour().position(x: Dial.center.x, y: Dial.center.y + Dial.r0 - 18)
            Text("6 PM").dialHour().position(x: Dial.center.x - Dial.r0 + 26, y: Dial.center.y)
            nowTag(L)
            ForEach(L.labels) { l in dialLabel(l) }
            header(s)
            outsideColumn(L.outside)
            laterColumn(L.later, now: s.now)
            Text("\(s.skills.count) skills · point at a star").font(.system(size: 11, weight: .medium)).foregroundStyle(WorldLook.cream.opacity(0.42))
                .fixedSize().starCalm(floor: 0.15).position(x: starC.x, y: starC.y + 84)
            starHits(stars, skills: s.skills)
            Text("Filled: done · Hollow: still to come · Orange: didn't finish").font(.system(size: 11, weight: .medium))
                .foregroundStyle(WorldLook.cream.opacity(0.36)).fixedSize().starCalm(floor: 0.15).offset(x: 24, y: 648)
            learnedNotice(s)
            askBubble
            if let h = hoverStar, h < s.skills.count, let st = stars.first(where: { $0.index == h }) { starTip(s.skills[h], at: st.at) }
            card(s, L)
        }
        .frame(width: Dial.size.width, height: Dial.size.height, alignment: .topLeading)
        .withStars {
            RadialGradient(colors: [Color(hex: 0x24242A, 0.6), .clear], center: UnitPoint(x: 0.41, y: 0.54), startRadius: 0, endRadius: 420)
        }
    }

    var orb: some View {
        Group {
            if HomeView.still {
                Presence(t: 30, lean: .zero, voice: 0, energy: 0)
            } else {
                TimelineView(.animation(minimumInterval: 1 / 30)) { tl in
                    Presence(t: tl.date.timeIntervalSince(WorldLook.start), lean: .zero, voice: 0, energy: 0)
                }
            }
        }
        .frame(width: 280, height: 280).scaleEffect(0.6).frame(width: 168, height: 168).allowsHitTesting(false)
    }

    @ViewBuilder func pulseCanvas(_ L: Dial.Layout, stars: [Dial.Star], skills: [SkillStar]) -> some View {
        let draw = { (t: Double) in
            Canvas { ctx, _ in
                Dial.draw(&ctx, L, pulse: 0.5 + 0.5 * sin(t * 2.2))
                for st in stars {
                    let tw = 0.75 + 0.25 * sin(t * (0.6 + Double(st.index % 7) * 0.13) + Double(st.index))
                    let hov = hoverStar == st.index
                    let r = st.r * (hov ? 2.4 : 1)
                    if skills[st.index].mine || hov {
                        ctx.fill(
                            Dial.dot(st.at, r * 5),
                            with: .radialGradient(
                                Gradient(colors: [Color(hex: 0xFFF0E0, st.a * tw * 0.35), .clear]), center: st.at, startRadius: 0, endRadius: r * 5))
                    }
                    ctx.fill(Dial.dot(st.at, r), with: .color(Color(hex: 0xFFF6EC, min(1, st.a * tw * (hov ? 1.6 : 1)))))
                    if sel == "skill:" + skills[st.index].path {
                        ctx.stroke(Dial.dot(st.at, 6), with: .color(Dial.cream.opacity(0.75)), lineWidth: 1.2)
                    }
                }
            }
        }
        if HomeView.still {
            draw(0)
        } else {
            TimelineView(.animation(minimumInterval: 1 / 20)) { tl in draw(tl.date.timeIntervalSince(WorldLook.start)) }
        }
    }

    func nowTag(_ L: Dial.Layout) -> some View {
        let p = Dial.point(Double(L.nowMinute), 132)
        return Text("Now " + Routines.clock(L.nowMinute)).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color(hex: 0xFFF4E8, 0.85))
            .fixedSize().position(x: p.x - 28, y: p.y + 16)
    }

    func dialLabel(_ l: Dial.Label) -> some View {
        let col = l.orange ? Color(hex: 0xF6B46E) : WorldLook.cream
        return Button {
            pick(l.rid)
        } label: {
            VStack(alignment: l.right ? .leading : .trailing, spacing: 1) {
                Text(l.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(col).lineLimit(1)
                Text(l.sub).font(.system(size: 10.5)).foregroundStyle(l.orange ? Color(hex: 0xF6B46E, 0.85) : WorldLook.cream.opacity(0.5)).lineLimit(
                    1)
            }
            .fixedSize()
            .starCalm(pad: 4, feather: 14, floor: 0.12)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 6).fill(WorldLook.cream.opacity(sel == l.rid ? 0.1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: 0, height: 0, alignment: l.right ? .leading : .trailing)
        .position(x: l.at.x + (l.right ? 4 : -4), y: l.at.y)
    }

    func header(_ s: RoutinesSnapshot) -> some View {
        let mine = s.routines.filter { !$0.outside }.count
        let asks = pendingAsks.count
        return VStack(alignment: .leading, spacing: 4) {
            Text("Routines").font(.system(size: 21, weight: .semibold))
            HStack(spacing: 0) {
                Text("\(mine) routine\(mine == 1 ? "" : "s") · \(s.skills.count) skills").foregroundStyle(WorldLook.cream.opacity(0.5))
                if s.needLook > 0 {
                    Text(" · ").foregroundStyle(WorldLook.cream.opacity(0.5))
                        + Text("\(s.needLook) need a look").foregroundStyle(Color(hex: 0xF6B46E))
                }
                if asks > 0 { Text(" · \(asks) waiting for your yes").foregroundStyle(WorldLook.cream.opacity(0.75)) }
            }
            .font(.system(size: 12))
        }
        .fixedSize().starCalm(floor: 0.12).offset(x: 24, y: 20)
    }

    func smallOrb(_ r: Routine, size: CGFloat = 18) -> some View {
        let col: Color = r.state == .failed ? Dial.orange : WorldLook.cream
        return Circle().fill(RadialGradient(colors: [col.opacity(0.75), col.opacity(0.15)], center: .center, startRadius: 0, endRadius: size / 2))
            .overlay(Circle().strokeBorder(col.opacity(0.45), lineWidth: 1)).frame(width: size, height: size)
            .opacity(r.state == .never || r.state == .paused ? 0.5 : 1)
    }

    func miniStop(_ r: Routine, sub: String, width: CGFloat) -> some View {
        Button {
            pick(r.id)
        } label: {
            VStack(spacing: 3) {
                smallOrb(r)
                Text(r.title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                Text(sub).font(.system(size: 10)).foregroundStyle(WorldLook.cream.opacity(0.45)).lineLimit(1)
            }
            .frame(width: width).contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 8).fill(WorldLook.cream.opacity(sel == r.id ? 0.08 : 0)))
        }.buttonStyle(.plain)
    }

    @ViewBuilder func outsideColumn(_ rs: [Routine]) -> some View {
        if !rs.isEmpty {
            VStack(spacing: 8) {
                Text("Runs outside One").font(.system(size: 10.5, weight: .medium)).foregroundStyle(WorldLook.cream.opacity(0.35))
                LazyVGrid(columns: [GridItem(.fixed(118)), GridItem(.fixed(118))], spacing: 10) {
                    ForEach(rs) { r in miniStop(r, sub: r.often, width: 118).opacity(0.6) }
                }
            }
            .frame(width: 250).starCalm(floor: 0.12).offset(x: 24, y: 96)
        }
    }

    @ViewBuilder func laterColumn(_ rs: [Routine], now: Date) -> some View {
        if !rs.isEmpty {
            VStack(spacing: 6) {
                Text("Not on today's dial").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(WorldLook.cream.opacity(0.42))
                ForEach(rs) { r in
                    let when = r.next.map { Routines.day($0, now: now, lower: false) } ?? ""
                    let sub =
                        r.state == .never
                        ? "Never ran yet" + (when.isEmpty ? "" : " · " + when)
                        : Dial.word(r).capitalizingFirst + (when.isEmpty ? "" : " · next " + when)
                    miniStop(r, sub: sub, width: 220)
                }
            }
            .frame(width: 240).starCalm(floor: 0.12).offset(x: 905, y: 80)
        }
    }

    func starHits(_ stars: [Dial.Star], skills: [SkillStar]) -> some View {
        let box = CGRect(x: 945, y: (stars.map(\.at.y).min() ?? 200) - 14, width: 160, height: 170)
        func nearest(_ p: CGPoint) -> Int? {
            let q = CGPoint(x: p.x + box.minX, y: p.y + box.minY)
            var best: Int?
            var bd: CGFloat = 12 * 12
            for s in stars {
                let d = (s.at.x - q.x) * (s.at.x - q.x) + (s.at.y - q.y) * (s.at.y - q.y)
                if d < bd {
                    bd = d
                    best = s.index
                }
            }
            return best
        }
        return Color.clear.contentShape(Rectangle()).frame(width: box.width, height: box.height)
            .onContinuousHover { ph in
                if case .active(let p) = ph { hoverStar = nearest(p) } else { hoverStar = nil }
            }
            .onTapGesture(coordinateSpace: .local) { p in if let i = nearest(p) { pick("skill:" + skills[i].path) } }
            .offset(x: box.minX, y: box.minY)
    }

    func starTip(_ s: SkillStar, at p: CGPoint) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(s.title).font(.system(size: 12, weight: .semibold))
            Text(s.name + (s.room.map { " · " + $0 } ?? "")).font(.system(size: 10.5)).foregroundStyle(WorldLook.cream.opacity(0.5))
        }
        .fixedSize().padding(.horizontal, 11).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: 0x202024, 0.97)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(WorldLook.cream.opacity(0.14)))
        .frame(width: 0, height: 0, alignment: .bottomTrailing)
        .position(x: p.x - 12, y: p.y - 8).allowsHitTesting(false)
    }

    func pick(_ id: String) {
        picked = true
        note = nil
        withAnimation(.easeOut(duration: 0.18)) { sel = sel == id ? nil : id }
    }
}

extension Text {
    func dialHour() -> some View { font(.system(size: 11, weight: .medium)).foregroundStyle(WorldLook.cream.opacity(0.3)).fixedSize() }
}

extension String {
    var capitalizingFirst: String { prefix(1).uppercased() + dropFirst() }
}
