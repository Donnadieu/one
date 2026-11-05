import Foundation

/// `One --test-search` (CI only, from a test copy; preflight runs it): a made-up brain in the scratch folder proves
/// the search index keeps private rooms and locked drawers out, picks up edits and deletes, rebuilds a broken index,
/// finds close spellings, and stays fast with 1,000 notes (the numbers are printed).
enum BrainIndexCheck {
    static func run() -> Int32 {
        let fm = FileManager.default
        var fails = 0
        func check(_ name: String, _ ok: Bool) {
            print("  \(ok ? "✓" : "✗") \(name)")
            if !ok { fails += 1 }
        }
        func write(_ u: URL, _ s: String) {
            try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? s.write(to: u, atomically: true, encoding: .utf8)
        }
        let brain = Brain.root
        let cloud = Env.support.appendingPathComponent("cloud/One Rooms", isDirectory: true)
        try? fm.removeItem(at: brain)
        try? fm.removeItem(at: BrainRooms.indexDir)
        let personal = brain.appendingPathComponent("personal-room")
        let nyx = brain.appendingPathComponent("nyx-room")
        let work = brain.appendingPathComponent("work-room")
        let team = cloud.appendingPathComponent("Team")
        write(personal.appendingPathComponent("brain/life.md"), "# Garden\n\nPlant zucchini by the fence. Quebec cousins visit in June.\n")
        write(nyx.appendingPathComponent("room.yaml"), "title: Nyx\nprivate: true\n")
        write(nyx.appendingPathComponent("brain/nyx.md"), "# Night\n\nMoonflower whisper, and the Quebec hotel.\n")
        write(work.appendingPathComponent("room.yaml"), "title: Work\nprivate: false  # shown in search\n")
        let trip = work.appendingPathComponent("brain/projects/quebec-trip.md")
        write(
            trip,
            "# Quebec trip\n\nPlanning the trip.\n\n## Flights\n\nNewark to Quebec City, Porter flight at 9am.\n\n## Hotel\n\nChateau near the old town.\n"
        )
        write(work.appendingPathComponent("brain/projects/constructease.md"), "# ConstructEase\n\nWeekly update goes out on Fridays to the client.\n")
        write(work.appendingPathComponent("confidential/salary.md"), "# Pay\n\nzucchini moonflower quebec confidentialword\n")
        write(work.appendingPathComponent("brain/Confidential/x.md"), "confidentialword two\n")
        write(work.appendingPathComponent(".git/notes.md"), "gitonlyword\n")
        write(work.appendingPathComponent("brain/.later.md.icloud"), "placeholderword\n")
        write(work.appendingPathComponent("brain/picture.png"), "pngonlyword\n")
        write(work.appendingPathComponent("brain/huge.md"), "hugeword " + String(repeating: "filler text ", count: 90_000))
        write(
            work.appendingPathComponent("brain/long.md"),
            "# Long\n\n" + (0..<60).map { "Paragraph \($0) about the lawn mower and the hedge." }.joined(separator: "\n\n"))
        write(brain.appendingPathComponent("assistant/this-mac.md"), "# This Mac\n\nCommit identity is Donnadieu, signed with GPG.\n")
        write(team.appendingPathComponent("one-room.json"), #"{"title":"Team","createdBy":"Omar","created":"2026-11-04","members":["Omar","Sam"]}"#)
        write(team.appendingPathComponent("entries/2026-11-04 0900 Sam - plan.md"), "By Sam\n\nShared plan for the Quebec offsite.\n")
        BrainRooms.sharedOverride = [team.path]
        let rooms = BrainRooms.all()
        let names = rooms.map { "\($0.name)\($0.isPrivate ? "*" : "")" }.sorted()
        check(
            "rooms and privacy: no room.yaml and private: true are private (\(names.joined(separator: " ")))",
            names == ["Team", "assistant", "nyx-room*", "personal-room*", "work-room"])
        func find(_ q: String, _ room: String? = nil) -> SearchResult { BrainSearch.search(q, room: room, limit: 20, all: rooms) }
        func real(_ p: String) -> String { URL(fileURLWithPath: p).resolvingSymlinksInPath().path }
        func files(_ r: SearchResult) -> [String] { r.hits.map { real($0.file) } }
        let tripPath = real(trip.path)
        let nyxDB = BrainRooms.file("nyx-room")

        // Privacy: a search that names no room never sees a private room or a locked drawer, and never opens their index.
        let q = find("quebec")
        check("unscoped: work and shared rooms found", Set(q.hits.map(\.room)) == ["work-room", "Team"])
        check(
            "unscoped: nothing from nyx-room, personal-room or confidential",
            !files(q).contains { $0.contains("nyx-room") || $0.contains("personal-room") || $0.lowercased().contains("confidential") })
        check("unscoped: 2 private rooms counted as left out", q.privateLeftOut == 2 && !q.searched.contains("nyx-room"))
        check(
            "unscoped: a private room's index is never opened or made",
            !fm.fileExists(atPath: nyxDB.path) && !fm.fileExists(atPath: BrainRooms.file("personal-room").path))
        check("unscoped: nyx and personal words find nothing", find("moonflower").hits.isEmpty && find("zucchini").hits.isEmpty)
        check("named: --room nyx-room finds nyx", files(find("moonflower", "nyx-room")).contains { $0.hasSuffix("nyx-room/brain/nyx.md") })
        check("named: --room personal (short name) finds personal", find("zucchini", "personal").hits.count == 1)
        check(
            "locked drawers never indexed, even named",
            find("confidentialword", "work-room").hits.isEmpty && find("confidentialword", "nyx-room").hits.isEmpty)
        check(
            ".git, iCloud placeholders, pictures and files over 1 MB skipped",
            ["gitonlyword", "placeholderword", "pngonlyword", "hugeword"].allSatisfy { find($0, "work-room").hits.isEmpty })
        check("an unknown room is an error, private names not listed", find("x", "garden-room").error.map { !$0.contains("nyx") } ?? false)
        check(
            "no database inside the brain or the shared folder",
            ![brain, cloud].contains { dir in
                (fm.enumerator(atPath: dir.path)?.allObjects as? [String] ?? []).contains { $0.hasSuffix(".sqlite") }
            })
        check(
            "shared and assistant indexes in One's folder",
            fm.fileExists(atPath: BrainRooms.indexDir.appendingPathComponent("shared-Team.sqlite").path)
                && fm.fileExists(atPath: BrainRooms.indexDir.appendingPathComponent("assistant.sqlite").path))

        // Results: full path, nearest heading, a marked snippet, ranked by the note's name first.
        let flight = find("porter flight", "work-room")
        check(
            "heading is the nearest one (Flights) and the path is absolute",
            flight.hits.first.map { $0.heading == "Flights" && real($0.file) == tripPath && $0.file.hasPrefix("/") && $0.snippet.contains("«") }
                ?? false)
        if let h = flight.hits.first { print("    first hit: \(h.room) | \(h.heading) | \(h.file) | \(h.snippet.prefix(80))") }
        check("stemming: 'planned' finds 'Planning'", files(find("planned", "work-room")).contains(tripPath))
        let long = BrainIndex.chunks(BrainIndex.read(work.appendingPathComponent("brain/long.md")))
        check(
            "long notes split into pieces of 1,500 characters at most (\(long.count) pieces)",
            long.count >= 2 && long.allSatisfy { $0.text.count <= 1500 })
        check("headings inside code blocks don't split", BrainIndex.chunks("# A\n```\n# not a heading\n```\ntext").count == 1)
        check("assistant folder searched", find("commit identity").hits.first?.room == "assistant")

        // Close spellings (trigram) only when the words find nothing.
        let typo = find("Quebek")
        print("    typo: \(typo.match), \(typo.hits.map { "\($0.room):\(URL(fileURLWithPath: $0.file).lastPathComponent)" })")
        check("a typo finds the note (close spelling)", typo.match == "close" && files(typo).contains(tripPath))
        check("part of a word finds it", files(find("Constructe")).contains { $0.hasSuffix("constructease.md") })
        check("close spellings keep private rooms out too", !find("Moonflowr").hits.contains { $0.room == "nyx-room" })
        check("some words only, when not all match", find("hedge spaceship", "work-room").match == "some")

        // Incremental refresh: an edit and a delete are picked up; nothing else is read again.
        let workRoom = rooms.first { $0.name == "work-room" }!
        write(work.appendingPathComponent("brain/projects/constructease.md"), "# ConstructEase\n\nPineapple deadline moved.\n")
        let st = BrainIndex.refresh(workRoom)
        check(
            "an edit is picked up, only that file read again (\(st.changed) changed)",
            st.changed == 1 && !find("pineapple", "work").hits.isEmpty && find("fridays", "work").hits.isEmpty)
        try? fm.removeItem(at: trip)
        let st2 = BrainIndex.refresh(workRoom)
        check("a delete is picked up", st2.removed == 1 && find("chateau", "work").hits.isEmpty)
        check("nothing changed = nothing read", BrainIndex.refresh(workRoom).changed == 0)

        // A broken index is deleted and made again.
        BrainIndex.remove(workRoom.db)
        write(workRoom.db, String(repeating: "not a database ", count: 400))
        let again = find("pineapple", "work-room")
        check("a corrupt index is rebuilt and still answers", !again.hits.isEmpty)
        check(
            "command line: words, --room, --limit, --json read",
            BrainSearch.parse(["Barbados", "trip", "--room", "work", "--limit", "3", "--json"]).map {
                $0.query == "Barbados trip" && $0.room == "work" && $0.limit == 3 && $0.json
            } ?? false)
        check("command line: no words is refused", BrainSearch.parse(["--room", "work"]) == nil)
        check("the assistant is told how to search, every prompt", MainActor.assumeIsolated { SessionNotes.helper }.contains("--search"))

        // Speed: 1,000 made-up notes.
        let perf = brain.appendingPathComponent("perf-room")
        write(perf.appendingPathComponent("room.yaml"), "private: false\n")
        let vocab = (0..<600).map { i in ["ka", "lo", "mi", "ne", "ru", "sa", "ti", "vo", "ze", "pa"].shuffledBy(i).prefix(3).joined() + "\(i % 7)" }
        for n in 0..<1000 {
            let w = (0..<180).map { vocab[($0 * 31 + n * 17 + $0 * n) % vocab.count] }
            let body =
                "# Note \(n)\n\n" + w[0..<60].joined(separator: " ") + "\n\n## Part two\n\n" + w[60..<120].joined(separator: " ")
                + "\n\n## Part three\n\n" + w[120...].joined(separator: " ") + "\n"
            write(perf.appendingPathComponent("notes/\(n / 100)/note-\(n).md"), body)
        }
        let perfRoom = BrainRooms.all().first { $0.name == "perf-room" }!
        let t0 = Date()
        let built = BrainIndex.refresh(perfRoom)
        let build = Date().timeIntervalSince(t0)
        let t1 = Date()
        _ = BrainIndex.refresh(perfRoom)
        let noop = Date().timeIntervalSince(t1)
        var times: [Double] = []
        for i in 0..<20 {
            let s = Date()
            let r = BrainSearch.search(vocab[i * 13] + " " + vocab[i * 7 + 1], room: "perf-room", limit: 10, refresh: false)
            times.append(Date().timeIntervalSince(s))
            if i == 0 && r.hits.isEmpty { print("    (no hits for the first timing query)") }
        }
        var closeTimes: [Double] = []
        var close = SearchResult()
        for i in 0..<5 {  // a typo'd word: the last two letters lost, an x added
            let s = Date()
            close = BrainSearch.search(String(vocab[i * 17 + 5].dropLast(2)) + "x", room: "perf-room", limit: 10, refresh: false)
            closeTimes.append(Date().timeIntervalSince(s))
        }
        let closeTime = closeTimes.reduce(0, +) / Double(closeTimes.count)
        let avg = times.reduce(0, +) / Double(times.count)
        print(
            String(
                format:
                    "    took: index 1,000 notes %.2f s (%d pieces), refresh with nothing changed %.0f ms, word query avg %.1f ms (max %.1f), close spelling avg %.1f ms (%d found)",
                build, built.chunks, noop * 1000, avg * 1000, (times.max() ?? 0) * 1000, closeTime * 1000, close.hits.count))
        check("1,000 notes indexed in under 2 s", built.files == 1000 && build < 2)
        check("a word query takes under 50 ms", avg < 0.05)
        // Close spellings vary 20-60 ms on CI's unoptimized test build (well under that in a release build).
        check("a close-spelling query takes under 150 ms", closeTime < 0.15)
        BrainRooms.sharedOverride = nil
        print(fails == 0 ? "search ok" : "search: \(fails) failed")
        return fails == 0 ? 0 : 1
    }
}

extension Array {
    /// A fixed shuffle (the same every run), for made-up test words.
    fileprivate func shuffledBy(_ seed: Int) -> [Element] {
        var a = self
        var x = UInt64(seed &* 2_654_435_761 &+ 1)
        for i in stride(from: a.count - 1, to: 0, by: -1) {
            x = x &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            a.swapAt(i, Int(x >> 33) % (i + 1))
        }
        return a
    }
}
