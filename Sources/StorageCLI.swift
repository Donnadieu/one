import Foundation

// MARK: - Brain storage commands, in one place

/// Every command-line mode of the storage plan (Made by Iris, "2026-11-04 Storage design for One.md"), so App.swift's
/// `main()` needs one line for all of them. Each `cli` returns nil when the arguments aren't its own.
enum StorageCLI {
    static func run(_ args: [String]) -> Int32? {
        FirstLaunchCheck.main(args)  // `--test-first-launch` (fresh-install workflow, CI only)
        if let c = FrontPage.cli(args) ?? SkillFiler.cli(args) { return c }  // --front-page, --file-skills
        if let c = History.cli(args) ?? Offsite.cli(args) ?? HistoryRender.cli(args) ?? HistoryCheck.cli(args) { return c }  // copies, restore
        if let c = ImproveCLI.run(args) { return c }  // --improve: the score and the nightly review (Improve*.swift)
        if let c = HiddenBrowser.cli(args) { return c }  // --hidden-browser, --test-hidden-browser (HiddenBrowser.swift)
        if let c = Keeper.cli(args) { return c }  // --keeper: macOS runs it every minute; opens One again if it ended (Keeper.swift)
        if let c = HealthWatch.cli(args) ?? Limit.cli(args) { return c }  // --health, --limit-answer
        return nil
    }
}
