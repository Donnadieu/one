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

/// Renders the assistant's Markdown replies: headings, bullet and numbered lists, quotes, code blocks,
/// simple tables and rules, with inline bold/italic/code/links.
struct MarkdownText: View {
    let text: String
    var size: CGFloat = 15
    enum Block: Hashable {
        case heading(Int, String)
        case bullet(Int, String)
        case numbered(Int, String, String)
        case quote(String)
        case code(String)
        case table([[String]])
        case rule
        case para(String)
    }

    static func blocks(_ src: String) -> [Block] {
        var out: [Block] = []
        var para: [String] = []
        var code: [String]? = nil
        var table: [[String]] = []
        func flushPara() {
            if !para.isEmpty {
                out.append(.para(para.joined(separator: " ")))
                para = []
            }
        }
        func flushTable() {
            if !table.isEmpty {
                out.append(.table(table))
                table = []
            }
        }
        for raw in src.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let c = code {
                    out.append(.code(c.joined(separator: "\n")))
                    code = nil
                } else {
                    flushPara()
                    flushTable()
                    code = []
                }
                continue
            }
            if code != nil {
                code!.append(raw)
                continue
            }
            if line.hasPrefix("|") && line.hasSuffix("|") {
                flushPara()
                let cells = line.dropFirst().dropLast().split(separator: "|", omittingEmptySubsequences: false).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                if !cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { table.append(cells) }
                continue
            }
            flushTable()
            if line.isEmpty {
                flushPara()
                continue
            }
            let indent = raw.prefix { $0 == " " }.count / 2
            if let r = line.range(of: #"^#{1,6} "#, options: .regularExpression) {
                flushPara()
                out.append(.heading(line[r].count - 1, String(line[r.upperBound...])))
            } else if line == "---" || line == "***" || line == "___" {
                flushPara()
                out.append(.rule)
            } else if let r = line.range(of: #"^[-*+•] "#, options: .regularExpression) {
                flushPara()
                out.append(.bullet(indent, String(line[r.upperBound...])))
            } else if let r = line.range(of: #"^\d+[.)] "#, options: .regularExpression) {
                flushPara()
                out.append(.numbered(indent, String(line[r].dropLast(2)), String(line[r.upperBound...])))
            } else if line.hasPrefix(">") {
                flushPara()
                out.append(.quote(line.dropFirst().trimmingCharacters(in: .whitespaces)))
            } else {
                para.append(line)
            }
        }
        if let c = code { out.append(.code(c.joined(separator: "\n"))) }
        flushPara()
        flushTable()
        return out
    }

    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, b in
                switch b {
                case .heading(let l, let t):
                    Text(Self.inline(t)).font(.system(size: size + CGFloat(max(0, 4 - l)) * 2, weight: .semibold)).padding(.top, 4)
                case .bullet(let ind, let t):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        Text(Self.inline(t)).fixedSize(horizontal: false, vertical: true)
                    }.padding(.leading, CGFloat(ind) * 16)
                case .numbered(let ind, let n, let t):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(n).").foregroundStyle(.secondary).monospacedDigit()
                        Text(Self.inline(t)).fixedSize(horizontal: false, vertical: true)
                    }.padding(.leading, CGFloat(ind) * 16)
                case .quote(let t):
                    Text(Self.inline(t)).foregroundStyle(.secondary).padding(.leading, 10)
                        .overlay(alignment: .leading) { Rectangle().fill(.secondary.opacity(0.4)).frame(width: 2) }
                case .code(let c):
                    Text(c).font(.system(size: size - 2, design: .monospaced)).padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.primary.opacity(0.06)))
                case .table(let rows):
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                            GridRow {
                                ForEach(Array(r.enumerated()), id: \.offset) { _, c in
                                    Text(Self.inline(c)).fontWeight(i == 0 ? .semibold : .regular)
                                }
                            }
                            if i == 0 { Divider() }
                        }
                    }
                case .rule: Divider()
                case .para(let t): Text(Self.inline(t)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.system(size: size))
        .multilineTextAlignment(.leading)
        .textSelection(.enabled)
    }
}

struct TryItem: Hashable {
    let symbol: String
    let tag: String
    let text: String
}

let tryItems: [TryItem] = [
    TryItem(symbol: "folder", tag: "Files", text: "Tidy my Downloads into folders that make sense"),
    TryItem(symbol: "doc.text.magnifyingglass", tag: "Files", text: "Find every receipt from this year and add them up"),
    TryItem(symbol: "safari", tag: "Browser", text: "Log in to a site for me and check my account"),
    TryItem(symbol: "airplane", tag: "Watch", text: "Watch a flight price and tell me when it drops"),
    TryItem(symbol: "sunrise", tag: "Every day", text: "Every morning at 7, send me my day on my phone"),
    TryItem(symbol: "hammer", tag: "Research", text: "Compare 3 contractors near me and save it to my Desktop"),
    TryItem(symbol: "envelope", tag: "Email", text: "Read my last 50 emails and tell me who's waiting on me"),
    TryItem(symbol: "brain", tag: "Memory", text: "Remember what I like, then plan my weekend around it"),
]

// MARK: - Screens

struct RootView: View {
    @StateObject var m = Model.shared
    @State var started = false
    var body: some View {
        Group {
            if m.onboarded && !m.switchingAI {
                HomeView(m: m)
            } else if !started && m.bubbles.isEmpty && !m.onboarded {
                WelcomeView { started = true }
            } else {
                OnboardingView(m: m)
            }
        }
        .frame(minWidth: 560, minHeight: 680)
        .onAppear { if m.onboarded { m.step = .done } }
    }
}

struct WelcomeView: View {
    var start: () -> Void
    @State var shown = 0
    let lines: [(String, String)] = [
        ("Hi. I'm your assistant.", "welcome1"),
        ("I live on this Mac, not in the cloud.", "welcome2"),
        ("I ask before I do anything that matters.", "welcome3"),
        ("If this Mac is closed or off, I'm off too.", "welcome4"),
    ]
    var body: some View {
        ZStack {
            Mist()
            VStack(spacing: 28) {
                Spacer()
                Emerging(text: lines[0].0, visible: shown >= 1).font(.system(size: 36, weight: .semibold))
                VStack(spacing: 12) {
                    ForEach(1..<lines.count, id: \.self) { i in
                        Emerging(text: lines[i].0, visible: shown >= i + 1)
                    }
                }.font(.title3).foregroundStyle(.secondary)
                Spacer()
                BigButton(label: "Start") {
                    Voice.shared.stop()
                    start()
                }
                .keyboardShortcut(.defaultAction)
                .opacity(shown > lines.count ? 1 : 0).blur(radius: shown > lines.count ? 0 : 12)
                .scaleEffect(shown > lines.count ? 1 : 0.85)
                .animation(.easeOut(duration: 1.4), value: shown)
                Button(Voice.shared.muted ? "Turn voice on" : "Mute voice") {
                    Voice.shared.muted.toggle()
                    shown = shown + 0
                }.buttonStyle(.link).font(.caption).opacity(shown > lines.count ? 0.7 : 0)
                Spacer()
            }.padding(40)
        }
        .task {
            try? await Task.sleep(for: .milliseconds(700))
            for (i, l) in lines.enumerated() {
                let d = Voice.shared.play(l.1)
                if d > 0 { try? await Task.sleep(for: .milliseconds(500)) }
                shown = i + 1
                try? await Task.sleep(for: .milliseconds(Int(max(d - 0.5, 1.3) * 1000) + 250))
            }
            shown = lines.count + 1
        }
    }
}

/// Text that rises out of a blur, like something surfacing through water.
struct Emerging: View {
    let text: String
    let visible: Bool
    var body: some View {
        Text(text).multilineTextAlignment(.center)
            .opacity(visible ? 1 : 0)
            .blur(radius: visible ? 0 : 14)
            .scaleEffect(visible ? 1 : 0.94)
            .offset(y: visible ? 0 : 14)
            .animation(.easeOut(duration: 1.5), value: visible)
    }
}

/// Soft, slowly drifting light behind the conversation.
struct Mist: View {
    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                for i in 0..<3 {
                    let k = Double(i)
                    let x = size.width * (0.5 + 0.28 * sin(t * 0.07 + k * 2.1))
                    let y = size.height * (0.45 + 0.22 * cos(t * 0.05 + k * 1.7))
                    let r = min(size.width, size.height) * (0.55 + 0.1 * sin(t * 0.09 + k))
                    ctx.fill(
                        Path(ellipseIn: CGRect(x: x - r / 2, y: y - r / 2, width: r, height: r)),
                        with: .color(Color.accentColor.opacity(0.10)))
                }
            }.blur(radius: 70)
        }.ignoresSafeArea().allowsHitTesting(false)
    }
}

struct BigButton: View {
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Circle().fill(Color.accentColor).frame(width: 120, height: 120)
                .overlay(Text(label).font(.title2.bold()).foregroundStyle(.white)).shadow(radius: 8)
        }.buttonStyle(.plain)
    }
}

struct BubbleView: View {
    let b: Bubble
    var body: some View {
        HStack {
            if b.fromMe { Spacer(minLength: 80) }
            Group {
                if b.fromMe || b.text.isEmpty {
                    Text(b.text.isEmpty ? "…" : b.text)
                } else {
                    MarkdownText(text: Choices.split(b.text).body, size: 17)
                }
            }
            .textSelection(.enabled)
            .font(b.fromMe ? .body : .title3)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(b.fromMe ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
            )
            .foregroundStyle(b.fromMe ? .white : .primary)
            if !b.fromMe { Spacer(minLength: 80) }
        }
    }
}

/// Shows the last few things said: the newest line surfaces in the middle, older ones fade away above it.
struct Stage: View {
    let bubbles: [Bubble]
    let busy: Bool
    @State var appeared: Set<UUID> = []
    var body: some View {
        let recent = Array(bubbles.suffix(4))
        VStack(spacing: 18) {
            Spacer(minLength: 20)
            ForEach(Array(recent.enumerated()), id: \.element.id) { i, b in
                let age = recent.count - 1 - i  // 0 = newest
                let on = appeared.contains(b.id)
                Group { if b.fromMe { Text(b.text) } else { MarkdownText(text: Choices.split(b.text).body, size: age == 0 ? 20 : 16) } }
                    .font(b.fromMe ? .title3 : (age == 0 ? .system(size: 26, weight: .medium) : .title3))
                    .foregroundStyle(b.fromMe ? Color.accentColor : .primary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
                    .opacity(on ? max(0.12, 1 - Double(age) * 0.32) : 0)
                    .blur(radius: on ? Double(age) * 0.8 : 14)
                    .scaleEffect(on ? 1 : 0.94)
                    .offset(y: on ? 0 : 16)
                    .onAppear { withAnimation(.easeOut(duration: 1.5)) { _ = appeared.insert(b.id) } }
            }
            if busy { ProgressView().controlSize(.small).padding(.top, 6) }
            Spacer(minLength: 20)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 1.0), value: bubbles.count)
    }
}

struct Chip: View {
    let label: String
    var selected = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(label).padding(.horizontal, 16).padding(.vertical, 9)
                .background(Capsule().fill(selected ? Color.accentColor : Color(nsColor: .controlBackgroundColor)))
                .foregroundStyle(selected ? .white : .primary)
                .overlay(Capsule().stroke(.quaternary))
        }.buttonStyle(.plain)
    }
}

struct OnboardingView: View {
    @ObservedObject var m: Model
    @State var text = ""
    @State var paste = ""
    var body: some View {
        Group {
            if m.step == .world {
                WorldStage(m: m)
            } else {
                VStack(spacing: 0) {
                    Stage(bubbles: m.bubbles, busy: m.busy)
                    answerArea.padding(24).frame(maxWidth: .infinity)
                        .opacity(m.speaking ? 0 : 1).blur(radius: m.speaking ? 8 : 0)
                        .allowsHitTesting(!m.speaking)
                        .animation(.easeOut(duration: 0.9), value: m.speaking)
                        .id(m.step).transition(.opacity.combined(with: .offset(y: 10)))
                        .animation(.easeOut(duration: 0.8), value: m.step)
                }
            }
        }
        .background(Mist())
        .task {
            if m.switchingAI {
                m.bubbles.removeAll()
                m.step = .pickAI
                await m.say("Which AI should I use?")
            } else {
                await m.beginOnboarding()
            }
        }
    }

    @ViewBuilder var answerArea: some View {
        switch m.step {
        case .installing:
            VStack(spacing: 14) {
                if m.needDevTools {
                    Button("Continue") { Task { await m.install() } }.buttonStyle(.borderedProminent).controlSize(.large)
                } else if let e = m.installError {
                    Text(e).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(3)
                    Button("Try again") { Task { await m.install() } }.buttonStyle(.borderedProminent).controlSize(.large)
                } else {
                    ProgressView(value: Double(min(m.installDone, 26)), total: 26).frame(maxWidth: 320)
                    Text(m.installLine.isEmpty ? "Starting…" : m.installLine)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).frame(maxWidth: 380)
                }
            }
        case .pickAI:
            VStack(spacing: 10) {
                ForEach(Provider.allCases) { p in
                    Button {
                        Task { await m.choose(p) }
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: p.symbol).font(.system(size: 20, weight: .light)).frame(width: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.title).font(.headline)
                                Text(m.signedIn[p] == true ? "Already signed in" : p.subtitle)
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }.padding(12).contentShape(Rectangle())
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
                    }.buttonStyle(.plain).disabled(m.busy)
                }
                if let p = m.signInProblem { Text(p).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                if m.switchingAI {
                    Button("Never mind") {
                        m.switchingAI = false
                        m.step = .done
                        m.bubbles.removeAll()
                    }.buttonStyle(.link)
                }
            }
        case .signingIn:
            VStack(spacing: 14) {
                if let c = m.signInCode {
                    Text("If the page asks for a code, enter:").foregroundStyle(.secondary)
                    Text(c).font(.system(size: 30, weight: .bold, design: .monospaced)).textSelection(.enabled)
                }
                if m.signInNeedsPaste {
                    Text("Paste the code the page shows you:").foregroundStyle(.secondary)
                    HStack {
                        TextField("Code", text: $paste).textFieldStyle(.roundedBorder).onSubmit(sendPaste)
                        Button("Continue", action: sendPaste).buttonStyle(.borderedProminent)
                    }.frame(maxWidth: 420)
                }
                if m.signInCode == nil && !m.signInNeedsPaste {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Waiting for you to sign in…").foregroundStyle(.secondary)
                    }
                }
                Button("Cancel") { m.cancelSignIn() }.buttonStyle(.link)
            }
        case .nameAssistant:
            VStack(spacing: 12) {
                HStack { ForEach(["Juno", "Max", "Sage", "Nova"], id: \.self) { n in Chip(label: n) { Task { await m.nameAssistant(n) } } } }
                field("Or type a name") { await m.nameAssistant($0) }
            }
        case .nameUser:
            field("Your name") { await m.nameUser($0) }
        case .rooms:
            VStack(spacing: 12) {
                Button("No, start simple") { Task { await m.roomsChosen(true) } }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                Text("or pick any that should be kept separate").font(.caption).foregroundStyle(.secondary)
                HStack {
                    ForEach([RoomKind.work, .cofounder, .privateRoom]) { k in
                        Chip(label: k.chip, selected: m.pickedRooms.contains(k)) {
                            if m.pickedRooms.contains(k) { m.pickedRooms.remove(k) } else { m.pickedRooms.insert(k) }
                        }
                    }
                }
                if !m.pickedRooms.isEmpty {
                    Button("Continue") { Task { await m.roomsChosen(false) } }.buttonStyle(.borderedProminent)
                }
            }.disabled(m.busy)
        case .backup:
            HStack(spacing: 16) {
                Button("Yes, back it up") { Task { await m.backupChosen(true) } }.buttonStyle(.borderedProminent).controlSize(.large)
                Button("Not now") { Task { await m.backupChosen(false) } }.controlSize(.large)
            }.disabled(m.busy)
        case .connect:
            VStack(spacing: 12) {
                Text("Pick as many as you like").font(.caption).foregroundStyle(.secondary)
                let opts = m.connectOptions
                VStack(spacing: 8) {
                    ForEach(Array(stride(from: 0, to: opts.count, by: 4)), id: \.self) { r in
                        HStack {
                            ForEach(opts[r..<min(r + 4, opts.count)], id: \.self) { c in
                                Chip(label: c, selected: m.pickedConnections.contains(c)) { m.toggleConnection(c) }
                            }
                        }
                    }
                }
                field("Or add your own, like \"my bank\"") { m.addOwnConnection($0) }
                HStack(spacing: 16) {
                    Button("Continue") { Task { await m.connectionsChosen() } }
                        .buttonStyle(.borderedProminent).disabled(m.pickedConnections.isEmpty)
                    Button("Not now") {
                        m.pickedConnections = []
                        Task { await m.connectionsChosen() }
                    }.buttonStyle(.link)
                }
            }
        case .whichEmail:
            VStack(spacing: 12) {
                HStack {
                    ForEach(["Gmail", "Outlook", "iCloud Mail", "Yahoo"], id: \.self) { e in
                        Chip(label: e, selected: m.pickedEmails.contains(e)) {
                            if m.pickedEmails.contains(e) { m.pickedEmails.remove(e) } else { m.pickedEmails.insert(e) }
                        }
                    }
                }
                Button("Continue") { Task { await m.emailsChosen() } }
                    .buttonStyle(.borderedProminent).disabled(m.pickedEmails.isEmpty)
            }
        case .passwords:
            let hasOP = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/op")
            VStack(spacing: 10) {
                HStack {
                    Chip(label: hasOP ? "1Password (found on this Mac)" : "1Password") { Task { await m.passwordsChosen("1Password") } }
                    Chip(label: "Bitwarden") { Task { await m.passwordsChosen("Bitwarden") } }
                }
                HStack {
                    Chip(label: "My Mac's Keychain") { Task { await m.passwordsChosen("your Mac's Keychain") } }
                    Chip(label: "Ask me each time") { Task { await m.passwordsChosen("Ask me each time") } }
                }
            }
        case .passwordsOK:
            HStack(spacing: 16) {
                Button("Yes") { Task { await m.passwordsOK(true) } }.buttonStyle(.borderedProminent).controlSize(.large)
                Button("Not now") { Task { await m.passwordsOK(false) } }.controlSize(.large)
            }
        case .wrapUp:
            VStack(spacing: 10) {
                ForEach(m.suggestions, id: \.self) { s in
                    Button {
                        m.finish()
                        Task { await m.send(s) }
                    } label: {
                        Text(s).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
                    }.buttonStyle(.plain).disabled(m.busy)
                }
                Button("I'll look around first") { m.finish() }.buttonStyle(.link).disabled(m.busy)
            }
        case .done, .world:
            EmptyView()
        }
    }

    func sendPaste() {
        let p = paste
        paste = ""
        m.pasteCode(p)
    }

    func field(_ placeholder: String, _ go: @escaping (String) async -> Void) -> some View {
        TextField(placeholder, text: $text).textFieldStyle(.plain).font(.title3)
            .padding(10).background(RoundedRectangle(cornerRadius: 20).stroke(.quaternary))
            .onSubmit {
                let t = text
                text = ""
                Task { await go(t) }
            }
            .frame(maxWidth: 440)
    }
}

/// Tap the assistant's name: one small card with its brain and its voice. Nothing else.
struct MeCard: View {
    @ObservedObject var m: Model
    var close: () -> Void = {}
    @State var model: String = MeCard.currentModel()
    @State var voice: String = Speaker.voiceID
    @State var gender: String = Speaker.voiceID.hasPrefix("am") || Speaker.voiceID.hasPrefix("bm") ? "Male" : "Female"
    @State var anyModel = false
    @State var search = ""
    @State var busy = false
    @AppStorage("voiceMuted") var muted = false
    static let voices: [String: [(String, String)]] = [
        "Female": [("af_heart", "Warm"), ("af_bella", "Bright"), ("bf_emma", "British")],
        "Male": [("am_michael", "Calm"), ("am_fenrir", "Deep"), ("bm_george", "British")],
    ]
    static func currentModel() -> String {
        let y = (try? String(contentsOf: Env.hermesHome.appendingPathComponent("config.yaml"), encoding: .utf8)) ?? ""
        for l in y.split(separator: "\n") where l.trimmingCharacters(in: .whitespaces).hasPrefix("default:") {
            return l.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        }
        return ""
    }
    var provider: Provider { Provider(rawValue: m.providerRaw) ?? .claude }
    static func allOpenRouter() -> [String] {
        guard let d = try? Data(contentsOf: Env.hermesHome.appendingPathComponent("models_dev_cache.json")),
            let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
            let o = j["openrouter"] as? [String: Any], let ms = o["models"] as? [String: Any]
        else { return [] }
        return ms.keys.sorted()
    }
    func pill(_ t: String, _ on: Bool, sub: String? = nil, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            VStack(spacing: 2) {
                Text(t).font(.system(size: 13.5, weight: .medium))
                if let sub { Text(sub).font(.system(size: 10.5)).foregroundStyle(WorldLook.cream.opacity(0.45)).lineLimit(1) }
            }
            .foregroundStyle(on ? .white : WorldLook.cream.opacity(0.8))
            .frame(maxWidth: .infinity).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(WorldLook.cream.opacity(on ? 0.12 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(WorldLook.cream.opacity(on ? 0.55 : 0.1), lineWidth: 1))
        }.buttonStyle(.plain)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.name).font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                    Text("To rename me, just ask.").font(.system(size: 12)).foregroundStyle(WorldLook.cream.opacity(0.5))
                }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("BRAIN").font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(WorldLook.cream.opacity(0.5))
                    Spacer()
                    Text(provider.title).font(.system(size: 11)).foregroundStyle(WorldLook.cream.opacity(0.45))
                }
                HStack(spacing: 8) {
                    ForEach(provider.tiers, id: \.1) { t in pill(t.0, model == t.1, sub: t.1) { pick(t.1) } }
                }
                if provider == .openrouter {
                    Button(anyModel ? "Hide the full list" : "Pick any model…") { anyModel.toggle() }.buttonStyle(.plain)
                        .font(.system(size: 12.5)).foregroundStyle(WorldLook.cream.opacity(0.6))
                    if anyModel {
                        TextField("Search, e.g. gemini, llama, gpt", text: $search).textFieldStyle(.roundedBorder)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(
                                    MeCard.allOpenRouter().filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }.prefix(60),
                                    id: \.self
                                ) { id in
                                    Button {
                                        pick(id)
                                    } label: {
                                        HStack {
                                            Text(id).font(.system(size: 12.5))
                                            Spacer()
                                            if model == id { Image(systemName: "checkmark") }
                                        }
                                    }
                                    .buttonStyle(.plain).foregroundStyle(WorldLook.cream.opacity(0.85))
                                }
                            }
                        }.frame(height: 140)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("VOICE").font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(WorldLook.cream.opacity(0.5))
                    Spacer()
                    Button {
                        muted.toggle()
                        if muted { Speaker.shared.stop() }
                    } label: {
                        Label(muted ? "Muted" : "Mute", systemImage: muted ? "speaker.slash" : "speaker.wave.2")
                    }
                    .buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(WorldLook.cream.opacity(muted ? 0.9 : 0.5))
                }
                HStack(spacing: 8) {
                    ForEach(["Female", "Male"], id: \.self) { g in
                        pill(g, gender == g) {
                            gender = g
                            let v = MeCard.voices[g]![0].0
                            choose(v)
                        }
                    }
                }
                HStack(spacing: 8) {
                    ForEach(MeCard.voices[gender]!, id: \.0) { v in
                        pill(v.1, voice == v.0, sub: voice == v.0 ? "✓ chosen" : "▶ hear it") { choose(v.0) }
                    }
                }
            }.opacity(muted ? 0.45 : 1)
            HStack {
                Spacer()
                Button("Done") { close() }.buttonStyle(.plain).font(.system(size: 13.5, weight: .medium)).foregroundStyle(
                    WorldLook.cream.opacity(0.7))
            }
        }
        .padding(22).frame(width: 420)
        .background(WorldLook.bg)
        .preferredColorScheme(.dark)
    }
    func choose(_ v: String) {
        voice = v
        Speaker.shared.use(voice: v, sample: muted ? nil : "Hi \(m.userName.isEmpty ? "there" : m.userName), this is how I'll sound.")
    }
    func pick(_ id: String) {
        guard id != model, !busy else { return }
        model = id
        busy = true
        Task { @MainActor in
            _ = await hermesRun(["config", "set", "model.default", id])
            _ = await Engine.shared.start()
            busy = false
        }
    }
}

struct HomeView: View {
    @ObservedObject var m: Model
    @State var draft = ""
    @State var folderSheet = false
    @State var talkKeySheet = false
    @State var connectionsSheet = false
    @State var roomsSheet = false
    @State var meCard = false
    @AppStorage("shelfCollapsed") var shelfCollapsed = false
    @AppStorage("tryHidden") var tryHidden = false
    @AppStorage("firstHome") var firstHome: Double = 0
    var tryShown: Bool { !tryHidden && (firstHome == 0 || Date().timeIntervalSince1970 - firstHome < 3 * 86400) }
    @AppStorage("voiceMuted") var voiceOff = false
    @ObservedObject var l = Listener.shared
    @State var micDownAt: Date?
    @State var micLatched = false
    @State var dropping = false
    @FocusState var typing: Bool
    var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 12 ? "Good morning" : (h < 17 ? "Good afternoon" : "Good evening")
    }
    var lastAsk: Bubble? { m.bubbles.last(where: { $0.fromMe }) }
    var lastReply: Bubble? { m.bubbles.last.flatMap { $0.fromMe ? nil : $0 } }
    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                Mist()
                ScrollView {
                    VStack(spacing: 18) {
                        Text("\(greeting), \(m.userName).").font(.system(size: 26, weight: .semibold)).padding(.top, 18)
                            .onAppear { if firstHome == 0 { firstHome = Date().timeIntervalSince1970 } }
                        NovaWithHelpers(m: m)
                        if m.thinking && m.openHelper == nil {
                            Text(m.working ?? "Working on it…").foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(2).transition(
                                .opacity)
                        }
                        if m.openHelper == nil { UpdateCard() }
                        if m.openHelper == nil, let inv = m.roomInvites.first, let info = Shared.info(inv) {
                            VStack(alignment: .leading, spacing: 12) {
                                Label("\(info.createdBy) invited you into a room", systemImage: "person.2.fill").font(.headline)
                                Text(
                                    "\"\(info.title)\": a room you both add to, each with your own assistant. It stays in sync through iCloud. Nothing from your other rooms goes in without your OK."
                                )
                                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                HStack(spacing: 8) {
                                    Button("Add it to my brain") { m.joinRoom(inv) }
                                        .buttonStyle(.borderedProminent).tint(Color(hex: 0xF4EFE8)).foregroundStyle(Color(hex: 0x141416))
                                    Button("Not now") {
                                        Shared.leave(inv)
                                        m.roomInvites.removeAll { $0 == inv }
                                    }.buttonStyle(.bordered)
                                }
                            }
                            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial))
                        }
                        if m.openHelper == nil && !m.interviewOffered && !m.thinking && Brain.exists {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Want me to get to know you?").font(.headline)
                                Text(
                                    "A few questions, one at a time, so I know what your personal room is for and how to help. You can skip any question, or stop whenever you like."
                                )
                                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                HStack(spacing: 8) {
                                    Button("Let's start") {
                                        m.interviewOffered = true
                                        Task { await m.send("Let's do the welcome interview. Get to know me.", toNova: true) }
                                    }
                                    .buttonStyle(.borderedProminent).tint(Color(hex: 0xF4EFE8)).foregroundStyle(Color(hex: 0x141416))
                                    Button("Maybe later") {
                                        m.interviewOffered = true
                                        m.bubbles.append(Bubble(fromMe: false, text: "Any time. Just say \"get to know me\"."))
                                    }.buttonStyle(.bordered)
                                }
                            }
                            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial))
                        }
                        if m.openHelper == nil, case let away = m.helpers.filter({ $0.finishedAway }), !away.isEmpty {
                            AwayCard(m: m, hs: away).transition(.opacity)
                        }
                        if !m.asks.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("NEEDS YOUR YES").font(.caption.bold()).foregroundStyle(.orange)
                                ForEach(m.asks) { a in AskCard(a: a) { m.answer(a, $0) } }
                            }
                        }
                        if let h = m.openedHelper {
                            HelperCard(m: m, h: h).transition(.opacity.combined(with: .offset(y: 8)))
                        } else if let ask = lastAsk {
                            VStack(spacing: 12) {
                                Text(ask.text).font(.callout).foregroundStyle(Color.accentColor).multilineTextAlignment(.center)
                                if let r = lastReply, !r.text.isEmpty {
                                    let parts = Choices.split(Helpers.strip(r.text))
                                    MarkdownText(text: parts.body, size: 16)
                                        .frame(maxWidth: .infinity, alignment: .leading).padding(18)
                                        .background(RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial))
                                        .id(r.id).transition(.opacity.combined(with: .offset(y: 10)))
                                    if !parts.choices.isEmpty && !m.thinking {
                                        ChoiceRow(choices: parts.choices, disabled: m.paused) { c in
                                            Task { await m.send(c) }
                                        } onOther: {
                                            typing = true
                                        }
                                        .transition(.opacity)
                                    }
                                }
                            }.animation(.easeOut(duration: 0.9), value: lastReply?.text.isEmpty)
                        }
                        askBox.padding(.top, 4)
                        if !tryShown {
                            Button {
                                tryHidden = false
                                firstHome = Date().timeIntervalSince1970
                            } label: {
                                Label("Ideas to try", systemImage: "lightbulb")
                            }
                            .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text(lastAsk == nil ? "THINGS ONLY I CAN DO FROM YOUR MAC" : "TRY SOMETHING ELSE")
                                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    Spacer()
                                    Button {
                                        withAnimation { tryHidden = true }
                                    } label: {
                                        Image(systemName: "xmark").font(.caption.weight(.semibold))
                                    }
                                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Hide these. Bring them back with Ideas to try.")
                                }
                                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                                    ForEach(tryItems, id: \.self) { it in
                                        Button {
                                            Task { await m.send(it.text) }
                                        } label: {
                                            VStack(alignment: .leading, spacing: 8) {
                                                HStack(spacing: 6) {
                                                    Image(systemName: it.symbol).font(.system(size: 14, weight: .light))
                                                    Text(it.tag.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                                                }
                                                Text(it.text).font(.callout).multilineTextAlignment(.leading).foregroundStyle(.primary)
                                            }
                                            .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading).padding(12)
                                            .background(RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial))
                                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.12)))
                                        }.buttonStyle(.plain).disabled(m.thinking || m.paused)
                                    }
                                }
                            }
                        }
                    }.padding(.horizontal, 28).padding(.bottom, 20)
                }
            }
            if !m.shelf.isEmpty {
                if shelfCollapsed {
                    Button {
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { shelfCollapsed = false }
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                            Image(systemName: "tray.full").font(.system(size: 13))
                            let fresh = m.shelf.filter(\.fresh).count
                            if fresh > 0 {
                                Text("\(fresh)").font(.system(size: 10, weight: .bold)).foregroundStyle(Color(hex: 0x141416)).padding(4).background(
                                    Circle().fill(Color(hex: 0xFFE2C2)))
                            }
                        }.foregroundStyle(.secondary).frame(width: 30).frame(maxHeight: .infinity).contentShape(Rectangle())
                    }.buttonStyle(.plain).background(Mist()).help("Show Ready for you").transition(.move(edge: .trailing))
                } else {
                    ShelfPanel(m: m).background(Mist()).overlay(alignment: .topTrailing) {
                        Button {
                            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { shelfCollapsed = true }
                        } label: {
                            Image(systemName: "sidebar.right").font(.system(size: 12))
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary).padding(.top, 14).padding(.trailing, 14).help("Hide Ready for you")
                    }.transition(.move(edge: .trailing))
                }
            }
        }
        .frame(minWidth: m.shelf.isEmpty || shelfCollapsed ? 560 : 830)
        .animation(.spring(response: 0.6, dampingFraction: 0.85), value: m.shelf.isEmpty)
        .overlay {
            if let id = m.openedShelf, let it = m.shelf.first(where: { $0.id == id }) {
                ShelfOpened(m: m, item: it).transition(.opacity)
            }
        }
        .overlay { if let u = m.viewing { FileViewer(m: m, url: u).transition(.opacity) } }
        .environment(
            \.openURL,
            OpenURLAction { u in
                var f: URL? = u.isFileURL ? u : nil
                if f == nil, u.scheme == nil, u.path.hasPrefix("/") { f = URL(fileURLWithPath: u.path) }
                if let f, FileViewer.readable.contains(f.pathExtension.lowercased()) {
                    m.viewing = f
                    return .handled
                }
                if let f {
                    NSWorkspace.shared.activateFileViewerSelecting([f])
                    return .handled
                }
                return .systemAction
            }
        )
        .onChange(of: m.draftSeed) { _, v in
            if let v {
                if !v.isEmpty { draft = v }
                m.draftSeed = nil
                typing = true
            }
        }
        .safeAreaInset(edge: .bottom) {
            if m.paused {
                Text("Stopped. I won't do anything until you turn me back on.")
                    .font(.callout).padding(8).frame(maxWidth: .infinity).background(Color.red.opacity(0.15))
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    voiceOff.toggle()
                    if voiceOff {
                        Speaker.shared.stop()
                        Voice.shared.stop()
                    }
                } label: {
                    Label(voiceOff ? "Voice off" : "Voice on", systemImage: voiceOff ? "speaker.slash" : "speaker.wave.2")
                }.help(voiceOff ? "Let \(m.name) talk" : "Stop \(m.name) from talking")
            }
            ToolbarItem(placement: .navigation) {
                Button {
                    meCard = true
                } label: {
                    Text(m.name).font(.headline)
                }.buttonStyle(.plain).help("\(m.name)'s brain and voice")
            }
            ToolbarItem {
                Button {
                    roomsSheet = true
                } label: {
                    Label("Rooms", systemImage: "circle.hexagongrid")
                }.help("See your rooms")
            }
            ToolbarItem {
                Button {
                    connectionsSheet = true
                } label: {
                    Label("Connections", systemImage: "point.3.connected.trianglepath.dotted")
                }.help("What \(m.name) can reach")
            }
            ToolbarItem {
                Button {
                    talkKeySheet = true
                } label: {
                    Label("Push to talk", systemImage: "mic")
                }.help("Choose a push-to-talk key")
            }
            ToolbarItem {
                Button {
                    folderSheet = true
                } label: {
                    Label("Folders", systemImage: "folder")
                }
            }
            ToolbarItem {
                Button {
                    m.switchingAI = true
                } label: {
                    Label("Switch AI", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            ToolbarItem {
                Button {
                    m.toggleStop()
                } label: {
                    Label(m.paused ? "Turn on" : "Stop", systemImage: m.paused ? "play.circle" : "stop.circle")
                }.tint(m.paused ? .green : .red)
            }
        }
        .navigationTitle("")
        .sheet(isPresented: $folderSheet) { FolderSheet(m: m) { folderSheet = false } }
        .sheet(isPresented: $talkKeySheet) { TalkKeySheet { talkKeySheet = false } }
        .sheet(isPresented: $roomsSheet) { RoomsView(m: m) { roomsSheet = false } }
        .sheet(isPresented: $connectionsSheet) { ConnectionsWorld(m: m) { connectionsSheet = false }.frame(width: 720, height: 680) }
        .popover(isPresented: $meCard, arrowEdge: .bottom) { MeCard(m: m) { meCard = false } }
        .onDrop(of: [.fileURL, .image], isTargeted: $dropping) { PictureIn.drop($0) }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 18).strokeBorder(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .overlay(
                        Text("Drop pictures or files here").font(.title3.weight(.medium)).padding(12).background(Capsule().fill(.ultraThinMaterial))
                    )
                    .padding(10).allowsHitTesting(false)
            }
        }
        .task { await m.ensureEngine() }
    }
    /// Hold the mic to talk (let go to send), or click once to start and again to send.
    var micButton: some View {
        let on = m.talkingInApp
        return ZStack {
            if on { Circle().fill(Color(hex: 0xFFE2C2, 0.18)).frame(width: 40 + 14 * l.level, height: 40 + 14 * l.level) }
            Image(systemName: on ? "mic.fill" : "mic").font(.system(size: 20, weight: on ? .regular : .light))
                .foregroundStyle(on ? Color(hex: 0xFFE2C2) : Color.primary)
        }
        .frame(width: 34, height: 34).contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard micDownAt == nil else { return }
                    micDownAt = Date()
                    if micLatched { return }
                    m.talkBegin()
                }
                .onEnded { _ in
                    let held = Date().timeIntervalSince(micDownAt ?? Date())
                    micDownAt = nil
                    if micLatched {
                        micLatched = false
                        m.talkEnd()
                        return
                    }
                    if held < 0.35 && m.talkingInApp {
                        micLatched = true
                        return
                    }  // a click: keep listening until the next click
                    m.talkEnd()
                }
        )
        .help("Hold to talk, or click to start and click again to send")
        .disabled(m.paused)
        .animation(.easeOut(duration: 0.12), value: l.level)
    }
    @ViewBuilder var talkLine: some View {
        if m.talkingInApp {
            HStack(spacing: 8) {
                Image(systemName: "waveform").foregroundStyle(Color(hex: 0xFFE2C2))
                Text(l.text.isEmpty ? "I'm listening…" : l.text).lineLimit(3)
                Spacer()
                Text(micLatched ? "Click the mic to send" : "Let go to send").font(.callout).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.ultraThinMaterial))
            .transition(.opacity)
        } else if let n = l.problem ?? m.talkNote {
            Text(n).font(.callout).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
                .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 6) { if m.talkNote == n { m.talkNote = nil } } }
        }
    }
    var askBox: some View {
        VStack(spacing: 8) {
            talkLine
            PictureStrip(m: m)
            HStack(spacing: 12) {
                Button {
                    PictureIn.pick()
                } label: {
                    Image(systemName: "paperclip").font(.system(size: 20, weight: .light))
                }
                .buttonStyle(.plain).help("Add a picture or file (or drag it in, or paste it)").disabled(m.paused)
                TextField(
                    m.about != nil
                        ? "What do you want to know? Or just press send."
                        : m.openedHelper.map { "Talk to \($0.title)…" } ?? (lastAsk == nil ? "Tell \(m.name) what you need…" : "Or say it your way…"),
                    text: $draft
                )
                .textFieldStyle(.plain).font(.title3).focused($typing)
                .padding(12).padding(.horizontal, 4).background(Capsule().fill(.ultraThinMaterial))
                .overlay(Capsule().stroke(Color.white.opacity(typing ? 0.28 : 0.1)))
                .onSubmit(go).disabled(m.paused)
                micButton
                Button(action: go) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 32, weight: .light)) }
                    .buttonStyle(.plain).disabled(
                        m.paused || m.busyHere || (draft.isEmpty && m.pictures.isEmpty && m.files.isEmpty && m.about == nil))
            }
        }
    }
    func go() {
        let t = draft
        draft = ""
        Task { await m.send(t) }
    }
}

/// The assistant's suggested answers as buttons, plus a way to just say something else.
struct ChoiceRow: View {
    let choices: [String]
    var disabled = false
    let pick: (String) -> Void
    var onOther: () -> Void = {}
    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(choices.enumerated()), id: \.offset) { i, c in
                Button {
                    pick(c)
                } label: {
                    Text(c).font(.callout.weight(i == 0 ? .semibold : .regular))
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .foregroundStyle(i == 0 ? WorldLook.bg : .primary)
                        .background(Capsule().fill(i == 0 ? WorldLook.cream : Color.white.opacity(0.08)))
                        .overlay(Capsule().stroke(Color.white.opacity(i == 0 ? 0 : 0.16)))
                }.buttonStyle(.plain)
            }
            Button(action: onOther) {
                Text("Something else…").font(.callout).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 9)
            }.buttonStyle(.plain)
            Spacer(minLength: 0)
        }.disabled(disabled)
    }
}

struct AskCard: View {
    let a: Ask
    let answer: (String?) -> Void
    func isNo(_ id: String) -> Bool { id.hasPrefix("deny") || id.hasPrefix("reject") }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(a.question).font(.headline)
            HStack {
                ForEach(a.options, id: \.0) { o in
                    Button(o.0 == "allow_once" ? "Yes" : (isNo(o.0) ? "No" : o.1)) { answer(o.0) }
                        .buttonStyle(.borderedProminent).tint(isNo(o.0) ? .gray : .accentColor)
                }
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.orange.opacity(0.12)))
    }
}
