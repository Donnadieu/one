import SwiftUI

// MARK: - Where each part of the Routines panel really lands, in design points (1152 × 676). Each part tags itself
// with `.routineZone(_:)`; the list check (`One --test-routines-list`) lays the real panel out and reads them back to
// prove the routines list never runs over the skills, and nothing leaves the panel, however many routines there are.

struct RoutineZones: PreferenceKey {
    static let space = "routines-stage"
    nonisolated(unsafe) static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { a, b in a.union(b) }
    }
}

extension View {
    func routineZone(_ name: String) -> some View {
        background(
            GeometryReader { g in
                Color.clear.preference(key: RoutineZones.self, value: [name: g.frame(in: .named(RoutineZones.space))])
            })
    }
}
