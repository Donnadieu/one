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
        check("a job that ran onto a second line still starts", lost.jobs.count == 1 && lost.jobs[0].1 == "Find a hotel in Quebec for Dec 20 to 24.")
        check("and none of it shows", lost.said == "Ok.\nMore soon.")
        let open = Helpers.read("Ok.\n[helper: Hotels | Find a hotel in Quebec\n[choices: A | B]")
        check("one missing its \"]\" starts with the rest of its line", open.jobs.count == 1 && open.jobs[0].1 == "Find a hotel in Quebec")
        check("and the choices line after it stays", open.said == "Ok.\n[choices: A | B]")
        let bad = Helpers.read("Ok.\n[helper: no bar here]")
        check("one with no title or job starts nothing and still never shows", bad.jobs.isEmpty && bad.said == "Ok.")
        check("nor is it read aloud", !Speaker.spoken("Ok.\n[helper: no bar here]").joined().contains("bar"))
    }
}
