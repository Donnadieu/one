import AppKit
import SwiftUI

// MARK: - Routines panel (top row › Routines). Claude Design "Routines View Options", B · Day dial, picked by Omar:
// every routine the assistant runs for you on a 24-hour dial around its orb, every skill as a star, a tapped one
// opens as a floating card (Run now / Pause / Ask), the "want me to save how I did …?" question and the "I learned
// something new" notice sit by the orb. Closes with X, a click outside, or Esc.

struct RoutinesPanel: View {
    @ObservedObject var m: Model
    @ObservedObject var pace = Pace.shared
    var fixed: RoutinesSnapshot? = nil  // renders: a made-up snapshot, nothing read from disk
    @State var snap = RoutinesSnapshot()
    @State var sel: String?  // a routine id, or "skill:<path>"
    @State var hoverStar: Int?
    @State var note: String?
    @State var busy = false
    @State var noticeGone = false
    @State var picked = false
    @State var finishedOpen = false  // the Finished list starts folded
    @State var renewAsk: String?  // a finished routine's id while "Run it again?" waits for a yes
    @State var renewHelp: String?  // Run again didn't take: offer to hand it to the assistant
    @State var onlyBot: String?  // the filter by bot: nil = all, "main" = the assistant's own, else a bot's id (RoutinesBots.swift)
    @State var listBy: RoutineList.By = .who  // the list on the right: grouped by who it's for, or how often (RoutinesListView.swift)
    @State var openGroup: String?  // the constellation tapped open (RoutinesSky.swift); a picked routine opens its own
    @State var detailsH: CGFloat = 0  // the picked routine's details, so the stars under it make room
    @State var selStar: CGPoint?  // the picked routine's star, for the thread to its mark on the dial
    @State var hoverRow: String?
    @State var removeAsk: String?  // a routine's id (or "group:<id>") while "Remove it?" waits for a yes

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
                await reload()
                if !picked { sel = RoutinesPanel.firstPick(snap) }
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
        .onAppear { if let f = fixed, !picked { sel = RoutinesPanel.firstPick(f) } }
    }

    /// The card open at first: one that needs a look, else one partly done.
    static func firstPick(_ s: RoutinesSnapshot) -> String? {
        let mine = s.routines.filter { !$0.outside }
        return (mine.first { $0.needsLook } ?? mine.first { $0.state == .failed })?.id
    }

    func close() { withAnimation(.easeOut(duration: 0.2)) { m.routinesOpen = false } }

    /// Reads everything again, with plain words, rooms and bots (RoutineLabels.swift).
    func reload() async {
        let fresh = await Task.detached { Routines.load() }.value
        var s = fresh
        s.routines = RoutineLabels.dress(fresh.routines, labels: RoutineLabels.load(), rooms: RoomPrivacy.facts, bots: m.helpers, owner: m.userName)
        snap = s
    }

    // MARK: The stage (design points)

    @ViewBuilder func stage(_ all: RoutinesSnapshot) -> some View {
        let s = only(all)  // filtered by bot (RoutinesBots.swift)
        let L = Dial.layout(s, tints: tints(all))
        let starC = Dial.starCenter  // its own place under the list, whatever the list holds
        let stars = Dial.stars(s.skills, center: starC, radius: Dial.starRadius)
        ZStack(alignment: .topLeading) {
            pulseCanvas(L, stars: stars, skills: s.skills)
            // The skills' own stars stay a cluster of their own: the galaxy keeps clear of them.
            Color.clear.frame(width: Dial.starRadius * 2, height: Dial.starRadius * 2).starCalm(radius: Dial.starRadius, feather: 30).position(starC)
                .allowsHitTesting(false)
            orb.starCalm(radius: 88, feather: 40).position(Dial.center)
            Text("6 AM").dialHour().position(x: Dial.center.x + Dial.r0 - 26, y: Dial.center.y)
            Text("Noon").dialHour().position(x: Dial.center.x, y: Dial.center.y + Dial.r0 - 18)
            Text("6 PM").dialHour().position(x: Dial.center.x - Dial.r0 + 26, y: Dial.center.y)
            nowTag(L)
            ForEach(L.labels) { l in dialLabel(l) }
            header(s)
            botFilter.offset(x: 24, y: 68)  // All · the assistant · each bot (RoutinesBots.swift)
            routineSky(s)  // every routine, as constellations: one group open at a time (RoutinesSky.swift)
            Text("What I know how to do · point at a star").font(.system(size: 11, weight: .medium)).foregroundStyle(WorldLook.cream.opacity(0.42))
                .fixedSize().starCalm(floor: 0.15).position(x: starC.x, y: starC.y + Dial.starRadius + 20)
            starHits(stars, skills: s.skills)
            legend.starCalm(floor: 0.15).offset(x: 24, y: 644)
            learnedNotice(s)
            askBubble
            if let h = hoverStar, h < s.skills.count, let st = stars.first(where: { $0.index == h }) { starTip(s.skills[h], at: st.at) }
            skyThread(L)  // the picked routine's mark on the dial, joined to its star in the list
            card(s, L)
            skillsZone(stars)
        }
        .frame(width: Dial.size.width, height: Dial.size.height, alignment: .topLeading)
        .coordinateSpace(name: RoutineZones.space)
        .onPreferenceChange(SkyStarKey.self) { p in if p != selStar { selStar = p } }
        .withStars {
            RadialGradient(colors: [Color(hex: 0x24242A, 0.6), .clear], center: UnitPoint(x: 0.41, y: 0.54), startRadius: 0, endRadius: 420)
        }
    }

    var orb: some View {
        Group {
            if HomeView.still {
                Presence(t: 30, lean: .zero, voice: 0, energy: 0)
            } else {
                TimelineView(.animation(minimumInterval: pace.front ? 1 / 30 : Pace.calmBack, paused: !pace.homeSeen)) { tl in
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
            TimelineView(.animation(minimumInterval: pace.front ? 1 / 20 : Pace.calmBack, paused: !pace.homeSeen)) { tl in
                draw(tl.date.timeIntervalSince(WorldLook.start))
            }
        }
    }

    /// The legend: each of the dial's marks, drawn the same way, with its word (`Dial.legend` says the same in text).
    var legend: some View {
        let items: [(Dial.Kind, String)] = [
            (.done, "Done"), (.partly, "Partly"), (.missed, "Missed"), (.failed, "Didn't work"),
        ]
        return HStack(spacing: 14) {
            ForEach(items.indices, id: \.self) { i in
                HStack(spacing: 6) {
                    Canvas { ctx, sz in
                        Dial.mark(
                            &ctx, Dial.Mark(rid: "legend", minute: 0, kind: items[i].0, at: CGPoint(x: sz.width / 2, y: sz.height / 2)), pulse: 0)
                    }
                    .frame(width: 16, height: 16)
                    Text(items[i].1)
                }
            }
        }
        .font(.system(size: 11, weight: .medium)).foregroundStyle(WorldLook.cream.opacity(0.42)).fixedSize()
        .accessibilityLabel(Dial.legend)
    }

    func nowTag(_ L: Dial.Layout) -> some View {
        let p = Dial.point(Double(L.nowMinute), 132)
        return Text("Now " + Routines.clock(L.nowMinute)).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color(hex: 0xFFF4E8, 0.85))
            .fixedSize().position(x: p.x - 28, y: p.y + 16)
    }

    func dialLabel(_ l: Dial.Label) -> some View {
        let col = l.orange ? Color(hex: 0xF6B46E) : l.tint.map { Color(hex: $0) } ?? WorldLook.cream
        let room = Dial.labelRoom(l)  // a long name stops short of the list on the right (…)
        return Button {
            pick(l.rid)
        } label: {
            VStack(alignment: l.right ? .leading : .trailing, spacing: 1) {
                Text(l.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(col).lineLimit(1)
                Text(l.sub).font(.system(size: 10.5)).foregroundStyle(l.orange ? Color(hex: 0xF6B46E, 0.85) : WorldLook.cream.opacity(0.5)).lineLimit(
                    1)
            }
            .starCalm(pad: 4, feather: 14, floor: 0.12)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .shadow(color: Dial.cream.opacity(sel == l.rid ? 0.45 : 0), radius: 8)  // picked: it glows, no box
            .contentShape(Rectangle())
            .routineZone("dial")
        }
        .buttonStyle(.plain).help(l.title)
        .frame(width: room, alignment: l.right ? .leading : .trailing)
        .frame(width: 0, height: 0, alignment: l.right ? .leading : .trailing)
        .position(x: l.at.x + (l.right ? 4 : -4), y: l.at.y)
    }

    func header(_ s: RoutinesSnapshot) -> some View {
        let mine = s.routines.filter { !$0.outside && $0.state != .finished }.count  // finished ones have their own list
        let asks = pendingAsks.count
        return VStack(alignment: .leading, spacing: 4) {
            Text("Routines").font(.system(size: 21, weight: .semibold))
            HStack(spacing: 0) {
                Text("\(mine) routine\(mine == 1 ? "" : "s")").foregroundStyle(WorldLook.cream.opacity(0.5))
                if s.needLook > 0 {
                    Text(" · ").foregroundStyle(WorldLook.cream.opacity(0.5))
                        + Text("\(s.needLook) need a look").foregroundStyle(Color(hex: 0xF6B46E))
                }
                if s.partly > 0 { Text(" · \(s.partly) partly done").foregroundStyle(WorldLook.cream.opacity(0.75)) }
                if asks > 0 { Text(" · \(asks) waiting for your yes").foregroundStyle(WorldLook.cream.opacity(0.75)) }
            }
            .font(.system(size: 12))
        }
        .fixedSize().starCalm(floor: 0.12).offset(x: 24, y: 20)
    }

    /// The skills' cluster, for the list check (RoutinesZones.swift).
    func skillsZone(_ stars: [Dial.Star]) -> some View {
        let xs = stars.map(\.at.x)
        let ys = stars.map(\.at.y)
        let box = CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0, width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0))
        return Color.clear.frame(width: box.width, height: box.height).routineZone("skills").allowsHitTesting(false)
            .position(x: box.midX, y: box.midY)
    }

    func starHits(_ stars: [Dial.Star], skills: [SkillStar]) -> some View {
        let c = Dial.starCenter
        let rr = Dial.starRadius + 14
        let box = CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2)
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
            Text(s.room ?? "Everywhere").font(.system(size: 10.5)).foregroundStyle(WorldLook.cream.opacity(0.5))
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
