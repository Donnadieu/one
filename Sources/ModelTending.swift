import Foundation

// MARK: - The main loops: what One looks after while it's open

extension Model {
    /// Started once at launch (App.swift), and by `--test-idle` so the idle cost it measures includes them.
    func startTending() {
        // A step only the person can do (a code, a passkey…) within a second; a robot check, every 4 s (BlockedAsk).
        Task { @MainActor in
            for tick in 0... {
                Model.shared.tendHumanSteps()
                Model.shared.tendKeepAwake()  // the Mac stays awake while anything works (KeepAwake.swift)
                if tick % 2 == 0 { Model.shared.tendEveryTwo() }  // goals' lines (ModelGoals.swift), helpers' programs (JobTree.swift)
                if tick % 4 == 0 { Task { await Model.shared.tendBlocked() } }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        Task { @MainActor in
            var tick = 0
            while true {
                Model.shared.scanShelf()
                Model.shared.tendFolders()
                Model.shared.tendLearning()
                if tick % 5 == 0 {
                    Model.shared.tendShared()
                    Model.shared.tendRoutines()
                }
                tick += 1
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}
