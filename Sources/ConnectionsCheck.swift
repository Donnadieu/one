import AppKit
import SwiftUI

// MARK: - Check: the Connections screen opens smoothly (`One --test-connections-open [rounds] [png dir]`)

/// Opens a window like Home (the orb breathing behind, the status read ahead the way Home does), then
/// opens Connections as the same pop-up the toolbar button opens, and measures how evenly frames arrive
/// once it's in: the gaps between animation frames and how long the main thread was busy. Timing starts
/// after the short fade-in. Optionally saves a picture of the open pop-up. Touches no settings, brain or engine.
@MainActor
enum ConnectionsCheck {
    static var ticks: [Date] = []
    static var beats: [Date] = []
    static var recording = false
    static let slide = 0.35

    struct Host: View {
        @State var open = false
        var body: some View {
            ZStack {
                WorldLook.bg.ignoresSafeArea()
                TimelineView(.animation) { tl in
                    Presence(t: tl.date.timeIntervalSince(WorldLook.start), lean: .zero, voice: 0, energy: 0).frame(width: 280, height: 280)
                }
            }
            .frame(width: 900, height: 780)
            .onePopup($open) { _ in
                ConnectionsWorld(m: Model.shared) { open = false }.frame(width: 720, height: 680)
                    .overlay(TimelineView(.animation) { tl in Color.clear.onChange(of: tl.date) { _, d in if recording { ticks.append(d) } } })
            }
            .task { await ConnectionsWorld.prefetch() }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("oneCheckOpen"))) { _ in open = true }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("oneCheckClose"))) { _ in open = false }
        }
    }

    static func run(rounds: Int, pictures: String?) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let win = NSWindow(contentRect: NSRect(x: 160, y: 120, width: 900, height: 780), styleMask: [.titled], backing: .buffered, defer: false)
        win.contentView = NSHostingView(rootView: Host())
        win.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        // A fast heartbeat on the main thread: a long gap between beats = the main thread was busy (a dropped frame).
        let beat = Timer(timeInterval: 0.002, repeats: true) { _ in MainActor.assumeIsolated { if recording { beats.append(Date()) } } }
        RunLoop.main.add(beat, forMode: .common)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            var worst = 0.0
            var worstBlock = 0.0
            for r in 1...rounds {
                ticks = []
                beats = []
                recording = true
                let ready = ConnectionsWorld.cached != nil
                let t0 = Date()
                NotificationCenter.default.post(name: Notification.Name("oneCheckOpen"), object: nil)
                try? await Task.sleep(for: .seconds(1.2))
                recording = false
                if r == rounds, let dir = pictures, let v = win.contentView {
                    save(v, to: URL(fileURLWithPath: dir).appendingPathComponent("connections-open.png"))
                }
                let f = ticks.filter { $0.timeIntervalSince(t0) > slide }
                let b = beats.filter { $0.timeIntervalSince(t0) > slide }
                let gaps = zip(f.dropFirst(), f).map { $0.timeIntervalSince($1) * 1000 }
                let blocks = zip(b.dropFirst(), b).map { $0.timeIntervalSince($1) * 1000 }
                let maxGap = gaps.max() ?? 999
                let maxBlock = blocks.max() ?? 999
                let slow = gaps.filter { $0 > 25 }.count
                let avg = gaps.isEmpty ? 999 : gaps.reduce(0, +) / Double(gaps.count)
                let first = ticks.first.map { $0.timeIntervalSince(t0) * 1000 } ?? -1
                print(
                    String(
                        format:
                            "round %d: status read ahead %@, first frame %.0f ms, then %d frames, avg %.1f ms, longest %.1f ms, %d over 25 ms, main thread busy up to %.1f ms",
                        r, ready ? "yes" : "no", first, f.count, avg, maxGap, slow, maxBlock))
                worst = max(worst, maxGap)
                worstBlock = max(worstBlock, maxBlock)
                NotificationCenter.default.post(name: Notification.Name("oneCheckClose"), object: nil)
                try? await Task.sleep(for: .seconds(1.0))
            }
            let ok = worst < 25 && worstBlock < 25
            print(
                ok ? "PASS connections open smoothly" : "FAIL connections open in steps (longest frame \(Int(worst)) ms, busy \(Int(worstBlock)) ms)")
            exit(ok ? 0 : 1)
        }
        app.run()
    }

    static func save(_ v: NSView, to url: URL) {
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("picture: \(url.path)")
    }
}
