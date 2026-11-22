import Foundation

// RED STUB (test first): the old behaviour, so RecipeTidyCheck fails before the real code lands.
struct RecipeTidyResult: Codable, Equatable {
    var skill: String
    var path: String
    var before: Int
    var after: Int
    var moved: [String] = []
    var backup: String?
    var lessons = 0
    var error: String?
    var split: Bool { !moved.isEmpty && error == nil }
}

enum RecipeTidy {
    static let limit = ImproveSeen.recipeLimit
    nonisolated(unsafe) static var afterWrite: ((URL) -> Void)?
    static func tend(roots: [String], date: String) -> [RecipeTidyResult] { [] }
    static func morningLine(date: String) -> String? { nil }
}

enum RecipeLessons {
    @discardableResult static func add(dir: URL, key: String, rule: String, first: String, last: String?, times: Int) -> String {
        let f = dir.appendingPathComponent("SKILL.md")
        let t = (try? String(contentsOf: f, encoding: .utf8)) ?? ""
        try? (t + "- [L-\(key)] \(rule) (seen \(first))\n").write(to: f, atomically: true, encoding: .utf8)
        return "added"
    }
}
