import Foundation

// MARK: - The main loops: what One looks after while it's open

extension Model {
    /// Something is at work: the assistant's reply, a helper or bot, a routine, or a step waiting on the person.
    /// Only then can a code ask, a robot check, a new file or a routine's report turn up any second.
    var tendingBusy: Bool {
        thinking || KeepAwake.routinesRunning > 0 || !humanSteps.isEmpty
            || helpers.contains { $0.state == "working" || $0.state == "needsYes" || $0.resumeQueued == true }
    }

    /// How long the loops sleep: quick while anything works, slow when One is open and idle (Ek, Nov 19 2026: "it
    /// just slows things down when it's open and not doing anything"; `--test-idle` holds the line).
    static let tendBusy = 1.0
    static let tendIdle = 3.0
    static let filesBusy = 3.0
    static let filesIdle = 15.0
    /// Last look for last night's review card (`tendLearning`).
    static var lastNightShelf = Date.distantPast

    /// Started once at launch (App.swift), and by `--test-idle` so the idle cost it measures includes them.
    func startTending() {
        // A step only the person can do (a code, a passkey…) within a second while anything works; a robot check
        // every 4 ticks (BlockedAsk). With nothing at work, every 3 s (a reply starting makes it quick again at once).
        Task { @MainActor in
            for tick in 0... {
                Model.shared.tendHumanSteps()
                Model.shared.tendKeepAwake()  // the Mac stays awake while anything works (KeepAwake.swift)
                if tick % 2 == 0 { Model.shared.tendEveryTwo() }  // goals' lines (ModelGoals.swift), helpers' programs (JobTree.swift)
                if tick % 4 == 0 { Task { await Model.shared.tendBlocked() } }
                try? await Model.nap(busy: Model.tendBusy, idle: Model.tendIdle)
            }
        }
        // New files for Ready for you, folders, learning: every 3 s while anything works, every 15 s when idle.
        // Shared rooms and routines' reports every 15 s either way.
        Task { @MainActor in
            var lastRooms = Date.distantPast
            while true {
                Model.shared.scanShelf()
                Model.shared.tendFolders()
                Model.shared.tendLearning()
                if Date().timeIntervalSince(lastRooms) >= 14.5 {
                    lastRooms = Date()
                    Model.shared.tendShared()
                    Model.shared.tendRoutines()
                }
                try? await Model.nap(busy: Model.filesBusy, idle: Model.filesIdle)
            }
        }
    }

    /// Sleeps `idle` seconds while nothing works, cut short (within a second) when something starts.
    static func nap(busy: Double, idle: Double) async throws {
        var slept = 0.0
        let step = min(busy, 1)
        while slept < (Model.shared.tendingBusy ? busy : idle) {
            try await Task.sleep(for: .seconds(step))
            slept += step
        }
    }
}
