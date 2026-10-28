import AppKit
import SwiftUI

// MARK: - Check: the Folders window fits (`One --test-folders-fit [png dir]`)

/// Opens a window like Home and opens "Which folders can I see?" as the same sheet the Folders button
/// opens, once with 0, 6 and 20 extra folders (made-up paths, nothing is saved: Done is never pressed).
/// Each time it checks that the sheet is no taller than the screen and that the whole content (title on
/// top, Done at the bottom) fits inside it, and optionally saves a picture of the open sheet.
/// Touches no settings, brain or engine.
@MainActor
enum FolderSheetCheck {
    static let sample = [
        "~/Repos", "~/conductor", "~/.gnupg", "~/.hermes/browser-profiles/elias-chrome", "~/Library/Preferences", "~/.one-signing",
    ]

    static func folders(_ n: Int) -> [String] {
        let home = NSHomeDirectory()
        return (0..<n).map { i in
            let base = i < sample.count ? sample[i] : "~/Projects/project-\(i - sample.count + 1)"
            return home + base.dropFirst()
        }
    }

    struct Pick: Identifiable {
        let n: Int
        var id: Int { n }
    }

    struct Host: View {
        @State var count: Pick?
        var body: some View {
            WorldLook.bg.frame(width: 900, height: 700)
                .sheet(item: $count) { p in FolderSheet(m: Model.shared, done: { count = nil }, folders: FolderSheetCheck.folders(p.n)) }
                .onReceive(NotificationCenter.default.publisher(for: Notification.Name("oneFoldersOpen"))) {
                    count = ($0.object as? Int).map(Pick.init)
                }
                .onReceive(NotificationCenter.default.publisher(for: Notification.Name("oneFoldersClose"))) { _ in count = nil }
        }
    }

    static func run(pictures: String?) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let win = NSWindow(contentRect: NSRect(x: 160, y: 120, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        win.contentView = NSHostingView(rootView: Host().preferredColorScheme(.dark))
        win.appearance = NSAppearance(named: .darkAqua)
        win.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.0))
            var ok = true
            let screen = NSScreen.main?.visibleFrame.height ?? 0
            for n in [0, 6, 20] {
                FolderSheet.seen = [:]
                NotificationCenter.default.post(name: Notification.Name("oneFoldersOpen"), object: n)
                try? await Task.sleep(for: .seconds(1.2))
                guard let sheet = win.attachedSheet, let v = sheet.contentView else {
                    print("FAIL \(n) folders: the sheet didn't open")
                    ok = false
                    continue
                }
                // Where the title's top and Done's bottom landed inside the sheet, against the sheet's own height.
                let have = v.bounds.height
                let top = FolderSheet.seen["title"]?.minY ?? -1
                let bottom = FolderSheet.seen["done"]?.maxY ?? .infinity
                let fits = top >= 0 && bottom <= have && sheet.frame.height <= screen
                ok = ok && fits
                print(
                    String(
                        format: "%@ %d folders: window %.0f tall, title top at %.0f, Done bottom at %.0f, screen %.0f", fits ? "PASS" : "FAIL", n,
                        have, top,
                        bottom, screen))
                if let dir = pictures {
                    picture(n, size: v.bounds.size, to: URL(fileURLWithPath: dir).appendingPathComponent("folders-\(n).png"))
                }
                NotificationCenter.default.post(name: Notification.Name("oneFoldersClose"), object: nil)
                try? await Task.sleep(for: .seconds(0.8))
            }
            print(ok ? "PASS the Folders window fits with 0, 6 and 20 folders" : "FAIL the Folders window doesn't fit")
            exit(ok ? 0 : 1)
        }
        app.run()
    }

    /// A sheet's text is drawn by macOS on top of its frosted backdrop, which a view snapshot can't capture
    /// (it comes out blank). So the picture draws the same view, at the size the sheet got, in a plain dark
    /// window of the same size; the pass/fail above comes from the real sheet.
    static func picture(_ n: Int, size: CGSize, to url: URL) {
        let view = FolderSheet(m: Model.shared, done: {}, folders: folders(n))
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(Color(hex: 0x26262B)).environment(\.colorScheme, .dark)
        let w = NSWindow(contentRect: NSRect(origin: CGPoint(x: -3000, y: 0), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua)
        let h = NSHostingView(rootView: view)
        w.contentView = h
        w.orderFront(nil)
        h.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard let rep = h.bitmapImageRepForCachingDisplay(in: h.bounds) else { return }
        h.cacheDisplay(in: h.bounds, to: rep)
        w.orderOut(nil)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("picture: \(url.path)")
    }
}
