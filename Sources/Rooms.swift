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

// MARK: - Shared rooms: a room kept in iCloud Drive and shared through Apple's own Share menu.
// No accounts to make. Clashes are avoided by design: each person adds new entries, nobody rewrites
// someone else's; the summary is rebuilt from entries; real clashes are kept as copies and merged.

struct RoomError: Error { let text: String }
struct SharedRoomInfo: Codable {
    var title: String
    var createdBy: String
    var created: String
    var members: [String]
}

enum Shared {
    static var cloud: URL {
        if let t = ProcessInfo.processInfo.environment["ONE_CLOUD_DIR"] { return URL(fileURLWithPath: t, isDirectory: true) }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }
    static var available: Bool { FileManager.default.fileExists(atPath: cloud.path) }
    static var base: URL { cloud.appendingPathComponent("One Rooms", isDirectory: true) }
    static var paths: [String] {
        get { (UserDefaults.standard.stringArray(forKey: "sharedRooms") ?? []).filter { FileManager.default.fileExists(atPath: $0) } }
        set { UserDefaults.standard.set(newValue, forKey: "sharedRooms") }
    }
    static var me: String {
        let n = UserDefaults.standard.string(forKey: "userName") ?? ""
        return n.isEmpty ? "Me" : n
    }
    static var ai: String {
        let n = UserDefaults.standard.string(forKey: "assistantName") ?? ""
        return n.isEmpty ? "the assistant" : n
    }
    static func info(_ u: URL) -> SharedRoomInfo? {
        guard let d = try? Data(contentsOf: u.appendingPathComponent("one-room.json")) else { return nil }
        return try? JSONDecoder().decode(SharedRoomInfo.self, from: d)
    }
    static func writeInfo(_ i: SharedRoomInfo, _ u: URL) {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? e.encode(i).write(to: u.appendingPathComponent("one-room.json"), options: .atomic)
    }
    static func others(_ i: SharedRoomInfo) -> [String] { i.members.filter { $0.lowercased() != me.lowercased() } }
    static func label(_ i: SharedRoomInfo) -> String {
        let o = others(i)
        return o.isEmpty ? "shared, waiting for someone to join" : "shared with " + o.joined(separator: ", ")
    }

    static let howItWorks = """
        # How this shared room works

        This room is shared between a few people through iCloud Drive. Each person has their own assistant (in the One app), and each assistant works only for its own person.

        ## So nobody overwrites anybody
        - Everything new goes in `entries/` as its own file, named `YYYY-MM-DD HHMM Name - short title.md` and starting with `By Name`.
        - Nobody edits or deletes an entry someone else wrote. To change your mind, add a new entry.
        - `summary.md` is rebuilt as a whole from the entries. Don't patch it by hand.
        - If two people change the same file at the same time, the app keeps both as `… (other version).md`. The assistant merges them and says so.

        ## Rules
        - Nothing from anyone's other rooms comes in here without that person's OK.
        - No assistant sends, spends or deletes anything on behalf of another member.
        - Changing these rules needs everyone in the room to agree.
        - Anyone can leave at any time and keep their own copy.
        """

    /// Makes a shared room (new, or by moving an existing local room into iCloud Drive). Returns its folder or an error.
    static func make(title: String, moving local: URL?) -> Result<URL, RoomError> {
        let fm = FileManager.default
        guard available else {
            return .failure(RoomError(text: "iCloud Drive is off on this Mac. Turn it on in System Settings › your name › iCloud › iCloud Drive."))
        }
        let safe = title.components(separatedBy: CharacterSet(charactersIn: "/:\\?*\"<>|")).joined(separator: "-").trimmingCharacters(
            in: .whitespaces)
        guard !safe.isEmpty else { return .failure(RoomError(text: "The room needs a name.")) }
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        var dest = base.appendingPathComponent(safe, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = base.appendingPathComponent("\(safe) \(n)", isDirectory: true)
            n += 1
        }
        do {
            if let local { try fm.moveItem(at: local, to: dest) } else { try fm.createDirectory(at: dest, withIntermediateDirectories: true) }
        } catch { return .failure(RoomError(text: "Couldn't make the room: \(error.localizedDescription)")) }
        let entries = dest.appendingPathComponent("entries", isDirectory: true)
        try? fm.createDirectory(at: entries, withIntermediateDirectories: true)
        try? howItWorks.write(to: dest.appendingPathComponent("HOW THIS ROOM WORKS.md"), atomically: true, encoding: .utf8)
        let sum = dest.appendingPathComponent("summary.md")
        if !fm.fileExists(atPath: sum.path) {
            try? "# \(title)\n\nWhat this room is about, rebuilt from the entries by the assistants.\n\n[nothing yet]\n".write(
                to: sum, atomically: true, encoding: .utf8)
        }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmm"
        let first = "# Room opened\n\nBy \(me)\n\n\(me) opened this shared room\(local == nil ? "" : ", bringing in their notes from before").\n"
        try? first.write(to: entries.appendingPathComponent("\(f.string(from: Date())) \(me) - room opened.md"), atomically: true, encoding: .utf8)
        let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        writeInfo(SharedRoomInfo(title: title, createdBy: me, created: day, members: [me]), dest)
        if let local { replaceRow(oldFolder: local.lastPathComponent, title: title, path: dest) } else { addRow(title: title, path: dest) }
        paths = paths + [dest.path]
        return .success(dest)
    }

    /// Adds someone else's room (accepted through iCloud) to this brain.
    static func join(_ u: URL) {
        guard var i = info(u) else { return }
        if !i.members.contains(where: { $0.lowercased() == me.lowercased() }) {
            i.members.append(me)
            writeInfo(i, u)
        }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmm"
        try? FileManager.default.createDirectory(at: u.appendingPathComponent("entries"), withIntermediateDirectories: true)
        try? "# Joined\n\nBy \(me)\n\n\(me) joined the room.\n".write(
            to: u.appendingPathComponent("entries/\(f.string(from: Date())) \(me) - joined.md"), atomically: true, encoding: .utf8)
        addRow(title: i.title, path: u)
        paths = paths + [u.path]
    }
    static func leave(_ u: URL) {
        paths = paths.filter { $0 != u.path }
        var d = UserDefaults.standard.stringArray(forKey: "sharedDismissed") ?? []
        d.append(u.path)
        UserDefaults.standard.set(d, forKey: "sharedDismissed")
    }

    /// Rooms other people shared with this Mac's iCloud that aren't in the brain yet.
    static func invites() -> [URL] {
        guard available else { return [] }
        let fm = FileManager.default
        let known = Set(paths)
        let dismissed = Set(UserDefaults.standard.stringArray(forKey: "sharedDismissed") ?? [])
        var out: [URL] = []
        for dir in [cloud, base] {
            for u in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [] {
                guard !known.contains(u.path), !dismissed.contains(u.path), let i = info(u) else { continue }
                if i.createdBy.lowercased() == me.lowercased() && i.members.count <= 1 { continue }
                out.append(u)
            }
        }
        return out
    }

    /// Keeps shared files downloaded and turns iCloud edit clashes into side-by-side copies. Returns new clash notes.
    static func tend() -> [String] {
        let fm = FileManager.default
        var notes: [String] = []
        for p in paths {
            let root = URL(fileURLWithPath: p)
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let f as URL in en {
                let name = f.lastPathComponent
                if name.hasPrefix("."), name.hasSuffix(".icloud") {
                    let real = f.deletingLastPathComponent().appendingPathComponent(String(name.dropFirst().dropLast(7)))
                    try? fm.startDownloadingUbiquitousItem(at: real)
                    continue
                }
                guard f.pathExtension == "md", let vs = NSFileVersion.unresolvedConflictVersionsOfItem(at: f), !vs.isEmpty else { continue }
                let stem = f.deletingPathExtension().lastPathComponent
                for (k, v) in vs.enumerated() {
                    let who = v.localizedNameOfSavingComputer ?? "another Mac"
                    let copy = f.deletingLastPathComponent().appendingPathComponent(
                        "\(stem) (other version\(vs.count > 1 ? " \(k + 1)" : "") from \(who)).md")
                    try? fm.copyItem(at: v.url, to: copy)
                    v.isResolved = true
                }
                try? NSFileVersion.removeOtherVersionsOfItem(at: f)
                notes.append(f.path)
            }
        }
        return notes
    }

    static func invite(_ u: URL) {
        guard let v = NSApp.keyWindow?.contentView else {
            NSWorkspace.shared.activateFileViewerSelecting([u])
            return
        }
        let picker = NSSharingServicePicker(items: [u])
        picker.show(relativeTo: NSRect(x: v.bounds.midX, y: 60, width: 1, height: 1), of: v, preferredEdge: .minY)
    }

    // The brain's table of rooms (AGENTS.md) gets a row pointing at the shared folder.
    static func addRow(title: String, path: URL) {
        let ag = Brain.root.appendingPathComponent("AGENTS.md")
        guard var t = try? String(contentsOf: ag, encoding: .utf8), !t.contains(path.path) else { return }
        let row =
            "| \(title) (shared) | `\(path.path)` | \(ai) | `summary.md` | what this room's members work on together; read its HOW THIS ROOM WORKS.md | anything from the other rooms without the owner's OK |\n"
        t = t.replacingOccurrences(
            of: "<!-- add-room adds one row per room above this line -->", with: row + "<!-- add-room adds one row per room above this line -->")
        try? t.write(to: ag, atomically: true, encoding: .utf8)
    }
    static func replaceRow(oldFolder: String, title: String, path: URL) {
        let ag = Brain.root.appendingPathComponent("AGENTS.md")
        guard var t = try? String(contentsOf: ag, encoding: .utf8) else { return }
        t = t.components(separatedBy: "\n").filter { !$0.contains("`\(oldFolder)/`") }.joined(separator: "\n")
        try? t.write(to: ag, atomically: true, encoding: .utf8)
        addRow(title: title, path: path)
    }

    /// What the assistant must know every turn about shared rooms (not shown to the user).
    static func note(clashes: [String]) -> String {
        let rooms = paths.compactMap { p -> String? in
            guard let i = info(URL(fileURLWithPath: p)) else { return nil }
            return "\"\(i.title)\" at \(p) (members: \(i.members.joined(separator: ", ")))"
        }
        guard !rooms.isEmpty else { return "" }
        var t =
            "\n\n(One app note, not from the user: SHARED ROOMS, kept in sync with other people through iCloud: \(rooms.joined(separator: "; ")). In a shared room: put each new thing in its own new file in entries/ named 'YYYY-MM-DD HHMM \(me) - short title.md' starting with 'By \(me)'. Never edit or delete a file someone else wrote. Rebuild summary.md as a whole after adding entries; never patch it. Nothing from \(me)'s other rooms goes in without \(me)'s OK. You work only for \(me): never act for the other members. When \(me) asks what's new, read the entries by others since last time.)"
        if !clashes.isEmpty {
            t +=
                "\n\n(One app note: two people changed these at the same time; the other version sits next to each one as '… (other version …).md'. Merge each into the original, delete the copy, and tell \(me) in one line what you combined: \(clashes.joined(separator: "; ")).)"
        }
        return t
    }
}

// MARK: - Your rooms: a live map of the brain, one cluster per room, one dot per note.

struct RoomNote: Identifiable {
    let id: String
    let title: String
    let room: Int
    let hub: Bool
    var links: [String]
}
struct RoomInfo: Identifiable {
    let id: String
    let title: String
    let color: Color
    var notes: [RoomNote]
    var crossed: [Int: Int]
    var shared: String? = nil
}
struct LaidNote {
    let n: RoomNote
    let p: CGPoint
    let r: CGFloat
    let color: Color
    let degree: Int
}

enum RoomMap {
    static let palette: [UInt32] = [0xFFE2C2, 0x9FC9B0, 0xA9C1E8, 0xE6A9C4, 0xD8D08F, 0xC9B2E8]
    static let skipFiles: Set<String> = ["AGENTS.md", "CLAUDE.md", "GEMINI.md", "README.md", "UNLOCK-CHECK.md"]
    static let skipDirs: Set<String> = ["skills", "agents", "templates", "confidential", ".git", "node_modules"]
    static let wiki = try! NSRegularExpression(pattern: #"\[\[([^\]\|#]+)"#)
    static let mdLink = try! NSRegularExpression(pattern: #"\]\(([^)\s]+\.md)\)"#)

    static func roomFolders() -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: Brain.root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let rooms = items.filter {
            $0.lastPathComponent.hasSuffix("-room") && ((try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
        }
        return rooms.sorted { a, b in
            if a.lastPathComponent == "personal-room" { return true }
            if b.lastPathComponent == "personal-room" { return false }
            return a.lastPathComponent < b.lastPathComponent
        } + Shared.paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
    static func roomTitle(_ url: URL) -> String {
        if let i = Shared.info(url) { return i.title }
        return roomTitle(url.lastPathComponent)
    }
    static func roomTitle(_ folder: String) -> String {
        if let k = RoomKind.allCases.first(where: { $0.folder == folder }) { return k.title.prefix(1).uppercased() + k.title.dropFirst() }
        let base = folder.replacingOccurrences(of: "-room", with: "").replacingOccurrences(of: "-", with: " ")
        return base.prefix(1).uppercased() + base.dropFirst() + " room"
    }
    static func noteTitle(_ url: URL, _ text: String) -> String {
        for l in text.split(separator: "\n").prefix(20) where l.hasPrefix("# ") { return String(l.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        return url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "-", with: " ")
    }
    static func matches(_ re: NSRegularExpression, _ t: String) -> [String] {
        re.matches(in: t, range: NSRange(t.startIndex..., in: t)).compactMap { Range($0.range(at: 1), in: t).map { String(t[$0]) } }
    }
    static func load() -> [RoomInfo] {
        let fm = FileManager.default
        let folders = roomFolders()
        var out: [RoomInfo] = []
        var allTexts: [Int: [String]] = [:]
        for (ri, r) in folders.enumerated() {
            let folder = r.lastPathComponent
            let sharedInfo = Shared.info(r)
            let hubPath =
                sharedInfo != nil
                ? r.appendingPathComponent("summary.md").path
                : RoomKind.allCases.first { $0.folder == folder }.map { r.appendingPathComponent($0.hub).path }
            var notes: [RoomNote] = []
            var texts: [String: String] = [:]
            if let en = fm.enumerator(at: r, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                for case let f as URL in en {
                    if skipDirs.contains(f.lastPathComponent) {
                        en.skipDescendants()
                        continue
                    }
                    guard notes.count < 200, f.pathExtension == "md", !skipFiles.contains(f.lastPathComponent),
                        let t = try? String(contentsOf: f, encoding: .utf8)
                    else { continue }
                    texts[f.path] = t
                    notes.append(RoomNote(id: f.path, title: noteTitle(f, t), room: ri, hub: f.path == hubPath, links: []))
                }
            }
            var byStem: [String: String] = [:]
            for n in notes { byStem[URL(fileURLWithPath: n.id).deletingPathExtension().lastPathComponent.lowercased()] = n.id }
            for k in notes.indices {
                let t = texts[notes[k].id] ?? ""
                var ls = Set<String>()
                for w in matches(wiki, t) { if let id = byStem[w.trimmingCharacters(in: .whitespaces).lowercased()] { ls.insert(id) } }
                for l in matches(mdLink, t) {
                    let target = URL(fileURLWithPath: l, relativeTo: URL(fileURLWithPath: notes[k].id).deletingLastPathComponent())
                        .standardizedFileURL.path
                    if texts[target] != nil {
                        ls.insert(target)
                    } else if let id = byStem[URL(fileURLWithPath: l).deletingPathExtension().lastPathComponent.lowercased()] {
                        ls.insert(id)
                    }
                }
                ls.remove(notes[k].id)
                notes[k].links = Array(ls)
            }
            if !notes.contains(where: \.hub) {
                notes.insert(RoomNote(id: "room:" + r.path, title: roomTitle(r), room: ri, hub: true, links: []), at: 0)
            }
            allTexts[ri] = Array(texts.values)
            out.append(
                RoomInfo(
                    id: folder, title: roomTitle(r), color: Color(hex: palette[ri % palette.count]), notes: notes, crossed: [:],
                    shared: sharedInfo.map(Shared.label)))
        }
        // "(from <room>)" lines: facts that crossed between rooms.
        for i in out.indices {
            for j in out.indices where j != i {
                let base = out[j].id.replacingOccurrences(of: "-room", with: "")
                let n = (allTexts[i] ?? []).reduce(0) { $0 + $1.lowercased().components(separatedBy: "(from \(base)").count - 1 }
                if n > 0 { out[i].crossed[j] = n }
            }
        }
        return out
    }
    static func layout(_ rooms: [RoomInfo], _ size: CGSize) -> [LaidNote] {
        let n = max(rooms.count, 1)
        let w = size.width
        let h = size.height
        var centers: [CGPoint] = []
        if n == 1 {
            centers = [CGPoint(x: w / 2, y: h / 2)]
        } else if n == 2 {
            centers = [CGPoint(x: w * 0.3, y: h * 0.55), CGPoint(x: w * 0.72, y: h * 0.42)]
        } else {
            for i in 0..<n {
                let a = Double(i) / Double(n) * 2 * .pi - .pi / 2
                centers.append(CGPoint(x: w / 2 + cos(a) * w * 0.31, y: h * 0.45 + sin(a) * h * 0.25))
            }
        }
        let spread = min(w / CGFloat(n == 1 ? 2.4 : Double(n) + 1.2), h / (n <= 2 ? 2.6 : n == 3 ? 3.4 : 4.4))
        var out: [LaidNote] = []
        for (ri, room) in rooms.enumerated() {
            let c = centers[ri]
            var degree: [String: Int] = [:]
            for x in room.notes {
                for l in x.links {
                    degree[l, default: 0] += 1
                    degree[x.id, default: 0] += 1
                }
            }
            let others = room.notes.filter { !$0.hub }
            for x in room.notes where x.hub { out.append(LaidNote(n: x, p: c, r: 9, color: room.color, degree: degree[x.id] ?? 0)) }
            for (i, x) in others.enumerated() {
                let a = Double(i) * 2.39996 + Double(ri)
                let d = spread * CGFloat(sqrt((Double(i) + 1.2) / Double(others.count + 1))) * 0.95
                let dg = degree[x.id] ?? 0
                out.append(
                    LaidNote(n: x, p: CGPoint(x: c.x + cos(a) * d, y: c.y + sin(a) * d * 0.85), r: dg > 0 ? 5 : 3.5, color: room.color, degree: dg))
            }
        }
        return out
    }
}

struct RoomsView: View {
    @ObservedObject var m: Model
    var close: () -> Void
    @State var rooms: [RoomInfo] = []
    @State var picked: String?
    @State var hover: String?
    @State var sharing = false
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text("Your rooms").font(.title3.weight(.semibold))
                    Text("Each room is a part of your life where \(m.name) acts differently and keeps the notes apart.")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    Button {
                        sharing = true
                    } label: {
                        Label("Share a room", systemImage: "person.2")
                    }
                    .help("Work on a room together with someone")
                    Button {
                        close()
                        Task { await m.send("I'd like to add a room.", toNova: true) }
                    } label: {
                        Label("Room", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent).tint(Color(hex: 0xF4EFE8)).foregroundStyle(Color(hex: 0x141416))
                    .help("Add a room")
                    Button("Done") { close() }.keyboardShortcut(.cancelAction)
                }
                .padding(16)
                if rooms.isEmpty {
                    Spacer()
                    Text("Your rooms show up here once setup is done.").foregroundStyle(.secondary)
                    Spacer()
                } else {
                    GeometryReader { g in
                        let laid = RoomMap.layout(rooms, g.size)
                        let at = Dictionary(laid.map { ($0.n.id, $0) }, uniquingKeysWith: { a, _ in a })
                        let labelled =
                            laid.count <= 14
                            ? Set(laid.map(\.n.id)) : Set(laid.sorted { $0.degree > $1.degree }.prefix(10).filter { $0.degree > 0 }.map(\.n.id))
                        Canvas { ctx, _ in
                            // facts that crossed between rooms
                            for (i, r) in rooms.enumerated() {
                                for (j, n) in r.crossed where j > i || rooms[j].crossed[i] == nil {
                                    guard let a = laid.first(where: { $0.n.room == i && $0.n.hub }),
                                        let b = laid.first(where: { $0.n.room == j && $0.n.hub })
                                    else { continue }
                                    let mid = CGPoint(x: (a.p.x + b.p.x) / 2, y: min(a.p.y, b.p.y) - 60)
                                    var path = Path()
                                    path.move(to: a.p)
                                    path.addQuadCurve(to: b.p, control: mid)
                                    ctx.stroke(path, with: .color(Color(hex: 0xF4EFE8, 0.3)), style: StrokeStyle(lineWidth: 1, dash: [2, 5]))
                                    ctx.draw(
                                        Text(n == 1 ? "1 fact crossed" : "\(n) facts crossed").font(.system(size: 10)).foregroundColor(
                                            Color(hex: 0xF4EFE8, 0.5)), at: CGPoint(x: mid.x, y: mid.y + 22))
                                }
                            }
                            for l in laid {
                                let hub = laid.first { $0.n.room == l.n.room && $0.n.hub }
                                if let hub, !l.n.hub {
                                    var p = Path()
                                    p.move(to: hub.p)
                                    p.addLine(to: l.p)
                                    ctx.stroke(p, with: .color(l.color.opacity(0.12)), lineWidth: 0.8)
                                }
                                for t in l.n.links {
                                    if let o = at[t] {
                                        var p = Path()
                                        p.move(to: l.p)
                                        p.addLine(to: o.p)
                                        ctx.stroke(p, with: .color(l.color.opacity(0.4)), lineWidth: 1)
                                    }
                                }
                            }
                            for l in laid {
                                let on = l.n.id == picked || l.n.id == hover
                                if l.n.hub || on {
                                    ctx.fill(
                                        Path(ellipseIn: CGRect(x: l.p.x - l.r * 2.4, y: l.p.y - l.r * 2.4, width: l.r * 4.8, height: l.r * 4.8)),
                                        with: .color(l.color.opacity(on ? 0.28 : 0.14)))
                                }
                                ctx.fill(
                                    Path(ellipseIn: CGRect(x: l.p.x - l.r, y: l.p.y - l.r, width: l.r * 2, height: l.r * 2)),
                                    with: .color(l.color.opacity(l.degree > 0 || l.n.hub ? 0.95 : 0.55)))
                                if l.n.hub || on || labelled.contains(l.n.id) {
                                    let txt = ctx.resolve(
                                        Text(l.n.title).font(.system(size: l.n.hub ? 12.5 : 11, weight: l.n.hub ? .semibold : .regular))
                                            .foregroundColor(Color(hex: 0xF4EFE8, l.n.hub || on ? 0.95 : 0.75)))
                                    let sz = txt.measure(in: CGSize(width: 220, height: 40))
                                    let pt = CGPoint(x: l.p.x, y: l.p.y + l.r * 2.4 + 8)
                                    ctx.fill(
                                        Path(
                                            roundedRect: CGRect(
                                                x: pt.x - sz.width / 2 - 4, y: pt.y - sz.height / 2 - 1, width: sz.width + 8, height: sz.height + 2),
                                            cornerRadius: 5), with: .color(Color(hex: 0x141416, 0.85)))
                                    ctx.draw(txt, at: pt)
                                }
                            }
                            for (i, r) in rooms.enumerated() {
                                guard let hub = laid.first(where: { $0.n.room == i && $0.n.hub }) else { continue }
                                let maxY = laid.filter { $0.n.room == i }.map(\.p.y).max() ?? hub.p.y
                                let count = r.notes.filter { !$0.id.hasPrefix("room:") }.count
                                ctx.draw(
                                    Text(r.title).font(.system(size: 13, weight: .semibold)).foregroundColor(r.color),
                                    at: CGPoint(x: hub.p.x, y: maxY + 30))
                                if let sh = r.shared {
                                    ctx.draw(
                                        Text(Image(systemName: "person.2.fill")).font(.system(size: 10)).foregroundColor(r.color),
                                        at: CGPoint(x: hub.p.x, y: hub.p.y - 22))
                                    ctx.draw(
                                        Text(sh).font(.system(size: 10.5)).foregroundColor(r.color.opacity(0.8)),
                                        at: CGPoint(x: hub.p.x, y: maxY + 62))
                                }
                                ctx.draw(
                                    Text(count == 1 ? "1 note" : "\(count) notes").font(.system(size: 10.5)).foregroundColor(
                                        Color(hex: 0xF4EFE8, 0.5)), at: CGPoint(x: hub.p.x, y: maxY + 46))
                            }
                        }
                        .contentShape(Rectangle())
                        .onContinuousHover { ph in
                            if case .active(let pt) = ph { hover = nearest(pt, laid) } else { hover = nil }
                        }
                        .onTapGesture(coordinateSpace: .local) { pt in if let n = nearest(pt, laid), !n.hasPrefix("room:") { picked = n } }
                    }
                }
            }
            if let id = picked, let note = rooms.flatMap(\.notes).first(where: { $0.id == id }) {
                NotePanel(note: note, rooms: rooms) { picked = $0 }
                    .frame(width: 290).padding(.vertical, 14).padding(.trailing, 14)
            }
        }
        .frame(minWidth: 900, minHeight: 580)
        .background(Color(hex: 0x141416))
        .environment(\.colorScheme, .dark)
        .sheet(isPresented: $sharing, onDismiss: { rooms = RoomMap.load() }) { ShareRoomSheet(m: m) { sharing = false } }
        .onAppear {
            rooms = RoomMap.load()
            picked = rooms.first?.notes.first { $0.hub && !$0.id.hasPrefix("room:") }?.id
        }
    }
    func nearest(_ pt: CGPoint, _ laid: [LaidNote]) -> String? {
        let best = laid.min { hypot($0.p.x - pt.x, $0.p.y - pt.y) < hypot($1.p.x - pt.x, $1.p.y - pt.y) }
        guard let best, hypot(best.p.x - pt.x, best.p.y - pt.y) < 18 else { return nil }
        return best.n.id
    }
}

struct ShareRoomSheet: View {
    @ObservedObject var m: Model
    var close: () -> Void
    @State var choice = "new"
    @State var name = ""
    @State var made: URL?
    @State var error: String?
    var shareable: [URL] {
        RoomMap.roomFolders().filter { !$0.path.hasPrefix(Shared.cloud.path) && !["personal-room", "private-room"].contains($0.lastPathComponent) }
    }
    var alreadyShared: [URL] { RoomMap.roomFolders().filter { $0.path.hasPrefix(Shared.cloud.path) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let made {
                Label("The room is ready", systemImage: "checkmark.circle.fill").font(.title3.weight(.semibold)).foregroundStyle(Color(hex: 0x9FC9B0))
                Text(
                    "Now invite them. Pick Messages or Mail, and make sure **Collaborate** is chosen, not \"Send copy\". They need One on their Mac too. When they accept, the room shows up in their One and both of you can add to it."
                )
                .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button {
                        Shared.invite(made)
                    } label: {
                        Label("Invite someone", systemImage: "person.badge.plus")
                    }
                    .buttonStyle(.borderedProminent).tint(Color(hex: 0xF4EFE8)).foregroundStyle(Color(hex: 0x141416))
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([made]) }
                    Spacer()
                    Button("Done") { close() }.keyboardShortcut(.defaultAction)
                }
                Text("If Collaborate doesn't appear: in Finder, right-click the folder › Share › Share Folder.").font(.caption).foregroundStyle(
                    .secondary)
            } else {
                Text("Share a room").font(.title3.weight(.semibold))
                Text(
                    "You and someone you trust both add to the same room, each with your own assistant. It stays in sync through iCloud, so there's nothing to sign up for. You each add new notes, nobody overwrites the other, and \(m.name) merges anything that clashes."
                )
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Picker("", selection: $choice) {
                    ForEach(alreadyShared, id: \.path) { u in Text(RoomMap.roomTitle(u) + " (already shared: invite someone)").tag(u.path) }
                    Text("A new room").tag("new")
                    ForEach(shareable, id: \.path) { u in Text("My " + RoomMap.roomTitle(u).lowercased() + " (moves into iCloud)").tag(u.path) }
                }.pickerStyle(.radioGroup).labelsHidden()
                if choice == "new" {
                    TextField("What should the room be called? For example: Our business", text: $name).textFieldStyle(.roundedBorder)
                }
                Text("Your personal and private rooms can't be shared. Nothing from your other rooms goes in without your OK.").font(.caption)
                    .foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red).font(.callout) }
                HStack {
                    Spacer()
                    Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                    Button(alreadyShared.contains { $0.path == choice } ? "Invite someone" : "Make it shared") { go() }.keyboardShortcut(
                        .defaultAction
                    )
                    .disabled(choice == "new" && name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(22).frame(width: 520)
        .onAppear { if let u = alreadyShared.first, made == nil { choice = u.path } }
    }
    func go() {
        if let u = alreadyShared.first(where: { $0.path == choice }) {
            made = u
            Shared.invite(u)
            return
        }
        let local = choice == "new" ? nil : URL(fileURLWithPath: choice)
        let title = local.map { RoomMap.roomTitle($0) } ?? name.trimmingCharacters(in: .whitespaces)
        switch Shared.make(title: title, moving: local) {
        case .failure(let e): error = e.text
        case .success(let u):
            made = u
            Task { _ = await Engine.shared.start() }
            Shared.invite(u)
        }
    }
}

struct NotePanel: View {
    let note: RoomNote
    let rooms: [RoomInfo]
    var go: (String) -> Void
    var body: some View {
        let raw = (try? String(contentsOfFile: note.id, encoding: .utf8)) ?? ""
        var lines = raw.components(separatedBy: "\n")
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") { lines = Array(lines[(end + 1)...]) }
        if let f = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }), lines[f].hasPrefix("# ") { lines.remove(at: f) }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let room = rooms[note.room]
        let all = room.notes
        let linked = Array(Set(note.links + all.filter { $0.links.contains(note.id) }.map(\.id))).compactMap { id in all.first { $0.id == id } }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(room.color).frame(width: 7, height: 7)
                Text(room.title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            Text(note.title).font(.system(size: 16, weight: .semibold))
            ScrollView {
                MarkdownText(text: text.isEmpty ? "Nothing written here yet." : text, size: 13).frame(maxWidth: .infinity, alignment: .leading)
            }
            if !linked.isEmpty {
                Text("LINKED NOTES").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary)
                FlowChips(items: linked.prefix(8).map { ($0.id, $0.title) }, tap: go)
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: note.id)])
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).font(.callout)
        }
        .padding(16).frame(maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color(hex: 0xF4EFE8, 0.08)))
    }
}

struct FlowChips: View {
    let items: [(String, String)]
    var tap: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(stride(from: 0, to: items.count, by: 2)), id: \.self) { i in
                HStack(spacing: 6) {
                    ForEach(items[i..<min(i + 2, items.count)], id: \.0) { it in
                        Button {
                            tap(it.0)
                        } label: {
                            Text(it.1).font(.system(size: 11)).lineLimit(1)
                                .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(Color.white.opacity(0.08)))
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
