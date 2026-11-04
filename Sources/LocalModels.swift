import Foundation
import Darwin

/// A local OpenAI-compatible service. Only loopback addresses are ever queried or saved.
struct LocalServer: Identifiable, Sendable {
    let name: String
    let port: Int
    let models: [String]
    var id: Int { port }
    var baseURL: String { "http://127.0.0.1:\(port)/v1" }
}

enum LocalModels {
    static let knownPorts = [11434: "Ollama", 1234: "LM Studio"]
    static let limit = 20
    static var server: Process?

    static func discover(ports: [Int]? = nil) async -> [LocalServer] {
        let candidates = ports ?? Array(Set(knownPorts.keys).union(listeningPorts())).sorted()
        var found: [LocalServer] = []
        for port in candidates where (1...65535).contains(port) {
            guard let url = URL(string: "http://127.0.0.1:\(port)/v1/models") else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 0.7
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                (response as? HTTPURLResponse)?.statusCode == 200,
                let models = modelNames(data), !models.isEmpty
            else { continue }
            found.append(LocalServer(name: knownPorts[port] ?? "Local server", port: port, models: models))
        }
        return found
    }

    static func modelNames(_ data: Data) -> [String]? {
        guard data.count < 1_000_000,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let entries = object["data"] as? [[String: Any]]
        else { return nil }
        return Array(Set(entries.compactMap { $0["id"] as? String }.filter { !$0.isEmpty })).sorted()
    }

    /// Only listening loopback ports are probed. Never scan the network or send model names to a remote host.
    static func listeningPorts() -> [Int] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-nP", "-iTCP@127.0.0.1", "-sTCP:LISTEN", "-F", "n"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            guard line.hasPrefix("n"), let port = Int(line.split(separator: ":").last ?? "") else { return nil }
            return port
        }.filter { !knownPorts.keys.contains($0) }.prefix(limit).map { $0 }
    }

    static var recommendation: (model: String, download: String) {
        var bytes: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        let result = sysctlbyname("hw.memsize", &bytes, &size, nil, 0)
        let gb = result != 0 ? 8 : Int(bytes / 1_073_741_824)
        return recommended(forGB: gb)
    }

    static func recommended(forGB gb: Int) -> (model: String, download: String) {
        if gb >= 40 { return ("gemma4:31b", "about 20 GB") }
        if gb >= 20 { return ("qwen3:14b", "about 9.3 GB") }
        return ("qwen3:8b", "about 5.2 GB")
    }

    static func weakTools(_ model: String) -> Bool {
        let id = model.lowercased()
        return id.contains("3b") || id.contains("4b") || id.contains("7b") || id.contains("8b") || id.contains("9b") || id.contains("mini")
    }

    static func command(_ path: String, _ arguments: [String], timeout: TimeInterval = 180) async -> (Int32, String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = arguments
                p.environment = Env.vars()
                p.currentDirectoryURL = Env.support
                let output = Pipe()
                p.standardOutput = output
                p.standardError = output
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch {
                    continuation.resume(returning: (-1, error.localizedDescription))
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                continuation.resume(returning: (p.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
        }
    }

    static func ollamaPath() -> String? {
        [
            Env.support.appendingPathComponent("local-model/bin/ollama").path,
            Env.support.appendingPathComponent("local-model/ollama").path,
            "/opt/homebrew/bin/ollama", "/usr/local/bin/ollama",
        ].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Start the CLI service again after One reopens, but only if the saved local choice uses Ollama.
    static func wakeIfSelected() async {
        let config = (try? String(contentsOf: Env.hermesHome.appendingPathComponent("config.yaml"), encoding: .utf8)) ?? ""
        guard config.contains("127.0.0.1:11434/v1"), config.contains("provider: custom"), await discover(ports: [11434]).isEmpty else { return }
        startOllama()
    }

    private static func startOllama() {
        guard server?.isRunning != true, let path = ollamaPath() else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["serve"]
        var environment = Env.vars()
        environment["OLLAMA_CONTEXT_LENGTH"] = "65536"
        p.environment = environment
        p.currentDirectoryURL = Env.support
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil { server = p }
    }

    /// Called only after the person confirms the named model download in the UI.
    static func installRecommended() async -> String? {
        if ollamaPath() == nil {
            guard let url = URL(string: "https://github.com/ollama/ollama/releases/latest/download/ollama-darwin.tgz") else {
                return "I couldn't find Ollama's download."
            }
            let folder = Env.support.appendingPathComponent("local-model", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let (download, _) = try await URLSession.shared.download(from: url)
                let archive = folder.appendingPathComponent("ollama-darwin.tgz")
                try? FileManager.default.removeItem(at: archive)
                try FileManager.default.moveItem(at: download, to: archive)
                let result = await command("/usr/bin/tar", ["-xzf", archive.path, "-C", folder.path], timeout: 180)
                try? FileManager.default.removeItem(at: archive)
                if result.0 != 0 { return "I couldn't unpack Ollama. \(String(result.1.suffix(180)))" }
            } catch { return "I couldn't download Ollama: \(error.localizedDescription)" }
        }
        guard let path = ollamaPath() else { return "Ollama didn't become available after installation." }
        if await discover(ports: [11434]).isEmpty {
            startOllama()
            if server?.isRunning != true { return "I couldn't start Ollama." }
        }
        let model = recommendation.model
        let result = await command(path, ["pull", model], timeout: 3600)
        if result.0 != 0 { return "The model download didn't finish. \(String(result.1.suffix(180)))" }
        return nil
    }
}
