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

// MARK: - Updates: checks GitHub releases, downloads the new app, swaps it and reopens. Brain, rooms and settings live outside the app and are never touched.

@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    static let repo = "Donnadieu/one"
    @Published var available: (version: String, notes: String, zip: URL)?
    @Published var state: String?  // "Downloading…", errors
    var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    static func newer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0
            let q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
    func check() async {
        guard let u = URL(string: "https://api.github.com/repos/\(Updater.repo)/releases?per_page=10") else { return }
        var req = URLRequest(url: u)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (d, _) = try? await URLSession.shared.data(for: req),
            let list = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]]
        else { return }
        var best: (String, String, URL)?
        for r in list where (r["draft"] as? Bool) != true {
            let tag = ((r["tag_name"] as? String) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            guard Updater.newer(tag, than: best?.0 ?? current),
                let zip = (r["assets"] as? [[String: Any]])?.first(where: { ($0["name"] as? String) == "One.zip" })?["browser_download_url"]
                    as? String,
                let zu = URL(string: zip)
            else { continue }
            best = (tag, (r["body"] as? String) ?? "", zu)
        }
        if let best, UserDefaults.standard.string(forKey: "updateSkipped") != best.0 || available == nil {
            available = (best.0, best.1, best.2)
        }
    }
    func loop() {
        Task {
            while true {
                await check()
                try? await Task.sleep(for: .seconds(6 * 3600))
            }
        }
    }
    /// Downloads, unpacks, then a tiny script waits for One to quit, swaps the app and reopens it.
    func install() async {
        guard let a = available else { return }
        let m = Model.shared
        if m.thinking || m.helpers.contains(where: { $0.state == "working" }) {
            state = "I'll update as soon as I finish what I'm doing."
            while m.thinking || m.helpers.contains(where: { $0.state == "working" }) { try? await Task.sleep(for: .seconds(5)) }
        }
        state = "Downloading the new version…"
        let dir = Env.support.appendingPathComponent("update", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let (tmp, resp) = try? await URLSession.shared.download(from: a.zip), (resp as? HTTPURLResponse)?.statusCode == 200 else {
            state = "The download didn't work. Check the internet and try again."
            return
        }
        let zip = dir.appendingPathComponent("One.zip")
        try? FileManager.default.moveItem(at: tmp, to: zip)
        state = "Getting it ready…"
        let ok: Bool = await withCheckedContinuation { c in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                p.arguments = ["-x", "-k", zip.path, dir.path]
                try? p.run()
                p.waitUntilExit()
                c.resume(returning: p.terminationStatus == 0)
            }
        }
        let newApp = dir.appendingPathComponent("One.app")
        guard ok, FileManager.default.fileExists(atPath: newApp.appendingPathComponent("Contents/MacOS/One").path) else {
            state = "The new version looked broken, so I kept this one. Try again later."
            return
        }
        let target = Bundle.main.bundlePath
        let script = """
            #!/bin/bash
            while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.5; done
            pkill -f "\(Env.engineDir.path)" 2>/dev/null; pkill -f "\(Env.support.path)/voice" 2>/dev/null
            xattr -dr com.apple.quarantine "\(newApp.path)" 2>/dev/null
            rm -rf "\(target).old" && mv "\(target)" "\(target).old" && mv "\(newApp.path)" "\(target)" && rm -rf "\(target).old" || { [ -d "\(target)" ] || mv "\(target).old" "\(target)"; }
            \(ProcessInfo.processInfo.environment["ONE_UPDATE_NO_REOPEN"] == "1" ? "echo done > \"\(dir.path)/swapped\"" : "open \"\(target)\"")
            """
        let sh = dir.appendingPathComponent("swap.sh")
        try? script.write(to: sh, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [sh.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            state = "I couldn't start the update."
            return
        }
        state = "Restarting…"
        Engine.shared.stop()
        try? await Task.sleep(for: .milliseconds(400))
        NSApp.terminate(nil)
    }
    func later() {
        if let a = available { UserDefaults.standard.set(a.version, forKey: "updateSkipped") }
        available = nil
    }
}

struct UpdateCard: View {
    @ObservedObject var u = Updater.shared
    var body: some View {
        if let a = u.available {
            VStack(alignment: .leading, spacing: 10) {
                Label("A new version of One is ready (\(a.version))", systemImage: "arrow.down.circle.fill").font(.headline)
                let notes = a.notes.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(4)
                    .joined(separator: "\n")
                if !notes.isEmpty { MarkdownText(text: notes, size: 13).foregroundStyle(.secondary) }
                Text("It only takes a moment. Your memory, rooms and settings stay exactly as they are.").font(.caption).foregroundStyle(.secondary)
                if let st = u.state { Text(st).font(.callout) }
                HStack(spacing: 8) {
                    Button("Update now") { Task { await u.install() } }
                        .buttonStyle(.borderedProminent).tint(Color(hex: 0xF4EFE8)).foregroundStyle(Color(hex: 0x141416))
                        .disabled(
                            u.state != nil && !(u.state ?? "").contains("try again") && !(u.state ?? "").contains("Try again")
                                && !(u.state ?? "").contains("couldn't"))
                    Button("Later") { u.later() }.buttonStyle(.bordered)
                }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial))
        }
    }
}
