import AppKit
import Foundation

// MARK: - Installs and restarts asked for from a chat, a helper or a script go through One, never by hand
//
// Nov 17 2026, 7:17 AM: a helper installed One 0.9.120 by hand (kill One, swap the app, open it). Its "is a
// routine running?" test read a field the engine never writes, so it went ahead while the YouTube long-video
// routine was 17 minutes into its run; the new One found the old background helper orphaned, stopped it as stale,
// and the run was cut. Now there is one way in: `One --update` leaves a request that the open One picks up and
// carries out with every wait an update already has (no routine at work, every helper between two steps, the Mac
// fully awake), and the engine plugin `one-browser-guard` refuses the hand-made kill/swap/relaunch commands.
enum UpdateRequest {
    enum Kind: String { case release, build, restart }
    struct Ask: Equatable {
        var kind: Kind
        var from: String?  // a built One.app, for `.build`
        var by: String
        var at: Date
    }

    static var file: URL { Env.support.appendingPathComponent("update-request.json") }

    /// The command everything outside One is told to use (the engine note, the plugin's block message, skills).
    static let howTo =
        "`One --update` installs the newest release, `One --update --from <path>/One.app` installs a build, "
        + "`One --update --restart` only restarts One. One does it as soon as no routine is running and every helper is "
        + "between two steps; your own turn is paused for the restart and picks back up by itself."

    static func write(_ a: Ask, to f: URL = file) -> Bool {
        var j: [String: Any] = ["kind": a.kind.rawValue, "by": a.by, "at": ISO8601DateFormatter().string(from: a.at)]
        if let from = a.from { j["from"] = from }
        try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let d = try? JSONSerialization.data(withJSONObject: j) else { return false }
        return (try? d.write(to: f, options: .atomic)) != nil
    }

    static func read(_ f: URL = file) -> Ask? {
        guard let d = try? Data(contentsOf: f), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
            let k = (j["kind"] as? String).flatMap(Kind.init(rawValue:))
        else { return nil }
        let at = (j["at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
        let from = j["from"] as? String
        if k == .build && (from ?? "").isEmpty { return nil }
        return Ask(kind: k, from: from, by: (j["by"] as? String) ?? "?", at: at)
    }

    /// Reads the request and removes it, so it's carried out once. A broken file is removed too.
    static func take(_ f: URL = file) -> Ask? {
        guard FileManager.default.fileExists(atPath: f.path) else { return nil }
        let a = read(f)
        try? FileManager.default.removeItem(at: f)
        return a
    }

    /// `One --update [--from <One.app>] [--restart]`: leaves the request for the open One and says what happens next.
    static func cli(_ args: [String]) -> Int32? {
        guard args.contains("--update") else { return nil }
        var a = Ask(kind: args.contains("--restart") ? .restart : .release, from: nil, by: "command line pid \(getppid())", at: Date())
        if let k = args.firstIndex(of: "--from") {
            guard k + 1 < args.count else {
                print("--from needs the path of a built One.app")
                return 2
            }
            let p = URL(fileURLWithPath: (args[k + 1] as NSString).expandingTildeInPath).standardizedFileURL.path
            guard FileManager.default.fileExists(atPath: p + "/Contents/MacOS/One") else {
                print("No One app at \(p) (Contents/MacOS/One is missing). Nothing was asked.")
                return 2
            }
            a.kind = .build
            a.from = p
        }
        guard write(a) else {
            print("Couldn't leave the request in \(file.path).")
            return 1
        }
        let what = a.kind == .restart ? "restart" : a.kind == .build ? "install the build at \(a.from ?? "")" : "install the newest release"
        let busy = Routines.inFlight()
        let wait = busy.isEmpty ? "" : " Waiting for \(Routines.list(busy)) to finish first."
        print(
            "Asked One to \(what).\(wait) It goes ahead once no routine is running and every helper is between two steps (open One picks this up within 10 s; a closed One does it when it next opens). Don't kill, swap or reopen One yourself."
        )
        return 0
    }

    /// The open One looks for a request every 10 s (also right at launch) and carries it out.
    @MainActor static func loop() {
        Task { @MainActor in
            while true {
                await tend()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    @MainActor static func tend() async {
        guard !Updater.shared.installing, let a = take() else { return }
        GatewayGuard.log("update asked (\(a.kind.rawValue)\(a.from.map { " from \($0)" } ?? ""), by \(a.by))")
        switch a.kind {
        case .restart: await Updater.shared.install(restartOnly: true)
        case .build: await Updater.shared.install(fromApp: a.from.map { URL(fileURLWithPath: $0) })
        case .release:
            Updater.shared.forgetLater()  // asked for now: a "Later" tapped earlier doesn't hold it back
            await Updater.shared.check()
            guard Updater.shared.available != nil else {
                GatewayGuard.log("update asked: already on the newest release (\(Updater.shared.current))")
                return
            }
            await Updater.shared.install()
        }
    }

    /// The script that waits for One to quit, stops its engine, then opens the same app again (a restart, no swap).
    static func relaunchScript(target: String, waitPID: Int32, noReopen: Bool, dir: String) -> String {
        """
        #!/bin/bash
        while kill -0 \(waitPID) 2>/dev/null; do sleep 0.5; done
        if [ \(Env.selfTest ? 1 : 0) = 0 ]; then
        pkill -f "\(Env.engineDir.path)" 2>/dev/null; pkill -f "\(Env.support.path)/voice" 2>/dev/null
        fi
        \(noReopen ? "echo done > \"\(dir)/restarted\"" : "for i in 1 2 3; do open \"\(target)\" && break; sleep 5; done")
        """
    }
}
