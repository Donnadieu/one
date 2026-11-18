import SwiftUI

// MARK: - What the routines' constellations do (RoutinesSky.swift draws them; Omar, Nov 17-18 2026: "a way to manage
// those routines on the right", then "no pop-up"). A picked routine opens in place under its own star: what it does,
// when it runs, its last result, and Run now · Pause · Remove · Ask, as quiet words. Remove (and Clear all on the quiet
// groups) asks first, right there. Nothing here is a box or a card.

extension RoutinesPanel {
    /// Renders through ImageRenderer draw a scroll view blank: they lay the open group out flat (clipped to its place).
    nonisolated(unsafe) static var flatList = false

    func listGroups(_ s: RoutinesSnapshot) -> [RoutineList.Group] {
        RoutineList.groups(s.routines, by: listBy, me: m.name) { r in
            guard let h = owner(r), let b = h.bot else { return nil }
            return (h.id.uuidString, b.name, Bots.hex(b.color))
        }
    }

    /// A routine's details, under its star.
    @ViewBuilder func skyDetails(_ r: Routine, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            if r.state == .finished && !r.outside { finishedDetails(r, now: now) } else { routineDetails(r, now: now) }
            if let note {
                Text(note).font(.system(size: 10.5)).foregroundStyle(WorldLook.cream.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: Sky.area.width - 44, alignment: .leading)
        .starCalm(pad: 4, feather: 14, floor: 0.12)
        .routineZone("details")
        .transition(.opacity)
    }

    @ViewBuilder func routineDetails(_ r: Routine, now: Date) -> some View {
        let failed = r.needsLook
        let partly = r.state == .failed && r.miss == .partly
        let last: String = {
            if r.state == .running, let l = r.lastRun { return "Running now. Before that: " + Routines.stamp(l, now: now) }
            return r.lastRun.map { Routines.stamp($0, now: now) + " · " + Dial.word(r) } ?? "Never ran yet"
        }()
        let next: String = r.state == .paused ? "Paused" : r.next.map { Routines.stamp($0, now: now) } ?? "Not again"
        Text(r.state == .failed ? Routines.missLine(r) : r.caughtUpAt != nil ? Routines.caughtUpLine(r) : r.line).font(.system(size: 11))
            .foregroundStyle(WorldLook.cream.opacity(0.7)).lineLimit(4).fixedSize(horizontal: false, vertical: true)
        VStack(alignment: .leading, spacing: 6) {
            fact("Runs", r.often)
            fact(failed ? "Next try" : "Next", next)
            fact(
                "Last", last, color: failed ? Color(hex: 0xF6B46E) : WorldLook.cream.opacity(0.85),
                sub: partly && !r.notes.did.isEmpty ? nil : r.reason)
            if partly || r.caughtUpAt != nil { outcomeFacts(r) }
            if let l = r.leftover { fact("Looks done", l) }
            if let room = r.room { fact("Room", room) }
            if let b = owner(r)?.bot { fact("Belongs to", b.name, color: Color(hex: Bots.hex(b.color))) }
            if r.outside { fact("Where", "Runs outside One", color: WorldLook.cream.opacity(0.6)) }
        }
        if removeAsk == r.id {
            removeRow(r)
        } else {
            HStack(spacing: 16) {
                if !r.outside {
                    skyAction(r.leftover != nil ? "Run" : "Run now", strong: true) {
                        Task {
                            await act(
                                r, ["cron", "run", r.id], doing: "Starting it now…", done: "It starts within a minute. Its result shows up here.")
                        }
                    }
                    skyAction(r.state == .paused ? "Resume" : "Pause") {
                        let on = r.state == .paused
                        Task {
                            await act(
                                r, ["cron", on ? "resume" : "pause", r.id], doing: on ? "Turning it back on…" : "Pausing it…",
                                done: on ? "It's back on." : "Paused. It won't run until you turn it back on.")
                        }
                    }
                }
                if RoutinesPanel.canRemove(r) {
                    skyAction("Remove") {
                        note = nil
                        removeAsk = r.id
                    }
                }
                skyAction("Ask \(m.name)") {
                    ask("Tell me about my routine “\(r.title)”: what it does, how it's been going, and anything I should do about it.")
                }
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder func finishedDetails(_ r: Routine, now: Date) -> some View {
        Text(Routines.finishedWhy(r)).font(.system(size: 11)).foregroundStyle(WorldLook.cream.opacity(0.7)).fixedSize(
            horizontal: false, vertical: true)
        VStack(alignment: .leading, spacing: 6) {
            fact("Finished", r.lastRun.map { Routines.stamp($0, now: now) } ?? "Yes")
            fact("Ran", r.runs == 1 ? "Once" : "\(r.runs) times", color: WorldLook.cream.opacity(0.85))
            if r.lastFailed { fact("Last run", "Didn't work", color: Color(hex: 0xF6B46E)) }
            fact("Runs", r.often)
            reportsFact(Routines.reports(r.id), now: now)
        }
        if renewAsk == r.id {
            Text(Routines.renewQuestion(r)).font(.system(size: 11)).foregroundStyle(WorldLook.cream.opacity(0.85)).fixedSize(
                horizontal: false, vertical: true)
            HStack(spacing: 16) {
                skyAction("Yes, run it again", strong: true) { Task { await renewNow(r) } }
                skyAction("Not now") { renewAsk = nil }
            }
        } else if removeAsk == r.id {
            removeRow(r)
        } else {
            HStack(spacing: 16) {
                skyAction("Run again", strong: true) {
                    note = nil
                    renewAsk = r.id
                }
                skyAction("Remove") {
                    note = nil
                    removeAsk = r.id
                }
                skyAction("Ask \(m.name)") {
                    ask("Tell me about my finished routine “\(r.title)”: what it found over its runs, and whether it's worth running again.")
                }
            }
            .padding(.top, 2)
        }
        if renewHelp == r.id {
            skyAction("Ask \(m.name) to do it", strong: true) {
                renewHelp = nil
                ask(
                    "Please set up my finished routine “\(r.title)” (id \(r.id)) to run again: same instructions, schedule and settings, "
                        + (r.once ? "once more, now." : "for another \(r.runs) runs.")
                        + " The Routines screen couldn't do it by itself. I've already said yes.")
            }
        }
    }

    /// "Remove these 5?" under a quiet group's name, in place.
    func clearAsk(_ g: RoutineList.Group) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Remove these \(g.rows.count)? They won't run again. Their past reports stay.").font(.system(size: 11)).foregroundStyle(
                WorldLook.cream.opacity(0.85)
            ).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                skyAction("Remove them", strong: true) { Task { await remove(g.rows) } }
                skyAction("Keep them") { removeAsk = nil }
            }
        }
        .starCalm(pad: 4, feather: 14, floor: 0.12)
        .routineZone("remove-ask")
    }

    /// "Remove it?" under a routine's details, for one that looks done, is paused or finished.
    func removeRow(_ r: Routine) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Remove it? It won't run again. Its past reports stay.").font(.system(size: 11)).foregroundStyle(WorldLook.cream.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                skyAction("Remove it", strong: true) { Task { await remove([r]) } }
                skyAction("Keep it") { removeAsk = nil }
            }
        }
        .routineZone("remove-ask")
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
        note =
            failed == 0
            ? (rs.count == 1 ? "Removed. Its past reports stay." : "Removed all \(rs.count).")
            : "\(failed) didn't go. Ask \(m.name) and I'll sort it out."
        if failed == 0 { sel = nil }
        await reload()
    }
}
