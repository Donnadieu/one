import AppKit
import SwiftUI

// MARK: - Render-only (`One --render-startup <prefix>`, from a test copy): the getting-ready layer (ReadyLayer.swift, option
// B "glass card"). `startup-before`: 4 helpers being picked back up, 2 back; `startup-chat`: all back, opening the chat;
// `startup-stuck`: taking longer than usual, with Try again; `startup-ready`: the layer gone, One open.
// Fills Model.shared with made-up helpers: never on the real One.

enum StartupRender {
    static let names = ["startup-before", "startup-chat", "startup-stuck", "startup-ready"]

    @MainActor static func cli(_ args: [String]) {
        guard let k = args.firstIndex(of: "--render-startup"), k + 1 < args.count else { return }
        TestWorld.enter()
        ChatText.still = true
        for name in names {
            set(name)
            let path = "\(args[k + 1])-\(name).png"
            if Model.shared.isReady {
                HomeRender.png(HomeRender.scene(6, keep: true), path, height: 760)
            } else {
                // The window behind, drawn without the layer, then the layer over all of it (as in the real window).
                ReadyLayerLook.hidden = true
                let r = ImageRenderer(content: HomeRender.scene(6, keep: true).frame(width: 1180, height: 760))
                r.scale = 2
                ReadyLayerLook.behind = r.nsImage
                ReadyLayerLook.hidden = false
                let v = AnyView(
                    ZStack {
                        if let b = ReadyLayerLook.behind { Image(nsImage: b).resizable() }
                        ReadyLayer(m: Model.shared)
                    }.foregroundStyle(WorldLook.cream))
                HomeRender.png(v, path, height: 760)
            }
            print("wrote \(args[k + 1])-\(name).png")
        }
        exit(0)
    }

    @MainActor static func set(_ name: String) {
        let m = Model.shared
        func h(_ title: String, _ state: String, _ line: String, seen: Bool? = true) -> Helper {
            var x = Helper(title: title, task: "", state: state, line: line)
            x.seen = seen
            return x
        }
        let back = [
            h("Folders window fix", "working", "Picking up where it left off…"),
            h("Routines view design", "working", "Picking up where it left off…"),
        ]
        let sleeping = [
            h("Long message box", "working", "Picking up where it left off…"), h("Rooms map layout", "working", "Picking up where it left off…"),
        ]
        m.helpers =
            [h("Andela calendar today", "done", "Done", seen: false)] + back + sleeping + [h("Version note build", "done", "Done", seen: false)]
        m.gateRoster = (back + sleeping).map(\.id)
        m.openHelper = nil
        m.bubbles = []
        m.shelf = [
            ShelfItem(
                title: "Andela calendar today", detail: "Today's meetings and the gaps between them.", from: "MD · ready to share",
                path: "/tmp/a.md", fresh: true),
            ShelfItem(
                title: "Version note build", detail: "What changed in this version, in plain words.", from: "MD · ready to share",
                path: "/tmp/v.md", fresh: true),
            ShelfItem(
                title: "Daily activity list", detail: "Everything you did yesterday, in order.", from: "MD · opened", path: "/tmp/d.md", fresh: false),
        ]
        switch name {
        case "startup-before":
            m.gate = .gettingReady
            m.waking = Set(sleeping.map(\.id))
            m.wakingTotal = 4
        case "startup-chat":
            m.gate = .gettingReady
            m.waking = []
            m.wakingTotal = 4
        case "startup-stuck":
            m.gate = .stuck(GateWords.slow)
            m.waking = Set(sleeping.map(\.id))
            m.wakingTotal = 4
        default:
            m.gate = .ready
            m.waking = []
            m.wakingTotal = 0
            m.gateRoster = []
        }
    }
}
