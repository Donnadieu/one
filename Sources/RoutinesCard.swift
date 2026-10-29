import AppKit
import SwiftUI

/// Puts the card at its usual height, and lifts a tall one (a run that lists what worked and what didn't) so its bottom
/// never runs off the panel.
struct CardSlot: Layout {
    let top: CGFloat
    var bottom: CGFloat = Dial.size.height - 14
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: subviews.first?.sizeThatFits(.unspecified).width ?? 0, height: Dial.size.height)
    }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let v = subviews.first else { return }
        let s = v.sizeThatFits(ProposedViewSize(width: b.width, height: nil))
        let y = max(b.minY + 70, min(b.minY + top, b.minY + bottom - s.height))
        v.place(at: CGPoint(x: b.minX, y: y), proposal: ProposedViewSize(width: b.width, height: s.height))
    }
    struct Place: ViewModifier {
        let top: CGFloat
        func body(content: Content) -> some View { CardSlot(top: top) { content }.offset(x: 890) }
    }
}

// MARK: - The routines panel's floating pieces: the card for a tapped routine or skill (Run now, Pause, Ask),
// the "want me to save how I did …?" question by the orb, and the fading "I learned something new" notice.

extension RoutinesPanel {
    var pendingAsks: [LearnOffer] { m.learning.offers.filter { $0.kind == "ask" } }

    // MARK: Card

    @ViewBuilder func card(_ s: RoutinesSnapshot, _ L: Dial.Layout) -> some View {
        let top = min(392, max(372, 120 + CGFloat(L.later.count) * 44 + 250))
        if let id = sel {
            Group {
                if id.hasPrefix("skill:"), let sk = s.skills.first(where: { "skill:" + $0.path == id }) {
                    skillCard(sk, now: s.now)
                } else if let r = s.routines.first(where: { $0.id == id }) {
                    routineCard(r, now: s.now)
                }
            }
            .frame(width: 250).starCalm().transition(.opacity)
            .modifier(CardSlot.Place(top: top))
        }
    }

    func cardShell<C: View>(orange: Bool, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(hex: 0x1E1E22, 0.98)))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(orange ? Dial.orange.opacity(0.4) : WorldLook.cream.opacity(0.12))
            )
            .shadow(color: orange ? Dial.orange.opacity(0.25) : Color(hex: 0xFFECD6, 0.12), radius: 18)
    }

    func eyebrow(_ text: String, dot: Color) -> some View {
        HStack(spacing: 7) {
            Circle().fill(dot).frame(width: 6, height: 6)
            Text(text).font(.system(size: 10.5, weight: .medium)).foregroundStyle(WorldLook.cream.opacity(0.55)).lineLimit(1)
            Spacer(minLength: 4)
            Button {
                pick(sel ?? "")
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(WorldLook.cream.opacity(0.45))
            }.buttonStyle(.plain).help("Close this card")
        }
    }

    func fact(_ k: String, _ v: String, color: Color = WorldLook.cream.opacity(0.85), sub: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(k).font(.system(size: 11)).foregroundStyle(WorldLook.cream.opacity(0.45)).frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(v).font(.system(size: 11.5, weight: .medium)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
                if let sub {
                    Text(sub).font(.system(size: 11)).foregroundStyle(Dial.orange.opacity(0.9)).lineLimit(3).fixedSize(
                        horizontal: false, vertical: true
                    ).help(sub)
                }
            }
        }
    }

    func pill(_ title: String, filled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(filled ? WorldLook.bg : WorldLook.cream)
                .padding(.horizontal, 11).frame(height: 28)
                .background(Capsule().fill(filled ? WorldLook.cream : WorldLook.cream.opacity(0.09)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain).fixedSize().disabled(busy).opacity(busy ? 0.5 : 1)
    }

    func routineCard(_ r: Routine, now: Date) -> some View {
        let failed = r.needsLook  // orange only when it did nothing it can show
        let partly = r.state == .failed && r.miss == .partly
        var last = "Never ran yet"
        if let l = r.lastRun { last = Routines.stamp(l, now: now) + " · " + Dial.word(r) }
        if r.state == .running, let l = r.lastRun { last = "Running now. Before that: " + Routines.stamp(l, now: now) }
        let next: String = r.state == .paused ? "Paused" : r.next.map { Routines.stamp($0, now: now) } ?? "Not again"
        return cardShell(orange: failed) {
            eyebrow(
                (r.outside ? "Runs outside One" : "Scheduled job") + (r.state == .paused ? " · paused" : ""),
                dot: failed ? Dial.orange : r.state == .never || r.state == .paused ? WorldLook.cream.opacity(0.4) : WorldLook.cream)
            Text(r.title).font(.system(size: 15, weight: .semibold)).padding(.top, 9).fixedSize(horizontal: false, vertical: true)
            Text(r.state == .failed ? Routines.missLine(r) : r.caughtUpAt != nil ? Routines.caughtUpLine(r) : r.what).font(.system(size: 11.5))
                .foregroundStyle(WorldLook.cream.opacity(0.6)).padding(
                    .top, 4
                ).lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
            Rectangle().fill(WorldLook.cream.opacity(0.08)).frame(height: 1).padding(.vertical, 11)
            VStack(alignment: .leading, spacing: 8) {
                fact("How often", r.often)
                fact(
                    "Last run", last, color: failed ? Color(hex: 0xF6B46E) : WorldLook.cream.opacity(0.85),
                    sub: partly && !r.notes.did.isEmpty ? nil : r.reason)
                if partly || r.caughtUpAt != nil { outcomeFacts(r) }
                fact(failed ? "Next try" : "Next", next)
            }
            HStack(spacing: 6) {
                if !r.outside {
                    pill("Run now", filled: true) {
                        Task {
                            await act(
                                r, ["cron", "run", r.id], doing: "Starting it now…", done: "It starts within a minute. Its result shows up here.")
                        }
                    }
                    pill(r.state == .paused ? "Turn back on" : "Pause") {
                        let on = r.state == .paused
                        Task {
                            await act(
                                r, ["cron", on ? "resume" : "pause", r.id], doing: on ? "Turning it back on…" : "Pausing it…",
                                done: on ? "It's back on." : "Paused. It won't run until you turn it back on.")
                        }
                    }
                }
                pill("Ask \(m.name)") {
                    ask("Tell me about my routine “\(r.title)”: what it does, how it's been going, and anything I should do about it.")
                }
            }
            .padding(.top, 14)
            if let note {
                Text(note).font(.system(size: 11)).foregroundStyle(WorldLook.cream.opacity(0.6)).padding(.top, 8).fixedSize(
                    horizontal: false, vertical: true)
            }
        }
    }

    /// What worked and what didn't, plainly, from the run's own report and step log.
    @ViewBuilder func outcomeFacts(_ r: Routine) -> some View {
        let n = r.notes
        let worked = n.did.filter { !n.caughtUp.contains($0) }
        if !worked.isEmpty { fact("Worked", Routines.names(worked).capitalizingFirst) }
        if !n.caughtUp.isEmpty {
            let at = n.caughtUpAt.map { " (" + Routines.clock(Routines.minutes($0)) + ")" } ?? ""
            fact("Made up", Routines.names(n.caughtUp).capitalizingFirst + " later" + at)
        }
        if r.state == .failed {
            if !n.didnt.isEmpty {
                fact("Didn't", Routines.names(n.didnt).capitalizingFirst, color: Color(hex: 0xF6B46E))
            } else if n.cut {
                let at = n.cutAt.map { " at " + Routines.clock(Routines.minutes($0)) } ?? ""
                fact("Didn't", "The rest: One restarted\(at)", color: WorldLook.cream.opacity(0.85))
            }
        }
    }

    func skillCard(_ s: SkillStar, now: Date) -> some View {
        cardShell(orange: false) {
            eyebrow("Skill" + (s.room.map { " · " + $0 } ?? ""), dot: WorldLook.cream)
            Text(s.title).font(.system(size: 15, weight: .semibold)).padding(.top, 9).fixedSize(horizontal: false, vertical: true)
            Text(s.name).font(.system(size: 10.5)).foregroundStyle(WorldLook.cream.opacity(0.4))
            if !s.about.isEmpty {
                Text(s.about).font(.system(size: 11.5)).foregroundStyle(WorldLook.cream.opacity(0.6)).padding(.top, 4).lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Rectangle().fill(WorldLook.cream.opacity(0.08)).frame(height: 1).padding(.vertical, 11)
            VStack(alignment: .leading, spacing: 8) {
                fact("Where", s.room ?? "\(m.name)'s own skills")
                fact("Made", s.made.map { Routines.stamp($0, now: now) } ?? (s.mine ? "For you" : "Before One"))
            }
            HStack(spacing: 6) {
                pill("Read it", filled: true) {
                    m.routinesOpen = false
                    m.viewing = URL(fileURLWithPath: s.path)
                }
                pill("Ask \(m.name)") { ask("Tell me about your skill “\(s.name)”: what it's for and when you use it.") }
            }
            .padding(.top, 14)
        }
    }

    func ask(_ text: String) {
        close()
        Task { await m.send(text, toNova: true) }  // getting ready: waits next up, goes when One opens
    }

    func act(_ r: Routine, _ args: [String], doing: String, done: String) async {
        busy = true
        note = doing
        let (code, _) = await hermesRun(args, timeout: 60)
        note = code == 0 ? done : "That didn't work. Ask \(m.name) and I'll sort it out."
        busy = false
        snap = await Task.detached { Routines.load() }.value
    }

    // MARK: "Want me to save how I did …?" by the orb

    @ViewBuilder var askBubble: some View {
        if let o = pendingAsks.last {
            let job = m.learning.jobs.first { $0.id == o.job }
            let what = o.helper.flatMap { h in m.helpers.first { $0.id == h }?.title } ?? job.map { $0.kind.isEmpty ? "that" : $0.kind } ?? "that"
            HStack(alignment: .center, spacing: 10) {
                MiniOrb()
                Text("Want me to save how I did \(what) as a recipe? Next time it'll be faster.").font(.system(size: 12.5))
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .trailing, spacing: 6) {
                    Group {
                        pill("Yes, save it", filled: true) { Task { _ = await m.learnPick(Learning.yes, helper: .some(o.helper)) } }
                        pill("No thanks") { Task { _ = await m.learnPick(Learning.no, helper: .some(o.helper)) } }
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10).frame(width: 440, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(hex: 0x1E1E22, 0.97)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Dial.orange.opacity(0.35)))
            .starCalm()
            .offset(x: Dial.center.x - 40, y: Dial.center.y + 222)
        }
    }

    // MARK: "I learned something new" (fades after a few seconds)

    @ViewBuilder func learnedNotice(_ s: RoutinesSnapshot) -> some View {
        let day: TimeInterval = 48 * 3600
        let fresh = s.skills.filter { $0.mine && ($0.made.map { s.now.timeIntervalSince($0) < day } ?? false) }.max {
            ($0.made ?? .distantPast) < ($1.made ?? .distantPast)
        }
        if let f = fresh, !noticeGone {
            let undo = m.learning.offers.last { $0.kind == "undo" && $0.skills.contains(f.name) }
            HStack(spacing: 10) {
                Image(systemName: "sparkle").font(.system(size: 11)).foregroundStyle(Color(hex: 0xFFE2C2))
                (Text("I learned something new: ") + Text(f.title).fontWeight(.semibold)
                    + Text(f.room.map { " (\($0))" } ?? "").foregroundColor(WorldLook.cream.opacity(0.5)))
                    .font(.system(size: 12)).lineLimit(1)
                Spacer(minLength: 6)
                if let undo {
                    pill("Undo") { Task { _ = await m.learnPick(Learning.undo, helper: .some(undo.helper)) } }
                } else {
                    pill("Read it") { pick("skill:" + f.path) }
                }
            }
            .padding(.leading, 14).padding(.trailing, 6).frame(width: 520, height: 40)
            .background(Capsule().fill(Color(hex: 0x1E1E22, 0.97)))
            .overlay(Capsule().strokeBorder(WorldLook.cream.opacity(0.12)))
            .starCalm()
            .offset(x: 316, y: 66)
            .transition(.opacity)
            .task {
                guard !HomeView.still else { return }
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                withAnimation(.easeOut(duration: 0.8)) { noticeGone = true }
            }
        }
    }
}
