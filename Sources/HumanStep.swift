import AppKit
import SwiftUI

// MARK: - A step only the person can do (a code, a passkey, a security key, a robot check)
//
// The engine's browser_vault (One's overlay, tools/overlay/tools/one_human_step.py) gives up on a step
// after 2 automatic tries, or at once when nothing automatic can work, and writes
// `<support>/handoff/<id>.request.json`. One puts one line in the chat and writes `<id>.answer.json`; the engine
// waits for that answer, then checks the page moved on. The page is never closed or reopened: many steps exist
// only in the open tab (a form POST answer, like DocuSign's "enter the code we sent"), and reopening their
// address lands on a log-in page (One 0.9.58 to 0.9.112 did that, Nov 11 2026). So, by the step's kind:
// - a code: no browser at all. The card has a box ("Type the code <site> sent you"); away from the Mac the same
//   ask goes to their phone chat and their reply is the code. The engine types it into the still-open tab.
// - a step done in the page (sign in, approve): that SAME live tab in One's window (StepWindow), or on the phone.
// - a robot check, a passkey or a security key: the plain Chrome window (HumanCheck.swift); those need a real
//   browser window, and their pages come back on a reload.
// A code never passes through the chat.

struct HumanStepAsk: Identifiable, Equatable {
    let id: String
    let site: String
    let kind: String
    let line: String
    let port: Int
    let target: String
    let url: String
    var ask = false  // One's own ask (BlockedAsk): "Yes, show it" / "Not now" first, then Done
    var session = ""  // the helper's conversation that's waiting on it (a message to that helper ends the wait)
    var phone = false  // a retry whose last code came from their phone chat: asked there again, not on the Mac
    var retry = false  // the code before didn't work
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
                    url: j["url"] as? String ?? "", ask: j["ask"] as? Bool ?? false, session: j["session"] as? String ?? "",
                    phone: j["phone"] as? Bool ?? false, retry: (j["try"] as? Int ?? 1) > 1))
        }
        return out
    }

    static let asking = [
        "code": "a code", "security_key": "your security key", "passkey": "your passkey",
        "approve": "a tap to approve on your phone", "check": "a quick check",
    ]

    /// The line in the chat, word for word (the engine sends the same one).
    static func line(site: String, kind: String) -> String {
        if kind == "code" { return "Type the code \(PhoneHandoff.site(site)) sent you, then tap Send. I'll put it into the page." }
        return "I need you for one step: \(site) is asking for \(asking[kind] ?? "a quick check"). Tap Show the window to do it there, then tap Done."
    }

    /// A code step: the card's box (and a phone reply) answer it; no browser is ever shown.
    static func takesCode(_ kind: String) -> Bool { kind == "code" }

    /// What the phone chat says when a code step waits and they're away: their reply is the code, or a way out.
    static func phoneAsk(site: String, title: String, retry: Bool = false) -> String {
        let s = PhoneHandoff.site(site)
        let first =
            retry
            ? "That code didn't work. Reply with the newest code \(s) sent you for \(title)."
            : "\(s.capitalizedFirst) sent you a code for \(title). Reply here with just the code and I'll type it into the page."
        return first + " Or reply \"no code\" if it never came, or \"cancel\"."
    }

    /// Marks that a code step's ask went to the phone chat (the engine's phone plugin takes the reply as the code).
    static func markPhoneAsk(_ id: String, chat: String) {
        let j: [String: Any] = ["id": id, "chat": chat, "at": Date().timeIntervalSince1970]
        guard let d = try? JSONSerialization.data(withJSONObject: j) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? d.write(to: dir.appendingPathComponent("\(id).phone.json"), options: .atomic)
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
        tendFolderLedger()  // a folder added outside the ask-in-chat flow gets flagged (FolderApprovals.swift)
        // Hidden browsers never in the Dock or in front; one macOS made a normal app restarts once nothing uses it.
        HiddenBrowser.tend(idle: !helpers.contains(where: HelperClose.busy) && humanSteps.isEmpty)
        // A code ask they moved to the phone ("I'm not at the Mac") stays off the Mac: its card never comes back.
        let now = HumanStep.pending().filter { !hiddenSteps.contains($0.id) }
        for a in now where !humanSteps.contains(where: { $0.id == a.id }) {
            // A retry whose last code came from the phone is asked there again, not on the Mac.
            if a.phone, HumanStep.takesCode(a.kind), askCodeByPhone(a) {
                hiddenSteps.insert(a.id)
                continue
            }
            humanSteps.append(a)
            let w = StepWindow(a) { [weak self] answer in self?.answerHumanStep(a.id, answer) }
            HumanStep.windows[a.id] = w
            // Never put a window in front on its own: their tap on "Show the window" is the yes (BrowserGuard rule).
            if !Voice.shared.muted { enqueue(.line(bubble: nil, spoken: a.line)) }  // after whatever is being said, never into it
        }
        for a in humanSteps where !now.contains(where: { $0.id == a.id }) { closeHumanStep(a.id) }
    }

    /// Done or I'm not at the Mac, from the chat card or the window itself.
    func answerHumanStep(_ id: String, _ answer: String) {
        // A robot check in a real window: One closes it and answers once the browser is hidden again.
        if HumanCheck.request(id, answer) { return }
        // A code with "I'm not at the Mac": the card always closes, at once and for good. With a phone chat the ask goes
        // there (their reply is the code, "no code" or "cancel"); without one the engine hears "away" and stops waiting.
        // (0.9.113: once the phone had been asked, this button did nothing and the card stayed up, Nov 11 2026.)
        if answer == "away", let a = humanSteps.first(where: { $0.id == id }) ?? HumanStep.pending().first(where: { $0.id == id }),
            HumanStep.takesCode(a.kind)
        {
            hiddenSteps.insert(id)
            closeHumanStep(id)
            if askCodeByPhone(a) { return }
        }
        HumanStep.answer(id, answer)
        closeHumanStep(id)
        blockedAnswered(id, answer)  // a helper One stopped at a robot check carries on with the job as asked
    }

    /// Their yes ("Yes, show it" on the card, in the chat, or "Show the window") is the yes to that window. A robot
    /// check, passkey or security key: the same profile opens as a plain Chrome window on the blocked page (address
    /// bar, nothing attached, so the tick counts). A sign-in or approve: the SAME live tab in One's window, never
    /// closed or reopened (a page reached by a form POST can't be reopened). A code: no window at all (the card's box).
    func showHumanStep(_ a: HumanStepAsk) {
        if HumanStep.takesCode(a.kind) {
            // Never a browser for a code: the page may exist only in the open tab. The card's box takes the code.
            HumanCheck.log("\(a.site): a code step; the card's box takes it, no window")
            return
        }
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
        HumanCheck.log("\(a.site): showing the same live tab (\(a.kind)), never closed or reopened")
        HumanStep.windows[a.id]?.show()
    }

    /// The code from the card's box: to the engine, which types it into the still-open tab and submits.
    func sendHumanCode(_ id: String, _ code: String) {
        let c = code.filter { !$0.isWhitespace && $0 != "-" }
        guard !c.isEmpty else { return }
        HumanStep.answer(id, "code", extra: ["code": c, "by": "person"])
        closeHumanStep(id)
    }

    /// A message to a helper (typed in its orb, a tell, a reply) ends whatever hand-off it's waiting on, with their
    /// words: the helper reads them at once instead of after the wait (0.9.113: "I'm not receiving any code" sat
    /// behind the code wait). A stop ends it as "cancelled". A robot-check window that's open finishes on its own.
    func endHumanSteps(session sid: String?, _ answer: String, text: String? = nil) {
        guard let sid, !sid.isEmpty else { return }
        for a in HumanStep.pending() where a.session == sid && HumanCheck.active?.id != a.id {
            HumanStep.answer(a.id, answer, extra: text.map { ["text": $0, "by": "person"] } ?? [:])
            hiddenSteps.insert(a.id)
            closeHumanStep(a.id)
            HumanCheck.log("\(a.site): the ask ended (\(answer)) for its helper")
        }
    }

    /// Sends a code step's ask to their phone chat once. False when there's no phone chat (then it's a plain "away").
    @discardableResult func askCodeByPhone(_ a: HumanStepAsk) -> Bool {
        if phoneSent.contains(a.id) { return true }
        guard !Env.selfTest, Messenger.configured, let chat = Messenger.envValue("TELEGRAM_HOME_CHANNEL") else { return false }
        phoneSent.insert(a.id)
        HumanStep.markPhoneAsk(a.id, chat: chat)
        let title = helpers.first(where: { $0.state == "working" })?.title ?? "your job"
        let text = HumanStep.phoneAsk(site: a.site, title: title, retry: a.retry)
        Task.detached { Messenger.tell(text) }
        HumanCheck.log("\(a.site): code step; the ask went to the phone chat")
        return true
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
    @State private var code = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(a.line).font(.headline).fixedSize(horizontal: false, vertical: true)
            if HumanStep.takesCode(a.kind) {
                // No browser for a code: it goes from this box straight into the page the helper has open.
                HStack {
                    TextField("Code", text: $code).textFieldStyle(.roundedBorder).font(.title3.monospacedDigit()).frame(maxWidth: 180)
                        .onSubmit { Model.shared.sendHumanCode(a.id, code) }
                    Button("Send") { Model.shared.sendHumanCode(a.id, code) }.buttonStyle(.borderedProminent)
                        .disabled(code.trimmingCharacters(in: .whitespaces).count < 4)
                    Spacer()
                }
                // Always a way out: each ends the ask at once and the helper is told which.
                HStack {
                    Button("I didn't get a code") { answer("no_code") }.buttonStyle(.bordered)
                    Button("Cancel") { answer("cancelled") }.buttonStyle(.bordered)
                    Button("I'm not at the Mac") { answer("away") }.buttonStyle(.bordered)
                    Spacer()
                }
            } else if a.ask && !shown {
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
