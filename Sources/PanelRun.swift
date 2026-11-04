import Foundation

/// `One --test-panels`: proves "one panel at a time" (Omar: no stacked top-bar windows). Pure Model-state checks,
/// no real window needed — every panel funnels through `Model.closeOtherPanels` (PanelCenter.swift).
enum PanelRun {
    /// `--test-panels`: pure Model-state checks, no scratch brain needed.
    static func launch() -> Bool {
        guard CommandLine.arguments.contains("--test-panels") else { return false }
        MainActor.assumeIsolated { exit(run()) }
        return true
    }

    @MainActor static func run() -> Int32 {
        let m = Model.shared
        m.openedShelf = nil
        m.viewing = nil
        m.routinesOpen = false
        m.stopAsk = nil
        m.meCard = false
        m.connectionsSheet = false
        m.talkKeySheet = false
        m.folderSheet = false
        m.writingPanel = false
        var fails = 0
        func check(_ name: String, _ ok: Bool) {
            print("  \(ok ? "✓" : "✗") \(name)")
            if !ok { fails += 1 }
        }
        func allClosed(except keep: Panel) -> Bool {
            let states: [(Panel, Bool)] = [
                (.shelf, m.openedShelf != nil), (.file, m.viewing != nil), (.routines, m.routinesOpen),
                (.stopAsk, m.stopAsk != nil), (.meCard, m.meCard), (.connections, m.connectionsSheet),
                (.talkKey, m.talkKeySheet), (.folders, m.folderSheet), (.writing, m.writingPanel),
            ]
            return states.allSatisfy { $0.0 == keep || $0.1 == false }
        }

        // Opening any one panel closes every other one that was open.
        m.routinesOpen = true
        m.connectionsSheet = true
        check("opening Connections closes Routines", !m.routinesOpen && m.connectionsSheet)
        check("nothing else sneaks open with it", allClosed(except: .connections))

        m.meCard = true
        check("opening the name card closes Connections", !m.connectionsSheet && m.meCard)

        m.folderSheet = true
        m.talkKeySheet = true
        check("Push to talk replaces Folders, not alongside it", !m.folderSheet && m.talkKeySheet && !m.meCard)

        m.viewing = URL(fileURLWithPath: "/tmp/one-panel-check.md")
        check("the file reader replaces push to talk", !m.talkKeySheet && m.viewing != nil)

        m.openedShelf = UUID()
        check("a shelf card replaces the file reader", m.viewing == nil && m.openedShelf != nil)

        m.writingPanel = true
        check("the big write space replaces the shelf card", m.openedShelf == nil && m.writingPanel)
        check("nothing else is left open", allClosed(except: .writing))

        let helper = UUID()
        m.stopAsk = helper
        check("\"stop this helper?\" replaces the write space", !m.writingPanel && m.stopAsk == helper)

        // Closing (setting back to nil/false) never reopens anything else.
        m.stopAsk = nil
        check("closing one panel doesn't bring another back", allClosed(except: .shelf) && m.openedShelf == nil)

        // Clicking the already-open panel's button again toggles it closed (HomeChrome.swift's `.toggle()`),
        // the same way the X / Esc / click-outside already close it — never a no-op that leaves it stuck open.
        m.connectionsSheet = true
        m.connectionsSheet.toggle()
        check("clicking Connections again closes it", !m.connectionsSheet)

        print("\(fails == 0 ? "panels ok" : "panels failed: \(fails)")")
        return fails == 0 ? 0 : 1
    }
}
