import SwiftUI

// MARK: - The ask box ("Or say it your way…"), on its own
//
// What is being typed (`AskDraft`) used to be `@State` on HomeView, so every keystroke ran the whole home screen's body
// again: the chat, the helper orbs, the bots, the shelf. Omar, Nov 18 2026: "every time I type it lags". Now the text
// lives in `AskDraft`, which only this box (and the bigger writing space, `WritingPanelHost`) watches: a keystroke
// redraws the box and nothing else. Measured by `One --test-smooth` (SmoothCheck.swift).

/// The words in the ask box. Watched only by the box itself and the writing panel, never by HomeView.
@MainActor
final class AskDraft: ObservableObject {
    @Published var text: String
    init(_ text: String = "") { self.text = text }
    /// Send what was typed (the box clears at once; the message goes through `Model.send`).
    func send(_ m: Model) {
        guard m.isReady else { return }  // getting ready: the box can't send (StartupGate.swift)
        let t = text
        text = ""
        m.writingPanel = false
        Task { await m.send(t) }
    }
}

/// The bigger space to write in, watching the same words.
struct WritingPanelHost: View {
    @ObservedObject var m: Model
    @ObservedObject var ask: AskDraft
    let close: () -> Void
    let send: () -> Void
    var body: some View { WritingPanel(m: m, draft: $ask.text, close: close, send: send) }
}

struct AskBox: View {
    @ObservedObject var m: Model
    @ObservedObject var ask: AskDraft
    @Binding var typing: Bool
    let windowHeight: CGFloat
    @StateObject var askMetrics = AskBox.makeMetrics()
    @AppStorage(Glass.key) var solid = Glass.standard
    @ObservedObject var l = Listener.shared
    @State var micDownAt: Date?
    @State var micLatched = false
    var lastAsk: Bubble? { m.bubbles.last(where: { $0.fromMe }) }
    var body: some View { askBox }
    /// Hold the mic to talk (let go to send), or click once to start and again to send.
    var micButton: some View {
        let on = m.talkingInApp
        return ZStack {
            if on { Circle().fill(Color(hex: 0xFFE2C2, 0.18)).frame(width: 40 + 14 * l.level, height: 40 + 14 * l.level) }
            Circle().fill(WorldLook.cream.opacity(on ? 0.16 : 0.08)).frame(width: 36, height: 36)
            Image(systemName: on ? "mic.fill" : "mic").font(.system(size: 15, weight: .regular))
                .foregroundStyle(on ? Color(hex: 0xFFE2C2) : WorldLook.cream.opacity(0.85))
        }
        .frame(width: 36, height: 36).contentShape(Circle())
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
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    Button("File…") { PictureIn.pick() }
                    Button("Photo…") { PictureIn.pickPhoto() }
                    Button("Screenshot") { PictureIn.screenshot() }
                    Button("Folder…") { m.folderSheet = true }
                } label: {
                    Image(systemName: "plus").font(.system(size: 16, weight: .regular)).foregroundStyle(WorldLook.cream.opacity(0.6))
                        .frame(width: 36, height: 36).contentShape(Circle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().disabled(!m.isReady)
                .help("Add a file or photo (or drag it in, or paste it)")
                let hint: String =
                    !m.isReady
                    ? GateWords.box
                    : m.about != nil
                        ? "What do you want to know? Or just press send."
                        : m.openedHelper.map { $0.bot == nil ? "Talk to \($0.title)…" : "Tell \($0.title)…" }
                            ?? (lastAsk == nil ? "Tell \(m.name) what you need…" : "Or say it your way…")
                if !m.isReady {
                    // Getting ready: nothing can be typed until One opens (what was typed before stays, dimmed).
                    Text(ask.text.isEmpty ? hint : ask.text).font(.system(size: 14)).foregroundStyle(
                        WorldLook.cream.opacity(ask.text.isEmpty ? 0.4 : 0.5)
                    )
                    .lineLimit(1).truncationMode(.head).frame(maxWidth: .infinity, alignment: .leading).frame(height: 36)
                } else if HomeView.still && ask.text.isEmpty {
                    Text(hint).font(.system(size: 14)).foregroundStyle(WorldLook.cream.opacity(0.4)).frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 36)
                } else {
                    AskField(text: $ask.text, focused: $typing, metrics: askMetrics, hint: hint, maxHeight: askMax, onSubmit: { ask.send(m) })
                }
                if m.isReady && !(ask.text.isEmpty && m.pictures.isEmpty && m.files.isEmpty && m.about == nil) {
                    // Never locked while busy: a message sent now goes into the running turn, or next up.
                    Button {
                        ask.send(m)
                    } label: {
                        Image(systemName: "arrow.up").font(.system(size: 14, weight: .semibold)).foregroundStyle(WorldLook.bg)
                            .frame(width: 36, height: 36).background(Circle().fill(WorldLook.cream))
                    }
                    .buttonStyle(.plain).help("Send").transition(.scale.combined(with: .opacity))
                }
                micButton.disabled(!m.isReady).opacity(m.isReady ? 1 : 0.45)
            }
            .padding(8)
            .opacity(m.isReady ? 1 : 0.6)
            .animation(.easeOut(duration: 0.4), value: m.isReady)
            .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(WorldLook.cream.opacity(0.06)))
            .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color(hex: 0x1C1C20, Glass.thin(solid) ? 0.6 : 0)))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(WorldLook.cream.opacity(typing ? 0.2 : 0.09)))
            .overlay(alignment: .topTrailing) {
                if !ask.text.isEmpty && askMetrics.contentHeight > AskEditor.oneLine + 3 * 17 {
                    Button {
                        m.writingPanel = true
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 12, weight: .medium))
                            .foregroundStyle(WorldLook.cream.opacity(0.7)).frame(width: 28, height: 28)
                            .background(Circle().fill(WorldLook.cream.opacity(0.08)))
                    }
                    .buttonStyle(.plain).help("Open a bigger space to write").padding(.top, 10).padding(.trailing, 12)
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: 620)
            .animation(.easeOut(duration: 0.15), value: ask.text.isEmpty)
            if askMetrics.contentHeight > AskEditor.oneLine + 1 && !ask.text.isEmpty {
                HStack {
                    Text("Shift + Return for a new line")
                    Spacer()
                    if case let n = AskField.words(ask.text), n > 100 { Text("\(n) words") }
                }
                .font(.system(size: 11)).foregroundStyle(WorldLook.cream.opacity(0.4)).padding(.horizontal, 20).frame(maxWidth: 620)
            }
        }
    }
    /// The box grows up to about half the window, then scrolls inside.
    var askMax: CGFloat { max(AskEditor.oneLine, windowHeight * 0.5 - 16) }
    static func makeMetrics() -> AskMetrics {
        let a = AskMetrics()
        if HomeView.still && !HomeView.stillDraft.isEmpty {
            a.contentHeight = AskField.stillHeight(HomeView.stillDraft, width: 620 - 16 - 36 * 3 - 8 * 3)
        }
        return a
    }
}
