import Foundation

// The storage plan's command lines and background loops, in one place so App.swift stays small.
// Each `cli` returns an exit code when the arguments are its own, else nil.

enum StorageCLI {
    /// `--front-page`, `--file-skills`, `--snapshot`, `--restore`, the locked copy, the history render and check.
    static func run(_ args: [String]) -> Int32? {
        FrontPage.cli(args) ?? SkillFiler.cli(args)
            ?? History.cli(args) ?? Offsite.cli(args) ?? HistoryRender.cli(args) ?? HistoryCheck.cli(args)
    }

    /// Started once at launch: the brain's search index (BrainIndex.swift) and the hourly instant copies
    /// plus the nightly locked copy (History.swift, Offsite.swift).
    @MainActor static func start() {
        BrainIndex.start()
        History.loop()
    }
}
