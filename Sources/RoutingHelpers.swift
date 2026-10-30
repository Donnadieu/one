import Foundation

// MARK: - Smart routing in the chats (see Routing.swift)

@MainActor
extension Model {
    /// Before a helper's first prompt: route the job, pick its brain, put one plain line in its own steps.
    /// Returns what to add to its first prompt; "" when the router isn't ready or isn't sure (it runs as before).
    func routeHelper(_ id: UUID, sid: String, title: String, task: String) async -> String {
        guard Routing.on, let r = RouteStore.route(task) else { return "" }
        RouteStore.began(id, text: task, kind: title, route: r)
        if let p = provider, let m = Router.model(r, provider: p, current: MeCard.currentModel()) {
            let t0 = Date()
            let ok = await Engine.shared.setModel(sid, m)
            RouteStore.log("helper \"\(title)\": brain \(m) \(ok ? "set" : "not set, kept theirs") in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        }
        if let line = Router.plainLine(r, index: RouteStore.index) { update(id) { HelperTrail.add(line, to: &$0) } }
        return Router.helperNote(r, index: RouteStore.index)
    }

    /// A main-chat turn: one short line about the room and their yes, or nothing. A short reply ("Post it") is read
    /// with the question it answers.
    func routeMain(_ text: String) -> String {
        guard Routing.on else { return "" }
        let typed = text.components(separatedBy: "\n\n(").first ?? text
        let before = typed.count < 60 ? String((bubbles.last { !$0.fromMe && !$0.text.isEmpty }?.text ?? "").suffix(300)) : ""
        guard let r = RouteStore.route(typed + "\n" + before) else { return "" }
        let inNyx = bubbles.suffix(8).contains { $0.text.range(of: #"\bNyx\b"#, options: .regularExpression) != nil }
        let room = Router.room(typed)  // the room comes from their own words only
        var rr = r
        rr.room = room
        return Router.mainNote(rr, inNyx: inNyx)
    }

    /// Every few seconds (with learning): keep the recipe index fresh; a helper stopped mid-job counts as not worked.
    func routeTend() {
        guard Routing.on else { return }
        RouteStore.tend()
        for h in helpers where h.state == "stopped" && RouteStore.state.open[h.id.uuidString] != nil {
            RouteStore.finished(h.id, ok: false)
        }
    }
}

enum Routing {
    /// Off switch (UserDefaults `smartRouting` = false): One then behaves exactly as before.
    static var on: Bool { UserDefaults.standard.object(forKey: "smartRouting") as? Bool ?? true }
}
