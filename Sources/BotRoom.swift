import Foundation

enum BotRoom {
    struct Line: Equatable {
        let day: String
        let text: String
    }
    static func lines(_ b: BotInfo, now: Date = Date()) -> [Line] { [] }
    static func memoryFile(_ b: BotInfo, now: Date = Date()) -> URL {
        URL(fileURLWithPath: b.roomPath, isDirectory: true).appendingPathComponent("memory/\(Bots.today(now)).md")
    }
    static func record(_ b: BotInfo, _ fact: String, now: Date = Date()) {}
}
