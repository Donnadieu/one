import AppKit
import SwiftUI

// MARK: - Render-only (`--render-world <prefix>` → popup-folders, popup-connections, popup-name, popup-talk,
// popup-stop, popup-reader, popup-writing, popup-routines, popup-share): each pop-up on the shared glass over the
// home scene, to check against Claude Design "Popup Glass" (A · Smoked glass). Set ONE_DESK=<png> to draw home's own
// glass over a desktop picture too. Never run on the real One (tools/test-copy.sh gives the copy its own settings).

enum PopupRender {
    static let names = [
        "popup-folders", "popup-connections", "popup-name", "popup-talk", "popup-stop", "popup-reader", "popup-writing", "popup-routines",
        "popup-share", "popup-close",
    ]
    static let size = CGSize(width: 1180, height: 760)
    static let titleRow: CGFloat = 52

    /// The `popup-*` names in the render list; true when this name was one of them.
    @MainActor static func draw(_ name: String, _ out: String) -> Bool {
        guard name.hasPrefix("popup-") else { return false }
        let home = image(name == "popup-share" ? AnyView(roomsBehind) : HomeRender.scene(4))
        PopupLook.behind = home
        PopupLook.behindAt = CGPoint(x: 0, y: titleRow)
        defer {
            PopupLook.behind = nil
            PopupLook.behindAt = .zero
        }
        let v = ZStack(alignment: .topLeading) {
            if let home { Image(nsImage: home).resizable().frame(width: size.width, height: size.height) }
            Color.black.opacity(PopupLook.dim).frame(height: titleRow)  // the dim reaches over the title row too
            panel(name).frame(width: size.width, height: size.height - titleRow).offset(y: titleRow)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: HomeView.stillDesk == nil ? 0 : 12, style: .continuous))
        .foregroundStyle(WorldLook.cream).environment(\.colorScheme, .dark)
        save(AnyView(v), "\(out)-\(name).png")
        return true
    }

    @MainActor @ViewBuilder static func panel(_ name: String) -> some View {
        let m = Model.shared
        let none: () -> Void = {}
        let common = ["Desktop", "Documents", "Downloads"].map { NSHomeDirectory() + "/" + $0 }
        switch name {
        case "popup-folders":
            PopupStage(close: none) { g in FolderSheet(m: m, done: {}, folders: common, room: g.height) }
        case "popup-connections":
            PopupStage(close: none) { g in ConnectionsWorld(m: m, fixedT: 40).frame(width: min(760, g.width - 48), height: min(680, g.height - 40)) }
        case "popup-name":
            PopupStage(close: none, align: .topLeading, inset: HomePopups.nameInset(top: 6)) { _ in MeCard(m: m) }
        case "popup-talk":
            PopupStage(close: none) { _ in TalkKeySheet {} }
        case "popup-stop":
            PopupStage(close: none) { _ in HelperStopAsk(title: "Canvas price options") { _ in } }
        case "popup-close":
            PopupStage(close: none) { _ in HelperCloseAsk(title: "Canvas price options") { _ in } }
        case "popup-reader":
            ShelfOpened(m: m, item: readerItem())
        case "popup-writing":
            WritingPanel(m: m, draft: .constant(LongMessageRender.message), close: {}, send: {})
        case "popup-routines":
            RoutinesPanel(m: m, fixed: routines())
        default:
            PopupStage(close: none) { _ in ShareRoomSheet(m: m) {} }
        }
    }

    /// The rooms map's own background, for Share a room (it opens over the rooms window, not over home).
    static var roomsBehind: some View {
        RadialGradient(
            colors: [Color(hex: 0x1C1B1F), Color(hex: 0x141416), Color(hex: 0x111113)], center: UnitPoint(x: 0.48, y: 0.52), startRadius: 0,
            endRadius: 700
        )
        .overlay(alignment: .topLeading) {
            Text("Your rooms").font(.system(size: 17, weight: .semibold)).foregroundStyle(WorldLook.cream).padding(.leading, 28).padding(.top, 24)
        }
    }

    static func readerItem() -> ShelfItem {
        let f = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Germán 1:1 prep pack.md")
        let text = """
            # Germán 1:1 prep pack

            ## Agenda
            1. **Where the scheduling screen stands**: shipped last week, two small bugs left.
            2. The PDF export with more than fifty line items, and when the fix lands.
            3. What he needs from you before Friday's client update.

            ## Three questions to ask
            - Which of the two repos should new work go into first?
            - Is the export fix worth a release on its own, or can it ride with the next one?
            - Who on their side checks the update before it goes out?

            ## Notes from last time
            He liked short updates that lead with what works. Keep it to one screen.
            """
        try? text.write(to: f, atomically: true, encoding: .utf8)
        return ShelfItem(
            title: "Germán 1:1 prep pack", detail: "Agenda, notes and three questions to ask.", from: "MD · ready to share", path: f.path)
    }

    @MainActor static func routines() -> RoutinesSnapshot {
        var s = RoutinesSnapshot(now: Date())
        s.routines = Routines.jobs(at: TestWorld.realSupport.appendingPathComponent("hermes/cron"), now: s.now)
        s.skills = Routines.skills()
        return s
    }

    @MainActor static func image(_ v: AnyView) -> NSImage? {
        let r = ImageRenderer(content: v.frame(width: size.width, height: size.height))
        r.scale = 2
        guard let img = r.nsImage else { return nil }
        img.size = size
        return img
    }

    @MainActor static func save(_ v: AnyView, _ path: String) {
        let r = ImageRenderer(content: v)
        r.scale = 2
        if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
            let data = rep.representation(using: .png, properties: [:])
        {
            try? data.write(to: URL(fileURLWithPath: path))
            print("wrote \(path)")
        }
    }
}
