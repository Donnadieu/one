import Foundation

// MARK: - A routine the engine switched off and never turned back on

/// The engine pauses a routine by itself when a run is cut off and it can't tell how that run ended ("Cron execution
/// unverified; reconcile <journal>" / "Canonical cron unknown"). Only that run's admission journal can lift the pause.
/// TODO(red): not built yet.
enum RoutineRevive {
    struct Stuck: Equatable {
        let id: String
        let title: String
        let since: Date?
        let missed: Bool
    }

    static func find(at cron: URL, now: Date = Date()) -> [Stuck] { [] }
    static func steps(_ id: String) -> [String] { [] }
    static func line(_ s: Stuck) -> String { "" }
    static func failedLine(_ s: Stuck) -> String { "" }
}

extension Routines {
    /// What a finished run says in the chat: its title and its answer. TODO(red): not built yet.
    static func report(_ text: String) -> (title: String, body: String)? { nil }
}
