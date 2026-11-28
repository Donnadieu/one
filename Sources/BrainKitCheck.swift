import Foundation

/// Part of `One --test-guards` (preflight, CI only): One's rooms carry no third-party course material.
/// A stand-in starter still has a kit in templates/cofounder-room (kit.yaml, frameworks/, its own skills), the way
/// the private starter does; a new co-founder room must come out a normal room anyway, built from templates/room.
/// A co-founder room an older One made (with the kit's files) is never touched by a newer One. And the app's own
/// bundled starter, when this build has one, holds none of it.
enum BrainKitCheck {
    static let kitPaths = ["kit.yaml", "frameworks", "skills/five-filters", "skills/what-step", "skills/kit-update", "skills/idea-foundation"]

    static func run(_ check: (String, Bool) -> Void) {
        let fm = FileManager.default
        let st = Env.support.appendingPathComponent("kit-check-starter", isDirectory: true)
        try? fm.removeItem(at: st)
        func put(_ rel: String, _ text: String, in base: URL) {
            let f = base.appendingPathComponent(rel)
            try? fm.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: f, atomically: true, encoding: .utf8)
        }
        put("AGENTS.md", "# Brain\n\n| Room | Folder |\n<!-- add-room adds one row per room above this line -->\n", in: st)
        put("owner.yaml", "name: \"\"   \n", in: st)
        put("templates/room/AGENTS.md", "# {{ROOM_TITLE}}\n\nHolds {{HOLDS}}\n", in: st)
        put("templates/room/policy.yaml", "send: ask\n", in: st)
        put("templates/room/memory/README.md", "# Memory\n", in: st)
        for k in ["kit.yaml", "frameworks/card.md", "skills/five-filters/SKILL.md", "skills/kit-update/SKILL.md"] {
            put("templates/cofounder-room/\(k)", "kit\n", in: st)
        }

        // 1. A new brain asked for a co-founder room: the personal room by default, and a normal co-founder room.
        try? fm.removeItem(at: Brain.root)
        let built = Brain.build(owner: "Sam", ai: "Nova", rooms: [.cofounder], from: st)
        let co = Brain.root.appendingPathComponent(RoomKind.cofounder.folder)
        check(
            "a new brain makes the personal room by default",
            built == nil && fm.fileExists(atPath: Brain.root.appendingPathComponent("personal-room/AGENTS.md").path))
        let agents = (try? String(contentsOf: co.appendingPathComponent("AGENTS.md"), encoding: .utf8)) ?? ""
        check("a new co-founder room is built from templates/room", agents.contains("# co-founder room") && agents.contains("buyers"))
        check(
            "…with no kit file in it (kit.yaml, frameworks/, the kit's skills)",
            kitPaths.allSatisfy { !fm.fileExists(atPath: co.appendingPathComponent($0).path) })
        let hub = (try? String(contentsOf: co.appendingPathComponent(RoomKind.cofounder.hub), encoding: .utf8)) ?? ""
        check("…and its own hub file, brain/company.md", hub.hasPrefix("# The business, as it stands"))
        check("…and a room.yaml (not private)", RoomYaml.read(co)?.isPrivate == false)

        // 2. A co-founder room an older One made from the kit: a newer One adds rooms beside it, never changes it.
        try? fm.removeItem(at: Brain.root)
        put("AGENTS.md", "# My brain\n<!-- add-room adds one row per room above this line -->\n", in: Brain.root)
        let old = ["kit.yaml": "version: old\n", "frameworks/card.md": "# Card\n", "skills/what-step/SKILL.md": "# Step\n", "AGENTS.md": "# Mine\n"]
        for (k, v) in old { put("\(RoomKind.cofounder.folder)/\(k)", v, in: Brain.root) }
        func snapshot() -> [String: Data] {
            var out: [String: Data] = [:]
            guard let en = fm.enumerator(at: co, includingPropertiesForKeys: nil) else { return out }
            for case let f as URL in en {
                if let d = try? Data(contentsOf: f) { out[f.path] = d }
            }
            return out
        }
        let before = snapshot()
        let again = Brain.build(owner: "Sam", ai: "Nova", rooms: [.cofounder, .work], from: st)
        check(
            "a newer One adds a room next to an older co-founder room",
            again == nil && fm.fileExists(atPath: Brain.root.appendingPathComponent("work-room/AGENTS.md").path))
        check("…and leaves that co-founder room exactly as it was (\(before.count) files)", before.count == old.count && snapshot() == before)

        // 3. The app's own starter (a release build has one; a pull request build usually doesn't).
        if let real = Brain.starter {
            var leftovers: [String] = []
            if let en = fm.enumerator(at: real, includingPropertiesForKeys: nil) {
                for case let f as URL in en {
                    let rel = String(f.path.dropFirst(real.path.count + 1))
                    let name = f.lastPathComponent
                    let text = (try? String(contentsOf: f, encoding: .utf8))?.lowercased() ?? ""
                    if rel.hasPrefix("templates/cofounder-room") || name == "kit.yaml" || name == "frameworks" || text.contains("next badge")
                        || text.contains("vibe founding")
                    {
                        leftovers.append(rel)
                    }
                }
            }
            check("the app's bundled brain starter has no kit material\(leftovers.isEmpty ? "" : ": \(leftovers.prefix(3))")", leftovers.isEmpty)
        } else {
            print("  · this build bundles no brain starter (a pull request build); build.sh checks a release's")
        }
        try? fm.removeItem(at: Brain.root)
        try? fm.removeItem(at: st)
    }
}
