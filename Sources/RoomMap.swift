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
