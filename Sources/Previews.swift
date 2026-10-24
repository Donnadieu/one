import Quartz
import SwiftUI
import AppKit
import AVFoundation
import Speech
import PDFKit
import Carbon
import EventKit
import CoreAudio
import UniformTypeIdentifiers

// MARK: - Rooms map + add a room (render-only design preview)
struct MapNode {
    let p: CGPoint
    let r: CGFloat
    let label: String?
    let hub: Bool
}

enum MapData {
    static func cluster(_ c: CGPoint, _ hub: String, _ named: [String], extra: Int, seed: Double, spread: CGFloat) -> [MapNode] {
        var v = [MapNode(p: c, r: 9, label: hub, hub: true)]
        let total = named.count + extra
        for i in 0..<total {
            let a = Double(i) / Double(total) * 2 * .pi + seed
            let d = spread * (0.55 + 0.45 * CGFloat(abs(sin(Double(i) * 2.7 + seed))))
            let p = CGPoint(x: c.x + cos(a) * d, y: c.y + sin(a) * d * 0.8)
            v.append(MapNode(p: p, r: i < named.count ? 5 : 3, label: i < named.count ? named[i] : nil, hub: false))
        }
        return v
    }
    static func place(_ c: CGPoint, _ hub: String, _ named: [(String, CGFloat, CGFloat)], _ dots: [(CGFloat, CGFloat)]) -> [MapNode] {
        [MapNode(p: c, r: 9, label: hub, hub: true)]
            + named.map { MapNode(p: CGPoint(x: c.x + $0.1, y: c.y + $0.2), r: 5, label: $0.0, hub: false) }
            + dots.map { MapNode(p: CGPoint(x: c.x + $0.0, y: c.y + $0.1), r: 3, label: nil, hub: false) }
    }
    static let personal = place(
        CGPoint(x: 205, y: 250), "Life",
        [("Family", -120, -40), ("Health", -60, -112), ("Quebec trip", 92, -86), ("Money", 128, 10), ("Home", 70, 104), ("Kids' school", -90, 92)],
        [(-150, 30), (-20, -140), (20, 130), (150, 70), (-40, 150), (130, -40), (-130, -95), (0, 70), (45, -45)])
    static let business = place(
        CGPoint(x: 455, y: 205), "Company",
        [("Ideas", -62, -70), ("Buyers", 68, -56), ("The offer", 70, 56), ("Pipeline", -40, 78)],
        [(10, -95), (100, 0), (-95, 10), (30, 100), (-10, -40)])
}

struct RoomGraph: View {
    var t: Double = 4
    var body: some View {
        Canvas { ctx, _ in
            func draw(_ nodes: [MapNode], _ tint: Color) {
                let hub = nodes[0]
                for (i, n) in nodes.enumerated().dropFirst() {
                    var path = Path()
                    path.move(to: hub.p)
                    path.addLine(to: n.p)
                    ctx.stroke(path, with: .color(tint.opacity(0.22)), lineWidth: 1)
                    if i > 1, i % 3 == 0 {
                        var q = Path()
                        q.move(to: n.p)
                        q.addLine(to: nodes[i - 1].p)
                        ctx.stroke(q, with: .color(tint.opacity(0.14)), lineWidth: 0.8)
                    }
                }
                for n in nodes {
                    let sel = n.label == "Quebec trip"
                    if n.hub || sel {
                        ctx.fill(
                            Path(ellipseIn: CGRect(x: n.p.x - n.r * 2.4, y: n.p.y - n.r * 2.4, width: n.r * 4.8, height: n.r * 4.8)),
                            with: .color(tint.opacity(sel ? 0.25 : 0.14)))
                    }
                    ctx.fill(
                        Path(ellipseIn: CGRect(x: n.p.x - n.r, y: n.p.y - n.r, width: n.r * 2, height: n.r * 2)),
                        with: .color(tint.opacity(n.label == nil ? 0.5 : 0.95)))
                    if let l = n.label {
                        let txt = ctx.resolve(
                            Text(l).font(.system(size: n.hub ? 12.5 : 11, weight: n.hub ? .semibold : .regular)).foregroundColor(
                                WorldLook.cream.opacity(n.hub ? 0.95 : 0.8)))
                        let sz = txt.measure(in: CGSize(width: 200, height: 40))
                        let at = CGPoint(x: n.p.x, y: n.p.y + n.r + 11)
                        ctx.fill(
                            Path(
                                roundedRect: CGRect(
                                    x: at.x - sz.width / 2 - 4, y: at.y - sz.height / 2 - 1, width: sz.width + 8, height: sz.height + 2),
                                cornerRadius: 5), with: .color(WorldLook.bg.opacity(0.85)))
                        ctx.draw(txt, at: at)
                    }
                }
            }
            // the one dated line that crossed between rooms
            var x = Path()
            x.move(to: MapData.personal[3].p)
            x.addQuadCurve(to: MapData.business[0].p, control: CGPoint(x: 360, y: 40))
            ctx.stroke(x, with: .color(WorldLook.cream.opacity(0.28)), style: StrokeStyle(lineWidth: 1, dash: [2, 5]))
            draw(MapData.personal, Color(hex: 0xFFE2C2))
            draw(MapData.business, Color(hex: 0x9FC9B0))
        }
    }
}

struct MapScene: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            WorldLook.bg
            RoomGraph()
            // room names
            VStack(alignment: .leading, spacing: 1) {
                Text("Personal room").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(hex: 0xFFE2C2))
                Text("15 notes").font(.system(size: 10.5)).foregroundStyle(WorldLook.cream.opacity(0.5))
            }.position(x: 92, y: 400)
            VStack(alignment: .leading, spacing: 1) {
                Text("Business room").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(hex: 0x9FC9B0))
                Text("9 notes").font(.system(size: 10.5)).foregroundStyle(WorldLook.cream.opacity(0.5))
            }.position(x: 500, y: 340)
            Text("1 date crossed: “trip Dec 20–24”").font(.system(size: 10)).foregroundStyle(WorldLook.cream.opacity(0.45))
                .position(x: 360, y: 74)
            // top bar
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                    Text("Nova")
                }
                .font(.system(size: 11.5, weight: .medium)).foregroundStyle(WorldLook.cream.opacity(0.85))
                .padding(.horizontal, 9).padding(.vertical, 4).background(Capsule().fill(Color.white.opacity(0.08)))
                Text("Your rooms").font(.system(size: 16, weight: .semibold)).foregroundStyle(WorldLook.cream)
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                    Text("Room")
                }
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(WorldLook.bg)
                .padding(.horizontal, 11).padding(.vertical, 5).background(Capsule().fill(WorldLook.cream))
            }
            .padding(.horizontal, 18).frame(width: 580).position(x: 290, y: 28)
            // the opened note
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Circle().fill(Color(hex: 0xFFE2C2)).frame(width: 7, height: 7)
                    Text("Personal room").font(.system(size: 10.5, weight: .medium)).foregroundStyle(WorldLook.cream.opacity(0.55))
                }
                Text("Quebec trip").font(.system(size: 16, weight: .semibold)).foregroundStyle(WorldLook.cream)
                Text(
                    "December 20–24, four of us: Omar, his wife, and the kids (7 and 3).\n\nFlights: Newark is cheapest at $3,104 for all four. Hotel pick: Le Germain, $289 a night, family room in Old Quebec."
                )
                .font(.system(size: 12.5)).foregroundStyle(WorldLook.cream.opacity(0.85)).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("LINKED NOTES").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(WorldLook.cream.opacity(0.45))
                    HStack(spacing: 6) {
                        ForEach(["Family", "Money"], id: \.self) { n in
                            Text(n).font(.system(size: 11)).foregroundStyle(WorldLook.cream.opacity(0.85))
                                .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(Color.white.opacity(0.07)))
                        }
                    }
                }
                Spacer()
                Text("Open in Finder").font(.system(size: 11.5, weight: .medium)).foregroundStyle(WorldLook.cream.opacity(0.75))
            }
            .padding(16).frame(width: 220, height: 400, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(WorldLook.cream.opacity(0.08)))
            .position(x: 700, y: 225)
        }
        .frame(width: 820, height: 450)
        .environment(\.colorScheme, .dark)
    }
}

struct RoomAddScene: View {
    var confirm = false
    var t: Double = 12
    var body: some View {
        ZStack {
            WorldLook.bg
            RadialGradient(colors: [Color(hex: 0x24262A, 0.6), .clear], center: UnitPoint(x: 0.5, y: 0.2), startRadius: 10, endRadius: 260)
            Presence(t: t, lean: .zero, voice: 0.3, energy: 0.15).frame(width: 280, height: 280).scaleEffect(0.36).position(x: 310, y: 62)
            if !confirm {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Spacer()
                        Text("I want a room for my business").font(.system(size: 13)).foregroundStyle(WorldLook.cream.opacity(0.9))
                            .padding(.horizontal, 12).padding(.vertical, 7).background(Capsule().fill(Color.white.opacity(0.08)))
                    }
                    Text(
                        "Good idea. A room is a part of your life where I act differently and keep the notes apart from everything else. Four quick questions, then you'll see it before I make it."
                    )
                    .font(.system(size: 14)).foregroundStyle(WorldLook.cream.opacity(0.92)).lineSpacing(2).fixedSize(
                        horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        ForEach(0..<4) { i in Capsule().fill(WorldLook.cream.opacity(i == 0 ? 0.9 : 0.18)).frame(width: i == 0 ? 22 : 8, height: 5) }
                        Text("1 of 4").font(.system(size: 10.5)).foregroundStyle(WorldLook.cream.opacity(0.5)).padding(.leading, 4)
                    }
                    Text("What should I be for you in this room?").font(.system(size: 15, weight: .semibold)).foregroundStyle(WorldLook.cream)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            chip("A co-founder who pushes me", main: true)
                            chip("An assistant who keeps things organized")
                        }
                        HStack(spacing: 8) {
                            chip("A coach who asks hard questions")
                            chip("Say it your way…")
                        }
                    }
                }
                .padding(20).frame(width: 520, alignment: .leading)
                .position(x: 310, y: 270)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Circle().fill(Color(hex: 0x9FC9B0)).frame(width: 9, height: 9)
                        Text("Business room").font(.system(size: 16, weight: .semibold)).foregroundStyle(WorldLook.cream)
                        Spacer()
                        Text("Here's the room. Look right?").font(.system(size: 11.5)).foregroundStyle(WorldLook.cream.opacity(0.55))
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        row("person.2", "My job here", "Your co-founder. I push you to make progress.")
                        row("eye", "Who might see it", "Just you, for now.")
                        row("lock", "How private", "Kept apart from your personal room. Only a date or number crosses, with your OK.")
                        row("arrow.up.right", "What I push you toward", "Talking to buyers and hitting deadlines.")
                    }
                    Divider().overlay(WorldLook.cream.opacity(0.1))
                    HStack(alignment: .top, spacing: 14) {
                        rule("On my own", "read, draft")
                        rule("Needs your yes", "send, spend, delete")
                        rule("Only you", "change these rules")
                    }
                    HStack(spacing: 8) {
                        Text("Make the room").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(WorldLook.bg)
                            .padding(.horizontal, 14).padding(.vertical, 7).background(Capsule().fill(WorldLook.cream))
                        chip("Change something")
                    }.padding(.top, 2)
                }
                .padding(18).frame(width: 520, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(WorldLook.cream.opacity(0.1)))
                .position(x: 310, y: 268)
            }
        }
        .frame(width: 620, height: 440)
        .environment(\.colorScheme, .dark)
    }
    func chip(_ s: String, main: Bool = false) -> some View {
        Text(s).font(.system(size: 12.5, weight: .medium)).foregroundStyle(WorldLook.cream)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(Color.white.opacity(main ? 0.12 : 0.07)))
            .overlay(Capsule().strokeBorder(WorldLook.cream.opacity(main ? 0.3 : 0.14)))
            .fixedSize()
    }
    func row(_ icon: String, _ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(Color(hex: 0x9FC9B0)).frame(width: 18)
            Text(k).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(WorldLook.cream.opacity(0.9)).frame(width: 165, alignment: .leading)
            Text(v).font(.system(size: 12.5)).foregroundStyle(WorldLook.cream.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
        }
    }
    func rule(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k.uppercased()).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(WorldLook.cream.opacity(0.5))
            Text(v).font(.system(size: 12)).foregroundStyle(WorldLook.cream.opacity(0.85))
        }
    }
}

// MARK: - "Ready for you" shelf (render-only design preview): what Nova and her helpers made.
struct ShelfCard: View {
    let icon: String
    let title: String
    let detail: String
    let from: String
    var fresh = false
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.07))
                .frame(width: 34, height: 34)
                .overlay(Image(systemName: icon).font(.system(size: 14)).foregroundStyle(Color(hex: 0xFFE2C2)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(WorldLook.cream.opacity(0.95))
                Text(detail).font(.system(size: 11)).foregroundStyle(WorldLook.cream.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
                Text(from).font(.system(size: 10)).foregroundStyle(WorldLook.cream.opacity(0.45))
            }
            Spacer(minLength: 0)
            if fresh { Circle().fill(Color(hex: 0xFFE2C2)).frame(width: 6, height: 6).padding(.top, 4) }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(fresh ? 0.07 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(WorldLook.cream.opacity(fresh ? 0.22 : 0.07)))
        .shadow(color: Color(hex: 0xFFE2C2, fresh ? 0.12 : 0), radius: 10)
    }
}

struct ShelfScene: View {
    var t: Double = 21.7
    var open = false
    var body: some View {
        ZStack(alignment: .topLeading) {
            WorldLook.bg
            RadialGradient(colors: [Color(hex: 0x24262A, 0.6), .clear], center: UnitPoint(x: 0.36, y: 0.48), startRadius: 10, endRadius: 280)
            Text("Good afternoon, Omar.").font(.system(size: 17, weight: .semibold)).foregroundStyle(WorldLook.cream.opacity(0.9))
                .position(x: 290, y: 34)
            Presence(t: t, lean: .zero, voice: 0.2, energy: 0.15).frame(width: 280, height: 280).scaleEffect(0.6).position(x: 290, y: 224)
            Text("Nova").font(.system(size: 12, weight: .semibold)).foregroundStyle(WorldLook.cream.opacity(0.8)).position(x: 290, y: 290)
            HelperOrb(state: .working, t: t, size: 40).position(x: 140, y: 150)
            HelperLabel(title: "Flight to Quebec", line: "Checking Google Flights…").position(x: 140, y: 198)
            // done helper flying to the shelf
            Path { p in
                p.move(to: CGPoint(x: 330, y: 250))
                p.addQuadCurve(to: CGPoint(x: 548, y: 112), control: CGPoint(x: 450, y: 160))
            }
            .stroke(
                LinearGradient(colors: [WorldLook.cream.opacity(0), WorldLook.cream.opacity(0.3)], startPoint: .leading, endPoint: .trailing),
                style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [1, 6]))
            HStack {
                Text("Talk to Nova…").font(.system(size: 13)).foregroundStyle(WorldLook.cream.opacity(0.5))
                Spacer()
                Image(systemName: "mic").foregroundStyle(WorldLook.cream.opacity(0.65))
            }
            .padding(.horizontal, 16).padding(.vertical, 10).frame(width: 340)
            .background(Capsule().fill(Color.white.opacity(0.06)))
            .overlay(Capsule().strokeBorder(WorldLook.cream.opacity(0.1)))
            .position(x: 290, y: 404)

            // the shelf
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Ready for you").font(.system(size: 13, weight: .semibold)).foregroundStyle(WorldLook.cream.opacity(0.9))
                    Text("2 new").font(.system(size: 10.5, weight: .medium)).foregroundStyle(WorldLook.bg)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Color(hex: 0xFFE2C2)))
                    Spacer()
                }.padding(.bottom, 2)
                ShelfCard(
                    icon: "receipt", title: "Receipts 2026", detail: "23 receipts · $1,284 total", from: "Receipts helper · just now", fresh: true)
                ShelfCard(
                    icon: "airplane", title: "Quebec flight prices", detail: "Newark $3,104 · Philadelphia $3,416", from: "Flight helper · 1:17 PM",
                    fresh: true)
                ShelfCard(icon: "envelope", title: "Reply to the school", detail: "Draft, not sent", from: "Nova · yesterday")
                ShelfCard(icon: "folder", title: "Downloads, tidied", detail: "9 folders · nothing deleted", from: "Downloads helper · Mon")
                Spacer()
                HStack(spacing: 5) {
                    Image(systemName: "folder").font(.system(size: 10))
                    Text("All saved in Documents › Made by Nova").font(.system(size: 10.5))
                }.foregroundStyle(WorldLook.cream.opacity(0.5))
            }
            .padding(14).frame(width: 250, height: 410, alignment: .top)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.035)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(WorldLook.cream.opacity(0.07)))
            .position(x: 680, y: 225)

            if open {
                Color.black.opacity(0.45)
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "receipt").foregroundStyle(Color(hex: 0xFFE2C2))
                        Text("Receipts 2026").font(.system(size: 15, weight: .semibold)).foregroundStyle(WorldLook.cream)
                        Spacer()
                        Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(WorldLook.cream.opacity(0.6))
                    }
                    Text("23 receipts from this year, $1,284 in total.").font(.system(size: 13.5)).foregroundStyle(WorldLook.cream.opacity(0.9))
                    VStack(spacing: 6) {
                        ForEach(
                            [
                                ("Amazon", "Mar 4", "$212.40"), ("Apple", "Jun 18", "$129.00"), ("Costco", "Aug 2", "$318.40"),
                                ("Target", "Sep 9", "$64.15"),
                            ], id: \.0
                        ) { r in
                            HStack {
                                Text(r.0)
                                Spacer()
                                Text(r.1).foregroundStyle(WorldLook.cream.opacity(0.5))
                                Text(r.2).frame(width: 70, alignment: .trailing)
                            }
                            .font(.system(size: 12.5)).foregroundStyle(WorldLook.cream.opacity(0.85))
                        }
                        Text("+ 19 more").font(.system(size: 11.5)).foregroundStyle(WorldLook.cream.opacity(0.5)).frame(
                            maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(10).background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
                    HStack(spacing: 8) {
                        Text("Open in Numbers").font(.system(size: 12, weight: .semibold)).foregroundStyle(WorldLook.bg)
                            .padding(.horizontal, 12).padding(.vertical, 6).background(Capsule().fill(WorldLook.cream))
                        ForEach(["Show in Finder", "Ask Nova about it"], id: \.self) { c in
                            Text(c).font(.system(size: 12, weight: .medium)).foregroundStyle(WorldLook.cream)
                                .padding(.horizontal, 11).padding(.vertical, 6)
                                .background(Capsule().fill(Color.white.opacity(0.08)))
                                .overlay(Capsule().strokeBorder(WorldLook.cream.opacity(0.14)))
                        }
                    }
                    Text("Tip: drag the card into Mail or Messages to share it.").font(.system(size: 10.5)).foregroundStyle(
                        WorldLook.cream.opacity(0.45))
                }
                .padding(18).frame(width: 420)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(hex: 0x1E1E22, 0.98)))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(WorldLook.cream.opacity(0.14)))
                .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
                .position(x: 410, y: 225)
            }
        }
        .frame(width: 820, height: 450)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Helpers (render-only design preview): Nova in the middle, each separate job as a small orb around her.

enum HelperState { case working, needsYes, done, stopped }

struct HelperOrb: View {
    let state: HelperState
    let t: Double
    var size: CGFloat = 46
    var body: some View {
        let warm = state == .needsYes
        ZStack {
            if warm {
                ForEach(0..<2, id: \.self) { i in
                    let p = (t * 0.6 + Double(i) * 0.5).truncatingRemainder(dividingBy: 1)
                    Circle().stroke(Color(hex: 0xF0A04B, 0.85 * (1 - p)), lineWidth: 1.6)
                        .frame(width: size * (1.1 + 0.45 * p), height: size * (1.1 + 0.45 * p))
                }
            }
            FloatingOrb(state: state == .working ? .working : .idle, size: size, fixedT: t)
                .saturation(state == .done || state == .stopped ? 0.3 : 1)
            if warm {
                Circle().fill(
                    RadialGradient(
                        colors: [Color(hex: 0xF0A04B, 0.55), Color(hex: 0xF0A04B, 0.1)], center: .center, startRadius: 2, endRadius: size * 0.55)
                )
                .frame(width: size, height: size).blendMode(.plusLighter)
            }
            if state == .done {
                Circle().fill(WorldLook.cream).frame(width: 16, height: 16)
                    .overlay(Image(systemName: "checkmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(WorldLook.bg))
                    .offset(x: size * 0.36, y: -size * 0.36)
            }
        }
        .frame(width: size * 1.8, height: size * 1.8)
    }
}

struct HelperLabel: View {
    let title: String
    let line: String
    var warm = false
    var body: some View {
        VStack(spacing: 2) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(warm ? Color(hex: 0xF6B46E) : WorldLook.cream.opacity(0.92))
            Text(line).font(.system(size: 10.5)).foregroundStyle(WorldLook.cream.opacity(warm ? 0.8 : 0.66))
        }.multilineTextAlignment(.center).fixedSize()
    }
}

struct HelpersScene: View {
    var t: Double = 21.7
    var open = false  // a helper tapped: its little conversation shown
    var body: some View {
        let novaY: CGFloat = open ? 336 : 214
        ZStack {
            WorldLook.bg
            RadialGradient(colors: [Color(hex: 0x24262A, 0.6), .clear], center: UnitPoint(x: 0.5, y: novaY / 440), startRadius: 10, endRadius: 280)
            Text("Good afternoon, Omar.").font(.system(size: 17, weight: .semibold)).foregroundStyle(WorldLook.cream.opacity(0.9))
                .position(x: 310, y: 30)
            // Nova
            Presence(t: t, lean: .zero, voice: open ? 0 : 0.25, energy: 0.15)
                .frame(width: 280, height: 280).scaleEffect(open ? 0.42 : 0.6).position(x: 310, y: novaY)
                .opacity(open ? 0.5 : 1)
            Text("Nova").font(.system(size: 12, weight: .semibold)).foregroundStyle(WorldLook.cream.opacity(open ? 0.45 : 0.8))
                .position(x: 310, y: novaY + (open ? 56 : 66))

            if open {
                // Tapped "Flight to Quebec": the orb comes forward and you talk to that job directly.
                HelperOrb(state: .working, t: t, size: 30).position(x: 310, y: 66)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Text("Flight to Quebec").font(.system(size: 13, weight: .semibold)).foregroundStyle(WorldLook.cream)
                        Text("· working").font(.system(size: 11.5)).foregroundStyle(WorldLook.cream.opacity(0.6))
                        Spacer()
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                            Text("Nova")
                        }
                        .font(.system(size: 11.5, weight: .medium)).foregroundStyle(WorldLook.cream.opacity(0.85))
                        .padding(.horizontal, 9).padding(.vertical, 4).background(Capsule().fill(Color.white.opacity(0.08)))
                    }
                    Text("PHL → YQB, Dec 20–24. Cheapest right now: $248 on United, 1 stop. I'll check every morning and tell you if it drops.")
                        .font(.system(size: 13)).foregroundStyle(WorldLook.cream.opacity(0.88)).lineSpacing(2).fixedSize(
                            horizontal: false, vertical: true)
                    HStack {
                        Text("make it Dec 21 instead").font(.system(size: 12.5)).foregroundStyle(WorldLook.cream.opacity(0.9))
                        Spacer()
                        Image(systemName: "mic").font(.system(size: 13)).foregroundStyle(WorldLook.cream.opacity(0.65))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Capsule().fill(Color.white.opacity(0.07)))
                }
                .padding(14).frame(width: 330)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(hex: 0x1E1E22, 0.97)))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(WorldLook.cream.opacity(0.14)))
                .shadow(color: .black.opacity(0.45), radius: 16, y: 6)
                .position(x: 310, y: 194)
                // the other helpers step back, still visible
                HelperOrb(state: .needsYes, t: t, size: 30).opacity(0.75).position(x: 520, y: 336)
                HelperLabel(title: "Downloads", line: "Needs your yes", warm: true).scaleEffect(0.9).position(x: 520, y: 374)
                HelperOrb(state: .done, t: t, size: 26).opacity(0.7).position(x: 100, y: 336)
                HelperLabel(title: "Receipts", line: "Done").scaleEffect(0.9).position(x: 100, y: 370)
            } else {
                // working: flight watch (upper left)
                HelperOrb(state: .working, t: t).position(x: 132, y: 132)
                HelperLabel(title: "Flight to Quebec", line: "Checking Google Flights…").position(x: 132, y: 184)
                // needs a yes (upper right)
                HelperOrb(state: .needsYes, t: t).position(x: 492, y: 150)
                HelperLabel(title: "Downloads", line: "Needs your yes · tap to answer", warm: true).position(x: 492, y: 202)
                // done: drifting back in to Nova
                HelperOrb(state: .done, t: t, size: 36).position(x: 420, y: 292)
                HelperLabel(title: "Receipts", line: "Done · $1,284 this year").position(x: 420, y: 334)
                // Talk to Nova any time, even while helpers work
                HStack {
                    Text("Talk to Nova…").font(.system(size: 13)).foregroundStyle(WorldLook.cream.opacity(0.5))
                    Spacer()
                    Image(systemName: "mic").foregroundStyle(WorldLook.cream.opacity(0.65))
                }
                .padding(.horizontal, 16).padding(.vertical, 10).frame(width: 360)
                .background(Capsule().fill(Color.white.opacity(0.06)))
                .overlay(Capsule().strokeBorder(WorldLook.cream.opacity(0.1)))
                .position(x: 310, y: 404)
            }
        }
        .frame(width: 620, height: 440)
        .environment(\.colorScheme, .dark)
    }
}

struct AwayScene: View {
    var t: Double = 33.1
    var body: some View {
        ZStack {
            WorldLook.bg
            RadialGradient(colors: [Color(hex: 0x24262A, 0.6), .clear], center: UnitPoint(x: 0.5, y: 0.28), startRadius: 10, endRadius: 260)
            Presence(t: t, lean: .zero, voice: 0.4, energy: 0.2).frame(width: 280, height: 280).scaleEffect(0.5).position(x: 310, y: 112)
            VStack(alignment: .leading, spacing: 12) {
                Text("While you were gone").font(.system(size: 13, weight: .semibold)).foregroundStyle(WorldLook.cream.opacity(0.8))
                ForEach(
                    [
                        ("airplane", "The flight to Quebec dropped to $214. Want me to hold it?"),
                        ("folder", "Your Downloads are sorted into 9 folders. Nothing was deleted."),
                        ("receipt", "Your receipts this year add up to $1,284."),
                    ], id: \.1
                ) { r in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: r.0).font(.system(size: 13)).foregroundStyle(Color(hex: 0xFFE2C2)).frame(width: 18)
                        Text(r.1).font(.system(size: 14)).foregroundStyle(WorldLook.cream.opacity(0.92)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 8) {
                    Text("Hold the flight").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(WorldLook.bg)
                        .padding(.horizontal, 14).padding(.vertical, 7).background(Capsule().fill(WorldLook.cream))
                    ForEach(["Show the folders", "Not now"], id: \.self) { c in
                        Text(c).font(.system(size: 12.5, weight: .medium)).foregroundStyle(WorldLook.cream)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                            .overlay(Capsule().strokeBorder(WorldLook.cream.opacity(0.14)))
                    }
                }.padding(.top, 4)
            }
            .padding(20).frame(width: 500, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(WorldLook.cream.opacity(0.08)))
            .position(x: 310, y: 300)
        }
        .frame(width: 620, height: 440)
        .environment(\.colorScheme, .dark)
    }
}
