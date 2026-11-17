import AppKit
import SwiftUI

/// `One --test-helpers-stress restartwait` (tools/restart-wait-check.sh, in preflight): the Nov 17 "Free Docker memory"
/// helper, replayed against the stand-in engine (tools/fake-engine.py, no account, no cost). A helper asks for a folder,
/// gets it (a real `One --grant-folder` from inside its turn) and ends its turn saying it'll restart to use it. One
/// hasn't restarted yet. It must show "Waiting for One to restart" with no way to clear it (no Got it, no Done, the
/// done-helper line refused); Stop still works. After the restart it picks back up by itself in the same conversation
/// and finishes. The same for a helper that asked One to restart (`One --update --restart`), and for one an older One
/// showed as done, or that Got it took off the screen, before the restart. A finished helper is never picked back up.
extension HelperStress {
    static let waitLine = "Waiting for One to restart"

    @MainActor
    static func restartWaitCheck(_ m: Model) async -> Int32 {
        m.helpers = []
        m.bubbles = []
        m.shelf = []
        let t0 = Date()
        func at() -> String { String(format: "%5.1fs", Date().timeIntervalSince(t0)) }
        func h(_ title: String) -> Helper? { m.helpers.last { $0.title == title } }
        func dir(_ name: String) -> String {
            let u = Env.support.appendingPathComponent(name, isDirectory: true)
            try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
            return u.standardizedFileURL.path
        }
        func turnOver(_ title: String) async { _ = await wait(30) { h(title).map { $0.state != "working" } ?? true } }
        func show(_ title: String) {
            let x = h(title)
            print("   [\(at())] \(title): \(x?.state ?? "gone") · \(x?.line ?? "-") · queued \(x?.resumeQueued ?? false)")
        }
        /// What a restart for a new folder does (Model.restartForFolders), then the engine back up with its helpers.
        func folderRestart() async {
            await m.restartForFolders(resume: false, pauseHelpers: false)
            if !Engine.shared.running {  // a test copy's restart stops at the engine: start it the way launch does
                _ = await Engine.shared.start()
                m.resumeInterrupted()
            }
        }
        /// One quits and opens again (an update or an asked-for restart): helpers read back the way launch reads them.
        func appRestart() async {
            Engine.shared.stop()
            _ = UpdateRequest.take()  // the open One took the request before it quit
            try? await Task.sleep(for: .milliseconds(300))
            m.helpers = Model.savedHelpers()
            _ = await Engine.shared.start()
            m.resumeInterrupted()
        }
        func asked(_ token: String) -> [Event] { events().filter { $0.ev == "restart-asked" && $0.job == token } }
        func resumed(_ token: String) -> [Event] { events().filter { $0.ev == "restart-resumed" && $0.job == token } }

        print("0. A plain job finishes first (it must never be picked back up)")
        m.spawnHelper(title: "Plain job", task: "STRESSJOB P1 secs=1")
        await turnOver("Plain job")
        check("the plain job is done", h("Plain job")?.state == "done")

        print("1. A helper gets a folder and ends its turn; One hasn't restarted yet")
        let docker = dir("group.com.docker")
        m.spawnHelper(title: "Free Docker memory", task: "STRESSGRANT path=\(docker) token=GRANT7731")
        await turnOver("Free Docker memory")
        show("Free Docker memory")
        guard let fd = h("Free Docker memory") else {
            check("the helper is listed", false)
            return 1
        }
        let sid0 = fd.sid
        check("its turn ran One --grant-folder for real", asked("GRANT7731").first?.resumed == true && Access.freshFolders.contains(docker))
        check("a restart is still to come (the engine's lock is older than the folder list)", FolderWatch.changed)
        check("it shows \"\(waitLine)\"", fd.line == waitLine && HelperRings.status(fd) == waitLine)
        check("it isn't shown done or as needing a look", fd.state != "done" && fd.viewState != .done && !fd.waiting)
        check("no Got it, Done or dismiss: it counts as busy (its card shows Stop only)", HelperClose.busy(fd))
        check("its words before the restart are kept", fd.reply.contains("I'll restart to use it"))
        check("a Got it tap is refused", !m.closeHelper(fd.id) && h("Free Docker memory") != nil)
        await m.send("STRESSDONE Free Docker memory")
        _ = await wait(15) { !m.thinking }
        let said = m.bubbles.last { !$0.fromMe }?.text ?? ""
        print("   [\(at())] reply: \(said.replacingOccurrences(of: "\n", with: " "))")
        check("the done-helper line is refused: it's still on the screen", h("Free Docker memory") != nil)
        check("and the reply says why", said.contains("stays on your screen") && said.lowercased().contains("restart"))
        m.resumeInterrupted()  // anything else that picks helpers back up must leave it waiting for the restart
        check("it isn't picked back up before One restarts", h("Free Docker memory")?.line == waitLine)

        print("   Stop still works on one that's waiting")
        let stopDir = dir("stop-me")
        m.spawnHelper(title: "Stop me", task: "STRESSGRANT path=\(stopDir) token=STOP5150")
        await turnOver("Stop me")
        check("it waits for the restart too", h("Stop me")?.line == waitLine)
        if let s = h("Stop me") { m.stopHelper(s.id) }
        _ = await wait(5) { h("Stop me")?.stopping != true }
        check("Stop stops it", h("Stop me")?.state == "stopped" && h("Stop me")?.stoppedByYou == true && h("Stop me")?.resumeQueued != true)

        print("2. One restarts for the folder")
        await folderRestart()
        _ = await wait(30) { h("Free Docker memory")?.state == "done" }
        show("Free Docker memory")
        let r = resumed("GRANT7731")
        check("it picked back up by itself", r.count == 1)
        check("in the same conversation, told its own last words", r.first?.sid == sid0 && r.first?.resumed == true)
        check("it finished", h("Free Docker memory")?.state == "done" && h("Free Docker memory")?.reply.contains("DONE GRANT7731") == true)
        check("the engine's lock now has the folder", FolderWatch.startedProfile.contains(docker) && !FolderWatch.changed)
        check("now it can be cleared (Got it)", !HelperClose.busy(h("Free Docker memory") ?? fd))
        _ = await wait(10) { m.bubbles.contains { $0.text.contains("Free Docker memory") && $0.text.contains("picked it back up") } }
        check(
            "they're told it picked back up", m.bubbles.contains { $0.text.contains("Free Docker memory") && $0.text.contains("picked it back up") })
        check("the one they stopped stays stopped", resumed("STOP5150").isEmpty && h("Stop me")?.stoppedByYou == true)

        print("3. A helper asks One to restart (One --update --restart) and ends its turn")
        m.spawnHelper(title: "Restart One", task: "STRESSRESTARTASK path=- token=RST5520")
        await turnOver("Restart One")
        show("Restart One")
        let sid3 = h("Restart One")?.sid
        check("the restart was asked for", FileManager.default.fileExists(atPath: UpdateRequest.file.path))
        check(
            "it shows \"\(waitLine)\", with no way to clear it", h("Restart One")?.line == waitLine && h("Restart One").map(HelperClose.busy) == true)
        check("a Got it tap is refused", h("Restart One").map { !m.closeHelper($0.id) } == true)
        await appRestart()
        _ = await wait(30) { h("Restart One")?.state == "done" }
        show("Restart One")
        check("after One opens again it picked back up in the same conversation", resumed("RST5520").first?.sid == sid3 && sid3 != nil)
        check("and finished", h("Restart One")?.reply.contains("DONE RST5520") == true && h("Restart One")?.state == "done")

        print("4. An older One: shown done, or taken off the screen with Got it, before the restart")
        let kept = dir("legacy-kept")
        let gone = dir("legacy-gone")
        m.spawnHelper(title: "Legacy kept", task: "STRESSGRANT path=\(kept) token=LEG4410")
        m.spawnHelper(title: "Legacy gone", task: "STRESSGRANT path=\(gone) token=LEG4420")
        await turnOver("Legacy kept")
        await turnOver("Legacy gone")
        for t in ["Legacy kept", "Legacy gone"] {
            guard let x = h(t), let old = olderOne(x) else { continue }
            m.helpers = m.helpers.map { $0.id == x.id ? old : $0 }  // what an older One showed: done, Got it
        }
        check("older One state: both shown done", h("Legacy kept")?.state == "done" && h("Legacy gone")?.state == "done")
        if let g = h("Legacy gone") {
            m.helpers.removeAll { $0.id == g.id }  // an older One's Got it: off the screen
            let trail = HelperTrail.url(g.id)  // and its trail as an older One wrote it (no conversation line)
            if let t = try? String(contentsOf: trail, encoding: .utf8) {
                try? t.components(separatedBy: "\n").filter { !$0.hasPrefix("Conversation: ") }.joined(separator: "\n")
                    .write(to: trail, atomically: true, encoding: .utf8)
            }
        }
        check("Got it took one off the screen", h("Legacy gone") == nil)
        await folderRestart()
        _ = await wait(30) {
            h("Legacy kept")?.state == "done" && h("Legacy kept")?.reply.contains("DONE") == true && h("Legacy gone")?.state == "done"
        }
        show("Legacy kept")
        show("Legacy gone")
        check(
            "the one shown done picked back up and finished",
            resumed("LEG4410").count == 1 && h("Legacy kept")?.reply.contains("DONE LEG4410") == true)
        check("the one Got it took off is back on the screen", h("Legacy gone") != nil)
        check("with its job, told its last words", h("Legacy gone")?.task.contains("LEG4420") == true && resumed("LEG4420").first?.resumed == true)
        check("and it finished", h("Legacy gone")?.state == "done" && h("Legacy gone")?.reply.contains("DONE LEG4420") == true)
        await folderRestart()  // another restart picks nothing up twice
        try? await Task.sleep(for: .seconds(2))
        check("none is picked back up twice", resumed("LEG4410").count == 1 && resumed("LEG4420").count == 1 && resumed("GRANT7731").count == 1)
        check(
            "the plain job was never picked back up",
            events().filter { $0.ev == "start" && $0.job == "P1" }.count == 1 && h("Plain job")?.state == "done")

        print("5. A real restart: One quits and opens again (One --update --restart, the second run reads it back)")
        let real = dir("real-restart")
        m.spawnHelper(title: "Real restart", task: "STRESSGRANT path=\(real) token=REAL9090")
        await turnOver("Real restart")
        show("Real restart")
        check("it waits for the restart", h("Real restart")?.line == waitLine && h("Real restart").map(HelperClose.busy) == true)
        if let x = h("Real restart") { shot(m, x, "before") }
        print("RESTART-QUIT fails=\(fails)")  // the script checks this run's failures, then opens One again
        fflush(stdout)
        Awake.fake = .full  // a runner has no lid: the restart waits for nothing
        await Updater.shared.install(restartOnly: true)  // quits One when it works
        print("FAIL One didn't quit for the restart: \(Updater.shared.state ?? "")")
        return 1
    }

    /// The second run: the same One opened again after the real restart.
    @MainActor
    static func restartWaitAfter(_ m: Model) async -> Int32 {
        print("6. One opened again after the restart")
        func h(_ title: String) -> Helper? { m.helpers.last { $0.title == title } }
        let x = h("Real restart")
        print("   saved: \(x?.state ?? "gone") · \(x?.line ?? "-") · queued \(x?.resumeQueued ?? false)")
        check("it's still on the screen after the restart", x != nil)
        check("queued to pick back up, not done", x?.resumeQueued == true && x?.state != "done")
        let sid = x?.sid
        m.resumeInterrupted()  // what launch does once the engine is up (ensureEngine)
        _ = await wait(30) { h("Real restart")?.state == "done" }
        let r = events().filter { $0.ev == "restart-resumed" && $0.job == "REAL9090" }
        check(
            "it picked back up by itself, in the same conversation, told its last words",
            r.count == 1 && r.first?.sid == sid && r.first?.resumed == true)
        check("and finished", h("Real restart")?.state == "done" && h("Real restart")?.reply.contains("DONE REAL9090") == true)
        if let y = h("Real restart") { shot(m, y, "after") }
        Engine.shared.stop()
        print(fails == 0 ? "restart-wait ok" : "restart-wait FAILED (\(fails))")
        return fails == 0 ? 0 : 1
    }

    /// The orb and its opened card, saved as a picture (ONE_SHOT_DIR, else the test's own folder).
    @MainActor
    static func shot(_ m: Model, _ h: Helper, _ name: String) {
        let d = ProcessInfo.processInfo.environment["ONE_SHOT_DIR"].map { URL(fileURLWithPath: $0) } ?? Env.support
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let v = HStack(alignment: .top, spacing: 24) {
            let look = HelperRings.layout(count: 1).look
            let opened = h.state == "done" && !h.waiting
            let tag = HelperTag(
                title: h.title, line: m.progressLine(h, now: Date(), short: true), look: look, warm: h.viewState == .needsYes, opened: opened)
            HelperFace(state: h.viewState, t: 21.7, orb: 56, gap: 7, opened: opened, tag: tag, sleeping: m.asleep(h)).frame(width: 260)
            HelperCard(m: m, h: h).frame(width: 520)
        }
        .padding(30).background(WorldLook.bg).environment(\.colorScheme, .dark)
        let r = ImageRenderer(content: v)
        r.scale = 2
        if let img = r.nsImage, let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t),
            let png = rep.representation(using: .png, properties: [:])
        {
            try? png.write(to: d.appendingPathComponent("restart-wait-\(name).png"))
            print("   picture: \(d.appendingPathComponent("restart-wait-\(name).png").path)")
        }
    }

    /// The helper as an older One left it: shown done (its "I'll restart" words as its result), nothing queued.
    static func olderOne(_ h: Helper) -> Helper? {
        guard let d = try? JSONEncoder().encode(h), var j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        for k in ["restartWait", "resumeQueued", "updatePaused", "pausedFor"] { j.removeValue(forKey: k) }
        j["state"] = "done"
        j["line"] = "Done · " + Helpers.summary(h.reply, 30)
        j["seen"] = true
        return (try? JSONSerialization.data(withJSONObject: j)).flatMap { try? JSONDecoder().decode(Helper.self, from: $0) }
    }
}
