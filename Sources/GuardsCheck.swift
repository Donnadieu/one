import Foundation

/// `One --test-guards`: proves the code-level guards work. Run with ONE_SUPPORT_DIR and ONE_CLOUD_DIR
/// pointing at empty scratch folders (tools/preflight.sh does). Never touches the real brain.
enum GuardsCheck {
    static func run() -> Int32 {
        let fm = FileManager.default
        let d = UserDefaults.standard
        let saved = (d.object(forKey: "sharedRooms"), d.object(forKey: "userName"), d.object(forKey: "experimentalOffTest"))
        defer {
            for (k, v) in [("sharedRooms", saved.0), ("userName", saved.1), ("experimentalOffTest", saved.2)] {
                if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) }
            }
        }
        var fails = 0
        func check(_ name: String, _ ok: Bool) {
            print("  \(ok ? "✓" : "✗") \(name)")
            if !ok { fails += 1 }
        }
        d.set("Omar", forKey: "userName")

        // Shared rooms: a private room with a secret, a shared room that receives a copy of it.
        let priv = Brain.root.appendingPathComponent("personal-room", isDirectory: true)
        try? fm.createDirectory(at: priv, withIntermediateDirectories: true)
        let secret = "My bank PIN reminder lives in the blue notebook in the kitchen drawer, never share it."
        try? "# Private\n\n\(secret)\n".write(to: priv.appendingPathComponent("private.md"), atomically: true, encoding: .utf8)
        let shared = Shared.cloud.appendingPathComponent("One Rooms/Biz", isDirectory: true)
        let entries = shared.appendingPathComponent("entries", isDirectory: true)
        try? fm.createDirectory(at: entries, withIntermediateDirectories: true)
        try? "# Old\n\nBy Omar\n\n\(secret)\n".write(to: entries.appendingPathComponent("old.md"), atomically: true, encoding: .utf8)
        Shared.paths = [shared.path]
        check(
            "first look leaves what's already shared alone",
            SharedGuard.tend().isEmpty && fm.fileExists(atPath: entries.appendingPathComponent("old.md").path))

        let leak = entries.appendingPathComponent("2026-10-24 1200 Omar - plan.md")
        try? "# Plan\n\nBy Omar\n\nWe should launch in May.\n\(secret)\n".write(to: leak, atomically: true, encoding: .utf8)
        let ok = entries.appendingPathComponent("2026-10-24 1201 Omar - launch.md")
        try? "# Launch\n\nBy Omar\n\nWe should launch in May and keep the price at forty dollars a month.\n".write(
            to: ok, atomically: true, encoding: .utf8)
        let theirs = entries.appendingPathComponent("2026-10-24 1202 Sam - copy.md")
        try? "# Sam\n\nBy Sam\n\n\(secret)\n".write(to: theirs, atomically: true, encoding: .utf8)
        let notes = SharedGuard.tend()
        let held = SharedGuard.heldDir.appendingPathComponent("Biz").appendingPathComponent(leak.lastPathComponent)
        check("a new file copying a private note is held back", !fm.fileExists(atPath: leak.path) && fm.fileExists(atPath: held.path))
        check("the person is told in plain words", notes.count == 1 && notes[0].contains("held back"))
        check("a new file with nothing private stays shared", fm.fileExists(atPath: ok.path))
        check("someone else's file is left alone", fm.fileExists(atPath: theirs.path))
        check("the assistant is told what's held", SharedGuard.note.contains(leak.lastPathComponent))
        try? fm.moveItem(at: held, to: leak)
        check("putting it back on purpose (share it anyway) sticks", SharedGuard.tend().isEmpty && fm.fileExists(atPath: leak.path))

        // A skill in the shared room that a private job edits is held back too (not only new files).
        let skill = shared.appendingPathComponent("skills/learned/pitch/SKILL.md")
        try? fm.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "---\nname: pitch\ndescription: Use when pitching.\n---\n\nOpen with the problem.\n".write(to: skill, atomically: true, encoding: .utf8)
        check("a new shared skill with nothing private stays", SharedGuard.tend().isEmpty && fm.fileExists(atPath: skill.path))
        try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: skill.path)
        _ = SharedGuard.tend()
        try? "---\nname: pitch\ndescription: Use when pitching.\n---\n\nOpen with the problem.\n\(secret)\n".write(
            to: skill, atomically: true, encoding: .utf8)
        let skillNotes = SharedGuard.tend()
        check("a shared skill changed to copy a private note is held back", !fm.fileExists(atPath: skill.path) && skillNotes.count == 1)

        // Experimental connections: off until tested.
        let skills = ExperimentalGuard.dir
        for n in ["feedly", "smart-home"] {
            try? fm.createDirectory(at: skills.appendingPathComponent(n), withIntermediateDirectories: true)
            try? "---\nname: \(n)\ndescription: test\n---\n".write(
                to: skills.appendingPathComponent("\(n)/SKILL.md"), atomically: true, encoding: .utf8)
        }
        let list = #"[{"id":"News","with":"Feedly","skill":"my-connections/feedly","tested":"2026-10-24"}]"#
        try? list.write(to: ConnectionsWorld.customFile, atomically: true, encoding: .utf8)
        let off = ExperimentalGuard.untested()
        check("an untested connection is switched off", off.contains("my-connections/smart-home"))
        check("a tested connection stays on", !off.contains { $0.contains("feedly") })
        try? "[{\"id\":\"News\",\"with\":\"Feedly\",\"skill\":\"my-connections/feedly\"}]".write(
            to: ConnectionsWorld.customFile, atomically: true, encoding: .utf8)
        check("listed without a test date is still off", ExperimentalGuard.untested().contains("my-connections/feedly"))
        check(
            "skills the person switched off are read back",
            ExperimentalGuard.listed("hermes: note\n  - godmode\n  - \"axolotl\"\n⚠ warning") == ["godmode", "axolotl"])

        // Friction log.
        check("\"that annoyed me\" is caught", FrictionLog.matches("Ugh, that annoyed me, it asked twice"))
        check("normal messages aren't", !FrictionLog.matches("Find my receipts from this year"))
        FrictionLog.add("that annoyed me: it asked twice", context: "Should I move 555 files?")
        let log = (try? String(contentsOf: FrictionLog.file, encoding: .utf8)) ?? ""
        check("complaints are written to the friction log", log.contains("asked twice") && log.contains("555 files"))

        print("\(fails == 0 ? "guards ok" : "guards failed: \(fails)")")
        return fails == 0 ? 0 : 1
    }
}
