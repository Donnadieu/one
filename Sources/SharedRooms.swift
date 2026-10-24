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
