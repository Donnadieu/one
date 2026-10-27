import Foundation

/// `One --test-production` (preflight): the person's files and settings are production, and no test can touch
/// them. Run from a test copy (tools/test-copy.sh), with and without ONE_SUPPORT_DIR. See TestWorld.swift.
enum ProductionCheck {
    static func run() -> Int32 {
        var fails = 0
        func check(_ name: String, _ ok: Bool) {
            print("  \(ok ? "✓" : "✗") \(name)")
            if !ok { fails += 1 }
        }
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        check("runs as a test copy, never as the real One", Bundle.main.bundleIdentifier != TestWorld.productionID)
        check("the test's One folder is not your real one", !TestWorld.isProduction(Env.support))
        check(
            "your Documents and real One folder count as production",
            TestWorld.isProduction(docs.appendingPathComponent("Made by Elias/x.md")) && TestWorld.isProduction(TestWorld.realSupport))
        check("a test is never the person's own One", !Env.production)
        check("the Ready for you folder of a test is inside the test world", !TestWorld.isProduction(Shelf.folder))
        check("the brain of a test is inside the test world", !TestWorld.isProduction(Brain.root))
        check("the engine home of a test is inside the test world", !TestWorld.isProduction(Env.hermesHome))

        // The Oct 27 accident, replayed on fakes: a shelf card in a "Made by …" folder must stay where it is.
        let made = Env.support.appendingPathComponent("fake-docs/Made by Ava", isDirectory: true)
        try? fm.createDirectory(at: made, withIntermediateDirectories: true)
        let file = made.appendingPathComponent("2026-10-27 Plan.md")
        try? "plan".write(to: file, atomically: true, encoding: .utf8)
        let gone = made.appendingPathComponent("2026-10-27 Gone.md")
        let items = [
            ShelfItem(title: "Plan", detail: "", from: "Ava", path: file.path),
            ShelfItem(title: "Gone", detail: "", from: "Ava", path: gone.path),
        ]
        let before = try? JSONEncoder().encode(items)
        UserDefaults.standard.set(before, forKey: "shelf")
        UserDefaults.standard.removeObject(forKey: "shelfMissing")
        let loaded = Shelf.load()
        Shelf.save([])
        check("loading the shelf in a test moves no file", fm.fileExists(atPath: file.path))
        check("nothing landed in the test's Ready for you folder", (try? fm.contentsOfDirectory(atPath: Shelf.folder.path))?.isEmpty ?? true)
        check("a test never rewrites the saved shelf", UserDefaults.standard.data(forKey: "shelf") == before)
        check("a test saves nothing about missing cards either", UserDefaults.standard.data(forKey: "shelfMissing") == nil && loaded.count == 1)
        // The person's own One: a card whose file went missing is kept aside, and comes back with its file.
        let a = ShelfItem(title: "A", detail: "", from: "Ava", path: "/x/a.md")
        let b = ShelfItem(title: "B", detail: "", from: "Ava", path: "/x/b.md")
        let r1 = Shelf.reconcile([a, b], missing: []) { $0 == a.path }
        check("a card whose file is missing is kept aside, not forgotten", r1.kept.map(\.path) == [a.path] && r1.missing.map(\.path) == [b.path])
        let r2 = Shelf.reconcile(r1.kept, missing: r1.missing) { _ in true }
        check("and comes back when its file does", Set(r2.kept.map(\.path)) == [a.path, b.path] && r2.missing.isEmpty)
        UserDefaults.standard.removeObject(forKey: "shelf")
        try? fm.removeItem(at: Env.support.appendingPathComponent("fake-docs"))
        print(fails == 0 ? "production ok" : "production FAILED (\(fails))")
        return fails == 0 ? 0 : 1
    }
}
