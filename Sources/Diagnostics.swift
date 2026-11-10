import Foundation

/// Command-line checks that run before the app starts (each returns at once unless its flag is given).
enum Diagnostics {
    static func main(_ args: [String]) {
        GlassCheck.main(args)  // `--test-glass`: home's glass lets the desktop through like the design
        VoiceStress.main(args)  // `--test-voice-stress`: the real audio line under load (sanitizer builds)
        SoakCheck.main(args)  // `--test-soak`: the whole app under load for minutes (tools/soak-check.sh)
        JobTreeCheck.main(args)  // `--test-stop-tree` (JobTree.swift)
        BudgetCheck.main(args)  // `--test-budgets` (Budget.swift)
        HealthCheck.main(args)  // `--test-health` (HealthCheck.swift)
        RepoTurnsCheck.main(args)  // `--test-repo-turns` (RepoQueue.swift)
        Pulse.cli(args)  // `--crash-line <pid>`: the one-line crash summary Pulse logs after a crash
        LinkGuard.cli(args)  // `--link-guard [--dry-run]`, `--test-link-guard`, `--test-rooms-privacy`, `--render-share-rooms`
    }
}
