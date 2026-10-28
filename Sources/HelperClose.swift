import SwiftUI

// MARK: - A helper's orb stays until they close it (Omar, Oct 28: "a helper orb must NEVER go away on its own").
// Not when it finishes, not when it's opened or read, not when a new helper starts, not after a restart, an update or
// a crash, and no cap on how many. The only ways off the screen: the X on its orb (or Close on its card), or asking
// the assistant to close it ([close-helper: …]). Proven by `make helpers-check` (HelperStress.swift).

enum HelperClose {
    /// Told to the assistant on every prompt and in SOUL (with the stop rule).
    static let rule =
        "To close a helper's orb (take it off the screen), when they say \"close the <name> helper\", \"close that one\" or \"close all\", add a line exactly like [close-helper: <its exact title>] or [close-helper: all] and confirm in one short line, like \"Closed Flight to Quebec.\" \"all\" closes every helper that isn't still working. An orb never goes away on its own: it stays until they close it."

    /// Which helpers a close line means: the exact title (any case, the most recently sent on ties), or "all" =
    /// every one that isn't still at work (a working one is closed only by its own name, which stops it first).
    static func match(_ name: String, in hs: [Helper]) -> [UUID] {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'“”‘’"))).lowercased()
        if n == "all" { return hs.filter { $0.state != "working" && $0.resumeQueued != true }.map(\.id) }
        let same = hs.enumerated().filter { $0.element.title.lowercased() == n }
        let pick = same.max { a, b in (a.element.started ?? .distantPast, a.offset) < (b.element.started ?? .distantPast, b.offset) }
        return pick.map { [$0.element.id] } ?? []
    }
    static func notFound(_ name: String) -> String { "I couldn't find a helper called \"\(name)\"." }

    /// The saved helpers, read back. One unreadable entry never costs the rest: each is read on its own, and
    /// anything that can't be read is set aside under `helpersUnreadable` instead of being written over.
    static func decode(_ d: Data) -> [Helper] {
        if let hs = try? JSONDecoder().decode([Helper].self, from: d) { return hs }
        guard let raw = (try? JSONSerialization.jsonObject(with: d)) as? [Any] else {
            UserDefaults.standard.set(d, forKey: "helpersUnreadable")
            Helpers.log("saved helpers couldn't be read; kept aside under helpersUnreadable")
            return []
        }
        var out: [Helper] = []
        var bad: [Any] = []
        for item in raw {
            if let one = try? JSONSerialization.data(withJSONObject: item), let h = try? JSONDecoder().decode(Helper.self, from: one) {
                out.append(h)
            } else {
                bad.append(item)
            }
        }
        if !bad.isEmpty, let keep = try? JSONSerialization.data(withJSONObject: bad) {
            UserDefaults.standard.set(keep, forKey: "helpersUnreadable")
            Helpers.log("\(bad.count) saved helper(s) couldn't be read; kept aside under helpersUnreadable")
        }
        return out
    }
}

extension Model {
    /// They closed this helper (its X, its card's Close, or by asking). The one and only way an orb leaves the screen.
    /// A helper still at work is stopped first, so nothing keeps running unseen.
    func closeHelper(_ id: UUID) {
        guard let h = helpers.first(where: { $0.id == id }) else { return }
        if h.state == "working" || h.resumeQueued == true { stopHelper(id) }
        if openHelper == id { openHelper = nil }
        doneQueue.removeAll { $0 == id }
        Helpers.log("helper \"\(h.title)\" closed by you (\(h.state))")
        withAnimation(.easeIn(duration: 0.6)) { helpers.removeAll { $0.id == id } }
    }

    /// The assistant wrote "[close-helper: …]": close the match. Returns a plain line if nothing matched.
    func closeHelpers(named name: String) -> String? {
        let ids = HelperClose.match(name, in: helpers)
        if ids.isEmpty { return name.lowercased().trimmingCharacters(in: .whitespaces) == "all" ? nil : HelperClose.notFound(name) }
        ids.forEach { closeHelper($0) }
        return nil
    }

    /// "Start again" on a stopped helper: the same orb goes back to work on its original job, from the start.
    /// (It used to be taken off the screen and a new one sent in its place.)
    func startAgain(_ id: UUID) {
        guard let h = helpers.first(where: { $0.id == id }), h.state == "stopped", h.resumeQueued != true else { return }
        update(id) {
            $0.state = "working"
            $0.line = "Getting started…"
            $0.stoppedByYou = nil
            $0.sid = nil
            $0.started = Date()
            HelperTrail.add("Started again by you", to: &$0)
        }
        saveTrail(id)
        Task { @MainActor in
            guard let sid = await Engine.shared.openSession() else {
                self.update(id) { HelperTrail.notFinished(&$0, .cutOff) }
                self.saveTrail(id)
                self.resumeWhenReady(after: 1)
                return
            }
            self.update(id) { $0.sid = sid }
            await self.runHelper(id, Helpers.brief(assistant: self.assistantName, user: self.userName, task: h.task), images: [])
        }
    }
}

/// The small X on a helper's orb while the pointer is over it: closes it. A working one asks first, on the shared
/// pop-up glass (`Model.closeAsk` → `HelperCloseAsk` in `HomePopups`).
struct HelperCloseDot: View {
    let title: String
    let working: Bool
    let ask: () -> Void
    let close: () -> Void
    @State var hover = false
    var body: some View {
        Button {
            if working { ask() } else { close() }
        } label: {
            Image(systemName: "xmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(WorldLook.bg)
                .frame(width: 17, height: 17)
                .background(Circle().fill(WorldLook.cream.opacity(hover ? 1 : 0.85)))
                .overlay(Circle().strokeBorder(WorldLook.bg, lineWidth: 2).padding(-2))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Close \(title)")
        .accessibilityLabel("Close \(title)")
    }
}

/// "Close <title>?" for a helper that's still working: closing it stops it. Same glass as every pop-up.
struct HelperCloseAsk: View {
    let title: String
    let done: (Bool) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text("Close \(title)?").font(.system(size: 15, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 120)  // the X and "Esc to close"
            }.frame(minHeight: 28)
            Text("It's still working. Closing it stops it.").font(.system(size: 13)).foregroundStyle(WorldLook.cream.opacity(0.7))
            HStack(spacing: 8) {
                Spacer()
                Button("Keep it") { done(false) }.buttonStyle(.bordered)
                Button {
                    done(true)
                } label: {
                    Text("Stop and close").font(.system(size: 13, weight: .semibold)).foregroundStyle(WorldLook.bg)
                        .padding(.horizontal, 16).frame(height: 30).background(Capsule().fill(WorldLook.cream))
                }
                .buttonStyle(.plain).keyboardShortcut(.defaultAction)
            }.padding(.top, 6)
        }
        .foregroundStyle(WorldLook.cream)
        .padding(20).frame(width: 380, alignment: .leading)
    }
}
