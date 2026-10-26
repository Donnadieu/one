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

@MainActor
struct RoomsView: View {
    @ObservedObject var m: Model
    @ObservedObject var graph: RoomGraph
    var close: () -> Void
    /// Renders only: draw one still frame (no clock, no ScrollView).
    var still = false
    @State var sharing = false
    init(m: Model, graph: RoomGraph? = nil, still: Bool = false, close: @escaping () -> Void) {
        let graph = graph ?? RoomGraph()
        self.m = m
        self.graph = graph
        self.still = still
        self.close = close
        if graph.rooms.isEmpty { graph.load(RoomMap.load()) }
    }
    var body: some View {
        ZStack {
            RadialGradient(
                colors: [Color(hex: 0x1C1B1F), Color(hex: 0x141416), Color(hex: 0x111113)], center: UnitPoint(x: 0.48, y: 0.52), startRadius: 0,
                endRadius: 700)
            if graph.rooms.isEmpty {
                Text("Your rooms show up here once setup is done.").foregroundStyle(Color(hex: 0xF4EFE8, 0.5))
            } else {
                RoomGraphView(g: graph, still: still)
            }
            VStack(spacing: 0) {
                RoomsHeader(m: m, g: graph, share: { sharing = true }, close: close)
                Spacer(minLength: 0)
                RoomsFooter(g: graph)
            }
            if let sel = graph.selected, let note = graph.note(sel) {
                HStack {
                    Spacer()
                    NotePanel(note: note, g: graph, index: sel, still: still)
                        .frame(width: 368).padding(.top, 80).padding(.bottom, 84).padding(.trailing, 16)
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            Button("") { graph.focus == nil && graph.selected == nil ? close() : graph.back() }
                .keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0)
        }
        .animation(.timingCurve(0.32, 0.72, 0.4, 1, duration: 0.52), value: graph.selected)
        .frame(minWidth: 900, minHeight: 580)
        .environment(\.colorScheme, .dark)
        .sheet(isPresented: $sharing, onDismiss: { reload() }, content: { ShareRoomSheet(m: m) { sharing = false } })
    }
    func reload() {
        let f = graph.focus.map { graph.rooms[$0].name }
        graph.load(RoomMap.load())
        graph.focus = f.flatMap { n in graph.rooms.firstIndex { $0.name == n } }
        graph.selected = nil
    }
}

/// "Your rooms" and what they are; inside a room it becomes "Your rooms › Work".
struct RoomsHeader: View {
    @ObservedObject var m: Model
    @ObservedObject var g: RoomGraph
    var share: () -> Void
    var close: () -> Void
    static let cream = Color(hex: 0xF4EFE8)
    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    if let f = g.focus, g.rooms.indices.contains(f) {
                        Button("Your rooms") { g.go(room: nil) }
                            .buttonStyle(.plain).font(.system(size: 17, weight: .semibold)).foregroundStyle(Self.cream.opacity(0.5))
                            .help("Back to all rooms")
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Self.cream.opacity(0.35))
                        Circle().fill(g.rooms[f].tint.color(1)).frame(width: 8, height: 8).shadow(color: g.rooms[f].tint.color(1), radius: 5)
                        Text(g.rooms[f].name).font(.system(size: 17, weight: .semibold)).foregroundStyle(Self.cream)
                    } else {
                        Text("Your rooms").font(.system(size: 17, weight: .semibold)).foregroundStyle(Self.cream)
                    }
                }
                .frame(height: 24)
                Text(subtitle).font(.system(size: 12.5)).foregroundStyle(Self.cream.opacity(0.5)).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button(action: share) {
                HStack(spacing: 7) {
                    Image(systemName: "person.2").font(.system(size: 12))
                    Text("Share a room").font(.system(size: 13, weight: .medium))
                }
                .padding(.horizontal, 14).frame(height: 32).background(Capsule().fill(Self.cream.opacity(0.07)))
            }
            .buttonStyle(.plain).foregroundStyle(Self.cream.opacity(0.85)).help("Work on a room together with someone")
            Button(action: close) {
                Text("Done").font(.system(size: 13, weight: .semibold)).padding(.horizontal, 18).frame(height: 32)
                    .background(Capsule().fill(Self.cream))
            }
            .buttonStyle(.plain).foregroundStyle(Color(hex: 0x141416))
        }
        .padding(.leading, 28).padding(.trailing, 24).frame(height: 72)
        .background(
            LinearGradient(
                stops: [.init(color: Color(hex: 0x141416), location: 0.3), .init(color: Color(hex: 0x141416, 0), location: 1)], startPoint: .top,
                endPoint: .bottom))
    }
    var subtitle: String {
        if let f = g.focus, g.rooms.indices.contains(f) { return g.rooms[f].sub }
        return "Each room is a part of your life. I keep what I learn in the right one."
    }
}

/// A short hint on the left, zoom buttons on the right.
struct RoomsFooter: View {
    @ObservedObject var g: RoomGraph
    var body: some View {
        HStack(spacing: 16) {
            Text(hint)
                .font(.system(size: 12)).foregroundStyle(Color(hex: 0xF4EFE8, 0.42)).fixedSize()
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                round("minus", "Zoom out") { g.zoomButton(1 / 1.35) }
                round("plus", "Zoom in") { g.zoomButton(1.35) }
                round("arrow.up.left.and.arrow.down.right", "Show everything") { g.fit() }
            }
        }
        .padding(.leading, 28).padding(.trailing, 20).frame(height: 72)
    }
    var hint: String {
        if g.selected != nil { return "Click a linked note to jump to it. Press Esc to close the note." }
        if g.focus != nil { return "Click a note to read it. Press Esc to see all rooms." }
        return "Drag a note to move it. Scroll to zoom. Click a room to go in."
    }
    func round(_ icon: String, _ help: String, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold)).frame(width: 32, height: 32)
                .background(Circle().fill(Color(hex: 0xF4EFE8, 0.07)))
        }
        .buttonStyle(.plain).foregroundStyle(Color(hex: 0xF4EFE8, 0.8)).help(help)
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

/// The note reader on the right: room, title, when it changed, the note itself, and its linked notes.
struct NotePanel: View {
    let note: RoomNote
    @ObservedObject var g: RoomGraph
    let index: Int
    var still = false
    static let cream = Color(hex: 0xF4EFE8)
    var text: String {
        let raw = (try? String(contentsOfFile: note.id, encoding: .utf8)) ?? ""
        var lines = raw.components(separatedBy: "\n")
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") { lines = Array(lines[(end + 1)...]) }
        if let f = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }), lines[f].hasPrefix("# ") { lines.remove(at: f) }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var meta: String {
        let n = g.nodes[index].deg
        let links = n == 1 ? "1 linked note" : "\(n) linked notes"
        let attrs = try? FileManager.default.attributesOfItem(atPath: note.id)
        guard let d = attrs?[.modificationDate] as? Date else { return links }
        return links + " · Updated " + d.formatted(.dateTime.month(.abbreviated).day())
    }
    /// Renders can't scroll: whole paragraphs up to ~700 characters, so nothing is cut mid-table.
    static func firstPart(_ s: String) -> String {
        var out = ""
        for p in s.components(separatedBy: "\n\n") {
            if !out.isEmpty && out.count + p.count > 700 { break }
            out += (out.isEmpty ? "" : "\n\n") + p
        }
        return out
    }
    var body: some View {
        let room = g.rooms[g.nodes[index].room]
        let linked = g.adj[index].sorted { g.nodes[$0].deg > g.nodes[$1].deg }.prefix(10)
        let shown = text.isEmpty ? "Nothing written here yet." : text
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(room.tint.color(1)).frame(width: 8, height: 8).shadow(color: room.tint.color(1), radius: 5)
                Text(room.name + " room" + (room.shared.map { " · " + $0 } ?? "")).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Self.cream.opacity(0.58)).lineLimit(1)
                Spacer()
                Button {
                    g.select(nil)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 28, height: 28)
                }
                .buttonStyle(.plain).foregroundStyle(Self.cream.opacity(0.5)).help("Close")
            }
            .padding(.top, 20).padding(.leading, 24).padding(.trailing, 18)
            Text(note.title).font(.system(size: 22, weight: .semibold)).foregroundStyle(Self.cream).lineLimit(3)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 10).padding(.horizontal, 24)
            Text(meta).font(.system(size: 12)).foregroundStyle(Self.cream.opacity(0.45)).padding(.top, 8).padding(.horizontal, 24)
            Group {
                if still {
                    Color.clear.overlay(alignment: .topLeading) {
                        MarkdownText(text: NotePanel.firstPart(shown), size: 14).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .clipped()
                } else {
                    ScrollView { MarkdownText(text: shown, size: 14).frame(maxWidth: .infinity, alignment: .leading) }
                }
            }
            .padding(.top, 18).padding(.horizontal, 24).padding(.bottom, 16).frame(minHeight: 120)
            VStack(alignment: .leading, spacing: 12) {
                if !linked.isEmpty {
                    Text("LINKED NOTES").font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(Self.cream.opacity(0.4))
                    FlowChips(items: linked.map { i in (i, g.nodes[i].name, g.rooms[g.nodes[i].room].tint.color(1)) }) { g.select($0) }
                }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: note.id)])
                } label: {
                    Label("Show in Finder", systemImage: "folder").font(.system(size: 12.5))
                }
                .buttonStyle(.plain).foregroundStyle(Self.cream.opacity(0.5))
            }
            .padding(.top, 16).padding(.horizontal, 24).padding(.bottom, 18)
            .overlay(alignment: .top) { Rectangle().fill(Self.cream.opacity(0.06)).frame(height: 1) }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(hex: 0x19191C, 0.96)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Self.cream.opacity(0.08)))
        .shadow(color: .black.opacity(0.6), radius: 30, y: 20)
    }
}

/// Linked-note chips that wrap onto as many lines as they need.
struct FlowChips: View {
    let items: [(Int, String, Color)]
    var tap: (Int) -> Void
    var body: some View {
        ChipWrap(spacing: 6) {
            ForEach(items, id: \.0) { it in
                Button {
                    tap(it.0)
                } label: {
                    HStack(spacing: 7) {
                        Circle().fill(it.2).frame(width: 6, height: 6)
                        Text(it.1).font(.system(size: 12.5)).lineLimit(1).truncationMode(.tail)
                    }
                    .padding(.leading, 9).padding(.trailing, 11).frame(height: 28)
                    .background(Capsule().fill(Color(hex: 0xF4EFE8, 0.06)))
                    .frame(maxWidth: 300, alignment: .leading)
                }
                .buttonStyle(.plain).foregroundStyle(Color(hex: 0xF4EFE8, 0.85))
            }
        }
    }
}

struct ChipWrap: Layout {
    var spacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 320
        return CGSize(width: w, height: rows(w, subviews).last.map { $0.y + $0.h } ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (i, r) in rows(bounds.width, subviews).enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + r.x, y: bounds.minY + r.y), proposal: ProposedViewSize(width: r.w, height: r.h))
        }
    }
    func rows(_ width: CGFloat, _ subviews: Subviews) -> [(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat)] {
        var out: [(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat)] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(ProposedViewSize(width: width, height: nil))
            let w = min(s.width, width)
            if x > 0 && x + w > width {
                x = 0
                y += rowH + spacing
                rowH = 0
            }
            out.append((x, y, w, s.height))
            x += w + spacing
            rowH = max(rowH, s.height)
        }
        return out
    }
}
