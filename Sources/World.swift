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

// MARK: - The world: everything One can reach, floating around it

struct Node: Identifiable, Hashable {
    let id: String
    let symbol: String
    let line: String
    let voice: String?
}

let worldNodes: [Node] = [
    Node(id: "Files", symbol: "folder", line: "I find, sort and tidy the folders you allow.", voice: "tourFiles"),
    Node(id: "Browser", symbol: "safari", line: "I open sites and click through them as you, in your own browser.", voice: "tourBrowser"),
    Node(id: "Email", symbol: "envelope", line: "I read every inbox you have and tell you what matters.", voice: "tourEmail"),
    Node(id: "Calendar", symbol: "calendar", line: "I keep your days straight and warn you before things clash.", voice: "tourCalendar"),
    Node(id: "Phone", symbol: "iphone", line: "Text me from your phone while this Mac does the work.", voice: "tourPhone"),
    Node(id: "Passwords", symbol: "key", line: "I sign in for you with your password manager, only with your OK.", voice: "tourPasswords"),
    Node(id: "Web", symbol: "globe", line: "I look things up for you and come back with a short, clear answer.", voice: "tourWeb"),
    Node(id: "News", symbol: "newspaper", line: "I follow the stories you care about and tell you each morning.", voice: "tourNews"),
]

// The world, as designed in Claude Design ("One World"): a quiet dark room, the assistant as a living
// set of soft rings in the middle, and everything it can reach drifting upright around it.

extension Color {
    init(hex: UInt32, _ a: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: a)
    }
}

enum WorldLook {
    static let bg = Color(hex: 0x141416)
    static let cream = Color(hex: 0xF4EFE8)
    static let W: CGFloat = 620, H: CGFloat = 440, CX: CGFloat = 310, CY: CGFloat = 220, RX: CGFloat = 222, RY: CGFloat = 150
    static let start = Date()
    /// Item centers: an upright orbit, one full turn every 200 s, with a little float on each.
    static func positions(_ t: Double, count: Int = worldNodes.count) -> [CGPoint] {
        let off = t * (2 * .pi / 200)
        var out: [CGPoint] = []
        for i in 0..<count {
            let di = Double(i)
            let th: Double = off + di * 2 * .pi / Double(count) - .pi / 2
            let fx: Double = sin(t * 0.37 + di * 2.1) * 3
            let fy: Double = sin(t * 0.6 + di * 1.3) * 4
            let x: CGFloat = CX + RX * CGFloat(cos(th)) + CGFloat(fx)
            let y: CGFloat = CY + RY * CGFloat(sin(th)) + CGFloat(fy)
            out.append(CGPoint(x: x, y: y))
        }
        return out
    }
    static func ease(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
}

/// The assistant: seven soft, wobbling rings that breathe, lean toward what it's talking about,
/// move with its voice and pulse when something connects.
struct Presence: View {
    let t: Double
    let lean: CGPoint
    let voice: Double
    let energy: Double
    /// Ring stroke width; bigger when the rings are drawn scaled down (floating orb) so they stay crisp.
    var line: CGFloat = 1.1
    var body: some View {
        Canvas { ctx, size in Presence.draw(&ctx, size, t: t, lean: lean, voice: voice, energy: energy, line: line) }
    }
    // Drawing is split into small typed steps: one big closure took slower Macs (CI) too long to type-check.
    static func draw(_ ctx: inout GraphicsContext, _ size: CGSize, t: Double, lean: CGPoint, voice: Double, energy: Double, line: CGFloat) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let breath: Double = 1 + 0.035 * sin(t * .pi * 2 / 5)
        let amp: Double = 1.8 + voice * 3.6 + energy * 4
        let glowC = CGPoint(x: c.x + lean.x, y: c.y + lean.y)
        let glowA: Double = 0.10 + voice * 0.05 + energy * 0.06
        let glow = Gradient(colors: [Color(.sRGB, red: 1, green: 236 / 255, blue: 214 / 255, opacity: glowA), .clear])
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .radialGradient(glow, center: glowC, startRadius: 10, endRadius: 130))
        for k in stride(from: 6, through: 0, by: -1) {
            ring(&ctx, k: Double(k), c: c, t: t, lean: lean, breath: breath, amp: amp, line: line)
        }
    }
    static func ringPath(o: CGPoint, base: Double, amp: Double, kd: Double, t: Double) -> Path {
        var path = Path()
        let scale: Double = amp * (1 + kd * 0.18)
        for sidx in 0...120 {
            let a: Double = Double(sidx) / 120 * 2 * .pi
            let w1: Double = 0.55 * sin(3 * a + t * 0.7 + kd * 0.9)
            let w2: Double = 0.3 * sin(5 * a - t * 0.9 + kd * 1.7)
            let w3: Double = 0.15 * sin(2 * a + t * 1.3)
            let r: Double = base + scale * (w1 + w2 + w3)
            let pt = CGPoint(x: o.x + CGFloat(cos(a) * r), y: o.y + CGFloat(sin(a) * r))
            if sidx == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        path.closeSubpath()
        return path
    }
    static func ring(_ ctx: inout GraphicsContext, k kd: Double, c: CGPoint, t: Double, lean: CGPoint, breath: Double, amp: Double, line: CGFloat) {
        let base: Double = (40 + kd * 4.6) * breath
        let o = CGPoint(x: c.x + lean.x * CGFloat(kd / 7), y: c.y + lean.y * CGFloat(kd / 7))
        let path = ringPath(o: o, base: base, amp: amp, kd: kd, t: t)
        if kd == 0 {
            let fill = Gradient(colors: [
                Color(.sRGB, red: 1, green: 246 / 255, blue: 236 / 255, opacity: 0.20),
                Color(.sRGB, red: 1, green: 246 / 255, blue: 236 / 255, opacity: 0.03),
            ])
            ctx.fill(path, with: .radialGradient(fill, center: CGPoint(x: o.x - 8, y: o.y - 10), startRadius: 2, endRadius: CGFloat(base * 1.1)))
        }
        let hue: Double = (32 + kd * 26) / 360
        let col = Color(hue: hue, saturation: 0.30, brightness: 0.95).opacity(0.62 - kd * 0.07)
        ctx.stroke(path, with: .color(col), lineWidth: line)
    }
}

struct WorldTile: View {
    let n: Node
    let selected: Bool
    let lit: Bool
    let hover: Bool
    var body: some View {
        let strong = selected || lit
        VStack(spacing: 8) {
            Image(systemName: n.symbol).font(.system(size: 19, weight: .light))
                .foregroundStyle(selected ? Color(hex: 0x141416) : (strong || hover ? .white : WorldLook.cream.opacity(0.85)))
                .frame(width: 52, height: 52)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(selected ? WorldLook.cream : WorldLook.cream.opacity(lit ? 0.14 : hover ? 0.09 : 0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(WorldLook.cream.opacity(selected ? 0 : lit ? 0.35 : hover ? 0.22 : 0.10), lineWidth: 1)
                )
                .shadow(color: Color(hex: 0xFFECD6, selected ? 0.45 : lit ? 0.35 : 0), radius: 14)
            Text(n.id).font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(strong ? .white : WorldLook.cream.opacity(0.72)).fixedSize()
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(WorldLook.bg.opacity(0.9)))  // threads pass under the label to the tile
        }
        .frame(width: 88, height: 82, alignment: .top)
        .animation(.easeOut(duration: 0.45), value: selected)
        .animation(.easeOut(duration: 0.45), value: lit)
    }
}

/// One frame of the stage (620 x 440 design units). Pure function of time, so it can be rendered to a PNG too.
struct WorldCanvas: View {
    let t: Double
    let lit: Int?  // the item being talked about in the tour
    let picking: Bool
    let linked: [String: Double]  // item -> time it was tapped
    let speaking: Bool
    var hover: String? = nil
    var tap: (Node) -> Void = { _ in }
    var onHover: (String?) -> Void = { _ in }
    var dim: Set<String> = []  // not built yet: drawn faint, no thread
    var nodes: [Node] = worldNodes

    var body: some View {
        let worldNodes = nodes
        let pos = WorldLook.positions(t, count: nodes.count)
        let prog: [Double] = worldNodes.map { n in linked[n.id].map { min(1, max(0, (t - $0) / 0.8)) } ?? 0 }
        let lastDone = worldNodes.compactMap { linked[$0.id].map { $0 + 0.8 } }.filter { $0 <= t }.max()
        let energy = lastDone.map { exp(-(t - $0) * 1.8) } ?? 0
        let voice = speaking ? 0.35 + 0.65 * abs(sin(t * 3.3) * sin(t * 5.7 + 1)) : 0
        var lean = CGPoint.zero
        if let l = lit {
            let dx = pos[l].x - WorldLook.CX
            let dy = pos[l].y - WorldLook.CY
            let d = max(hypot(dx, dy), 1)
            lean = CGPoint(x: dx / d * 5, y: dy / d * 5)
        }
        return ZStack(alignment: .topLeading) {
            Presence(t: t, lean: lean, voice: voice, energy: energy)
                .frame(width: 280, height: 280)
                .position(x: WorldLook.CX, y: WorldLook.CY)
            Canvas { ctx, _ in
                for (i, n) in worldNodes.enumerated() where prog[i] > 0 {
                    let (x, y) = (pos[i].x, pos[i].y)
                    let dx = x - WorldLook.CX
                    let dy = y - WorldLook.CY
                    let d = max(hypot(dx, dy), 1)
                    let ux = dx / d
                    let uy = dy / d
                    let sx = WorldLook.CX + ux * 70
                    let sy = WorldLook.CY + uy * 70
                    let sxx: CGFloat = abs(ux) > 1e-3 ? 27 / abs(ux) : 1e9
                    let syy: CGFloat = uy < -1e-3 ? 27 / -uy : (uy > 1e-3 ? 27 / uy : 1e9)
                    let cl = min(sxx, syy)
                    let ex = x - ux * cl
                    let ey = y - uy * cl
                    let bend = 14 * CGFloat(sin(t * 0.5 + Double(i)))
                    let mx = (sx + ex) / 2 - uy * bend
                    let my = (sy + ey) / 2 + ux * bend
                    var path = Path()
                    path.move(to: CGPoint(x: ex, y: ey))
                    path.addQuadCurve(to: CGPoint(x: sx, y: sy), control: CGPoint(x: mx, y: my))
                    let e = WorldLook.ease(prog[i])
                    ctx.stroke(
                        path.trimmedPath(from: 0, to: e), with: .color(WorldLook.cream.opacity(0.2 + 0.35 * e)),
                        style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                    if prog[i] >= 1 {
                        let f = (t * 0.35 + Double(i) * 0.37).truncatingRemainder(dividingBy: 1)
                        let u = CGFloat(f)
                        let a0 = (1 - u) * (1 - u)
                        let a1 = 2 * (1 - u) * u
                        let a2 = u * u
                        let qx = a0 * ex + a1 * mx + a2 * sx
                        let qy = a0 * ey + a1 * my + a2 * sy
                        ctx.fill(
                            Path(ellipseIn: CGRect(x: qx - 2, y: qy - 2, width: 4, height: 4)),
                            with: .color(Color(hex: 0xFFF6EC, sin(f * .pi) * 0.9)))
                    }
                    _ = n
                }
            }
            .frame(width: WorldLook.W, height: WorldLook.H)
            .allowsHitTesting(false)
            ForEach(Array(worldNodes.enumerated()), id: \.element.id) { i, n in
                let sel = linked[n.id] != nil
                let isLit = lit == i
                let op: Double = dim.contains(n.id) ? (isLit ? 0.6 : 0.28) : picking ? 1 : (lit == nil ? 0.7 : (isLit ? 1 : 0.32))
                WorldTile(n: n, selected: sel, lit: isLit, hover: picking && hover == n.id)
                    .opacity(op).animation(.easeOut(duration: 0.6), value: op)
                    .contentShape(Rectangle())
                    .onTapGesture { if picking { tap(n) } }
                    .onHover { onHover($0 ? n.id : nil) }
                    .position(x: pos[i].x, y: pos[i].y + 15)
            }
        }
        .frame(width: WorldLook.W, height: WorldLook.H)
    }
}

struct WorldStage: View {
    @ObservedObject var m: Model
    @State var folderSheet = false
    @State var hover: String?
    @State var linkedAt: [String: Double] = [:]
    var picking: Bool { !m.touring }
    var litIndex: Int? { m.tourNode.flatMap { id in worldNodes.firstIndex { $0.id == id } } }
    var body: some View {
        ZStack {
            WorldLook.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                VStack(spacing: 10) {
                    Text(m.tourNode ?? " ").font(.system(size: 12, weight: .medium)).tracking(0.4)
                        .foregroundStyle(WorldLook.cream.opacity(0.5)).opacity(m.tourNode == nil ? 0 : 1)
                    Text(m.worldCaption).font(.system(size: 22, weight: .medium)).tracking(-0.2)
                        .foregroundStyle(.white).multilineTextAlignment(.center).frame(maxWidth: 440)
                    Text("Tap to connect. You can change this anytime.").font(.system(size: 13))
                        .foregroundStyle(WorldLook.cream.opacity(0.6)).opacity(picking ? 1 : 0)
                }
                .frame(minHeight: 120).padding(.top, 28).padding(.horizontal, 24)
                .id(m.worldCaption).transition(.opacity.combined(with: .offset(y: -6)))
                .animation(.easeOut(duration: 0.32), value: m.worldCaption)
                GeometryReader { geo in
                    let k = min(geo.size.width / WorldLook.W, geo.size.height / WorldLook.H, 1.2)
                    TimelineView(.animation) { tl in
                        WorldCanvas(
                            t: tl.date.timeIntervalSince(WorldLook.start), lit: litIndex, picking: picking,
                            linked: linkedAt, speaking: Date() < m.speakUntil, hover: hover,
                            tap: tapped, onHover: { hover = $0 })
                    }
                    .scaleEffect(k)
                    .frame(width: geo.size.width, height: geo.size.height)
                }
                ZStack {
                    Button("Skip tour") { m.skipTour = true }.buttonStyle(.plain)
                        .foregroundStyle(WorldLook.cream.opacity(0.55)).opacity(m.touring ? 1 : 0)
                    VStack(spacing: 12) {
                        Button {
                            Task { await m.connectionsChosen() }
                        } label: {
                            Text(m.pickedConnections.isEmpty ? "Connect" : "Connect \(m.pickedConnections.count)")
                                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Color(hex: 0x141416))
                                .frame(minWidth: 150).padding(.vertical, 11)
                                .background(Capsule().fill(WorldLook.cream))
                        }.buttonStyle(.plain).opacity(m.pickedConnections.isEmpty ? 0.35 : 1).disabled(m.pickedConnections.isEmpty)
                        Button("Not now") {
                            m.pickedConnections = []
                            Task { await m.connectionsChosen() }
                        }
                        .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(WorldLook.cream.opacity(0.6))
                    }.opacity(picking ? 1 : 0).allowsHitTesting(picking)
                }.frame(height: 90).padding(.bottom, 26).animation(.easeOut(duration: 0.6), value: m.touring)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $folderSheet) {
            FolderSheet(m: m) {
                folderSheet = false
                syncLinks()
            }
        }
        .onChange(of: m.pickedConnections) { _, _ in syncLinks() }
        .task { await m.runTour() }
    }
    func syncLinks() {
        let now = Date().timeIntervalSince(WorldLook.start)
        for id in m.pickedConnections where linkedAt[id] == nil { linkedAt[id] = now }
        for id in linkedAt.keys where !m.pickedConnections.contains(id) { linkedAt[id] = nil }
    }
    func tapped(_ n: Node) {
        if n.id == "Files" { folderSheet = true } else { m.toggleConnection(n.id) }
    }
}

struct FolderSheet: View {
    @ObservedObject var m: Model
    let done: () -> Void
    @State var folders: [String] = Access.folders
    let common = ["Desktop", "Documents", "Downloads"].map { NSHomeDirectory() + "/" + $0 }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Which folders can I see?").font(.title2.bold())
            Text("Everything else stays locked. You can change this any time.").foregroundStyle(.secondary)
            HStack {
                ForEach(common, id: \.self) { f in
                    Chip(label: (f as NSString).lastPathComponent, selected: folders.contains(f)) { toggle(f) }
                }
            }
            Button("Choose another folder…", action: pick)
            ForEach(folders.filter { !common.contains($0) }, id: \.self) { f in
                HStack {
                    Image(systemName: "folder").font(.system(size: 13, weight: .light))
                    Text((f as NSString).abbreviatingWithTildeInPath)
                    Spacer()
                    Button("Remove") { toggle(f) }.buttonStyle(.link)
                }
            }
            Spacer()
            HStack {
                Spacer()
                Button("Done") {
                    m.setFolders(folders)
                    done()
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 480, height: 360)
    }
    func toggle(_ p: String) { if let i = folders.firstIndex(of: p) { folders.remove(at: i) } else { folders.append(p) } }
    func pick() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        if panel.runModal() == .OK { for u in panel.urls where !folders.contains(u.path) { folders.append(u.path) } }
    }
}
