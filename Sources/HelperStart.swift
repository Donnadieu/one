import Foundation

// MARK: - What One adds to a new helper's first prompt (besides its job and the router's recipes)

@MainActor
extension Model {
    /// Look only (LookOnly.swift), its own copy of a repo another helper is working in (HelperRepos.swift), and
    /// today's related results from earlier helpers (HelperFindings.swift). Each adds one plain line to its steps.
    func helperStartNotes(_ id: UUID, title: String, task: String) async -> String {
        var out = ""
        if LookOnly.marked(task) {
            update(id) {
                $0.lookOnly = true
                HelperTrail.add(LookOnly.trailLine, to: &$0)
            }
            syncLookOnly(id)
            out += LookOnly.helperNote(userName)
        }
        out += await ownCopies(id, title: title, task: task)
        let earlier = EarlierResults.pick(job: task, title: title, from: shelf)
        if !earlier.isEmpty {
            update(id) {
                HelperTrail.add("Reading what earlier helpers found: \(Helpers.list(earlier.map { "\u{201C}\($0.title)\u{201D}" }))", to: &$0)
            }
            out += EarlierResults.note(earlier)
        }
        return out
    }

    /// The repos this job names that another helper is working in right now get a copy of their own for this one.
    private func ownCopies(_ id: UUID, title: String, task: String) async -> String {
        let repos = await Task.detached { HelperRepos.repos(in: task) }.value
        guard !repos.isEmpty else { return "" }
        var mine: [String] = []
        var copies: [(copy: HelperRepos.Copy, other: String)] = []
        for r in repos {
            guard
                let other = helpers.first(where: { $0.id != id && HelperRepos.busy($0) && ($0.repos ?? HelperRepos.repos(in: $0.task)).contains(r) })
            else {
                mine.append(r)
                continue
            }
            if let c = await Task.detached(operation: { HelperRepos.make(repo: r, title: title, helper: id) }).value {
                copies.append((c, other.title))
                update(id) { HelperTrail.add("Working in its own copy of \((r as NSString).lastPathComponent) (another helper is in it)", to: &$0) }
            } else {
                mine.append(r)  // git said no: it works as before
            }
        }
        update(id) { $0.repos = mine }
        return HelperRepos.note(copies)
    }

    /// Its orb left the screen: its copies go (unsaved work is kept).
    func releaseCopies(_ id: UUID) {
        let hid = id.uuidString
        Task.detached { HelperRepos.release(helper: hid) }
    }

    /// Once at launch: copies left by helpers that are no longer on the screen.
    func sweepCopies() {
        let alive = Set(helpers.map { $0.id.uuidString })
        Task.detached { HelperRepos.sweep(alive: alive) }
    }
}

extension HelperRepos {
    /// A helper that is (or will be again) working in its repos: working, waiting for their yes, or paused to pick back up.
    static func busy(_ h: Helper) -> Bool {
        h.state == "working" || h.state == "needsYes" || (h.state == "stopped" && h.resumeQueued == true)
    }
}
