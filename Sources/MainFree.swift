import Foundation

// MARK: - The main chat is always free to talk
//
// Omar (Nov 11 2026): "We should always default to a helper. My main assistant should always be ready to talk."
// That evening the main chat read his note, then wrote two long job files with tool calls before sending anything;
// it was cut off before its helper lines went out, so he waited minutes and nothing was sent. Earlier the same day
// it ran checks itself (hand-off files, process lists, release lists) instead of sending a helper.
// The rule lives in its instructions (SOUL, `Helpers.note`). This is the safety net in One itself
// (docs/decisions.md, 0.9.116):
//   - a visible main-chat turn that works on its own for more than about 20 seconds, or more than 3 steps, without
//     a helper line is handed to a helper by One: the turn is stopped, a helper gets their whole ask plus the steps
//     already taken, and the chat says so in one line;
//   - a message they send while the main chat is working (any step under way, no helper line yet) hands that work
//     to a helper at once, so their message is answered next instead of waiting behind it;
//   - job files a cut-off turn wrote (work/helper-jobs) are never dropped: they go out as helpers, or, after Stop,
//     the chat says so plainly with Send them now / Leave them.

/// What the main chat's current turn has done so far.
struct MainTurn {
    var id = UUID()
    var started = Date()
    var live = false
    var hidden = false
    var idx = 0
    var asked: Composed?
    var steps: [String] = []
    var words = 0
    var lastWords = Date()
    /// The helpers One handed this turn to (titles), once it did.
    var handedTo: [String]?
}

/// A job file the main chat wrote that never went out as a helper.
struct UnsentJob: Equatable {
    let title: String
    let path: String
}

enum MainFree {
    static let secs: TimeInterval = 20
    static let steps = 3
    static let sendNow = "Send them now"
    static let leave = "Leave them"
    enum Moment { case step, tick, message }

    /// Hand the turn to a helper now? Pure, so the check can try every case.
    /// `steps` counts the step just starting (`.step`); `quiet` is how long since its last new words.
    static func handOff(elapsed: TimeInterval, steps n: Int, quiet: TimeInterval, helperLine: Bool, at: Moment) -> Bool {
        if helperLine { return false }  // it's sending one: let it finish
        switch at {
        case .message: return n >= 1  // they wrote while it works: the work goes to a helper, they're answered
        case .step: return n > steps || elapsed >= secs  // a 4th step, or any step after 20 s
        case .tick:
            // A long step, or quiet work after one; or nothing at all to show for a minute (thinking, squeezing).
            return (n >= 1 && elapsed >= secs && quiet >= 5) || (elapsed >= 60 && quiet >= 10)
        }
    }

    /// A short title for a helper from what they asked (2 to 4 words).
    static func title(_ typed: String) -> String {
        let filler: Set<String> = [
            "so", "okay", "ok", "hey", "please", "can", "could", "would", "will", "you", "i", "we", "need", "want", "to", "just", "now",
            "let's", "lets", "the", "a", "an", "and", "um", "well",
        ]
        let words =
            typed.components(separatedBy: .newlines).first?.split(separator: " ").map {
                $0.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
            }.filter { !$0.isEmpty } ?? []
        let rest = Array(words.drop { filler.contains($0.lowercased()) }.prefix(4))
        guard let first = rest.first else { return "Your ask" }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + rest.dropFirst()).joined(separator: " ")
    }

    /// The engine said the turn ended early: cut off, cancelled or failed.
    static func cutOff(stop: String, text: String) -> Bool {
        stop == "cancelled" || stop.hasPrefix("error") || text.hasPrefix("Operation interrupted")
            || text.contains("this turn was interrupted")
    }

    static var jobsDir: URL { Env.support.appendingPathComponent("work/helper-jobs") }

    /// Job files written since `since` that no helper line in `sent` names.
    static func unsent(since: Date, sent: String) -> [UnsentJob] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: jobsDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { f in
            guard f.pathExtension == "md", !sent.contains(f.lastPathComponent),
                let d = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            else { return false }
            return d >= since.addingTimeInterval(-1)
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .map { UnsentJob(title: jobTitle($0), path: $0.path) }
    }

    /// The file's own heading when it's short, else its name in words.
    static func jobTitle(_ f: URL) -> String {
        let head =
            ((try? String(contentsOf: f, encoding: .utf8)) ?? "").components(separatedBy: .newlines)
            .first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) } ?? ""
        if !head.isEmpty, head.split(separator: " ").count <= 6 { return head }
        let w = f.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "-", with: " ")
        return w.prefix(1).uppercased() + w.dropFirst()
    }

    static func names(_ t: [String]) -> String {
        t.count <= 1 ? (t.first ?? "") : t.dropLast().joined(separator: ", ") + " and " + (t.last ?? "")
    }
    static func handedLine(_ titles: [String]) -> String {
        titles.count == 1
            ? "That needs more than a quick look, so I've sent a helper: \(titles[0]). I'm free to talk."
            : "That needs more than a quick look, so I've sent helpers: \(names(titles)). I'm free to talk."
    }
    static func sentLine(_ jobs: [UnsentJob]) -> String {
        let one = jobs.count == 1
        return "I'd written \(one ? "a job" : "\(jobs.count) jobs") but got cut off before sending \(one ? "it" : "them"), "
            + "so I've sent \(one ? "it" : "them") now: \(names(jobs.map(\.title)))."
    }
    static func askLine(_ jobs: [UnsentJob]) -> String {
        let one = jobs.count == 1
        return "You pressed Stop before I sent \(one ? "a job" : "\(jobs.count) jobs") I'd written: \(names(jobs.map(\.title))). "
            + "\(one ? "It hasn't" : "They haven't") started.\n[choices: \(sendNow) | \(leave)]"
    }

    static func log(_ line: String) { Helpers.log("main chat: " + line) }
}

@MainActor
extension Model {
    /// A main-chat turn begins (runTurn): One watches it until it ends.
    func mainFreeBegin(_ c: Composed, hidden: Bool, idx: Int) {
        mainTurn = MainTurn(live: true, hidden: hidden, idx: idx, asked: c)
        guard !hidden else { return }  // One's own notes (a good-morning report, carry on): never handed off
        let id = mainTurn.id
        Task { @MainActor in
            while self.mainTurn.id == id && self.mainTurn.live {
                try? await Task.sleep(for: .milliseconds(500))
                self.mainFreeLook(.tick)
            }
        }
    }

    /// A step of the main chat's turn is starting.
    func mainFreeStep(_ title: String) {
        guard mainTurn.live else { return }
        mainTurn.steps.append(title)
        mainFreeLook(.step)
    }

    /// Hands the running turn to a helper when it's been working here too long, or they just wrote.
    @discardableResult func mainFreeLook(_ at: MainFree.Moment) -> Bool {
        guard mainTurn.live, !mainTurn.hidden, mainTurn.handedTo == nil, !paused, goals["main"]?.active != true else { return false }
        let words = heldText.isEmpty ? (mainTurn.idx < bubbles.count ? bubbles[mainTurn.idx].text : "") : heldText
        if words.count != mainTurn.words {
            mainTurn.words = words.count
            mainTurn.lastWords = Date()
        }
        let elapsed = Date().timeIntervalSince(mainTurn.started)
        guard
            MainFree.handOff(
                elapsed: elapsed, steps: mainTurn.steps.count, quiet: Date().timeIntervalSince(mainTurn.lastWords),
                helperLine: words.contains("[helper:"), at: at)
        else { return false }
        handOffMainTurn(elapsed: elapsed, why: at)
        return true
    }

    /// Stops the turn and starts its helper(s) now: the jobs it wrote down, else their whole ask.
    private func handOffMainTurn(elapsed: TimeInterval, why: MainFree.Moment) {
        guard let c = mainTurn.asked else { return }
        let files = MainFree.unsent(since: mainTurn.started, sent: "")
        Engine.shared.cancel()
        if !files.isEmpty {
            for j in files { spawnHelper(title: j.title, task: "Do the job in \(j.path)") }
            mainTurn.handedTo = files.map(\.title)
        } else {
            let title = MainFree.title(c.typed)
            let steps = mainTurn.steps.map { "- " + $0.prefix(160) }.joined(separator: "\n")
            let task =
                c.engine + pictureNote(c.images)
                + "\n\n(From \(assistantName), the main chat: I started on this myself and handed it to you so I stay free to talk with "
                + "\(userName.isEmpty ? "them" : userName). \(steps.isEmpty ? "I hadn't taken any steps yet." : "Steps I had already taken:\n" + steps)\n"
                + "Check what's already done before redoing anything.)"
            spawnHelper(title: title, task: task)
            mainTurn.handedTo = [title]
        }
        MainFree.log("handed to \(mainTurn.handedTo ?? []) after \(Int(elapsed)) s, \(mainTurn.steps.count) steps (\(why))")
    }

    /// Pictures that came with the ask, saved where a helper can open them (helpers get text only).
    private func pictureNote(_ images: [String]) -> String {
        guard !images.isEmpty else { return "" }
        let dir = SharedFile.folder()
        let paths = images.enumerated().compactMap { k, b64 -> String? in
            let f = dir.appendingPathComponent("picture-\(k + 1).jpg")
            guard let d = Data(base64Encoded: b64), (try? d.write(to: f)) != nil else { return nil }
            return f.path
        }
        return paths.isEmpty ? "" : "\n\n(Pictures they sent with it, open them: \(paths.joined(separator: ", ")))"
    }

    /// The turn is over (runTurn, after its helper lines went out): what the chat says instead, if anything.
    func mainFreeEnd(_ full: String, stop: String, sent: [(String, String)]) -> String {
        let t = mainTurn
        mainTurn.live = false
        if let titles = t.handedTo { return MainFree.handedLine(titles) }
        guard MainFree.cutOff(stop: stop, text: full) else { return full }
        let jobs = MainFree.unsent(since: t.started, sent: sent.map { $0.0 + " " + $0.1 }.joined(separator: "\n"))
        guard !jobs.isEmpty else { return full }
        if paused {  // Stop means stop: nothing starts by itself
            unsentJobs = jobs
            MainFree.log("cut off by Stop with \(jobs.count) unsent jobs: asked")
            return MainFree.askLine(jobs)
        }
        for j in jobs { spawnHelper(title: j.title, task: "Do the job in \(j.path)") }
        MainFree.log("cut off (\(stop)) with \(jobs.count) unsent jobs: sent them")
        return MainFree.sentLine(jobs)
    }

    /// Their tap on Send them now / Leave them. True when it was One's own question.
    func mainFreePick(_ c: String) -> Bool {
        guard !unsentJobs.isEmpty, c == MainFree.sendNow || c == MainFree.leave else { return false }
        let jobs = unsentJobs
        unsentJobs = []
        me(c)
        if c == MainFree.sendNow { for j in jobs { spawnHelper(title: j.title, task: "Do the job in \(j.path)") } }
        let said = c == MainFree.sendNow ? "Sent: \(MainFree.names(jobs.map(\.title)))." : "Left them. Ask me any time and I'll send them."
        bubbles.append(Bubble(fromMe: false, text: said))
        saveBubbles()
        return true
    }
}
