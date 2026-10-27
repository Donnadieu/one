import SwiftUI

// MARK: - Sending while busy
//
// Nothing ever waits for a free moment to be typed or said. A message sent while the assistant (or a
// helper) is working goes straight into that running turn through the engine's own mid-turn message
// (Hermes puts it right after the latest step, as "[OUT-OF-BAND USER MESSAGE …]"). When the engine
// can't take one at that moment (the turn hasn't started answering yet, the reply is about to be read
// aloud, a picture is attached, or One is stopped), it waits "next up" and goes the moment it can:
// into the turn as soon as it's under way, or, if the turn ends first, as the start of the next one.
// Messages go one at a time, oldest first, so they always arrive in order. Stop is separate:
// a new message never stops anything.

/// What `compose` makes of what was typed or said.
struct Composed {
    var display: String
    var engine: String
    var images: [String]
    /// The words themselves (display ends with them, engine starts with them).
    var typed: String
}

/// A message sent while busy.
struct FollowUp: Identifiable, Equatable {
    enum State { case next, sending, sent }
    let id = UUID()
    var c: Composed
    var helper: UUID?
    var hidden = false
    var state: State = .next
    var display: String { c.display }
    var engine: String { c.engine }

    static func == (a: FollowUp, b: FollowUp) -> Bool { a.id == b.id && a.state == b.state && a.c.engine == b.c.engine }

    /// The same message with new words (the pictures/files it carries stay).
    func edited(_ words: String) -> FollowUp {
        var f = self
        let t = c.typed
        f.c.display = (c.display.hasSuffix(t) ? String(c.display.dropLast(t.count)) : "") + words
        f.c.engine = words + (c.engine.hasPrefix(t) ? String(c.engine.dropFirst(t.count)) : "")
        f.c.typed = words
        return f
    }
}

@MainActor
extension Model {
    func followUp(_ c: Composed, helper: UUID?, hidden: Bool) {
        followUps.append(FollowUp(c: c, helper: helper, hidden: hidden))
        pumpFollowUps()
        if let h = helper { nextUpForHelper(h) } else { nextUpReady() }
    }

    /// Something came back from the main conversation's turn: it's under way and can take messages.
    func turnUnderway() {
        guard turnLive else { return }
        turnStarted = true
        pumpFollowUps()
    }
    func helperUnderway(_ id: UUID) {
        helperLive.insert(id)
        pumpFollowUps()
    }

    /// Can this message go into a running turn right now?
    func canSteer(_ f: FollowUp) -> Bool {
        guard !paused, !f.hidden, f.images.isEmpty, editingFollowUp != f.id, Date() >= steerRetryAt else { return false }
        if let h = f.helper { return helperLive.contains(h) && helpers.first { $0.id == h }?.state == "working" }
        return turnLive && turnStarted
    }

    /// The oldest message still waiting for each conversation, if the engine can take it now.
    /// A later message never overtakes an earlier one for the same conversation.
    private func nextSteerable() -> FollowUp? {
        var seen: Set<String> = []
        for f in followUps where f.state != .sent && !f.hidden {
            let key = f.helper?.uuidString ?? "main"
            if seen.contains(key) { continue }
            seen.insert(key)
            if f.state == .next && canSteer(f) { return f }
        }
        return nil
    }

    /// Hands waiting messages to running turns, one at a time.
    func pumpFollowUps() {
        guard !steeringNow else { return }
        steeringNow = true
        Task { @MainActor in
            while let f = self.nextSteerable() {
                var sid: String?
                if let h = f.helper {
                    sid = self.helpers.first { $0.id == h }?.sid
                    if sid == nil { break }
                }
                self.setState(f.id, .sending)
                let r = await Engine.shared.steer(sid == nil ? f.engine : Helpers.forHelper(f.engine), session: sid)
                if r.hasPrefix("error") {
                    // Not taken (e.g. a step that can't take a message): it waits and is tried again shortly.
                    self.setState(f.id, .next)
                    self.steerRetryAt = Date().addingTimeInterval(3)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { Task { @MainActor in self.pumpFollowUps() } }
                    break
                }
                self.setState(f.id, .sent)
            }
            self.steeringNow = false
        }
    }

    private func setState(_ id: UUID, _ s: FollowUp.State) {
        if let k = followUps.firstIndex(where: { $0.id == id }) { followUps[k].state = s }
    }

    /// The main turn ended: what went into it stays on its reply; what was in flight finishes first.
    func turnOver(_ idx: Int, failed: Bool) async {
        turnLive = false
        turnStarted = false
        while steeringNow { try? await Task.sleep(for: .milliseconds(100)) }
        try? await Task.sleep(for: .milliseconds(150))  // the last words of a message answered on its own
        let sent = followUps.filter { $0.helper == nil && $0.state == .sent }
        followUps.removeAll { f in sent.contains { $0.id == f.id } }
        if failed && !sent.isEmpty {
            // The turn broke: they may not have been seen. Send them again next rather than lose them.
            followUps.insert(
                contentsOf: sent.map {
                    var f = $0
                    f.state = .next
                    return f
                }, at: 0)
        } else if idx < bubbles.count {
            bubbles[idx].followUps += sent.filter { !$0.hidden }.map(\.display)
        }
    }

    /// Nothing is running: the waiting messages go now, in order, as the next turn.
    func nextUpReady() {
        guard !paused, !thinking else { return }
        let batch = leadingWaiting(helper: nil)
        guard !batch.isEmpty else { return }
        followUps.removeAll { f in batch.contains { $0.id == f.id } }
        let shown = batch.filter { !$0.hidden }.map(\.display).joined(separator: "\n")
        let c = Composed(
            display: shown, engine: batch.map(\.engine).joined(separator: "\n\n"), images: batch.flatMap(\.c.images),
            typed: shown)
        thinking = true
        Task { @MainActor in await self.runTurn(c, hidden: shown.isEmpty) }
    }

    /// A helper's turn ended: messages that went in become part of what was asked.
    func helperTurnOver(_ id: UUID) async {
        helperLive.remove(id)
        while steeringNow { try? await Task.sleep(for: .milliseconds(100)) }
        let sent = followUps.filter { $0.helper == id && $0.state == .sent }
        followUps.removeAll { f in sent.contains { $0.id == f.id } }
        guard !sent.isEmpty else { return }
        update(id) { h in h.asked = ([h.asked ?? ""] + sent.map(\.display)).filter { !$0.isEmpty }.joined(separator: "\n") }
    }

    func nextUpForHelper(_ id: UUID) {
        guard !paused, let h = helpers.first(where: { $0.id == id }), h.state != "working", h.sid != nil else { return }
        let batch = leadingWaiting(helper: id)
        guard !batch.isEmpty else { return }
        followUps.removeAll { f in batch.contains { $0.id == f.id } }
        update(id) { $0.asked = batch.map(\.display).joined(separator: "\n") }
        Task { @MainActor in
            await self.runHelper(id, batch.map(\.engine).joined(separator: "\n\n"), images: batch.flatMap(\.c.images))
        }
    }

    /// The waiting messages at the front of a conversation's line, up to one being changed.
    private func leadingWaiting(helper: UUID?) -> [FollowUp] {
        var out: [FollowUp] = []
        for f in followUps where f.helper == helper {
            if f.state != .next || f.id == editingFollowUp { break }
            out.append(f)
        }
        return out
    }

    /// After a stop is lifted or a waiting message was changed: send whatever can go now.
    func sendWaiting() {
        pumpFollowUps()
        nextUpReady()
        for id in Set(followUps.compactMap(\.helper)) { nextUpForHelper(id) }
    }

    func editFollowUp(_ id: UUID, to words: String?) {
        let w = words?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let k = followUps.firstIndex(where: { $0.id == id }), followUps[k].state == .next {
            if w.isEmpty { followUps.remove(at: k) } else { followUps[k] = followUps[k].edited(w) }
        }
        editingFollowUp = nil
        sendWaiting()
    }
}

extension FollowUp {
    var images: [String] { c.images }
}

// MARK: - How they look: under what was asked, each with a small tag

struct FollowUpList: View {
    @ObservedObject var m: Model
    let helper: UUID?
    /// Already went into an earlier reply (saved with it).
    var sent: [String] = []
    var to: String { helper.flatMap { id in m.helpers.first { $0.id == id }?.title } ?? m.name }
    var body: some View {
        let live = m.followUps.filter { $0.helper == helper && !$0.hidden }
        if !sent.isEmpty || !live.isEmpty {
            VStack(spacing: 6) {
                ForEach(Array(sent.enumerated()), id: \.offset) { _, t in FollowUpLine(text: t, tag: "Sent to \(to)", waiting: false) }
                ForEach(live) { f in
                    if m.editingFollowUp == f.id {
                        FollowUpEditor(words: f.c.typed) { m.editFollowUp(f.id, to: $0) }
                    } else if f.state == .next {
                        Button {
                            m.editingFollowUp = f.id
                        } label: {
                            FollowUpLine(text: f.display, tag: "Next up", waiting: true)
                        }
                        .buttonStyle(.plain).help("Tap to change it or not send it")
                    } else {
                        FollowUpLine(text: f.display, tag: "Sent to \(to)", waiting: false)
                    }
                }
            }
            .animation(.easeOut(duration: 0.3), value: live)
        }
    }
}

struct FollowUpLine: View {
    let text: String
    let tag: String
    let waiting: Bool
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(text).font(.callout).foregroundStyle(Color.accentColor.opacity(waiting ? 0.75 : 1)).multilineTextAlignment(.center)
            Text(tag).font(.caption2.weight(.semibold))
                .foregroundStyle(waiting ? WorldLook.bg : Color.secondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(waiting ? Color(hex: 0xFFE2C2) : Color.white.opacity(0.08)))
                .overlay(Capsule().stroke(Color.white.opacity(waiting ? 0 : 0.16)))
                .fixedSize()
        }
        .transition(.opacity.combined(with: .offset(y: 6)))
    }
}

/// Change a waiting message, or don't send it at all.
struct FollowUpEditor: View {
    @State var words: String
    let done: (String?) -> Void
    var body: some View {
        HStack(spacing: 8) {
            TextField("", text: $words).textFieldStyle(.plain).font(.callout)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().fill(.ultraThinMaterial)).overlay(Capsule().stroke(Color.white.opacity(0.28)))
                .onSubmit { done(words) }
            Button {
                done(words)
            } label: {
                Text("Save").font(.callout.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 7)
                    .foregroundStyle(WorldLook.bg).background(Capsule().fill(WorldLook.cream))
            }.buttonStyle(.plain)
            Button {
                done(nil)
            } label: {
                Text("Don't send").font(.callout).foregroundStyle(.secondary).padding(.horizontal, 6).padding(.vertical, 7)
            }.buttonStyle(.plain)
        }
    }
}
