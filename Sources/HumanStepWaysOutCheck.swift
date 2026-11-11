import Foundation

/// `One --test-human-step`, part 5: a code ask always has a way out (Nov 11 2026, DocuSign's SMS step on 0.9.113:
/// the ask came back after every answer, "I'm not at the Mac" did nothing once the phone had been asked, Omar's
/// message to the helper sat behind the wait, and stopping the helper left the card up).
extension HumanStepCheck {
    @MainActor
    static func codeWaysOut(_ m: Model) async -> Int {
        var fails = 0
        func check(_ name: String, _ ok: Bool) {
            print("  \(ok ? "✓" : "✗") \(name)")
            fflush(stdout)
            if !ok { fails += 1 }
        }
        func codeAsk(_ id: String, session: String = "") {
            var j: [String: Any] = [
                "id": id, "created": Date().timeIntervalSince1970, "site": "account-d.docusign.com", "kind": "code", "port": 1,
                "target_id": "t-\(id)", "url": "https://account-d.docusign.com/x", "box": true,
            ]
            if !session.isEmpty { j["session"] = session }
            try? JSONSerialization.data(withJSONObject: j).write(to: HumanStep.dir.appendingPathComponent("\(id).request.json"))
            m.tendHumanSteps()
        }
        func answer(_ id: String) -> [String: Any]? {
            (try? Data(contentsOf: HumanStep.dir.appendingPathComponent("\(id).answer.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
        func shown(_ id: String) -> Bool { m.humanSteps.contains { $0.id == id } }
        let stamp = Int(Date().timeIntervalSince1970)

        print("5. a code ask: every button ends it, and the card always goes")
        for (tap, want) in [("no_code", "no_code"), ("cancelled", "cancelled")] {
            let id = "\(tap)\(stamp)"
            codeAsk(id)
            m.answerHumanStep(id, tap)
            m.tendHumanSteps()
            check(
                "\(tap == "no_code" ? "I didn't get a code" : "Cancel") ends the ask (\(want)) and the card goes",
                answer(id)?["answer"] as? String == want && !shown(id))
        }
        // The ask already went to the phone chat (it does by itself after a minute): on 0.9.113 the button then did nothing.
        let away = "awayphone\(stamp)"
        codeAsk(away)
        m.phoneSent.insert(away)
        m.answerHumanStep(away, "away")
        m.tendHumanSteps()
        check("I'm not at the Mac closes the card even after the phone was asked", !shown(away))
        m.answerHumanStep(away, "away")
        m.tendHumanSteps()
        check("...and it stays closed (a second tap, the next second)", !shown(away))

        print("6. a message to a helper waiting on a code ends the wait with their words")
        let h = Helper(title: "Intake e-sign test", task: "x", sid: "local-loop-msg-\(stamp)", state: "working", line: "Working on it…")
        m.helpers.append(h)
        let msg = "msg\(stamp)"
        codeAsk(msg, session: h.sid ?? "")
        m.tellHelper(h.id, message: "I'm not receiving any code")
        try? await Task.sleep(for: .milliseconds(300))
        m.tendHumanSteps()
        let a = answer(msg)
        check(
            "the wait ends with answer message, carrying the text",
            a?["answer"] as? String == "message" && (a?["text"] as? String ?? "").contains("I'm not receiving any code"))
        check("the card goes", !shown(msg))

        print("7. stopping a helper ends its open code ask and the card goes")
        let s = Helper(title: "Intake e-sign stop", task: "x", sid: "local-loop-stop-\(stamp)", state: "working", line: "Working on it…")
        m.helpers.append(s)
        let st = "stop\(stamp)"
        codeAsk(st, session: s.sid ?? "")
        check("the card is up", shown(st))
        m.stopHelper(s.id)
        try? await Task.sleep(for: .milliseconds(300))
        m.tendHumanSteps()
        check("the stop ends the ask (cancelled) and the card goes", answer(st)?["answer"] as? String == "cancelled" && !shown(st))
        m.helpers.removeAll { $0.id == h.id || $0.id == s.id }
        return fails
    }
}
