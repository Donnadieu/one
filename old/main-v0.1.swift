// One — a one-button personal assistant (test build).
// Setup is a conversation; sign-in uses the user's own AI subscription.
import SwiftUI
import AppKit
import Network
import CryptoKit
import Security

// MARK: - Providers

enum Provider: String, CaseIterable, Identifiable {
    case claude, chatgpt, openrouter
    var id: String { rawValue }
    var title: String {
        switch self { case .claude: "Claude"; case .chatgpt: "ChatGPT"; case .openrouter: "OpenRouter" }
    }
    var subtitle: String {
        switch self {
        case .claude: "Use your Claude Pro or Max plan"
        case .chatgpt: "Use your ChatGPT Plus or Pro plan"
        case .openrouter: "Pay as you go. Any model."
        }
    }
    var symbol: String {
        switch self { case .claude: "sparkle"; case .chatgpt: "bubble.left.and.bubble.right"; case .openrouter: "arrow.triangle.branch" }
    }
}

enum Status: Equatable {
    case checking, connected(String), notSignedIn, notInstalled, failed(String)
    var label: String {
        switch self {
        case .checking: "Checking…"
        case .connected(let s): s
        case .notSignedIn: "Not connected"
        case .notInstalled: "Not on this Mac yet"
        case .failed(let s): s
        }
    }
    var isConnected: Bool { if case .connected = self { return true }; return false }
}

// MARK: - Running commands (never shown to the user)

final class Box: @unchecked Sendable { var data = Data() }

final class Runner: @unchecked Sendable {
    static let shared = Runner()
    private let lock = NSLock()
    private var current: Process?

    static var workDir: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("One", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static var env: [String: String] {
        var e = ProcessInfo.processInfo.environment
        let h = NSHomeDirectory()
        e["PATH"] = "\(h)/.local/bin:\(h)/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        // Use the subscription sign-in, never a stray API key from the shell.
        for k in ["ANTHROPIC_API_KEY", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "OPENAI_API_KEY"] { e.removeValue(forKey: k) }
        return e
    }

    static func which(_ tool: String) -> Bool {
        let h = NSHomeDirectory()
        for d in ["\(h)/.local/bin", "\(h)/.npm-global/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            if FileManager.default.isExecutableFile(atPath: "\(d)/\(tool)") { return true }
        }
        return false
    }

    func run(_ args: [String], timeout: TimeInterval = 180) async -> (code: Int32, out: String, err: String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                p.arguments = args
                p.environment = Runner.env
                p.currentDirectoryURL = Runner.workDir
                let o = Pipe(), e = Pipe()
                p.standardOutput = o; p.standardError = e; p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch {
                    cont.resume(returning: (-1, "", error.localizedDescription)); return
                }
                self.lock.lock(); self.current = p; self.lock.unlock()
                let ob = Box(), eb = Box(), g = DispatchGroup()
                g.enter(); DispatchQueue.global().async { ob.data = o.fileHandleForReading.readDataToEndOfFile(); g.leave() }
                g.enter(); DispatchQueue.global().async { eb.data = e.fileHandleForReading.readDataToEndOfFile(); g.leave() }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
                p.waitUntilExit(); g.wait()
                self.lock.lock(); if self.current === p { self.current = nil }; self.lock.unlock()
                cont.resume(returning: (p.terminationStatus,
                                        String(decoding: ob.data, as: UTF8.self),
                                        String(decoding: eb.data, as: UTF8.self)))
            }
        }
    }

    func stop() {
        lock.lock(); let p = current; lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }
}

// MARK: - Keychain (OpenRouter key never touches a plain file)

enum Keychain {
    static let service = "One Assistant"
    static func save(_ value: String, account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base; add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
    static func read(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var r: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &r) == errSecSuccess, let d = r as? Data else { return nil }
        return String(decoding: d, as: UTF8.self)
    }
    static func delete(_ account: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecAttrAccount as String: account] as CFDictionary)
    }
}

// MARK: - Sign-in flows

enum Auth {
    static func status(_ p: Provider) async -> Status {
        switch p {
        case .claude:
            guard Runner.which("claude") else { return .notInstalled }
            let r = await Runner.shared.run(["claude", "auth", "status"], timeout: 30)
            if let d = r.out.data(using: .utf8),
               let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               j["loggedIn"] as? Bool == true {
                return .connected("Connected with your Claude plan")
            }
            return .notSignedIn
        case .chatgpt:
            guard Runner.which("codex") else { return .notInstalled }
            let r = await Runner.shared.run(["codex", "login", "status"], timeout: 30)
            let s = r.out + r.err
            if s.contains("ChatGPT") && s.lowercased().contains("logged in") { return .connected("Connected with your ChatGPT plan") }
            if s.lowercased().contains("logged in") { return .connected("Connected with an OpenAI key") }
            return .notSignedIn
        case .openrouter:
            return Keychain.read("openrouter") != nil ? .connected("Connected to OpenRouter") : .notSignedIn
        }
    }

    /// Installs the tool the provider needs, using each vendor's official installer.
    static func install(_ p: Provider) async -> Bool {
        switch p {
        case .claude:
            let r = await Runner.shared.run(["/bin/bash", "-c", "curl -fsSL https://claude.ai/install.sh | bash"], timeout: 600)
            return r.code == 0
        case .chatgpt:
            guard Runner.which("npm") else { return false }
            let r = await Runner.shared.run(["npm", "install", "-g", "@openai/codex"], timeout: 600)
            return r.code == 0
        case .openrouter: return true
        }
    }

    /// Opens the provider's own sign-in page in the browser; returns when it finishes.
    static func signIn(_ p: Provider) async -> Status {
        switch p {
        case .claude:
            _ = await Runner.shared.run(["claude", "auth", "login"], timeout: 600)
        case .chatgpt:
            _ = await Runner.shared.run(["codex", "login"], timeout: 600)
        case .openrouter:
            do { Keychain.save(try await OpenRouterPKCE().run(), account: "openrouter") }
            catch { return .failed("Sign-in didn't finish: \(error.localizedDescription)") }
        }
        return await status(p)
    }
}

/// OpenRouter's official "sign in for apps" flow (OAuth PKCE with a localhost callback).
final class OpenRouterPKCE: @unchecked Sendable {
    struct Err: LocalizedError { let errorDescription: String? }
    let verifier: String = {
        var b = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, b.count, &b)
        return Data(b).base64URL
    }()
    var challenge: String { Data(SHA256.hash(data: Data(verifier.utf8))).base64URL }
    let port: UInt16 = 3000

    var authURL: URL {
        var c = URLComponents(string: "https://openrouter.ai/auth")!
        c.queryItems = [.init(name: "callback_url", value: "http://localhost:\(port)/one-callback"),
                        .init(name: "code_challenge", value: challenge),
                        .init(name: "code_challenge_method", value: "S256")]
        return c.url!
    }

    func run() async throws -> String {
        let code = try await waitForCode(openingBrowser: true)
        return try await exchange(code: code)
    }

    func waitForCode(openingBrowser: Bool) async throws -> String {
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        defer { listener.cancel() }
        return try await withCheckedThrowingContinuation { cont in
            let done = Box()
            listener.newConnectionHandler = { conn in
                conn.start(queue: .global())
                conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                    let req = String(decoding: data ?? Data(), as: UTF8.self)
                    let path = req.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                    let code = URLComponents(string: "http://localhost\(path)")?
                        .queryItems?.first(where: { $0.name == "code" })?.value
                    let body = code != nil
                        ? "<h2 style='font-family:-apple-system'>You're connected. You can close this tab.</h2>"
                        : "<h2 style='font-family:-apple-system'>Waiting for OpenRouter…</h2>"
                    let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in conn.cancel() })
                    if let code, done.data.isEmpty { done.data = Data([1]); cont.resume(returning: code) }
                }
            }
            listener.stateUpdateHandler = { st in
                if case .failed(let e) = st, done.data.isEmpty { done.data = Data([1]); cont.resume(throwing: e) }
                if case .ready = st, openingBrowser { DispatchQueue.main.async { NSWorkspace.shared.open(self.authURL) } }
            }
            listener.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 600) {
                if done.data.isEmpty { done.data = Data([1]); cont.resume(throwing: Err(errorDescription: "timed out")) }
            }
        }
    }

    func exchange(code: String) async throws -> String {
        var r = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/auth/keys")!)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["code": code, "code_verifier": verifier,
                                                                 "code_challenge_method": "S256"])
        let (d, resp) = try await URLSession.shared.data(for: r)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try JSONSerialization.jsonObject(with: d) as? [String: Any],
              let key = j["key"] as? String else {
            throw Err(errorDescription: "OpenRouter said: \(String(decoding: d, as: UTF8.self).prefix(200))")
        }
        return key
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Talking to the assistant

enum Brain {
    static let authProblem = "AUTH_EXPIRED"
    static let persona = "You are a warm, plain-spoken personal assistant running on the user's own Mac. Keep replies short and clear. No jargon."

    static func ask(_ text: String, via p: Provider) async -> String {
        switch p {
        case .claude:
            let r = await Runner.shared.run(["claude", "-p", text, "--append-system-prompt", persona,
                                             "--output-format", "text"], timeout: 300)
            let all = r.out + r.err
            if all.contains("Failed to authenticate") || all.contains("OAuth") || all.contains("/login") {
                return Brain.authProblem
            }
            return r.code == 0 ? r.out.trimmingCharacters(in: .whitespacesAndNewlines)
                               : "I couldn't reach Claude. \(all.prefix(200))"
        case .chatgpt:
            let outFile = Runner.workDir.appendingPathComponent("last-reply.txt")
            try? FileManager.default.removeItem(at: outFile)
            let r = await Runner.shared.run(["codex", "exec", "--skip-git-repo-check", "-s", "read-only",
                                             "--output-last-message", outFile.path,
                                             "\(persona)\n\nUser: \(text)"], timeout: 300)
            if let s = try? String(contentsOf: outFile, encoding: .utf8), !s.isEmpty {
                return s.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return "I couldn't reach ChatGPT. \(r.err.suffix(200))"
        case .openrouter:
            guard let key = Keychain.read("openrouter") else { return "OpenRouter isn't connected yet." }
            var r = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
            r.httpMethod = "POST"
            r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.setValue("One Assistant", forHTTPHeaderField: "X-Title")
            r.httpBody = try? JSONSerialization.data(withJSONObject: [
                "model": "openrouter/auto",
                "messages": [["role": "system", "content": persona], ["role": "user", "content": text]]])
            guard let (d, _) = try? await URLSession.shared.data(for: r),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let c = (j["choices"] as? [[String: Any]])?.first,
                  let m = c["message"] as? [String: Any], let s = m["content"] as? String
            else { return "I couldn't reach OpenRouter." }
            return s
        }
    }
}

// MARK: - App state

struct Msg: Identifiable { let id = UUID(); let fromMe: Bool; let text: String }

@MainActor
final class Model: ObservableObject {
    @AppStorage("provider") var providerRaw: String = ""
    @AppStorage("setupDone") var setupDone = false
    @Published var statuses: [Provider: Status] = [:]
    @Published var busy: Provider?
    @Published var messages: [Msg] = []
    @Published var thinking = false
    @Published var paused = false

    var provider: Provider? { Provider(rawValue: providerRaw) }

    func refresh() async {
        for p in Provider.allCases { statuses[p] = .checking }
        for p in Provider.allCases { statuses[p] = await Auth.status(p) }
    }

    func connect(_ p: Provider) async {
        busy = p; defer { busy = nil }
        if statuses[p] == .notInstalled {
            statuses[p] = .failed("Installing… this can take a few minutes")
            guard await Auth.install(p) else { statuses[p] = .failed("Couldn't install it automatically"); return }
            statuses[p] = await Auth.status(p)
        }
        if statuses[p]?.isConnected == true {
            statuses[p] = .failed("Checking the connection works…")
            if await Brain.ask("Reply with exactly the word: ready", via: p) == Brain.authProblem {
                statuses[p] = .notSignedIn
            } else { statuses[p] = .connected("Connected and working") }
        }
        if statuses[p]?.isConnected != true {
            statuses[p] = .failed("Finish signing in on the page that just opened")
            statuses[p] = await Auth.signIn(p)
        }
        if statuses[p]?.isConnected == true {
            providerRaw = p.rawValue
            setupDone = true
            if messages.isEmpty {
                messages.append(Msg(fromMe: false, text: "I'm set up and using \(p.title). What can I help you with?"))
            }
        }
    }

    func send(_ text: String) async {
        guard !paused, let p = provider, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        messages.append(Msg(fromMe: true, text: text))
        thinking = true
        var reply = await Brain.ask(text, via: p)
        if reply == Brain.authProblem { reply = "My sign-in to \(p.title) expired. Open Connections and press Connect to sign in again." }
        thinking = false
        if !paused { messages.append(Msg(fromMe: false, text: reply)) }
    }

    func stopEverything() { paused.toggle(); if paused { Runner.shared.stop(); thinking = false } }
}

// MARK: - Screens

struct RootView: View {
    @StateObject var m = Model()
    @State var step = 0   // 0 welcome, 1 pick AI
    var body: some View {
        Group {
            if m.setupDone && m.provider != nil { TalkView(m: m) }
            else if step == 0 { WelcomeView { step = 1 } }
            else { PickAIView(m: m) }
        }
        .frame(minWidth: 520, minHeight: 600)
        .task { await m.refresh() }
    }
}

struct WelcomeView: View {
    var start: () -> Void
    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Text("Hi. I'm your assistant.").font(.system(size: 34, weight: .semibold))
            VStack(spacing: 10) {
                Text("I live on this Mac, not in the cloud.")
                Text("I can't see your files unless you say so.")
                Text("If this Mac is closed or off, I'm off too.")
            }.font(.title3).foregroundStyle(.secondary)
            Spacer()
            Button(action: start) {
                Circle().fill(Color.accentColor).frame(width: 120, height: 120)
                    .overlay(Text("Start").font(.title2.bold()).foregroundStyle(.white))
                    .shadow(radius: 8)
            }.buttonStyle(.plain).keyboardShortcut(.defaultAction)
            Spacer()
        }.padding(40)
    }
}

struct PickAIView: View {
    @ObservedObject var m: Model
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Which AI do you already pay for?").font(.title.bold())
            Text("I'll use it as my brain. You can switch any time.").foregroundStyle(.secondary)
            ForEach(Provider.allCases) { p in
                let st = m.statuses[p] ?? .checking
                HStack(spacing: 14) {
                    Image(systemName: p.symbol).font(.title2).frame(width: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(p.title).font(.headline)
                        Text(st.isConnected ? "Found on this Mac. \(st.label)." : p.subtitle)
                            .font(.subheadline).foregroundStyle(.secondary)
                        if case .failed(let s) = st { Text(s).font(.caption).foregroundStyle(.orange) }
                    }
                    Spacer()
                    if m.busy == p { ProgressView().controlSize(.small) }
                    else {
                        Button(st.isConnected ? "Use this" : (st == .notInstalled ? "Set it up" : "Connect")) {
                            Task { await m.connect(p) }
                        }.buttonStyle(.borderedProminent).disabled(m.busy != nil || st == .checking)
                    }
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
            }
            Text("Don't have one? OpenRouter lets you pay a few dollars and try any model.")
                .font(.footnote).foregroundStyle(.secondary)
            Spacer()
        }.padding(32)
    }
}

struct TalkView: View {
    @ObservedObject var m: Model
    @State var draft = ""
    @State var showConnections = false
    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(m.messages) { msg in
                            HStack {
                                if msg.fromMe { Spacer(minLength: 60) }
                                Text(msg.text).textSelection(.enabled).padding(12)
                                    .background(RoundedRectangle(cornerRadius: 14)
                                        .fill(msg.fromMe ? Color.accentColor : Color(nsColor: .controlBackgroundColor)))
                                    .foregroundStyle(msg.fromMe ? .white : .primary)
                                if !msg.fromMe { Spacer(minLength: 60) }
                            }.id(msg.id)
                        }
                        if m.thinking { HStack { ProgressView().controlSize(.small); Text("Thinking…").foregroundStyle(.secondary); Spacer() } }
                    }.padding(20)
                }.onChange(of: m.messages.count) { _, _ in
                    if let last = m.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            if m.paused {
                Text("Stopped. I won't do anything until you turn me back on.")
                    .font(.callout).padding(8).frame(maxWidth: .infinity).background(Color.red.opacity(0.15))
            }
            HStack(spacing: 12) {
                TextField("Ask me anything…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain).font(.title3).lineLimit(1...5)
                    .padding(12).background(RoundedRectangle(cornerRadius: 22).stroke(.quaternary))
                    .onSubmit(sendDraft).disabled(m.paused)
                Button(action: sendDraft) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 34))
                }.buttonStyle(.plain).disabled(m.paused || m.thinking || draft.isEmpty)
            }.padding(16)
        }
        .toolbar {
            ToolbarItem { Button { showConnections = true } label: { Label("Connections", systemImage: "switch.2") } }
            ToolbarItem {
                Button { m.stopEverything() } label: {
                    Label(m.paused ? "Turn on" : "Stop", systemImage: m.paused ? "play.circle.fill" : "stop.circle.fill")
                }.tint(m.paused ? .green : .red)
            }
        }
        .navigationTitle("One · \(m.provider?.title ?? "")")
        .sheet(isPresented: $showConnections) {
            VStack(alignment: .leading) {
                PickAIView(m: m)
                Button("Done") { showConnections = false }.keyboardShortcut(.defaultAction).padding()
            }.frame(width: 520, height: 520)
        }
    }
    func sendDraft() { let t = draft; draft = ""; Task { await m.send(t) } }
}

struct OneApp: App {
    var body: some Scene {
        WindowGroup("One") { RootView() }.windowResizability(.contentSize)
    }
}

// MARK: - Entry (with a headless self-test for checking the plumbing)

@main
struct Entry {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--selftest") {
            let sem = DispatchSemaphore(value: 0)
            Task.detached {
                for p in Provider.allCases {
                    let st = await Auth.status(p)
                    print("[\(p.title)] status: \(st.label)")
                    if st.isConnected {
                        let t0 = Date()
                        let reply = await Brain.ask("Reply with exactly the word: ready", via: p)
                        print("[\(p.title)] reply (\(Int(Date().timeIntervalSince(t0)))s): \(reply.prefix(120))")
                    }
                }
                let pk = OpenRouterPKCE()
                print("[OpenRouter] sign-in URL: \(pk.authURL.absoluteString.prefix(90))…")
                sem.signal()
            }
            sem.wait(); exit(0)
        }
        if args.contains("--pkce-listen-test") {
            // Proves the localhost callback catches the code (no real exchange).
            let sem = DispatchSemaphore(value: 0)
            Task.detached {
                do { print("callback code received: \(try await OpenRouterPKCE().waitForCode(openingBrowser: false))") }
                catch { print("listener error: \(error)") }
                sem.signal()
            }
            sem.wait(); exit(0)
        }
        OneApp.main()
    }
}
