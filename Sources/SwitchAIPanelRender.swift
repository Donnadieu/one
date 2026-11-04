import AppKit
import SwiftUI

// MARK: - Render-only (`One --render-switch-ai <png>`, from a test copy): the new Switch AI pop-up over the
// home screen, to check it against the old first-run-screen bug (duplicate title, clipped list, blank wait).

enum SwitchAIPanelRender {
    static func cli(_ args: [String]) {
        guard let k = args.firstIndex(of: "--render-switch-ai"), k + 1 < args.count else { return }
        let mode = k + 2 < args.count ? args[k + 2] : "picker"
        MainActor.assumeIsolated { png(args[k + 1], mode: mode) }
        exit(0)
    }
    @MainActor static func png(_ path: String, mode: String) {
        let scene = HomeRender.scene(3)
        let m = Model.shared
        SwitchAIPanel.renderStill = true
        if mode == "waiting" {
            m.switchingAI = true
            m.switchWaitMessage = "Switching to Grok once your 2 helpers finish. They'll stay on their current AI."
        } else {
            m.switchingAI = true
        }
        let v = AnyView(
            scene.overlay {
                PopupStage(close: {}, panel: { _ in SwitchAIPanel(m: m) {} })
            }
        )
        HomeRender.png(v, path, height: 760)
    }
}
