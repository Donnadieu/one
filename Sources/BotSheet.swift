import AppKit
import SwiftUI

// MARK: - A bot's menu, its glass sheet and the archived bots (Claude Design "Bots manage B - Glass sheet", picked by
// Omar Nov 17 2026). The bot's chat stays as it is; managing it happens in one centred sheet on the pop-up glass
// (X, a click outside or Esc closes it). About shows its job, what it may use, when it checks in, its routines and
// its memory file; Edit flips the same sheet to fields; Delete… asks once in a small box on top. The ⋯ on a bot's
// row (or a right-click on it) opens the menu: About · Edit… · Archive · Delete…. Archived bots wait behind a small
// box with a count next to New bot. The work itself is in BotsManage.swift.

/// The ⋯ menu beside a bot's row (drawn over home, at the bot's moon).
struct BotMenuLayer: View {
    @ObservedObject var m: Model
    let points: [String: CGPoint]
    var body: some View {
        if let id = m.botMenu, let h = m.helpers.first(where: { $0.id == id }), let b = h.bot, let p = points[id.uuidString] {
            let open = !UserDefaults.standard.bool(forKey: "botsCollapsed")
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle()).onTapGesture { m.botMenu = nil }  // a click anywhere else closes it
                BotMenu(m: m, id: id, name: b.name).fixedSize()
                    .offset(x: p.x + (open ? 186 : 26), y: max(8, p.y - 24))
                Button("") { m.botMenu = nil }.keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0)
            }
        }
    }
}

/// About · Edit… · Archive · Delete…, on the pop-up glass.
struct BotMenu: View {
    @ObservedObject var m: Model
    let id: UUID
    let name: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            item("About \(name)") { m.botSheet = BotSheetAsk(id: id, mode: .about) }
            item("Edit…") { m.botSheet = BotSheetAsk(id: id, mode: .edit) }
            item("Archive") { m.archiveBot(id) }
            Rectangle().fill(WorldLook.cream.opacity(0.1)).frame(height: 1).padding(.horizontal, 8).padding(.vertical, 4)
            item("Delete…", warn: true) { m.botSheet = BotSheetAsk(id: id, mode: .confirm) }
        }
        .padding(6).frame(minWidth: 190, alignment: .leading)
        .background(PopupGlass().clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(WorldLook.cream.opacity(0.14)))
        .shadow(color: .black.opacity(0.5), radius: 24, y: 14)
    }
    func item(_ title: String, warn: Bool = false, _ act: @escaping () -> Void) -> some View {
        BotMenuItem(title: title, warn: warn) {
            m.botMenu = nil
            act()
        }
    }
}

struct BotMenuItem: View {
    let title: String
    var warn = false
    let act: () -> Void
    @State var hover = false
    nonisolated(unsafe) static var stillHover: String?  // renders: this item looks hovered
    var body: some View {
        Button(action: act) {
            Text(title).font(.system(size: 13)).foregroundStyle(warn ? Color(hex: 0xF6B46E) : WorldLook.cream.opacity(0.9))
                .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 7).fill(WorldLook.cream.opacity(hover || BotMenuItem.stillHover == title ? 0.09 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover = $0 }
    }
}

/// The same items as the ⋯ menu, for a right-click on a bot (and the ⋯ in its chat's header).
struct BotMenuItems: View {
    @ObservedObject var m: Model
    let h: Helper
    var body: some View {
        Button("About \(h.title)") { m.botSheet = BotSheetAsk(id: h.id, mode: .about) }
        Button("Edit…") { m.botSheet = BotSheetAsk(id: h.id, mode: .edit) }
        Button("Archive") { m.archiveBot(h.id) }
        if h.state == "working" { Button("Stop") { m.stopHelper(h.id) } }
        Divider()
        Button("Delete…") { m.botSheet = BotSheetAsk(id: h.id, mode: .confirm) }
    }
}

/// The sheet and the archived list, over home.
struct BotPopups: ViewModifier {
    @ObservedObject var m: Model
    func body(content: Content) -> some View {
        let ask = m.botSheet
        let h = ask.flatMap { a in m.helpers.first { $0.id == a.id } }
        content
            .onePopup(h?.bot != nil, close: { m.botSheet = nil }) { g in
                if let h, let b = h.bot { BotSheet(m: m, h: h, b: b, room: g).id(h.id) }
            }
            .onePopup($m.botsArchive, align: .bottomLeading, inset: EdgeInsets(top: 0, leading: 14, bottom: 64, trailing: 0)) { _ in
                ArchivedBots(m: m)
            }
    }
}

struct BotSheet: View {
    @ObservedObject var m: Model
    let h: Helper
    let b: BotInfo
    let room: CGSize
    @State var routines: [Routine] = BotSheet.stillRoutines
    nonisolated(unsafe) static var stillRoutines: [Routine] = []  // renders only
    @State var name: String
    @State var color: String
    @State var job: String
    @State var uses: [String]
    @State var checkIn: String
    @State var extra = ""
    @State var adding = false
    @State var miss: String?
    nonisolated(unsafe) static var stillEdit: (name: String, color: String)?  // renders: a rename half typed

    init(m: Model, h: Helper, b: BotInfo, room: CGSize) {
        self.m = m
        self.h = h
        self.b = b
        self.room = room
        _name = State(initialValue: BotSheet.stillEdit?.name ?? b.name)
        _color = State(initialValue: BotSheet.stillEdit?.color ?? b.color)
        _job = State(initialValue: b.job)
        _uses = State(initialValue: b.uses)
        _checkIn = State(initialValue: b.checkIn)
    }

    var mode: BotSheetAsk.Mode { m.botSheet?.mode ?? .about }
    var editing: Bool { mode == .edit }
    func go(_ to: BotSheetAsk.Mode) { withAnimation(.easeOut(duration: 0.18)) { m.botSheet = BotSheetAsk(id: h.id, mode: to) } }

    var body: some View {
        VStack(spacing: 0) {
            top.padding(.bottom, 18)
            if HomeView.still {
                rows  // renders draw a scroll view's contents blank
            } else {
                ScrollView(.vertical, showsIndicators: false) { rows }
            }
            Spacer(minLength: 12)
            Rectangle().fill(WorldLook.cream.opacity(0.08)).frame(height: 1).padding(.bottom, 14)
            footer
        }
        .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 20)
        .frame(width: min(560, room.width - 48), height: min(645, room.height - 40))
        .disabled(mode == .confirm)
        .overlay { if mode == .confirm { confirm } }
        .task {
            guard routines.isEmpty, !HomeView.still else { return }
            routines = await Task.detached { Model.ownRoutines() }.value  // jobs.json, off the main thread
        }
    }

    // MARK: Top: the moon, its name and room (edit: the six colours)

    var top: some View {
        VStack(spacing: 8) {
            BotMoon(hex: Bots.hex(editing ? color : b.color), size: 76, t: 21.7, needsYes: !editing && h.state == "needsYes")
            if editing {
                HStack(spacing: 12) {
                    ForEach(Bots.colors, id: \.name) { c in
                        Button {
                            color = c.name
                        } label: {
                            Circle().fill(Color(hex: c.hex)).frame(width: 18, height: 18)
                                .overlay(Circle().strokeBorder(WorldLook.cream, lineWidth: color == c.name ? 1.6 : 0).padding(-3.5))
                        }
                        .buttonStyle(.plain).help(c.name.capitalizingFirst)
                    }
                }
                .padding(.top, 6)
            } else {
                Text(b.name).font(.system(size: 22, weight: .semibold)).tracking(-0.3).padding(.top, 4)
                HStack(spacing: 4) {
                    Text("\(b.room) room").foregroundStyle(WorldLook.cream.opacity(0.55))
                    if b.archived != nil {
                        Text("· Archived").foregroundStyle(WorldLook.cream.opacity(0.55))
                    } else if h.state == "needsYes" || h.state == "working" {
                        Text("· " + BotsColumn.line(h)).foregroundStyle(h.state == "needsYes" ? Color(hex: 0xF6B46E) : WorldLook.cream.opacity(0.55))
                    }
                }
                .font(.system(size: 13)).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: The rows

    @ViewBuilder var rows: some View {
        VStack(spacing: 0) {
            if editing {
                row("Name") { field($name, "Its name", lines: 1) }
                row("Job") { field($job, "Its one job", lines: 2) }
                row("May use") { useChips }
                row("Checks in") { checkChips }
                row("Room") { Text("\(b.room) · can't be moved yet").foregroundStyle(WorldLook.cream.opacity(0.6)) }
                if let miss { Text(miss).font(.system(size: 12)).foregroundStyle(Color(hex: 0xF6B46E)).padding(.top, 6) }
            } else {
                row("Job") { Text(b.job).fixedSize(horizontal: false, vertical: true) }
                row("May use") {
                    if b.uses.isEmpty {
                        Text("Only what you give it").foregroundStyle(WorldLook.cream.opacity(0.6))
                    } else {
                        ChipWrap(spacing: 8) { ForEach(b.uses, id: \.self) { chip($0, on: false, plain: true) } }
                    }
                }
                row("Checks in") { Text(Bots.checkWord(b.checkIn).capitalizingFirst) }
                row("Routines") { routineList }
                row("Memory") { memory }
                row("Made") { Text(b.made.formatted(.dateTime.month(.abbreviated).day())) }
            }
        }
        .font(.system(size: 14)).foregroundStyle(WorldLook.cream)
    }

    func row<V: View>(_ label: String, @ViewBuilder _ v: () -> V) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(WorldLook.cream.opacity(0.08)).frame(height: 1)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(label).font(.system(size: 13)).foregroundStyle(WorldLook.cream.opacity(0.42)).frame(width: 92, alignment: .leading)
                v().frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 11)
        }
    }

    @ViewBuilder func field(_ text: Binding<String>, _ prompt: String, lines: Int) -> some View {
        Group {
            if HomeView.still {
                HStack(spacing: 1) {
                    Text(text.wrappedValue)
                    if lines == 1 { Rectangle().fill(WorldLook.cream).frame(width: 1.5, height: 17) }
                }
            } else {
                TextField(prompt, text: text, axis: .vertical).textFieldStyle(.plain).lineLimit(lines...max(lines, 3))
            }
        }
        .font(.system(size: 14, weight: lines == 1 ? .semibold : .regular))
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: lines == 1 ? 34 : 52, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.black.opacity(0.28)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(WorldLook.cream.opacity(lines == 1 ? 0.3 : 0.12)))
    }

    func chip(_ s: String, on: Bool, plain: Bool = false) -> some View {
        HStack(spacing: 5) {
            if on { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
            Text(s).font(.system(size: 12.5))
        }
        .padding(.horizontal, 11).frame(height: 26)
        .foregroundStyle(WorldLook.cream.opacity(plain || on ? 0.95 : 0.6))
        .overlay(Capsule().strokeBorder(WorldLook.cream.opacity(plain ? 0.28 : on ? 0.7 : 0.16)))
        .contentShape(Capsule())
    }

    var useChips: some View {
        let base = ["Browser", "Email drafts", "Calendar", "Files"]
        let all =
            base
            + (b.uses + uses).reduce(into: [String]()) { a, u in
                if !base.contains(where: { $0.lowercased() == u.lowercased() }) && !a.contains(u) { a.append(u) }
            }
        return ChipWrap(spacing: 8) {
            ForEach(all, id: \.self) { u in
                let on = uses.contains { $0.lowercased() == u.lowercased() }
                Button {
                    if on { uses.removeAll { $0.lowercased() == u.lowercased() } } else { uses.append(u) }
                } label: {
                    chip(u, on: on)
                }
                .buttonStyle(.plain)
            }
            if adding && !HomeView.still {
                TextField("What else?", text: $extra).textFieldStyle(.plain).font(.system(size: 12.5)).frame(width: 120)
                    .padding(.horizontal, 11).frame(height: 26).overlay(Capsule().strokeBorder(WorldLook.cream.opacity(0.3)))
                    .onSubmit {
                        let e = extra.trimmingCharacters(in: .whitespaces)
                        if !e.isEmpty && !uses.contains(e) { uses.append(e) }
                        extra = ""
                        adding = false
                    }
            } else {
                Button {
                    adding = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus").font(.system(size: 9, weight: .semibold))
                        Text("Something else").font(.system(size: 12.5))
                    }
                    .padding(.horizontal, 11).frame(height: 26).foregroundStyle(WorldLook.cream.opacity(0.6))
                    .overlay(Capsule().strokeBorder(WorldLook.cream.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    var checkChips: some View {
        HStack(spacing: 2) {
            ForEach([("morning", "Every morning"), ("incoming", "When something comes in"), ("asked", "Only when I ask")], id: \.0) { k, label in
                let on = checkIn == k
                Button {
                    checkIn = k
                } label: {
                    HStack(spacing: 5) {
                        if on { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
                        Text(label).font(.system(size: 12, weight: on ? .semibold : .regular)).lineLimit(1).fixedSize()
                    }
                    .padding(.horizontal, 8).frame(height: 28)
                    .foregroundStyle(WorldLook.cream.opacity(on ? 1 : 0.6))
                    .background(RoundedRectangle(cornerRadius: 7).fill(WorldLook.cream.opacity(on ? 0.12 : 0)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3).background(RoundedRectangle(cornerRadius: 9).fill(Color.black.opacity(0.28)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(WorldLook.cream.opacity(0.1)))
    }

    @ViewBuilder var routineList: some View {
        let mine = BotStore.owned(h, in: routines)
        if mine.isEmpty {
            Text(b.checkIn == "asked" ? "None: it works when you ask" : "None yet").foregroundStyle(WorldLook.cream.opacity(0.6))
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(mine, id: \.id) { r in
                    Button {
                        m.botSheet = nil
                        m.routinesPick = (h.id.uuidString, r.id)
                        m.routinesOpen = true
                    } label: {
                        HStack(spacing: 10) {
                            Circle().fill(Color(hex: Bots.hex(b.color), r.state == .paused ? 0.4 : 1)).frame(width: 7, height: 7)
                            Text(r.title).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(r.state == .paused ? "Paused" : r.often).font(.system(size: 12.5)).foregroundStyle(WorldLook.cream.opacity(0.55))
                                .lineLimit(1)
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(WorldLook.cream.opacity(0.4))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help("Open it on the Routines dial")
                }
            }
        }
    }

    var memory: some View {
        let n = Bots.remembered(b)
        let url = Bots.memory(b)
        let short = [b.room, "bots", url.deletingLastPathComponent().lastPathComponent, url.lastPathComponent].joined(separator: "/")
        return VStack(alignment: .leading, spacing: 4) {
            Text("Remembers \(n) thing\(n == 1 ? "" : "s")")
            HStack(spacing: 12) {
                Text(short).font(.system(size: 12, design: .monospaced)).foregroundStyle(WorldLook.cream.opacity(0.55)).lineLimit(1).truncationMode(
                    .middle)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(.plain).font(.system(size: 12.5)).underline().foregroundStyle(WorldLook.cream.opacity(0.85))
            }
        }
    }

    // MARK: Footer and the delete question

    @ViewBuilder var footer: some View {
        HStack(spacing: 20) {
            if editing {
                Text("Its chat, memory and routines stay with it.").font(.system(size: 12.5)).foregroundStyle(WorldLook.cream.opacity(0.45))
                Spacer()
                pill("Cancel", filled: false) {
                    resetFields()
                    go(.about)
                }
                pill("Save", filled: true) { save() }
            } else {
                if b.archived != nil {
                    textButton("Restore") {
                        m.restoreBot(h.id)
                        m.botSheet = nil
                    }
                } else {
                    textButton("Archive") {
                        m.botSheet = nil
                        m.archiveBot(h.id)
                    }
                }
                textButton("Delete…", warn: true) { go(.confirm) }
                Spacer()
                pill("Edit", filled: true) { go(.edit) }
            }
        }
    }

    func textButton(_ t: String, warn: Bool = false, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(t).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(warn ? Color(hex: 0xF6B46E) : WorldLook.cream.opacity(0.85))
        }
        .buttonStyle(.plain)
    }

    func pill(_ t: String, filled: Bool, warn: Bool = false, wide: Bool = false, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(t).font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(filled ? WorldLook.bg : WorldLook.cream.opacity(0.9))
                .padding(.horizontal, 20).frame(minWidth: 72, maxWidth: wide ? .infinity : nil, minHeight: 34)
                .background(Capsule().fill(filled ? (warn ? Color(hex: 0xF6B46E) : WorldLook.cream) : Color.white.opacity(0.06)))
                .overlay(Capsule().strokeBorder(WorldLook.cream.opacity(filled ? 0 : 0.22)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    func resetFields() {
        name = b.name
        color = b.color
        job = b.job
        uses = b.uses
        checkIn = b.checkIn
        miss = nil
    }

    func save() {
        var e = BotEdit()
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty && n != b.name { e.name = n }
        if color != b.color { e.color = color }
        let j = job.trimmingCharacters(in: .whitespacesAndNewlines)
        if !j.isEmpty && j != b.job { e.job = j }
        if uses != b.uses { e.uses = uses }
        if checkIn != b.checkIn { e.checkIn = checkIn }
        if !e.isEmpty, let why = m.editBot(h.id, e) {
            miss = why
            return
        }
        go(.about)
    }

    var confirm: some View {
        ZStack {
            Color.black.opacity(0.35).allowsHitTesting(false)  // the sheet under it is disabled meanwhile
            VStack(spacing: 8) {
                BotMoon(hex: Bots.hex(b.color), size: 46, t: 21.7)
                Text("Delete \(b.name)?").font(.system(size: 16, weight: .semibold)).padding(.top, 4)
                Text("Its memory and routines go too.").font(.system(size: 13)).foregroundStyle(WorldLook.cream.opacity(0.6))
                HStack(spacing: 10) {
                    pill("Delete it", filled: true, warn: true, wide: true) { m.deleteBot(h.id) }
                    pill("Keep it", filled: false, wide: true) { go(.about) }
                }
                .padding(.top, 10)
            }
            .padding(22).frame(width: 340)
            .background(PopupGlass().clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(WorldLook.cream.opacity(0.16)))
            .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
        }
    }
}

/// Behind the small box next to New bot: each archived bot, with Restore and Delete….
struct ArchivedBots: View {
    @ObservedObject var m: Model
    var body: some View {
        let list = m.archivedBots
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("Archived bots").font(.system(size: 13.5, weight: .semibold))
                Text("\(list.count)").font(.system(size: 13)).foregroundStyle(WorldLook.cream.opacity(0.45))
            }
            .padding(.bottom, 10).padding(.trailing, 70)
            if list.isEmpty {
                Text("None. Archived bots wait here, kept whole.").font(.system(size: 12.5)).foregroundStyle(WorldLook.cream.opacity(0.5))
            }
            ForEach(list) { h in
                if let b = h.bot {
                    VStack(spacing: 0) {
                        Rectangle().fill(WorldLook.cream.opacity(0.08)).frame(height: 1)
                        HStack(spacing: 12) {
                            BotMoon(hex: Bots.hex(b.color), size: 30, t: 21.7, faint: true).saturation(0.3)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(b.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                Text("Archived " + (b.archived ?? Date()).formatted(.dateTime.month(.abbreviated).day())).font(.system(size: 11.5))
                                    .foregroundStyle(WorldLook.cream.opacity(0.45))
                            }
                            Spacer(minLength: 8)
                            Button {
                                m.restoreBot(h.id)
                                if m.archivedBots.isEmpty { m.botsArchive = false }
                            } label: {
                                Text("Restore").font(.system(size: 12, weight: .semibold)).fixedSize().padding(.horizontal, 12).frame(height: 26)
                                    .overlay(Capsule().strokeBorder(WorldLook.cream.opacity(0.3))).contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            Button {
                                m.botsArchive = false
                                m.botSheet = BotSheetAsk(id: h.id, mode: .confirm)
                            } label: {
                                Text("Delete…").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(hex: 0xF6B46E)).fixedSize()
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 9)
                    }
                }
            }
        }
        .foregroundStyle(WorldLook.cream).padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 10).frame(width: 390, alignment: .leading)
    }
}
