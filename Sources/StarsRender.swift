import AppKit
import SwiftUI

// MARK: - Dev only: the galaxy's renders and its cost (run from a test copy, never the real One).
//   One --render-stars <prefix>    writes <prefix>-home.png, -helper.png, -startup.png, -setup.png
//   One --stars-cpu <seconds>      draws the live sky at its real rate (12 a second) for that long, prints ms per frame
//   One --stars-live <seconds>     a real window: process CPU with the twinkling sky, with Reduce Motion, and with none

enum StarsRender {
    @MainActor static func cli(_ args: [String]) {
        if let k = args.firstIndex(of: "--render-stars"), k + 1 < args.count {
            TestWorld.enter()
            MainActor.assumeIsolated { renders(args[k + 1]) }
            exit(0)
        }
        if let k = args.firstIndex(of: "--stars-live"), k + 1 < args.count {
            TestWorld.enter()
            MainActor.assumeIsolated { live(Double(args[k + 1]) ?? 10) }
            exit(0)
        }
        if let k = args.firstIndex(of: "--stars-cpu"), k + 1 < args.count {
            TestWorld.enter()
            MainActor.assumeIsolated { cpu(Double(args[k + 1]) ?? 20) }
            exit(0)
        }
    }

    @MainActor static func renders(_ out: String) {
        ChatText.still = true
        let home = HomeRender.scene(4)
        HomeRender.png(home, "\(out)-home.png", height: 760)
        print("wrote \(out)-home.png")
        let m = Model.shared
        if var h = m.helpers.first {
            h.asked = "Get me ready for my 1:1 with Germán on Thursday."
            h.reply =
                "I pulled the last three 1:1 notes and this sprint's open items. The prep pack is ready: agenda, two wins to mention, and three questions about the release date. Want me to send Germán the agenda now?\n\n[choices: Yes, send it | Not yet | Change the agenda]"
            m.helpers[0] = h
            m.openHelper = h.id
        }
        HomeRender.png(HomeRender.scene(4, keep: true), "\(out)-helper.png", height: 760)
        print("wrote \(out)-helper.png")
        m.openHelper = nil
        m.step = .installing
        m.bubbles = [
            Bubble(fromMe: false, text: "First, I'm setting myself up on this Mac. This only happens once. Please hang on while I get ready.")
        ]
        m.installDone = 9
        m.installLine = "Getting my voice ready…"
        png(AnyView(SetupStill(m: m)), "\(out)-startup.png")
        m.step = .world
        m.touring = false
        png(AnyView(WorldStage(m: m)), "\(out)-setup.png")
    }

    @MainActor static func png(_ v: AnyView, _ path: String) {
        let r = ImageRenderer(content: v.frame(width: 1180, height: 760).environment(\.colorScheme, .dark).foregroundStyle(WorldLook.cream))
        r.scale = 2
        if let img = r.nsImage, let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t),
            let d = rep.representation(using: .png, properties: [:])
        {
            try? d.write(to: URL(fileURLWithPath: path))
            print("wrote \(path)")
        }
    }

    static func cpuTime() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6 + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
    }

    /// A real 1180 × 760 window, like home: the sky twinkling, then with Reduce Motion, then no sky at all.
    @MainActor static func live(_ seconds: Double) {
        NSApplication.shared.setActivationPolicy(.accessory)
        let w = NSWindow(
            contentRect: NSRect(x: 40, y: 40, width: 1180, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua)
        func scene(stars: Bool, still: Bool) -> AnyView {
            let words = Text("Good morning, Omar.").font(.system(size: 26, weight: .semibold)).foregroundStyle(WorldLook.cream).starCalm()
            let body = VStack {
                words.padding(.top, 30)
                Spacer()
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            return AnyView(
                Group { if stars { body.withStars(top: 52) } else { body } }.id("\(stars)-\(still)")
                    .environment(\.colorScheme, .dark).background(WorldLook.bg))
        }
        let host = NSHostingView(rootView: scene(stars: true, still: false))
        w.contentView = host
        w.orderFrontRegardless()
        // A real app loop (NSApp.run), as One has: each phase settles 1 s, then is measured.
        let phases: [(String, Bool, Bool)] = [("twinkling sky", true, false), ("Reduce Motion (still sky)", true, true), ("no sky", false, false)]
        var k = 0
        var c0 = 0.0
        var t0 = Date()
        func begin() {
            let (_, stars, still) = phases[k]
            Stars.reduceMotion = still  // what the Mac's Reduce Motion setting does to the sky
            host.rootView = scene(stars: stars, still: still)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                c0 = cpuTime()
                t0 = Date()
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                    let pct = (cpuTime() - c0) / Date().timeIntervalSince(t0) * 100
                    print(String(format: "%@: process CPU %.1f%% of one core over %.0f s", phases[k].0, pct, seconds))
                    fflush(stdout)
                    k += 1
                    if k < phases.count {
                        begin()
                    } else {
                        NSApp.stop(nil)
                        NSApp.postEvent(
                            NSEvent.otherEvent(
                                with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                subtype: 0, data1: 0, data2: 0)!, atStart: true)
                    }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { begin() }
        NSApp.run()
        w.orderOut(nil)
    }

    /// Draws exactly what the live sky draws each tick, into a 2x window-sized bitmap, at 12 a second.
    @MainActor static func cpu(_ seconds: Double) {
        let size = CGSize(width: 1180, height: 760)
        let zones = [
            Stars.Zone(rect: CGRect(x: 400, y: 300, width: 92, height: 92), calm: StarCalm(radius: 100, feather: 50)),
            Stars.Zone(rect: CGRect(x: 905, y: 60, width: 260, height: 690), calm: StarCalm(pad: 0, feather: 18)),
            Stars.Zone(rect: CGRect(x: 140, y: 650, width: 620, height: 50), calm: StarCalm()),
        ]
        var u0 = rusage()
        getrusage(RUSAGE_SELF, &u0)
        let start = Date()
        var frames = 0
        var busy = 0.0
        while Date().timeIntervalSince(start) < seconds {
            let t0 = Date()
            let t = t0.timeIntervalSince(start)
            let r = ImageRenderer(
                content: Canvas { ctx, s in Stars.draw(&ctx, size: s, t: t, zones: zones) }.frame(width: size.width, height: size.height))
            r.scale = 2
            _ = r.cgImage
            busy += Date().timeIntervalSince(t0)
            frames += 1
            let next = start.addingTimeInterval(Double(frames) / Stars.fps)
            let wait = next.timeIntervalSinceNow
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        }
        let ms = busy / Double(max(frames, 1)) * 1000
        var u1 = rusage()
        getrusage(RUSAGE_SELF, &u1)
        func sec(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        let used = sec(u1.ru_utime) + sec(u1.ru_stime) - sec(u0.ru_utime) - sec(u0.ru_stime)
        let cpu = used / Date().timeIntervalSince(start) * 100
        print(String(format: "stars: %d frames in %.0f s, %.2f ms per frame; process CPU %.1f%% of one core", frames, seconds, ms, cpu))
    }
}

/// The setup screen as it really looks while One installs itself (what `OnboardingView` shows, without its task).
struct SetupStill: View {
    @ObservedObject var m: Model
    var body: some View {
        VStack(spacing: 0) {
            // `Stage` fades its lines in on appear, which a still never runs: its newest line, drawn as it settles.
            Spacer(minLength: 20)
            MarkdownText(text: m.bubbles.last?.text ?? "", size: 20).font(.system(size: 26, weight: .medium)).multilineTextAlignment(.center)
                .frame(maxWidth: 480).starCalm(feather: 30, floor: 0.15).padding(.horizontal, 32)
            Spacer(minLength: 20)
            VStack(spacing: 14) {
                // ImageRenderer can't draw a ProgressView (it shows a yellow box): the same bar, drawn.
                ZStack(alignment: .leading) {
                    Capsule().fill(WorldLook.cream.opacity(0.12))
                    Capsule().fill(Color.accentColor).frame(width: 320 * CGFloat(min(m.installDone, 26)) / 26)
                }.frame(width: 320, height: 5)
                Text(m.installLine).font(.caption).foregroundStyle(.secondary)
            }
            .starCalm(feather: 26, floor: 0.15).padding(24).frame(maxWidth: .infinity)
        }
        .withStars()
        .background(Mist())
        .background(WorldLook.bg)
    }
}
