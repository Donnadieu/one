import Foundation

// MARK: - Plain words for each routine (stub: names and lines come straight from the engine for now).

struct RoutineLabel: Codable, Equatable {
    var name: String
    var line: String
}

extension Routine {
    var name: String { title }
    var line: String { what }
    var room: String? { nil }
}

enum RoutineLabels {
    static var file: URL { Env.support.appendingPathComponent("routines/labels.json") }
    static func load() -> [String: RoutineLabel] {
        guard let d = try? Data(contentsOf: file) else { return [:] }
        return (try? JSONDecoder().decode([String: RoutineLabel].self, from: d)) ?? [:]
    }
    static func dress(_ rs: [Routine], labels: [String: RoutineLabel], rooms: [RoomFacts], bots: [Helper]) -> [Routine] { rs }
}
