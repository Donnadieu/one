import AppKit
import SwiftUI

// MARK: - Render-only: "Earlier versions" and the locked-copy card (`One --render-history <prefix>`)

/// From a test copy, with ONE_SUPPORT_DIR set to an empty scratch folder: made-up notes and made-up copies are
/// written there (never the real brain or One's folder). Frames: `earlier-versions`, `earlier-versions-open`,
/// `offsite-card`, `offsite-code`.
enum HistoryRender {
    static func cli(_ args: [String]) -> Int32? {
        guard let k = args.firstIndex(of: "--render-history"), k + 1 < args.count else { return nil }
        guard ProcessInfo.processInfo.environment["ONE_SUPPORT_DIR"] != nil, !TestWorld.isProduction(Env.support) else {
            print("refusing: set ONE_SUPPORT_DIR to an empty scratch folder first")
            return 2
        }
        let prefix = args[k + 1]
        MainActor.assumeIsolated {
            HomeView.still = true
            let vs = fakeVersions()
            let note = Env.support.appendingPathComponent("render-brain/personal-room/brain/garden.md").path
            NotePanel.stillVersions = vs
            NotePanel.stillPick = nil
            png(rooms(note), prefix + "earlier-versions.png", RoomsRender.size)
            NotePanel.stillPick = vs[1].id
            png(rooms(note), prefix + "earlier-versions-open.png", RoomsRender.size)
            NotePanel.stillVersions = nil
            let card = { (s: String) in
                AnyView(
                    VStack { OffsiteCard(m: Model.shared, still: s) }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(WorldLook.bg).environment(\.colorScheme, .dark))
            }
            png(card("offer"), prefix + "offsite-card.png", CGSize(width: 640, height: 230))
            png(card("code"), prefix + "offsite-code.png", CGSize(width: 640, height: 260))
        }
        return 0
    }

    /// A made-up garden note now, and four earlier versions of it in made-up copies.
    @MainActor static func fakeVersions() -> [History.Version] {
        let fm = FileManager.default
        let brain = Env.support.appendingPathComponent("render-brain/personal-room/brain", isDirectory: true)
        try? fm.createDirectory(at: brain, withIntermediateDirectories: true)
        let now = Date()
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        func at(_ day: Int, _ h: Int, _ m: Int) -> Date {
            cal.date(byAdding: .minute, value: h * 60 + m, to: cal.date(byAdding: .day, value: day, to: today)!)!
        }
        let text = [
            "# Garden plan\n\nTomatoes go in the sunny bed by the fence. Basil between them.\n\n- Water every other morning\n- Stakes by mid-May\n",
            "# Garden plan\n\nTomatoes go in the sunny bed by the fence.\n\n- Water every other morning\n- Stakes by mid-May\n- Ask Ana about the compost\n",
            "# Garden plan\n\nTomatoes and peppers in the sunny bed.\n\n- Water every morning\n",
            "# Garden plan\n\nTomatoes in the sunny bed.\n",
            "# Garden plan\n\nIdeas for the spring garden.\n",
        ]
        try? text[0].write(to: brain.appendingPathComponent("garden.md"), atomically: true, encoding: .utf8)
        let olds: [(Date, String?)] = [(at(0, 15, 0), nil), (at(0, 11, 0), "before restore"), (at(-1, 21, 15), nil), (at(-3, 9, 0), nil)]
        return olds.enumerated().map { i, o in
            let name = History.name(o.0, label: o.1)
            let dir = History.folder.appendingPathComponent(name, isDirectory: true)
            let f = dir.appendingPathComponent("My Brain/personal-room/brain/garden.md")
            try? fm.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text[i + 1].write(to: f, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.modificationDate: o.0.addingTimeInterval(-600)], ofItemAtPath: f.path)
            return History.Version(
                snapshot: History.Snapshot(name: name, url: dir, date: o.0, label: o.1), url: f, size: Int64(text[i + 1].utf8.count),
                changed: o.0.addingTimeInterval(-600), isDir: false)
        }
    }

    /// The rooms map inside a made-up personal room, the garden note open in the reader.
    @MainActor static func rooms(_ note: String) -> AnyView {
        let dir = URL(fileURLWithPath: note).deletingLastPathComponent()
        let others = ["Spring chores", "Seeds to buy", "Compost", "Life"]
        var notes = [RoomNote(id: note, title: "Garden plan", room: 0, hub: false, links: others.map { dir.appendingPathComponent($0 + ".md").path })]
        for (i, t) in others.enumerated() {
            notes.append(RoomNote(id: dir.appendingPathComponent(t + ".md").path, title: t, room: 0, hub: i == 3, links: [note]))
        }
        let g = RoomGraph()
        g.load([RoomInfo(id: "personal-room", title: "Personal room", color: Color(hex: 0xFFE2C2), notes: notes, crossed: [:])])
        g.start(room: "Personal", note: "Garden plan")
        g.prepareStill(RoomsRender.size)
        return AnyView(RoomsView(m: Model.shared, graph: g, still: true) {})
    }

    @MainActor static func png(_ v: some View, _ path: String, _ size: CGSize) {
        let r = ImageRenderer(content: v.frame(width: size.width, height: size.height))
        r.scale = 2
        if let img = r.nsImage, let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t),
            let d = rep.representation(using: .png, properties: [:])
        {
            try? d.write(to: URL(fileURLWithPath: path))
            print("wrote \(path)")
        }
    }
}
