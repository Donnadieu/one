import AppKit
import SwiftUI

// MARK: - Render-only (`--render-world <prefix>`, from a test copy): the whole home screen with 4, 8, 10, 15 or 22
// helpers, to check the constellation against the Claude Design mockup. Never run on the real One: it fills
// Model.shared with made-up helpers (tools/test-copy.sh gives the copy its own settings).

enum HomeRender {
    nonisolated(unsafe) static var closeFirst = false  // `home-close`: the first orb shows its X, as if pointed at
    static let jobs: [(String, String, String)] = [
        ("Germán 1:1 prep", "needsYes", ""), ("Canvas price options", "working", "Reading your files…"),
        ("Stale task check", "new", ""), ("Helper double count", "working", "Counting twice to be sure…"),
        ("Money since January", "done", ""), ("Check Project Ledger", "working", "Looking at X…"),
        ("Helper view design", "working", "Sketching three layouts…"), ("Argo P009 check", "done", ""),
        ("Email triage 8 PM", "needsYes", ""), ("Restore Made by Elias", "done", ""),
        ("Missing update prompt", "working", "Reading the update notes…"), ("Kaustav lead entry", "new", ""),
        ("Slack bot icon", "done", ""), ("Daily activity list", "working", "Going through today…"), ("Mark Ready as read", "done", ""),
    ]
    static func helpers(_ n: Int) -> [Helper] {
        let pick = n == 4 ? [0, 1, 2, 4] : Array(0..<n)
        return pick.map { i in
            let (title, st, line) = jobs[i % jobs.count]
            var h = Helper(title: i < jobs.count ? title : "\(title) \(i / jobs.count + 1)", task: "", state: st == "new" ? "done" : st, line: line)
            h.seen = st == "new" ? false : true
            return h
        }
    }
    @MainActor static func scene(_ n: Int, keep: Bool = false) -> AnyView {
        HomeView.still = true
        HomeView.outerStars = true
        // `home-glass`: drawn over a desktop picture (ONE_DESK=<png>; ONE_GLASS_OLD=1 for the look before the fix).
        if let d = ProcessInfo.processInfo.environment["ONE_DESK"] { HomeView.stillDesk = NSImage(contentsOfFile: d) }
        GlassStill.oldMaterial = ProcessInfo.processInfo.environment["ONE_GLASS_OLD"] == "1"
        let m = Model.shared
        m.assistantName = "Elias"
        m.userName = "Omar"
        ShelfCopy.shared.note = nil
        if !keep {
            m.helpers = helpers(n)
            m.openHelper = nil
        }
        HomeView.stillClose = closeFirst ? HelperRings.sorted(m.helpers).first?.id : nil
        m.interviewOffered = true
        m.bubbles = [
            Bubble(fromMe: true, text: "Check on everything that's still open"),
            Bubble(fromMe: false, text: "Sent three helpers. I'll tell you when they're back."),
        ]
        m.shelf = [
            ShelfItem(
                title: "Germán 1:1 prep pack", detail: "Agenda, notes and three questions to ask.", from: "MD · ready to share", path: "/tmp/g.md",
                fresh: true),
            ShelfItem(
                title: "Money since January", detail: "What came in and went out, month by month.", from: "Sheet · ready to share",
                path: "/tmp/m.csv", fresh: true),
            ShelfItem(
                title: "Canvas price options", detail: "Three plans side by side, with what each costs.", from: "PNG · ready to share",
                path: "/tmp/c.png", fresh: true),
            ShelfItem(
                title: "Daily activity list", detail: "Everything you did today, in order.", from: "MD · opened", path: "/tmp/d.md", fresh: false),
        ]
        return AnyView(
            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    HStack(spacing: 8) {
                        ForEach([0xFF5F57, 0xFEBC2E, 0x28C840], id: \.self) { Circle().fill(Color(hex: UInt32($0))).frame(width: 12, height: 12) }
                    }
                    NamePill(name: m.name) {}
                    Spacer()
                    TopBarButtons(name: m.name, voiceOff: false, paused: false)
                }
                .padding(.leading, 18).padding(.trailing, 16).frame(height: 52)
                HomeView(m: m).frame(height: (n > 22 ? 1200 : n > 15 ? 1000 : 760) - 52, alignment: .top).clipped()
            }
            .withStars(top: 52)
            .background(HomeBackdrop(outer: true))
            .clipShape(RoundedRectangle(cornerRadius: HomeView.stillDesk == nil ? 0 : 12, style: .continuous))
            .foregroundStyle(WorldLook.cream).environment(\.colorScheme, .dark))
    }
    @MainActor static func png(_ v: AnyView, _ path: String, height: CGFloat) {
        let r = ImageRenderer(content: v.frame(width: 1180, height: height))
        r.scale = 2
        if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
            let data = rep.representation(using: .png, properties: [:])
        {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
