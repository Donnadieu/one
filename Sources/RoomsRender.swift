import AppKit
import SwiftUI

// MARK: - Review renders of the rooms map against the real brain (never shown in the app).

@MainActor
enum RoomsRender {
    static let size = CGSize(width: 1280, height: 820)

    /// A still frame: all rooms, inside a room, or a note open.
    static func scene(room: String? = nil, note: String? = nil, mainNote: Bool = false) -> AnyView {
        let g = RoomGraph()
        g.load(RoomMap.load())
        g.start(room: room, note: note, mainNote: mainNote)
        g.prepareStill(size)
        return AnyView(RoomsView(m: Model.shared, graph: g, still: true) {})
    }
    /// A note open in the reader, picked by the end of its path; `from`…`to` (words in the note) shows a selection.
    static func note(path: String, from: String? = nil, to: String? = nil) -> AnyView {
        let g = RoomGraph()
        g.load(RoomMap.load())
        guard let i = g.nodes.indices.first(where: { g.nodes[$0].id.hasSuffix(path) }) else { return AnyView(Text("missing \(path)")) }
        g.start(room: g.rooms[g.nodes[i].room].name)
        g.selected = i
        g.prepareStill(size)
        var sel: NSRange?
        if let from, let to {
            let s = NoteText.attributed(NotePanel.body(g.nodes[i].id), size: 14).string as NSString
            let a = s.range(of: from)
            let b = s.range(of: to)
            if a.location != NSNotFound, b.location != NSNotFound { sel = NSRange(location: a.location, length: NSMaxRange(b) - a.location) }
        }
        return AnyView(RoomsView(m: Model.shared, graph: g, still: true, select: sel) {})
    }
    static func png(_ v: some View, _ path: String, scale: CGFloat = 2) {
        let r = ImageRenderer(content: v.frame(width: size.width, height: size.height))
        r.scale = scale
        if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
            let data = rep.representation(using: .png, properties: [:])
        {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
    /// `--render-rooms-fly <dir> [room]`: 30 fps frames of the camera flying into a room and back out.
    static func fly(_ dir: String, room: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let g = RoomGraph()
        g.load(RoomMap.load())
        g.prepareStill(size)
        g.frozen = false
        let target = g.rooms.firstIndex { $0.name.lowercased() == room.lowercased() } ?? 0
        let view = RoomsView(m: Model.shared, graph: g, still: true) {}
        for f in 0..<105 {
            if f == 15 { g.go(room: target) }
            if f == 60 { g.go(room: nil) }
            g.step(1.0 / 30)
            png(view, String(format: "%@/f%04d.png", dir, f), scale: 1)
        }
        print("wrote \(dir) (105 frames)")
    }
}
