import Foundation

// MARK: - A bot's things go to the bot (stubs: the checks in BotRouteCheck.swift come first)

enum BotRoute {
    static func owner(_ a: HumanStepAsk, in hs: [Helper], helperFor: [String: UUID]) -> UUID? { nil }
    static func steps(_ all: [HumanStepAsk], open: UUID?, in hs: [Helper], helperFor: [String: UUID]) -> [HumanStepAsk] { all }
    static func askFor(helper: UUID?, steps: [HumanStepAsk], in hs: [Helper], helperFor: [String: UUID]) -> HumanStepAsk? { steps.first }
    static func routineBot(title: String, origin: String?, in hs: [Helper]) -> Helper? { nil }
    static func adopt(_ have: [ShelfItem], bots: [Helper]) -> [ShelfItem] { [] }
    static func shown(_ shelf: [ShelfItem], bots: [Helper]) -> [ShelfItem] { shelf }
    static func chatFiles(_ shelf: [ShelfItem], bot: UUID) -> [ShelfItem] { [] }
    static func showsInChat(_ o: Outgoing) -> Bool { false }
    static func awayCard(_ h: Helper, away: Bool, open: UUID?) -> Bool { away }
}

@MainActor
extension Model {
    var stepsHere: [HumanStepAsk] { humanSteps }
    func stepWaiting(_ h: Helper) -> Bool { false }
    func deliverToBot(_ id: UUID, title: String, body: String) {}
    func takeRoutineNews(_ id: UUID) -> String { "" }
}
