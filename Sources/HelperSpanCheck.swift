import Foundation

// MARK: - `One --test-helpers`: a tag runs over any number of paragraphs (Nov 10, 2026; TagLines.swift)
// The Nov 10 reply: a [helper: …] job over several paragraphs, blank lines between them, was read only to the end
// of its first line. The helper got the first paragraph; the rest showed in the chat and was read aloud.

extension HelperCheck {
    /// Shaped like the Nov 10 reply: several paragraphs, a quoted choices tag and a link, then the reply's job kind.
    static let spanReply =
        "Sending one helper to fix all three.\n\n"
        + "[helper: Icon and import | Fix three bugs. Read [the notes](https://example.com/notes) first.\n\n"
        + "(1) WRONG ICON. Check what the app's icon file holds.\n\n"
        + "(2) NO IMPORT PROMPT. Make it show on first launch, and check arr[0] too.\n\n"
        + "(3) LOGINS LOST. Bring the cookies over.\n\n"
        + "Rules: before replacing the open copy, ask \"Install it now?\" with [choices: Yes, install it | Not now].]\n\n"
        + "[job-kind: app bug fixes]"
    static let spanJob =
        "Fix three bugs. Read [the notes](https://example.com/notes) first.\n\n"
        + "(1) WRONG ICON. Check what the app's icon file holds.\n\n"
        + "(2) NO IMPORT PROMPT. Make it show on first launch, and check arr[0] too.\n\n"
        + "(3) LOGINS LOST. Bring the cookies over.\n\n"
        + "Rules: before replacing the open copy, ask \"Install it now?\" with [choices: Yes, install it | Not now]."
    /// Words only the job has: none of them may ever show or be spoken.
    static let spanWords = [
        "[helper", "Fix three", "the notes", "WRONG ICON", "IMPORT PROMPT", "arr[0]", "LOGINS", "Rules:", "Install it", "Not now", "]",
    ]

    /// What the person sees once the turn is over (ModelChat: tags out, then job kind out), and what's spoken.
    @MainActor static func seen(_ reply: String) -> (shown: String, spoken: String) {
        let said = Learning.tags(Helpers.read(reply).said).clean
        return (Choices.split(Helpers.strip(said)).body, Speaker.spoken(said).joined(separator: " "))
    }
    static func free(_ text: String, of words: [String]) -> Bool { !words.contains(where: text.contains) }

    @MainActor
    static func spanTags(_ check: (String, Bool) -> Void) {
        // 1. A helper job over several paragraphs, with a link, code and a choices tag inside.
        let r = Helpers.read(spanReply)
        check("a job over 5 paragraphs starts one helper", r.jobs.count == 1 && r.jobs.first?.0 == "Icon and import")
        check("with every paragraph, link, code and choices tag in it", r.jobs.first?.1 == spanJob)
        let s = seen(spanReply)
        check("the chat shows only the sentence before it (\(s.shown))", s.shown == "Sending one helper to fix all three.")
        check("and no buttons from the job's choices", Choices.split(Helpers.strip(r.said)).choices.isEmpty)
        check("nothing of the job is read aloud (\(s.spoken))", s.spoken == "Sending one helper to fix all three." && free(s.spoken, of: spanWords))
        let streamed = leak(spanReply, spanWords)
        check("while it streams, no piece of the job ever shows" + streamed, streamed.isEmpty)
        check("nor is any piece spoken while it streams", spokenLeak(spanReply, spanWords).isEmpty)
        check("the same through Helpers.extract (helpers and checks use it)", Helpers.extract(spanReply).1.first?.1 == spanJob)

        // 2. A tell over several paragraphs, quoting a choices tag.
        let tell =
            "Sent to Flight to Quebec.\n\n[tell-helper: Flight to Quebec | Skip the tests.\n\nThen find the flight.\n\n"
            + "Ask which one, ending with [choices: Cheapest | Fastest].]\n\nAnything else?"
        let t = Helpers.read(tell)
        check(
            "a tell over 3 paragraphs reaches the helper whole",
            t.tells.count == 1 && t.tells.first?.0 == "Flight to Quebec"
                && t.tells.first?.1 == "Skip the tests.\n\nThen find the flight.\n\nAsk which one, ending with [choices: Cheapest | Fastest].")
        let ts = seen(tell)
        let tellWords = ["Skip", "find the flight", "Cheapest", "Fastest", "[tell", "]"]
        check("none of it shows (\(ts.shown))", ts.shown == "Sent to Flight to Quebec.\n\nAnything else?")
        check("none of it is spoken (\(ts.spoken))", free(ts.spoken, of: tellWords) && ts.spoken.contains("Anything else"))
        check("nor while it streams" + leak(tell, tellWords), leak(tell, tellWords).isEmpty && spokenLeak(tell, tellWords).isEmpty)

        // 3. Brackets inside: a lone "]" in the first paragraph still keeps the rest in the job.
        let lone = "On it.\n\n[helper: Tidy | Step 1] sort the files.\n\nStep 2: move the PDFS.\n\nStep 3: report.]\n\nBack soon."
        let l = Helpers.read(lone)
        check(
            "a lone \"]\" early in a job keeps every paragraph in it",
            l.jobs.first?.1 == "Step 1] sort the files.\n\nStep 2: move the PDFS.\n\nStep 3: report." && seen(lone).shown == "On it.\n\nBack soon.")

        // 4. Two helper tags in one reply, each over several paragraphs, and the reply's own choices.
        let two =
            "Sending two helpers.\n\n[helper: Flights | Find a flight.\n\nUnder $400, [choices: A | B] if unsure.]\n\n"
            + "[helper: Hotels | Find a hotel.\n\nNear the old town.]\n\nThey'll report back.\n[choices: Sounds good | Wait]"
        let w = Helpers.read(two)
        check(
            "two helpers start, each with its whole job",
            w.jobs.map(\.0) == ["Flights", "Hotels"]
                && w.jobs.map(\.1) == ["Find a flight.\n\nUnder $400, [choices: A | B] if unsure.", "Find a hotel.\n\nNear the old town."])
        let ws = seen(two)
        check("only the reply's own words show (\(ws.shown))", ws.shown == "Sending two helpers.\n\nThey'll report back.")
        check("and its own choices become buttons", Choices.split(Helpers.strip(w.said)).choices == ["Sounds good", "Wait"])
        let twoWords = ["Find a", "$400", "old town", "[helper", "A | B"]
        check("none of either job is spoken or shown while it streams", free(ws.spoken, of: twoWords) && leak(two, twoWords).isEmpty)

        // 5. A tag that never closes: everything from it to the end is hidden, its text still goes, and it's logged.
        let log = Env.hermesHome.appendingPathComponent("logs/one-helpers.log")
        try? FileManager.default.removeItem(at: log)
        let open = "Sending a helper.\n\n[helper: Report | Write the report.\n\nThen email it to [the team.\n\nThanks!"
        let o = Helpers.read(open)
        check(
            "one never closed still starts with everything after it",
            o.jobs.first?.0 == "Report" && o.jobs.first?.1 == "Write the report.\n\nThen email it to [the team.\n\nThanks!")
        let os = seen(open)
        check("and nothing from it to the end shows or is spoken (\(os.shown))", os.shown == "Sending a helper." && os.spoken == "Sending a helper.")
        check("it's logged", (try? String(contentsOf: log, encoding: .utf8))?.contains("never closed") == true)
        let openTwo = "Two.\n[helper: A | job a, never closed [x\n\nmore of a\n[helper: B | job b]\nAfter."
        let ot = Helpers.read(openTwo)
        check(
            "a second helper after an unclosed one still starts on its own",
            ot.jobs.map(\.0) == ["A", "B"] && ot.jobs.first?.1 == "job a, never closed [x\n\nmore of a" && ot.said == "Two.")
        let tellOpen = Helpers.read("Sent.\n[tell-helper: X | Skip the tests.\n\nShip it.")
        check(
            "a tell never closed: the message still goes, none of it shows",
            tellOpen.tells.first?.1 == "Skip the tests.\n\nShip it." && tellOpen.said == "Sent.")

        // 6. The voice never reads a tag, even one the parser can't read (no colon, odd case).
        let odd = "Sure.\n[Helper - Fix it | do the secret thing]\nThen more secret text."
        check(
            "a tag written wrong is never read aloud",
            !Speaker.spoken(odd).joined().contains("secret") && Speaker.spoken(odd).joined().contains("Sure"))
        check(
            "nor a tag in the middle of a sentence",
            !Speaker.spoken("Okay. Sending it now [helper: X | the hidden job]").joined().contains("hidden"))
    }

    /// The first thing spoken, at any cut of `reply` while it streams in, that contains one of `words` ("" = none).
    @MainActor static func spokenLeak(_ reply: String, _ words: [String]) -> String {
        for n in stride(from: 1, through: reply.count, by: 2) {
            let said = Speaker.spoken(String(reply.prefix(n))).joined(separator: " ")
            if words.contains(where: said.contains) { return ": " + said }
        }
        return ""
    }
}
