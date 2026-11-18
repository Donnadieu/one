import SwiftUI

// MARK: - The routines list on the right of the Routines panel (Omar, Nov 17 2026: "We need to have a way to manage
// those routines on the right"). It has a fixed place between the top and the skills' stars and scrolls inside it,
// so it never runs over them however many routines there are. Groups fold and show a count; each row has a plain
// name, what it does, its next run and last result. Tapping a row opens its card (Run now, Pause, Remove, Ask).

extension RoutinesPanel {
    /// Renders through ImageRenderer draw a scroll view blank: they lay the list out flat (clipped to its place).
    nonisolated(unsafe) static var flatList = false

    func listGroups(_ s: RoutinesSnapshot) -> [RoutineList.Group] {
        RoutineList.groups(s.routines, by: listBy, me: m.name) { r in
            guard let h = owner(r), let b = h.bot else { return nil }
            return (h.id.uuidString, b.name, Bots.hex(b.color))
        }
    }

    @ViewBuilder func routineList(_ s: RoutinesSnapshot) -> some View {
        let gs = listGroups(s)
        let shut = folded ?? (finishedOpen ? [] : RoutineList.folded(gs))
        let box = Dial.listBox
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("All routines").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(WorldLook.cream.opacity(0.55))
                Spacer(minLength: 4)
                byChip(.who, "Who")
                byChip(.often, "How often")
            }
            if let note, sel == nil {
                Text(note).font(.system(size: 10.5)).foregroundStyle(WorldLook.cream.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
            }
            Group {
                if RoutinesPanel.flatList {
                    groupsColumn(gs, shut: shut, now: s.now).frame(maxHeight: .infinity, alignment: .top).clipped()
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: true) { groupsColumn(gs, shut: shut, now: s.now).padding(.trailing, 6) }
                            .onChange(of: sel) { _, new in reveal(new, gs, shut, proxy) }
                            .onAppear { reveal(sel, gs, shut, proxy) }
                    }
                }
            }
        }
        .padding(10)
        .frame(width: box.width, height: box.height, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(hex: 0x1A1A1E, 0.9)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(WorldLook.cream.opacity(0.08)))
        .routineZone("list")
        .starCalm(floor: 0.12)
        .offset(x: box.minX, y: box.minY)
    }

    /// Picked on the dial (or open at first): open its group and bring its row into view.
    func reveal(_ id: String?, _ gs: [RoutineList.Group], _ shut: Set<String>, _ proxy: ScrollViewProxy) {
        guard let id, let g = gs.first(where: { $0.rows.contains { $0.id == id } }) else { return }
        if shut.contains(g.id) { folded = shut.subtracting([g.id]) }
        DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) } }
    }

    func byChip(_ b: RoutineList.By, _ label: String) -> some View {
        let on = listBy == b
        return Button {
            withAnimation(.easeOut(duration: 0.18)) {
                listBy = b
                folded = nil
            }
        } label: {
            Text(label).font(.system(size: 10.5, weight: on ? .semibold : .regular)).foregroundStyle(WorldLook.cream.opacity(on ? 0.95 : 0.5))
                .padding(.horizontal, 8).frame(height: 20)
                .overlay(Capsule().strokeBorder(WorldLook.cream.opacity(on ? 0.5 : 0.12)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain).help(b == .who ? "Group by who it's for: \(m.name), a room or a bot" : "Group by how often it runs")
    }

    func groupsColumn(_ gs: [RoutineList.Group], shut: Set<String>, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(gs) { g in
                groupHeader(g, open: !shut.contains(g.id), shut: shut)
                if !shut.contains(g.id) {
                    if removeAsk == "group:" + g.id { clearAsk(g) }
                    ForEach(g.rows) { r in listRow(r, now: now, tint: g.tint, quiet: g.clearable).id(r.id) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func groupHeader(_ g: RoutineList.Group, open: Bool, shut: Set<String>) -> some View {
        let looks = g.rows.filter(\.needsLook).count
        return HStack(spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) {
                    var f = shut
                    if open { f.insert(g.id) } else { f.remove(g.id) }
                    folded = f
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(WorldLook.cream.opacity(0.4)).frame(width: 10)
                    if let t = g.tint { Circle().fill(Color(hex: t)).frame(width: 7, height: 7) }
                    Text(g.title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(WorldLook.cream.opacity(g.clearable ? 0.55 : 0.85))
                        .lineLimit(1)
                    Text("\(g.rows.count)").font(.system(size: 10, weight: .semibold)).foregroundStyle(WorldLook.cream.opacity(0.55))
                        .padding(.horizontal, 6).frame(height: 16).background(Capsule().fill(WorldLook.cream.opacity(0.08)))
                    if looks > 0 {
                        Text("\(looks) need\(looks == 1 ? "s" : "") a look").font(.system(size: 10)).foregroundStyle(Color(hex: 0xF6B46E)).lineLimit(
                            1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(open ? "Fold this group" : "Show these routines")
            if g.clearable && open && removeAsk != "group:" + g.id {
                Button {
                    note = nil
                    removeAsk = "group:" + g.id
                } label: {
                    Text("Clear all").font(.system(size: 10.5, weight: .medium)).foregroundStyle(WorldLook.cream.opacity(0.6)).underline(
                        color: WorldLook.cream.opacity(0.25))
                }.buttonStyle(.plain).help("Remove every routine in this group (asks first)")
            }
        }
        .padding(.top, 6).padding(.bottom, 2)
    }

    func listRow(_ r: Routine, now: Date, tint: UInt32?, quiet: Bool) -> some View {
        let look = r.needsLook
        return Button {
            pick(r.id)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Group { if r.state == .finished { finishedCheck(11) } else { smallOrb(r, size: 11) } }.padding(.top, 3)
                VStack(alignment: .leading, spacing: 1.5) {
                    Text(r.name).font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(look ? Color(hex: 0xF6B46E) : tint.map { Color(hex: $0) } ?? WorldLook.cream.opacity(quiet ? 0.7 : 1))
                        .lineLimit(1)
                    Text(r.line).font(.system(size: 10.5)).foregroundStyle(WorldLook.cream.opacity(0.55)).lineLimit(1)
                    Text(r.leftover != nil ? "Looks done · " + RoutineList.status(r, now: now) : RoutineList.status(r, now: now))
                        .font(.system(size: 10)).foregroundStyle(look ? Color(hex: 0xF6B46E, 0.85) : WorldLook.cream.opacity(0.4)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4).padding(.horizontal, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(WorldLook.cream.opacity(sel == r.id ? 0.09 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(r.line)
    }

    /// "Remove these 5?" under a quiet group's title.
    func clearAsk(_ g: RoutineList.Group) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Remove these \(g.rows.count)? They won't run again. Their past reports stay.").font(.system(size: 11)).foregroundStyle(
                WorldLook.cream.opacity(0.8)
            ).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                pill("Remove them", filled: true) { Task { await remove(g.rows) } }
                pill("Keep them") { removeAsk = nil }
            }
        }
        .padding(8).background(RoundedRectangle(cornerRadius: 10).fill(WorldLook.cream.opacity(0.05)))
    }

    /// "Remove it?" on a routine's card, for one that looks done, is paused or finished.
    @ViewBuilder func removeRow(_ r: Routine) -> some View {
        if removeAsk == r.id {
            Text("Remove “\(r.name)”? It won't run again. Its past reports stay.").font(.system(size: 11.5)).foregroundStyle(
                WorldLook.cream.opacity(0.8)
            ).padding(.top, 12).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                pill("Remove it", filled: true) { Task { await remove([r]) } }
                pill("Keep it") { removeAsk = nil }
            }
            .padding(.top, 8)
        }
    }

    static func canRemove(_ r: Routine) -> Bool { !r.outside && (r.leftover != nil || r.state == .paused || r.state == .finished) }

    func remove(_ rs: [Routine]) async {
        busy = true
        note = rs.count == 1 ? "Removing it…" : "Removing them…"
        var failed = 0
        for r in rs where !r.outside {
            let (code, _) = await hermesRun(RoutineList.removeSteps(r), timeout: 60)
            if code != 0 { failed += 1 }
        }
        busy = false
        removeAsk = nil
        note = failed == 0 ? (rs.count == 1 ? "Removed." : "Removed all \(rs.count).") : "\(failed) didn't go. Ask \(m.name) and I'll sort it out."
        if failed == 0 { sel = nil }
        await reload()
    }
}
