import Foundation

// MARK: - One panel at a time (Omar: "I don't see the use of having multiple overlapping windows").
// Every in-window overlay (MeCard, Connections, Push-to-talk, Folders, Routines, the file/shelf readers, the
// "stop this helper?" ask, and the big writing space) plus the separate Rooms window all funnel through
// `Model.closeOtherPanels`, called from each panel's own `didSet`. That makes "at most one panel visible" true
// by construction: opening any one of them always clears every other one first.
//
// The human-check / sign-in window (HumanCheckCard.swift) is a DIFFERENT, separate NSPanel and is never part of
// this: it must never be blocked or closed by anything here.

/// Every panel this rule covers. `.rooms` is the one real macOS window among them (RoomGraphView.swift).
enum Panel: Equatable {
    case shelf, file, routines, stopAsk, meCard, connections, talkKey, folders, writing, rooms, switchAI
}

extension Model {
    /// Closes every panel except `keep`. Called by each panel's own property observer when it opens, and by
    /// `RoomsWindow.show` before it opens the separate Rooms window.
    func closeOtherPanels(keep: Panel) {
        if keep != .shelf { openedShelf = nil }
        if keep != .file { viewing = nil }
        if keep != .routines { routinesOpen = false }
        if keep != .stopAsk { stopAsk = nil }
        if keep != .meCard { meCard = false }
        if keep != .connections { connectionsSheet = false }
        if keep != .talkKey { talkKeySheet = false }
        if keep != .folders { folderSheet = false }
        if keep != .writing { writingPanel = false }
        if keep != .rooms, RoomsWindow.isOpen { RoomsWindow.panel?.close() }
        if keep != .switchAI { switchingAI = false }
    }
}
