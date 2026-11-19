import AppKit
import SwiftUI

// MARK: - Star path chat views (Claude Design "Chosen Star path with summary"). Not drawn yet: the check comes first.

/// A chat's messages as a star path: earlier days folded into one star each, the newest day open.
struct StarChat: View {
    let speaker: StarSpeaker
    let lines: [StarLine]
    @ObservedObject var state: StarState
    var body: some View { EmptyView() }
}

/// The card on top: what it did and what's waiting on you, one line until tapped.
struct StarSummaryCard: View {
    let summary: StarSummary
    let speaker: StarSpeaker
    @ObservedObject var state: StarState
    var body: some View { EmptyView() }
}
