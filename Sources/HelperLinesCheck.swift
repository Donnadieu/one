import Foundation

// MARK: - `One --test-helpers`: a helper line is opaque (HelperLines.swift)

extension HelperCheck {
    /// The Oct 28 reply: three helper lines whose job text quotes a close, a stop and a choices line.
    static let quotedReply =
        "Sending three helpers now.\n"
        + "[helper: No X on orbs | Remove the X from the orbs. Elias confirms with \"Got it\" and writes [close-helper: Movie times] on its own line. Keep [close-helper: …] parsing.]\n"
        + "[helper: Voice and Stop fix | Make Stop also stop helpers when they say [stop-helper: all], and never read tag lines aloud.]\n"
        + "[helper: Choices check | Check that a reply ending in [choices: A | B] shows two buttons.]\n"
        + "They'll report back when done.\n"
        + "[choices: Sounds good | Wait]"
    static let quotedJobs = [
        "Remove the X from the orbs. Elias confirms with \"Got it\" and writes [close-helper: Movie times] on its own line. Keep [close-helper: …] parsing.",
        "Make Stop also stop helpers when they say [stop-helper: all], and never read tag lines aloud.",
        "Check that a reply ending in [choices: A | B] shows two buttons.",
    ]

    @MainActor
    static func quotedTags(_ check: (String, Bool) -> Void) {
        let r = Helpers.read(quotedReply)
        check(
            "3 helper lines quoting close, stop and choices: all 3 start", r.jobs.map(\.0) == ["No X on orbs", "Voice and Stop fix", "Choices check"])
        check("each with its whole job text", r.jobs.map(\.1) == quotedJobs)
        check("nothing is stopped or closed", r.stops.isEmpty && r.closes.isEmpty)
        check(
            "the reply keeps only what was said, and its own choices",
            r.said == "Sending three helpers now.\nThey'll report back when done.\n[choices: Sounds good | Wait]")
        let parts = Choices.split(Helpers.strip(r.said))
        check("its own choices still become buttons", parts.choices == ["Sounds good", "Wait"])
        let spoken = Speaker.spoken(quotedReply).joined(separator: " ")
        check(
            "nothing of the helper lines is read aloud (\(spoken))",
            !spoken.contains("orbs") && !spoken.contains("Movie times") && !spoken.contains("Make Stop") && !spoken.contains("buttons"))
        // While it streams in: every cut of the reply hides the helper lines, never a piece of one.
        var leaked = ""
        for n in stride(from: 1, through: quotedReply.count, by: 3) {
            let shown = Helpers.strip(String(quotedReply.prefix(n)))
            if ["orbs", "Got it", "Make Stop", "buttons", "[helper", "Movie times"].contains(where: shown.contains) {
                leaked = shown
                break
            }
        }
        check("while it streams, no piece of a helper line ever shows\(leaked.isEmpty ? "" : ": " + leaked)", leaked.isEmpty)
        check(
            "nor once it's all in",
            Helpers.strip(quotedReply) == "Sending three helpers now.\nThey'll report back when done.\n[choices: Sounds good | Wait]")

        // Real stop and close lines in the assistant's own words still work, beside a helper line.
        let mixed = Helpers.read(
            "Stopped Price check.\n[stop-helper: Price check]\n[helper: New one | Find a hotel. Ignore [stop-helper: all].]\n[close-helper: Old one]")
        check("a stop or close line of its own still counts", mixed.stops == ["Price check"] && mixed.closes == ["Old one"])
        check("and the helper beside it starts whole", mixed.jobs.count == 1 && mixed.jobs[0].1 == "Find a hotel. Ignore [stop-helper: all].")
        check("a stop line run into a sentence still counts", Helpers.read("Done.[stop-helper: A] Stopped A.").stops == ["A"])

        // A helper line written wrong is never shown, and starts when its title and job can be read.
        let lost = Helpers.read("Ok.\n[helper: Hotels | Find a hotel in Quebec\nfor Dec 20 to 24.]\nMore soon.")
        check(
            "a job that ran onto a second line still starts, lines kept",
            lost.jobs.count == 1 && lost.jobs[0].1 == "Find a hotel in Quebec\nfor Dec 20 to 24.")
        check("and none of it shows", lost.said == "Ok.\nMore soon.")
        let open = Helpers.read("Ok.\n[helper: Hotels | Find a hotel in Quebec\n[choices: A | B]")
        check(
            "one missing its \"]\" starts with everything after it",
            open.jobs.count == 1 && open.jobs[0].1 == "Find a hotel in Quebec\n[choices: A | B]")
        check("and none of that shows (fail safe: hidden to the end)", open.said == "Ok.")
        let bad = Helpers.read("Ok.\n[helper: no bar here]")
        check("one with no title or job starts nothing and still never shows", bad.jobs.isEmpty && bad.said == "Ok.")
        check("nor is it read aloud", !Speaker.spoken("Ok.\n[helper: no bar here]").joined().contains("bar"))

        // [tell-helper: Title | message]: parsed, hidden, never read aloud, and never fires when only quoted
        // inside a helper's own job text (same Oct 28 rule as stop/close).
        let told = Helpers.read("Sent to Switch AI bug.\n[tell-helper: Switch AI bug | Skip the tests, I just need the flight.]")
        check("a tell line is parsed", told.tells.count == 1 && told.tells[0] == ("Switch AI bug", "Skip the tests, I just need the flight."))
        check("and never shown", told.said == "Sent to Switch AI bug.")
        let toldAll = Helpers.read("Told everyone.\n[tell-helper: all | I'm going to bed.]")
        check("\"all\" parses too", toldAll.tells.first?.0 == "all" && toldAll.tells.first?.1 == "I'm going to bed.")
        check(
            "while it streams, no piece of a tell line ever shows",
            !Helpers.strip("Sent to Switch AI b").contains("[tell")
                && !Helpers.strip("Sent to Switch AI bug.\n[tell-helper: Switch").contains("[tell"))
        check(
            "nor once it's all in",
            Helpers.strip("Sent to Switch AI bug.\n[tell-helper: Switch AI bug | Skip the tests.]") == "Sent to Switch AI bug.")
        check(
            "nor is it read aloud",
            !Speaker.spoken("Sent to Switch AI bug.\n[tell-helper: Switch AI bug | Skip the tests, secret recipe inside.]").joined().contains(
                "secret recipe"))
        let quotedTell = Helpers.read(
            "[helper: New one | Find a hotel. Ignore [tell-helper: all | go away].]\n[tell-helper: Old one | For real this time.]")
        check(
            "a tell quoted inside a helper's job never fires, only the real one beside it does",
            quotedTell.tells.count == 1 && quotedTell.tells[0].0 == "Old one"
                && quotedTell.jobs.first?.1 == "Find a hotel. Ignore [tell-helper: all | go away].")
    }

    /// Nov 5: a tell line was read up to its first "]". A message quoting a [choices: …] tag reached the helper cut
    /// short and the rest showed in the chat and was read aloud. Every tag now ends at its own balancing "]".
    static let nestedReply =
        "Sent to Flight to Quebec.\n"
        + "[tell-helper: Flight to Quebec | Ask them which flight they want, ending with [choices: Cheapest | Fastest], then wait for their answer.]"
    static let nestedMessage = "Ask them which flight they want, ending with [choices: Cheapest | Fastest], then wait for their answer."

    @MainActor
    static func nestedTags(_ check: (String, Bool) -> Void) {
        let r = Helpers.read(nestedReply)
        check("a tell quoting a [choices: …] tag reaches the helper whole", r.tells.count == 1 && r.tells.first?.1 == nestedMessage)
        check("none of it shows (\(r.said))", r.said == "Sent to Flight to Quebec." && Helpers.strip(nestedReply) == "Sent to Flight to Quebec.")
        check("its choices never become buttons in the main chat", Choices.split(Helpers.strip(r.said)).choices.isEmpty)
        let spoken = Speaker.spoken(nestedReply).joined(separator: " ")
        check(
            "none of it is read aloud (\(spoken))",
            spoken.contains("Sent to Flight") && !spoken.contains("Cheapest") && !spoken.contains("wait for") && !spoken.contains("]"))
        let streamed = leak(nestedReply, ["[tell", "Ask them", "Cheapest", "wait for", "]"])
        check("while it streams, no piece of it ever shows" + streamed, streamed.isEmpty)

        // Links, code, a choices tag at the very end, and a stray "]" stay inside the message.
        let ends = Helpers.read("Sent.\n[tell-helper: X | Pick one [choices: A | B]]")
        check("a choices tag at the very end of the message stays in it", ends.tells.first?.1 == "Pick one [choices: A | B]" && ends.said == "Sent.")
        let link = Helpers.read("Sent.\n[tell-helper: X | Read [the plan](https://example.com/a) and check arr[0].] Anything else?")
        check(
            "a link and code stay in it, the sentence after it stays out",
            link.tells.first?.1 == "Read [the plan](https://example.com/a) and check arr[0]." && link.said == "Sent.\nAnything else?")
        check("a stray \"]\" later on the line is still the message's", Helpers.read("[tell-helper: X | use a] b]").tells.first?.1 == "use a] b")

        // More than one line: the message keeps its lines up to its closing "]"; one that never closes takes the rest.
        let multi = "Sent.\n[tell-helper: X | First, skip the tests.\nThen ship it, ending with [choices: Ship | Wait].]\nAnything else?"
        let m = Helpers.read(multi)
        check(
            "a message over two lines arrives whole, lines kept",
            m.tells.first?.1 == "First, skip the tests.\nThen ship it, ending with [choices: Ship | Wait]." && m.said == "Sent.\nAnything else?")
        let multiStreamed = leak(multi, ["[tell", "skip", "Ship", "]"])
        check("nor does any of it show while it streams" + multiStreamed, multiStreamed.isEmpty)
        check("nor is it read aloud", !Speaker.spoken(multi).joined().contains("skip") && Choices.split(Helpers.strip(m.said)).choices.isEmpty)
        let open = Helpers.read("Sent.\n[tell-helper: X | Skip the tests\n[choices: Ok | Wait]")
        check(
            "one missing its \"]\" takes everything after it, and none of it shows",
            open.tells.first?.1 == "Skip the tests\n[choices: Ok | Wait]" && open.said == "Sent.")
        check("nor do its words become buttons", Choices.split(Helpers.strip(open.said)).choices.isEmpty)

        // A stop or close quoted inside a tell's message goes to the helper; it never fires.
        let quoted = Helpers.read("Sent.\n[tell-helper: X | If they say [stop-helper: all] or [done-helper: all], stop.]")
        check(
            "a stop or close quoted in a tell never fires",
            quoted.stops.isEmpty && quoted.closes.isEmpty && quoted.tells.first?.1 == "If they say [stop-helper: all] or [done-helper: all], stop.")
        // Stop and close lines end at their own "]" too: brackets in a title stay, a tag beside one stays its own.
        let both = Helpers.read("Stopped it.\n[stop-helper: Fix [beta] build] [done-helper: Fix [beta] build]")
        check(
            "a stop and a close on one line, brackets in the title: both read whole",
            both.stops == ["Fix [beta] build"] && both.closes == ["Fix [beta] build"] && both.said == "Stopped it.")
        check("a half-written stop with brackets never shows", leak("Ok.\n[stop-helper: Fix [beta] build]", ["[stop", "beta", "]"]).isEmpty)

        // [job-kind: …] and [learned: …]: brackets inside, or run into a sentence, never show or speak.
        let k = Learning.tags("Here you go. [job-kind: fix [beta] build]")
        check("a job kind with brackets inside, run into a sentence, is read and hidden", k.kind == "fix [beta] build" && k.clean == "Here you go.")
        check("and never shows while it streams", leak("Here you go.\n[job-kind: fix [beta] build]", ["[job", "beta", "]"]).isEmpty)
    }
    /// The first thing that shows, at any cut of `reply` while it streams in, that contains one of `words` ("" = none).
    static func leak(_ reply: String, _ words: [String]) -> String {
        for n in 1...reply.count {
            let shown = Helpers.strip(String(reply.prefix(n)))
            let body = Choices.split(shown).body
            if words.contains(where: body.contains) { return ": " + body }
        }
        return ""
    }
}
