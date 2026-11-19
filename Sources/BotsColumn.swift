import SwiftUI

// MARK: - The bots on the left (Claude Design "One bots design", B · Moons, picked by Omar Nov 17 2026).
// No panel box: each bot is a small orb in its colour (a "moon") on the stage's left edge, its name and what it's
// doing now beside it, grouped by room under faint labels; a private room shows only a lock and a count until
// tapped. Orange ring = needs your yes; cream dot = something new. A working bot is joined to the assistant's orb
// by a lit thread with a travelling light (`BotThreads`). Collapsed: only the moons. Before the first bot there is
// only one faint "New bot" circle. Tapping a moon opens its chat in the middle (HelperCard: `BotHeader` + `BotThread`).

/// Where each moon and the assistant's orb sit, so a working bot's thread can be drawn between them.
struct BotAnchors: PreferenceKey {
    static var defaultValue: [String: Anchor<CGPoint>] { [:] }
    static func reduce(value: inout [String: Anchor<CGPoint>], nextValue: () -> [String: Anchor<CGPoint>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// A bot's picture: a small copy of One's rings in its colour, never an avatar.
struct BotMoon: View {
    let hex: UInt32
    var size: CGFloat = 30
    var t: Double = 0  // the moment shown; with `live`, where its own clock starts
    /// Moves on its own clock at the screen's full rate. Only this small picture redraws, never the column around it
    /// (the whole column redrawing 20 times a second made typing and the orbs stutter, Nov 18 2026).
    var live = false
    var needsYes = false
    var unread = false
    var faint = false
    var body: some View {
        Group {
            if live && !HomeView.still {
                TimelineView(.animation(minimumInterval: Motion.every)) { tl in
                    Canvas { ctx, sz in BotMoon.draw(&ctx, sz, hex: hex, t: tl.date.timeIntervalSince(WorldLook.start) + t) }
                }
            } else {
                Canvas { ctx, sz in BotMoon.draw(&ctx, sz, hex: hex, t: t) }
            }
        }
        .frame(width: size, height: size)
        .opacity(faint ? 0.45 : 1)
        .overlay(Circle().strokeBorder(Color(hex: 0xF6B46E, needsYes ? 0.9 : 0), lineWidth: 1.6).padding(-3))
        .overlay(alignment: .topTrailing) {
            if unread && !needsYes {
                Circle().fill(WorldLook.cream).frame(width: 7, height: 7).overlay(
                    Circle().strokeBorder(WorldLook.bg, lineWidth: 1.5).padding(-1.5)
                )
                .offset(x: 1, y: -1)
            }
        }
    }
    static func draw(_ ctx: inout GraphicsContext, _ sz: CGSize, hex: UInt32, t: Double) {
        let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
        let r = min(sz.width, sz.height) / 2
        let col = Color(hex: hex)
        ctx.fill(
            Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
            with: .radialGradient(Gradient(colors: [col.opacity(0.22), col.opacity(0)]), center: c, startRadius: 0, endRadius: r))
        for k in 0..<4 {
            let base = r * (0.34 + 0.14 * CGFloat(k))
            var p = Path()
            for i in 0...40 {
                let th = Double(i) / 40 * 2 * .pi
                let w = base * (1 + 0.05 * CGFloat(sin(th * 3 + t * 0.8 + Double(k) * 1.7)))
                let q = CGPoint(x: c.x + w * CGFloat(cos(th)), y: c.y + w * CGFloat(sin(th)))
                if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
            }
            ctx.stroke(p, with: .color(col.opacity(0.85 - 0.16 * Double(k))), lineWidth: 1.1)
        }
        let core = r * 0.3
        ctx.fill(
            Path(ellipseIn: CGRect(x: c.x - core, y: c.y - core, width: core * 2, height: core * 2)),
            with: .radialGradient(
                Gradient(colors: [Color(hex: 0xFFF6EC, 0.9), col.opacity(0.5), col.opacity(0)]), center: c, startRadius: 0, endRadius: core))
    }
}

struct BotsColumn: View {
    @ObservedObject var m: Model
    @AppStorage("botsCollapsed") var collapsed = false
    @State var shown: Set<String> = []  // private rooms tapped open
    @State var hovered: UUID?  // the row showing its ⋯ (BotSheet.swift)
    nonisolated(unsafe) static var stillHover: UUID?  // renders only
    var body: some View {
        let bots = m.bots
        // No clock here: each moon keeps its own (`BotMoon.live`). Renders show the moment 21.7 s in.
        if bots.isEmpty { first } else { column(bots, t: HomeView.still ? 21.7 : 0) }
    }

    /// Before the first bot: one faint circle at the bottom left, nothing else.
    var first: some View {
        VStack(spacing: 10) {
            Spacer()
            if !m.archivedBots.isEmpty { archiveBox }
            newBot(faint: true)
        }
        .frame(width: 52).padding(.bottom, 22).padding(.leading, 6)
    }

    func column(_ bots: [Helper], t: Double) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { collapsed.toggle() }
            } label: {
                Image(systemName: collapsed ? "chevron.right" : "chevron.left").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(WorldLook.cream.opacity(0.4)).frame(width: 30, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(collapsed ? "Show your bots' names" : "Only the orbs").padding(.leading, 4)
            let list = VStack(alignment: .leading, spacing: 16) {
                ForEach(BotsColumn.groups(bots), id: \.path) { g in group(g, t: t) }
            }
            .padding(.top, 8).padding(.bottom, 12)
            if HomeView.still {
                list  // renders draw a scroll view's contents blank
                Spacer(minLength: 0)
            } else {
                ScrollView(.vertical, showsIndicators: false) { list }
            }
            if collapsed {
                VStack(alignment: .leading, spacing: 10) {
                    if !m.archivedBots.isEmpty { archiveBox }
                    newBot(faint: false)
                }
            } else {
                HStack(spacing: 0) {
                    newBot(faint: false)
                    Spacer(minLength: 8)
                    if !m.archivedBots.isEmpty { archiveBox.padding(.trailing, 8) }
                }
            }
        }
        .frame(width: collapsed ? 58 : 214, alignment: .leading)
        .padding(.top, 14).padding(.bottom, 22).padding(.leading, 12)
    }

    struct Group {
        let name: String
        let path: String
        let isPrivate: Bool
        let bots: [Helper]
    }
    /// Bots by room, in the order their rooms first appear.
    static func groups(_ bots: [Helper]) -> [Group] {
        var order: [String] = []
        var by: [String: [Helper]] = [:]
        for h in bots {
            guard let b = h.bot else { continue }
            if by[b.roomPath] == nil { order.append(b.roomPath) }
            by[b.roomPath, default: []].append(h)
        }
        return order.compactMap { p in
            guard let hs = by[p], let b = hs.first?.bot else { return nil }
            return Group(name: b.room, path: p, isPrivate: Bots.isPrivateSoon(b), bots: hs)
        }
    }

    @ViewBuilder func group(_ g: Group, t: Double) -> some View {
        let locked = g.isPrivate && !shown.contains(g.path)
        VStack(alignment: .leading, spacing: 10) {
            if !collapsed {
                HStack(spacing: 5) {
                    Text(g.name.uppercased()).font(.system(size: 9.5, weight: .semibold)).tracking(1.1)
                    if g.isPrivate { Image(systemName: "lock.fill").font(.system(size: 8)) }
                }
                .foregroundStyle(WorldLook.cream.opacity(0.32)).padding(.leading, 4)
            }
            if locked {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { _ = shown.insert(g.path) }
                } label: {
                    HStack(spacing: 10) {
                        Circle().strokeBorder(WorldLook.cream.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [2, 2])).frame(
                            width: 30, height: 30
                        )
                        .overlay(Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(WorldLook.cream.opacity(0.4)))
                        if !collapsed {
                            Text("\(g.bots.count) bot\(g.bots.count == 1 ? "" : "s") · tap to show").font(.system(size: 11)).foregroundStyle(
                                WorldLook.cream.opacity(0.45))
                        }
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("A private room: its bots show only when you tap")
            } else {
                ForEach(g.bots) { h in row(h, t: t) }
            }
        }
    }

    func row(_ h: Helper, t: Double) -> some View {
        let b = h.bot!
        let open = m.openHelper == h.id
        let yes = (h.viewState == .needsYes && h.state == "needsYes") || m.stepWaiting(h)  // its yes, or a sign-in waiting
        let lit = (HomeView.still ? BotsColumn.stillHover == h.id : hovered == h.id) || m.botMenu == h.id
        return Button {
            withAnimation(.easeOut(duration: 0.3)) { m.focusHelper(h.id) }
        } label: {
            HStack(spacing: 10) {
                BotMoon(hex: Bots.hex(b.color), size: 30, t: t + Double(b.name.count), live: true, needsYes: yes, unread: h.waiting)
                    .anchorPreference(key: BotAnchors.self, value: .center) { [h.id.uuidString: $0] }
                if !collapsed {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(b.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(yes ? Color(hex: 0xF6B46E) : WorldLook.cream)
                        Text(BotsColumn.line(h, waiting: m.stepWaiting(h))).font(.system(size: 10.5))
                            .foregroundStyle(yes ? Color(hex: 0xF6B46E, 0.8) : WorldLook.cream.opacity(0.5))
                    }
                    .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 4).padding(.vertical, 3).padding(.trailing, lit && !collapsed ? 30 : 0)
            .background(RoundedRectangle(cornerRadius: 10).fill(WorldLook.cream.opacity(open || lit ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            if lit && !collapsed {
                Button {
                    m.botMenu = m.botMenu == h.id ? nil : h.id
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 11, weight: .bold)).foregroundStyle(WorldLook.cream.opacity(0.85))
                        .frame(width: 26, height: 22).background(RoundedRectangle(cornerRadius: 7).fill(WorldLook.cream.opacity(0.12)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(.trailing, 5).help("About, edit, archive or delete \(b.name)")
            }
        }
        .onHover { hovered = $0 ? h.id : (hovered == h.id ? nil : hovered) }
        .help(collapsed ? "\(b.name): \(BotsColumn.line(h))" : "Open \(b.name)'s chat")
        .contextMenu { BotMenuItems(m: m, h: h) }
        .starCalm(pad: 6, feather: 14, floor: 0.12)
    }

    /// What a bot is doing now, in a few words.
    static func line(_ h: Helper, waiting: Bool = false) -> String {
        if h.state == "needsYes" || waiting { return "Needs your yes" }
        if h.state == "working" { return h.line }
        if h.waiting { return "Something new · tap to see" }
        if h.state == "stopped" { return "Stopped" }
        switch h.bot?.checkIn {
        case "morning": return "Resting · checks in at 8 AM"
        case "incoming": return "Watching for new things"
        default: return "Resting · ready when you are"
        }
    }

    /// The archived bots: a small box with how many, next to New bot (BotSheet.swift `ArchivedBots`).
    var archiveBox: some View {
        Button {
            m.botsArchive.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "archivebox").font(.system(size: 10.5))
                if !collapsed { Text("\(m.archivedBots.count)").font(.system(size: 11.5, weight: .medium)) }
            }
            .foregroundStyle(WorldLook.cream.opacity(m.botsArchive ? 0.85 : 0.5)).padding(.horizontal, 8).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 7).fill(WorldLook.cream.opacity(m.botsArchive ? 0.1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help("Archived bots: kept, off the left")
        .padding(.leading, collapsed ? 4 : 0)
    }

    func newBot(faint: Bool) -> some View {
        Button {
            m.openHelper = nil
            Task { await m.send("I'd like a new bot.", toNova: true) }
        } label: {
            HStack(spacing: 10) {
                Circle().strokeBorder(WorldLook.cream.opacity(faint ? 0.22 : 0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .frame(width: 30, height: 30)
                    .overlay(
                        Image(systemName: "plus").font(.system(size: 10, weight: .semibold)).foregroundStyle(
                            WorldLook.cream.opacity(faint ? 0.3 : 0.5)))
                if !collapsed && !faint { Text("New bot").font(.system(size: 12, weight: .medium)).foregroundStyle(WorldLook.cream.opacity(0.5)) }
            }
            .padding(.horizontal, 4).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!m.isReady)
        .help(faint ? "New: keep a bot. A helper you keep for one job, with its own chat." : "Make a new bot")
    }
}

/// A working bot's thread to the assistant's orb, with a light travelling along it (only on the home view).
struct BotThreads: View {
    @ObservedObject var m: Model
    let points: [String: CGPoint]
    var body: some View {
        let working = m.openHelper == nil ? m.bots.filter { $0.state == "working" } : []
        if let orb = points["orb"], !working.isEmpty {
            // The travelling light moves at the screen's full rate; only this canvas redraws for it.
            let open = !UserDefaults.standard.bool(forKey: "botsCollapsed")
            let lines = working.compactMap { h in points[h.id.uuidString].flatMap { p in h.bot.map { (p, Bots.hex($0.color)) } } }
            TimelineView(.animation(minimumInterval: Motion.every, paused: HomeView.still)) { tl in
                let t = HomeView.still ? 0.62 : tl.date.timeIntervalSince(WorldLook.start)
                Canvas { ctx, _ in
                    for (p, hex) in lines { BotThreads.thread(&ctx, from: p, to: orb, hex: hex, t: t, open: open) }
                }
            }
            .allowsHitTesting(false)
        }
    }
    static func thread(
        _ ctx: inout GraphicsContext, from a: CGPoint, to o: CGPoint, hex: UInt32, t: Double,
        open: Bool = !UserDefaults.standard.bool(forKey: "botsCollapsed")
    ) {
        // From the end of its row (clear of its name and the rows under it), then across to the orb's edge.
        let start = CGPoint(x: a.x + (open ? 178 : 20), y: a.y)
        let end = CGPoint(x: o.x - 52, y: o.y)
        let c1 = CGPoint(x: start.x + 90, y: start.y)
        let c2 = CGPoint(x: end.x - 130, y: end.y)
        var p = Path()
        p.move(to: start)
        p.addCurve(to: end, control1: c1, control2: c2)
        let col = Color(hex: hex)
        ctx.stroke(p, with: .color(col.opacity(0.32)), style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
        let q = BotThreads.at(CGFloat((t * 0.35).truncatingRemainder(dividingBy: 1)), start, c1, c2, end)
        ctx.fill(
            Path(ellipseIn: CGRect(x: q.x - 7, y: q.y - 7, width: 14, height: 14)),
            with: .radialGradient(Gradient(colors: [col.opacity(0.6), col.opacity(0)]), center: q, startRadius: 0, endRadius: 7))
        ctx.fill(Path(ellipseIn: CGRect(x: q.x - 1.8, y: q.y - 1.8, width: 3.6, height: 3.6)), with: .color(Color(hex: 0xFFF6EC)))
    }
    /// A point on a cubic curve at `f` (0…1).
    static func at(_ f: CGFloat, _ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> CGPoint {
        let g = 1 - f
        let k0 = g * g * g
        let k1 = 3 * g * g * f
        let k2 = 3 * g * f * f
        let k3 = f * f * f
        return CGPoint(x: k0 * a.x + k1 * b.x + k2 * c.x + k3 * d.x, y: k0 * a.y + k1 * b.y + k2 * c.y + k3 * d.y)
    }
}

/// The top of a bot's chat: its moon, name, room and job, the three quiet facts, and "What it did".
struct BotHeader: View {
    @ObservedObject var m: Model
    let h: Helper
    let b: BotInfo
    var body: some View {
        let days = Bots.days(b)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                BotMoon(hex: Bots.hex(b.color), size: 40, t: 21.7, needsYes: h.state == "needsYes" || m.stepWaiting(h))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(b.name).font(.headline)
                        Text("· " + BotsColumn.line(h, waiting: m.stepWaiting(h))).foregroundStyle(
                            h.state == "needsYes" || m.stepWaiting(h) ? Color.orange : Color.secondary
                        ).lineLimit(1)
                    }
                    Text("\(b.room) room · \(b.job)").font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    Text(Bots.facts(b, remembered: Bots.remembered(b))).font(.system(size: 11.5)).foregroundStyle(WorldLook.cream.opacity(0.45))
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                Menu {
                    BotMenuItems(m: m, h: h)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("About, edit, archive or delete \(b.name)")
                Button {
                    withAnimation(.easeOut(duration: 0.3)) { m.openHelper = nil }
                } label: {
                    Label(m.name, systemImage: "chevron.left")
                }
                .buttonStyle(.bordered).controlSize(.small).help("Back to \(m.name)")
            }
            if !days.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("WHAT IT DID").font(.system(size: 9.5, weight: .semibold)).tracking(1.1).foregroundStyle(WorldLook.cream.opacity(0.32))
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(days.indices, id: \.self) { i in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 0) {
                                    Circle().fill(Color(hex: Bots.hex(b.color), i == days.count - 1 ? 1 : 0.55)).frame(width: 7, height: 7)
                                    Rectangle().fill(WorldLook.cream.opacity(i == days.count - 1 ? 0 : 0.12)).frame(height: 1)
                                }
                                Text(days[i].day).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(WorldLook.cream.opacity(0.7))
                                Text(days[i].what).font(.system(size: 10.5)).foregroundStyle(WorldLook.cream.opacity(0.45)).lineLimit(2)
                                    .padding(.trailing, 10)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            Rectangle().fill(WorldLook.cream.opacity(0.08)).frame(height: 1)
        }
    }
}

/// A bot's kept chat: its last few exchanges, oldest first (the engine keeps the whole conversation).
struct BotThread: View {
    let h: Helper
    var body: some View {
        let all = h.log ?? []
        let log = Array(all.suffix(6))
        VStack(alignment: .leading, spacing: 14) {
            if all.count > log.count {
                Text("Earlier messages are kept in its memory.").font(.system(size: 11)).foregroundStyle(WorldLook.cream.opacity(0.35))
            }
            ForEach(log.indices, id: \.self) { i in entry(log[i]) }
            if h.state == "working", let a = h.asked, !a.isEmpty {
                LongFoldText(text: a, key: nil, size: ChatText.callout, plain: true, accent: true)
            }
            if log.isEmpty && h.state != "working" {
                Text("Nothing yet. Tell it what you need below.").foregroundStyle(.secondary)
            }
        }
    }
    @ViewBuilder func entry(_ e: String) -> some View {
        let you = "**You:** "
        if e.hasPrefix(you), let cut = e.range(of: "\n\n") {
            LongFoldText(
                text: String(e[e.index(e.startIndex, offsetBy: you.count)..<cut.lowerBound]), key: nil, size: ChatText.callout, plain: true,
                accent: true)
            ChatText(text: String(e[cut.upperBound...]), size: 14.5).frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ChatText(text: e, size: 14.5).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// "Keep as a bot" on a finished helper: its name, a colour, its room. Then it stays on the left with its chat.
struct KeepBotCard: View {
    @ObservedObject var m: Model
    let h: Helper
    let done: () -> Void
    @State var name: String
    @State var color: String
    @State var rooms: [Bots.Room] = KeepBotCard.stillRooms
    @State var room: String?
    nonisolated(unsafe) static var stillRooms: [Bots.Room] = []  // renders only
    init(m: Model, h: Helper, done: @escaping () -> Void) {
        self.m = m
        self.h = h
        self.done = done
        _name = State(initialValue: String(h.title.prefix(30)))
        _color = State(initialValue: Bots.nextColor(used: m.bots.compactMap(\.bot?.color)))
        _room = State(initialValue: KeepBotCard.stillRooms.first { !$0.isPrivate }?.path)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keep as a bot").font(.headline)
            Text(
                "It keeps this chat and what it learned, so you can come back to it. It sits on the left and asks before sending, spending or posting."
            )
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                BotMoon(hex: Bots.hex(color), size: 28, t: 21.7)
                if HomeView.still {
                    Text(name).padding(.horizontal, 8).frame(width: 220, height: 24, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(WorldLook.cream.opacity(0.06)))
                } else {
                    TextField("Its name", text: $name).textFieldStyle(.roundedBorder).frame(width: 220)
                }
            }
            HStack(spacing: 10) {
                ForEach(Bots.colors, id: \.name) { c in
                    Button {
                        color = c.name
                    } label: {
                        Circle().fill(Color(hex: c.hex)).frame(width: 18, height: 18)
                            .overlay(Circle().strokeBorder(WorldLook.cream, lineWidth: color == c.name ? 1.5 : 0).padding(-4))
                    }
                    .buttonStyle(.plain).help(c.name.capitalizingFirst)
                }
            }
            if !rooms.isEmpty {
                HStack(spacing: 8) {
                    Text("Room").font(.callout).foregroundStyle(.secondary)
                    ForEach(rooms, id: \.path) { r in
                        Button {
                            room = r.path
                        } label: {
                            HStack(spacing: 4) {
                                if room == r.path { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
                                if r.isPrivate { Image(systemName: "lock.fill").font(.system(size: 8)) }
                                Text(r.name).font(.system(size: 12))
                            }
                            .padding(.horizontal, 9).frame(height: 24)
                            .overlay(Capsule().strokeBorder(WorldLook.cream.opacity(room == r.path ? 0.7 : 0.18)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Not now", action: done).buttonStyle(.bordered)
                Button("Keep it") {
                    guard let r = rooms.first(where: { $0.path == room }) ?? rooms.first else { return }
                    withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) { m.keepAsBot(h.id, name: name, color: color, room: r) }
                    done()
                }
                .buttonStyle(.borderedProminent).tint(WorldLook.cream).foregroundStyle(WorldLook.bg).disabled(rooms.isEmpty)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(WorldLook.cream.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(WorldLook.cream.opacity(0.1)))
        .task {
            guard rooms.isEmpty else { return }
            let found = await Task.detached { Bots.rooms() }.value  // rooms live in Documents: read off the main thread
            rooms = found
            if room == nil { room = (found.first { !$0.isPrivate } ?? found.first)?.path }
        }
    }
}

/// While a bot's chat is open the assistant stays home: its orb small and dim above the chat; a tap goes back.
struct IrisHome: View {
    @ObservedObject var m: Model
    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.3)) { m.openHelper = nil }
        } label: {
            VStack(spacing: 2) {
                Group {
                    if HomeView.still {
                        Presence(t: 30, lean: .zero, voice: 0, energy: 0).frame(width: 280, height: 280).scaleEffect(0.26)
                    } else {
                        Orb(size: 26)
                    }
                }
                .frame(width: 74, height: 74)
                Text("Back to \(m.name)").font(.system(size: 11, weight: .medium)).foregroundStyle(WorldLook.cream.opacity(0.5))
            }
            .opacity(0.75).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help("Back to \(m.name)")
        .anchorPreference(key: BotAnchors.self, value: .center) { ["orb": $0] }
    }
}
