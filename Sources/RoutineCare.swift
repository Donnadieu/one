import Foundation

// MARK: - Routines that fix themselves, and ask once when only the person can (stub: the check comes first)

enum RoutineCare {
    struct Need: Codable, Equatable, Hashable {
        var site: String
        var port: Int
        var cookies: [String]
        var login: String?
        var key: String { "sign_in:\(site)@\(port)" }
    }
    struct Blocker: Codable, Equatable {
        var key = ""
        var source = ""
        var routines: [String] = []
        var missed: [String: [Date]] = [:]
    }
    struct Event: Codable, Equatable {
        var at: Date
        var job: String
        var kind: String
        var cause: String
    }
    struct State: Codable, Equatable {
        var blockers: [Blocker] = []
        var handled: [String: String] = [:]
        var preflighted: [String: String] = [:]
        var open: [Blocker] { blockers }
    }
    struct Effect: Equatable {
        var kind: String
        var job = ""
        var text = ""
    }
    struct Job {
        init?(_ j: [String: Any], out: URL?) { return nil }
    }
    struct Doer {
        var cron: ([String]) -> Void
        var fixer: (String, String) -> Void
        var say: (String) -> Void
        var target: (Blocker) -> String?
    }
    static var note: String { "" }
    static func step(_ s: inout State, jobs: [Job], needs: [String: [Need]], signedIn: [String: Bool], now: Date, quiet: Bool = false) -> [Effect] {
        []
    }
    static func wanted(_ s: State, jobs: [Job], needs: [String: [Need]], now: Date) -> Set<Need> { [] }
    static func perform(_ e: [Effect], state: State, doer: Doer, now: Date) {}
    static func isAsk(_ id: String) -> Bool { false }
    static func title(_ b: Blocker) -> String { "" }
    static func hasAll(_ cookies: [String: String], _ n: Need) -> Bool { false }
    static func inbox(_ args: [String]) {}
    static func events() -> [Event] { [] }
    static func weekLine(_ e: [Event], now: Date) -> String { "" }
    static func weekNote(_ typed: String, now: Date) -> String { "" }
    static func needs() -> [String: [Need]] { [:] }
    static func cli(_ args: [String]) -> Int32? { nil }
}
