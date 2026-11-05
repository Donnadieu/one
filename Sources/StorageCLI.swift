import Foundation

// MARK: - Brain storage commands, in one place

/// Every command-line mode of the storage plan (Made by Iris, "2026-11-04 Storage design for One.md"), so App.swift's
/// `main()` needs one line for all of them. Each `cli` returns nil when the arguments aren't its own.
enum StorageCLI {
    static func run(_ args: [String]) -> Int32? {
        if let c = FrontPage.cli(args) ?? SkillFiler.cli(args) { return c }  // --front-page, --file-skills
        if let c = History.cli(args) ?? Offsite.cli(args) ?? HistoryRender.cli(args) ?? HistoryCheck.cli(args) { return c }  // copies, restore
        return nil
    }
}
