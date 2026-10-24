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
