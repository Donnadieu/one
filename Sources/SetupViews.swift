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
