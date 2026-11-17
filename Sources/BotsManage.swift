import Foundation

// MARK: - Managing a bot once it's made (Claude Design "One bots design", "Bots manage B - Glass sheet", picked by
// Omar Nov 17 2026). STUBS: the checks in BotsManageCheck.swift are written first and must fail against these.

struct BotEdit: Equatable {
    var name: String?
    var color: String?
    var job: String?
    var uses: [String]?
    var add: [String] = []
    var drop: [String] = []
    var checkIn: String?
    static func uses(_ now: [String], _ e: BotEdit) -> [String] { now }
}

struct BotAbout {
    let name: String
    let color: String
    let room: String
    let job: String
    let uses: [String]
    let checksIn: String
    let routines: [Routine]
    let memory: String
    let remembered: Int
    let made: Date
    static func make(_ h: Helper, routines: [Routine]) -> BotAbout? { nil }
}

enum BotTags {
    static let tags = ["edit-bot", "archive-bot", "restore-bot", "delete-bot"]
    typealias Read = (said: String, edits: [(String, BotEdit)], archives: [String], restores: [String], deletes: [String])
    static func edit(_ body: String) -> (String, BotEdit)? { nil }
    static func read(_ text: String) -> Read { (text, [], [], [], []) }
}

enum BotGate {
    @MainActor static var asked: [String: Date] = [:]
    @MainActor static func decide(_ deletes: [String], said: String, typed: String, now: Date = Date()) -> (act: [String], ask: String) {
        (deletes, "")
    }
}

enum BotStore {
    struct Edited {
        var steps: [[String]] = []
        var miss: String?
        var tell: String?
    }
    static func owned(_ h: Helper, in routines: [Routine]) -> [Routine] { [] }
    static func edit(_ hs: inout [Helper], at i: Int, _ e: BotEdit, routines: [Routine]) -> Edited { Edited() }
    static func archive(_ hs: inout [Helper], at i: Int, routines: [Routine]) -> [[String]] { [] }
    static func restore(_ hs: inout [Helper], at i: Int) -> [[String]] { [] }
    static func delete(_ hs: inout [Helper], at i: Int, routines: [Routine]) -> [[String]] { [] }
}

extension Bots {
    static func active(_ hs: [Helper]) -> [Helper] { hs.filter { $0.bot != nil } }
    static func archived(_ hs: [Helper]) -> [Helper] { [] }
}
