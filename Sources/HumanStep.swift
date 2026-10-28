import AppKit
import SwiftUI

// MARK: - A step only the person can do (a code, a passkey, a security key, a robot check)
//
// The engine's browser_vault (One's overlay, tools/overlay/tools/one_human_step.py) gives up on a step
// after 2 automatic tries, or at once when nothing automatic can work, and writes
// `<support>/handoff/<id>.request.json`. One then shows that SAME tab of the shared hidden browser in a
// window in front (a live view: the hidden browser keeps running, with its saved sign-ins), puts one line
// in the chat with Done / I'm not at the Mac, and writes `<id>.answer.json`. The engine waits for that
// answer, then checks the page moved on. A code never passes through the chat.

struct HumanStepAsk: Identifiable, Equatable {
    let id: String
    let site: String
    let kind: String
    let line: String
    let port: Int
    let target: String
    let url: String
    var ask = false  // One's own ask (BlockedAsk): "Yes, show it" / "Not now" first, then Done
}

enum HumanStep {
    static var dir: URL { Env.support.appendingPathComponent("handoff") }

    /// Requests the engine is waiting on: no answer yet, less than an hour old.
    static func pending() -> [HumanStepAsk] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        var out: [HumanStepAsk] = []
        for n in names.sorted() where n.hasSuffix(".request.json") {
            guard let d = try? Data(contentsOf: dir.appendingPathComponent(n)),
                let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                let id = j["id"] as? String, let port = j["port"] as? Int, let target = j["target_id"] as? String
            else { continue }
            if fm.fileExists(atPath: dir.appendingPathComponent("\(id).answer.json").path) { continue }
            if Date().timeIntervalSince1970 - ((j["created"] as? Double) ?? 0) > 3600 { continue }
            let site = j["site"] as? String ?? "the site"
            let kind = j["kind"] as? String ?? "check"
            out.append(
                HumanStepAsk(
                    id: id, site: site, kind: kind, line: j["line"] as? String ?? line(site: site, kind: kind), port: port, target: target,
                    url: j["url"] as? String ?? "", ask: j["ask"] as? Bool ?? false))
        }
        return out
    }

    static let asking = [
        "code": "a code", "security_key": "your security key", "passkey": "your passkey",
        "approve": "a tap to approve on your phone", "check": "a quick check",
    ]

    /// The line in the chat, word for word (the engine sends the same one).
    static func line(site: String, kind: String) -> String {
        "I need you for one step: \(site) is asking for \(asking[kind] ?? "a quick check"). Tap Show the window to do it there, then tap Done."
    }

    /// "done" or "away". The engine reads it and carries on.
    static func answer(_ id: String, _ a: String, extra: [String: Any] = [:]) {
        var j: [String: Any] = ["answer": a, "by": "one", "at": Date().timeIntervalSince1970]
        j.merge(extra) { _, new in new }
        guard let d = try? JSONSerialization.data(withJSONObject: j) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent("\(id).answer.tmp")
        try? d.write(to: tmp)
        _ = try? FileManager.default.replaceItemAt(dir.appendingPathComponent("\(id).answer.json"), withItemAt: tmp)
        if !FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(id).answer.json").path) {
            try? FileManager.default.moveItem(at: tmp, to: dir.appendingPathComponent("\(id).answer.json"))
        }
    }

    /// Open windows, one per request.
    @MainActor static var windows: [String: StepWindow] = [:]
}

@MainActor
extension Model {
    /// Runs every second: shows new requests, and clears ones the page or the engine already settled.
    func tendHumanSteps() {
        let now = HumanStep.pending()
        for a in now where !humanSteps.contains(where: { $0.id == a.id }) {
            humanSteps.append(a)
            let w = StepWindow(a) { [weak self] answer in self?.answerHumanStep(a.id, answer) }
            HumanStep.windows[a.id] = w
            // Never put a window in front on its own: their tap on "Show the window" is the yes (BrowserGuard rule).
            if !Voice.shared.muted { Task { _ = await Speaker.shared.sayNow(a.line) } }
        }
        for a in humanSteps where !now.contains(where: { $0.id == a.id }) { closeHumanStep(a.id) }
    }

    /// Done or I'm not at the Mac, from the chat card or the window itself.
    func answerHumanStep(_ id: String, _ answer: String) {
        // A robot check in a real window: One closes it and answers once the browser is hidden again.
        if HumanCheck.request(id, answer) { return }
        HumanStep.answer(id, answer)
        closeHumanStep(id)
        blockedAnswered(id, answer)  // a helper One stopped at a robot check carries on with the job as asked
    }

    /// Their yes ("Yes, show it" on the card, in the chat, or "Show the window") is the yes to that window: the same
    /// profile opens as a plain Chrome window on the blocked page (address bar, nothing attached, so the tick counts).
    /// The live view is only the last resort, when that browser isn't One's own hidden browser.
    func showHumanStep(_ a: HumanStepAsk) {
        if HumanCheck.active != nil {
            HumanCheck.log("\(a.site): a check window is already open; not opening a second one")
            return
        }
        if HumanCheck.wanted(a),
            HumanCheck.begin(
                a,
                finished: { [weak self] answer in
                    self?.closeHumanStep(a.id)
                    self?.blockedAnswered(a.id, answer)
                })
        {
            return
        }
        HumanCheck.log("\(a.site): no hidden browser of One's on port \(a.port); showing the live view instead")
        HumanStep.windows[a.id]?.show()
    }

    func closeHumanStep(_ id: String) {
        humanSteps.removeAll { $0.id == id }
        HumanStep.windows.removeValue(forKey: id)?.close()
    }
}

/// The line in the chat, with its two buttons.
struct HumanStepCard: View {
    let a: HumanStepAsk
    let answer: (String) -> Void
    @State private var shown = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(a.line).font(.headline).fixedSize(horizontal: false, vertical: true)
            if a.ask && !shown {
                // One's own ask: the window shows only after their yes.
                HStack {
                    Button("Yes, show it") {
                        shown = true
                        // The same route as a yes typed or tapped in the chat: a real Chrome window on the page.
                        // (0.9.51–0.9.53 called the live view here directly, so the plain window never opened.)
                        Model.shared.showHumanStep(a)
                    }.buttonStyle(.borderedProminent)
                    Button("Not now") { answer("away") }.buttonStyle(.bordered)
                    Spacer()
                }
            } else {
                buttons
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.orange.opacity(0.12)))
    }
    var buttons: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Done") { answer("done") }.buttonStyle(.borderedProminent)
                Button("I'm not at the Mac") { answer("away") }.buttonStyle(.bordered)
                Spacer()
                Button("Show the window") { Model.shared.showHumanStep(a) }.buttonStyle(.bordered)
            }
        }
    }
}
