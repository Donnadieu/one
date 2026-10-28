import Quartz
import SwiftUI
import AppKit
import AVFoundation
import Speech
import PDFKit
import Carbon
import EventKit
import CoreAudio
import UniformTypeIdentifiers

// MARK: - Paths and environment

enum Env {
    nonisolated(unsafe) static var selfTest = false
    /// Launched as a command-line tool (`One --check-update`, `--render-world`, …), not by a person.
    /// The window still loads in some of these modes; it must never start the engine, because that
    /// used to restart the person's live engine helper and fail the message they were waiting on.
    static var commandLine: Bool { CommandLine.arguments.dropFirst().contains { $0.hasPrefix("--") } }
    static var support: URL {
        // A test never gets the real folder: ONE_SUPPORT_DIR, or the scratch folder TestWorld.enter() made.
        let base = ProcessInfo.processInfo.environment["ONE_SUPPORT_DIR"].map { URL(fileURLWithPath: $0) } ?? (selfTest ? TestWorld.scratch : nil)
        let u =
            base
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("One", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    /// One's own Hermes home: separate from any Hermes the user already runs.
    static var hermesHome: URL {
        let u = support.appendingPathComponent(selfTest ? "selftest-hermes" : "hermes", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    /// One's own copy of Hermes, installed on first launch. Never the user's own Hermes.
    static var engineDir: URL { support.appendingPathComponent("engine", isDirectory: true) }
    static var ownHermes: String { engineDir.appendingPathComponent(".hermes/bin/hermes").path }
    static var hermesPath: String? {
        if let t = testEngine { return t }
        if FileManager.default.isExecutableFile(atPath: ownHermes) { return ownHermes }
        // Developer fallback (ONE_USE_SYSTEM_HERMES=1): use an existing install.
        guard ProcessInfo.processInfo.environment["ONE_USE_SYSTEM_HERMES"] == "1" || selfTest else { return nil }
        let h = NSHomeDirectory()
        return ["\(h)/.local/bin/hermes", "/opt/homebrew/bin/hermes", "/usr/local/bin/hermes"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    /// A test's stand-in engine (`tools/fake-engine.py`, `make helpers-check`): only ever in a test, never in the person's One.
    static var testEngine: String? {
        guard selfTest, let t = ProcessInfo.processInfo.environment["ONE_TEST_ENGINE"], FileManager.default.isExecutableFile(atPath: t) else {
            return nil
        }
        return t
    }
    static func vars() -> [String: String] {
        var e = ProcessInfo.processInfo.environment
        let h = NSHomeDirectory()
        e["PATH"] = "\(engineDir.path)/.hermes/bin:\(h)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        e["HERMES_HOME"] = hermesHome.path
        e["PYTHONUNBUFFERED"] = "1"
        e["NO_COLOR"] = "1"
        e["TERM"] = "dumb"
        // One's folder lock already wraps everything; Chrome can't start a second sandbox inside it.
        e["AGENT_BROWSER_ARGS"] = "--no-sandbox,--disable-dev-shm-usage"
        // Never a browser window on their screen: the engine's browser tools stay hidden (see BrowserGuard).
        e["AGENT_BROWSER_HEADED"] = "false"
        e["HERMES_YOLO_MODE"] = "1"  // regular people can't judge "script execution" prompts
        // The browser helper keeps its files in ~/.config by default, which the folder lock closes.
        e["BH_HOME"] = support.appendingPathComponent("browser").path
        // 1Password's `op` keeps its settings in ~/.config/op, which the folder lock closes
        // ("cannot read config … operation not permitted"); give it a folder of its own.
        let op = support.appendingPathComponent("op")
        try? FileManager.default.createDirectory(at: op, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        e["OP_CONFIG_DIR"] = op.path
        // Hermes records which phone bot is in use under ~/.local/state, which the folder lock closes,
        // so the bot never connected. Keep that record in One's own home (also apart from any other Hermes).
        e["HERMES_GATEWAY_LOCK_DIR"] = hermesHome.appendingPathComponent("gateway-locks").path
        e["BH_RUNTIME_DIR"] = "/tmp/one-bh-\(getuid())"  // short path: socket names have a length limit
        for k in ["ANTHROPIC_API_KEY", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "OPENAI_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN"] {
            e.removeValue(forKey: k)
        }
        if !selfTest { e.removeValue(forKey: "OPENROUTER_API_KEY") }
        return e
    }
}

final class Box<T>: @unchecked Sendable {
    var v: T
    init(_ v: T) { self.v = v }
}

// MARK: - Folder access (macOS sandbox around the engine)

enum Access {
    nonisolated(unsafe) static var override: [String]?
    nonisolated(unsafe) static var readsOverride: [String]?
    static var folders: [String] {
        if let o = override { return o }
        // A `defaults write … -string "$CUR\n<path>"` from a shell can leave a literal \n: accept both.
        return lines(UserDefaults.standard.string(forKey: "folders"))
    }
    static func lines(_ raw: String?) -> [String] {
        (raw ?? "").replacingOccurrences(of: "\\n", with: "\n").split(separator: "\n").map(String.init)
    }
    /// Extra read-only paths a connection needs (e.g. a KeePass file), `~` expanded.
    static var connectorReads: [String] {
        if let o = readsOverride { return o }
        return lines(UserDefaults.standard.string(forKey: "connectorReads")).map { ($0 as NSString).expandingTildeInPath }
    }
    static func set(_ f: [String]) { UserDefaults.standard.set(f.joined(separator: "\n"), forKey: "folders") }
    /// The Folders window applies only the person's own changes (what they added or removed since it
    /// opened) onto the list as it is NOW. Writing back its whole copy would drop a folder the assistant,
    /// a helper or a routine added (`defaults write`) while the window was open.
    static func merge(opened: [String], chosen: [String], current: [String]) -> [String] {
        let removed = Set(opened).subtracting(chosen)
        var out = current.filter { !removed.contains($0) }
        for f in chosen where !out.contains(f) { out.append(f) }
        return out
    }
    /// The list as another process (`defaults write`) may have just left it.
    static var freshFolders: [String] {
        if override == nil { CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication) }
        return folders
    }
    /// Everything in the home folder is closed except the engine itself, the brain and the folders the user approved.
    static func profile() -> String {
        let h = NSHomeDirectory()
        func q(_ p: String) -> String {
            "(subpath \"" + p.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\")"
        }
        // GitHub and git logins the person already has on this Mac (so "connect my GitHub" just works).
        let logins = ["\(h)/.config/gh", "\(h)/.gitconfig", "\(h)/.config/git", "\(h)/.ssh", "\(h)/.git-credentials"]
        let rw = [Env.support.path, Brain.root.path, "\(h)/.cache", "\(h)/Library/Caches", "\(h)/.config/gh"] + folders + Shared.paths
        // The GitHub login token itself sits in the macOS keychain.
        var ro = ["\(h)/.local", "\(h)/Library/Keychains"] + logins
        // git's extra settings files (e.g. ~/.gitconfig-work pulled in by includeIf)
        ro += ((try? FileManager.default.contentsOfDirectory(atPath: h)) ?? []).filter { $0.hasPrefix(".gitconfig") }.map { "\(h)/\($0)" }
        if Env.hermesPath != Env.ownHermes { ro += ["\(h)/.hermes/hermes-agent", "\(h)/.hermes/tools", "\(h)/.hermes/node"] }
        // Each connection opens only what it needs (e.g. KeePass: its settings, the database, the key file).
        ro += connectorReads
        ro += ["\(h)/Library/Application Support/KeePassXC"]
        return """
            (version 1)
            (allow default)
            (deny file-read-data file-write* (subpath "\(h)"))
            (allow file-read-data \((ro + rw).map(q).joined(separator: " ")))
            (allow file-write* \(rw.map(q).joined(separator: " ")))
            (deny file-write* \(BrowserGuard.lockedPaths.map(q).joined(separator: " ")))
            """
    }
}
