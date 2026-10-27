import AppKit
import SwiftUI

// MARK: - The window in front: a live view of the hidden browser's own tab
//
// The shared browser runs hidden (and keeps its saved sign-ins), so it can't open a window of its own
// without being restarted. Instead One connects to the very tab that asks for the step (Chrome's
// DevTools port on this Mac), streams its picture, and passes clicks, typing, paste and scrolling back
// to it. Same browser, same tab, same session: what the person types lands on the real page.

@MainActor
final class StepWindow: NSObject, NSWindowDelegate {
    let ask: HumanStepAsk
    let answer: (String) -> Void
    let page: StepPage
    var window: NSWindow?

    init(_ a: HumanStepAsk, answer: @escaping (String) -> Void) {
        ask = a
        self.answer = answer
        page = StepPage(port: a.port, target: a.target)
    }

    func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1040, height: 780), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered, defer: false)
            w.title = "\(ask.site): \(HumanStep.asking[ask.kind] ?? "a quick check")"
            w.isReleasedWhenClosed = false
            w.level = .floating
            w.delegate = self
            w.contentView = NSHostingView(
                rootView: StepWindowView(ask: ask, page: page) { [weak self] a in self?.answer(a) }.environment(\.colorScheme, .dark))
            w.center()
            window = w
            page.connect()
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        page.canvas.window?.makeFirstResponder(page.canvas)
    }

    func close() {
        page.disconnect()
        window?.delegate = nil
        window?.close()
        window = nil
    }

    /// Closing the window isn't an answer: the card in the chat stays, with "Show the window".
    func windowWillClose(_ notification: Notification) {
        page.disconnect()
        window = nil
    }
}

struct StepWindowView: View {
    let ask: HumanStepAsk
    @ObservedObject var page: StepPage
    let answer: (String) -> Void
    var body: some View {
        VStack(spacing: 0) {
            StepCanvasHost(canvas: page.canvas).frame(minWidth: 480, minHeight: 360)
                .overlay {
                    if page.frames == 0 {
                        Text(page.problem ?? "Opening \(ask.site)…").foregroundStyle(.secondary)
                    }
                }
            HStack(spacing: 12) {
                Text(ask.line).font(.callout).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Done") { answer("done") }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                Button("I'm not at the Mac") { answer("away") }.buttonStyle(.bordered)
            }
            .padding(12).background(.ultraThinMaterial)
        }
    }
}

struct StepCanvasHost: NSViewRepresentable {
    let canvas: StepCanvas
    func makeNSView(context: Context) -> StepCanvas { canvas }
    func updateNSView(_ v: StepCanvas, context: Context) {}
}

/// One tab of the local browser, over its DevTools socket.
@MainActor
final class StepPage: ObservableObject {
    let port: Int
    let target: String
    let canvas = StepCanvas()
    @Published var frames = 0
    @Published var problem: String?
    /// The page's size in its own (CSS) pixels, from the last picture.
    var pageSize = CGSize(width: 1, height: 1)
    private var socket: URLSessionWebSocketTask?
    private var nextID = 100
    private var replies: [Int: CheckedContinuation<[String: Any], Never>] = [:]

    init(port: Int, target: String) {
        self.port = port
        self.target = target
        canvas.page = self
    }

    func connect() {
        guard socket == nil, let u = URL(string: "ws://127.0.0.1:\(port)/devtools/page/\(target)") else { return }
        let s = URLSession(configuration: .ephemeral).webSocketTask(with: u)
        s.maximumMessageSize = 32 << 20
        socket = s
        s.resume()
        listen(s)
        send("Page.enable")
        send("Page.bringToFront")
        send("Page.startScreencast", ["format": "jpeg", "quality": 80, "everyNthFrame": 1])
    }

    func disconnect() {
        guard let s = socket else { return }
        send("Page.stopScreencast")
        socket = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { s.cancel(with: .goingAway, reason: nil) }
        for (_, c) in replies { c.resume(returning: [:]) }
        replies.removeAll()
    }

    private func listen(_ s: URLSessionWebSocketTask) {
        s.receive { [weak self] result in
            switch result {
            case .success(let m):
                var text = ""
                if case .string(let t) = m { text = t } else if case .data(let d) = m { text = String(decoding: d, as: UTF8.self) }
                Task { @MainActor in
                    self?.handle(text)
                    if self?.socket === s { self?.listen(s) }
                }
            case .failure(let e):
                Task { @MainActor in
                    guard let self, self.socket === s else { return }
                    self.problem = "The page couldn't be shown (\(e.localizedDescription))."
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let j = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return }
        if let id = j["id"] as? Int, let c = replies.removeValue(forKey: id) {
            c.resume(returning: j["result"] as? [String: Any] ?? [:])
            return
        }
        guard j["method"] as? String == "Page.screencastFrame", let p = j["params"] as? [String: Any] else { return }
        if let sid = p["sessionId"] { send("Page.screencastFrameAck", ["sessionId": sid]) }
        if let md = p["metadata"] as? [String: Any], let w = md["deviceWidth"] as? Double, let h = md["deviceHeight"] as? Double, w > 0, h > 0 {
            pageSize = CGSize(width: w, height: h)
        }
        if let b = p["data"] as? String, let d = Data(base64Encoded: b), let img = NSImage(data: d) {
            canvas.image = img
            canvas.needsDisplay = true
            frames += 1
        }
    }

    func send(_ method: String, _ params: [String: Any] = [:]) {
        nextID += 1
        write(nextID, method, params)
    }

    /// Sends and waits for the answer (used for typing in order, and by the check).
    @discardableResult func call(_ method: String, _ params: [String: Any] = [:]) async -> [String: Any] {
        nextID += 1
        let id = nextID
        guard socket != nil else { return [:] }
        return await withCheckedContinuation { c in
            replies[id] = c
            write(id, method, params)
        }
    }

    private func write(_ id: Int, _ method: String, _ params: [String: Any]) {
        guard let s = socket, let d = try? JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params]) else { return }
        s.send(.string(String(decoding: d, as: UTF8.self))) { _ in }
    }

    // What the person does in the window, passed to the page.

    func mouse(_ type: String, at p: CGPoint, clicks: Int = 1) {
        send(
            "Input.dispatchMouseEvent",
            ["type": type, "x": p.x, "y": p.y, "button": "left", "buttons": type == "mouseReleased" ? 0 : 1, "clickCount": clicks])
    }

    func move(to p: CGPoint) { send("Input.dispatchMouseEvent", ["type": "mouseMoved", "x": p.x, "y": p.y]) }

    func wheel(at p: CGPoint, dx: Double, dy: Double) {
        send("Input.dispatchMouseEvent", ["type": "mouseWheel", "x": p.x, "y": p.y, "deltaX": dx, "deltaY": dy])
    }

    func type(_ text: String) {
        for ch in text.map(String.init) {
            send("Input.dispatchKeyEvent", ["type": "keyDown", "text": ch, "unmodifiedText": ch, "key": ch])
            send("Input.dispatchKeyEvent", ["type": "keyUp", "key": ch])
        }
    }

    func paste(_ text: String) { send("Input.insertText", ["text": text]) }

    /// Keys that don't type a letter: (key, code, Windows key code).
    static let special: [UInt16: (String, String, Int)] = [
        51: ("Backspace", "Backspace", 8), 117: ("Delete", "Delete", 46), 36: ("Enter", "Enter", 13), 76: ("Enter", "NumpadEnter", 13),
        48: ("Tab", "Tab", 9), 53: ("Escape", "Escape", 27), 123: ("ArrowLeft", "ArrowLeft", 37), 124: ("ArrowRight", "ArrowRight", 39),
        125: ("ArrowDown", "ArrowDown", 40), 126: ("ArrowUp", "ArrowUp", 38), 115: ("Home", "Home", 36), 119: ("End", "End", 35),
    ]

    func key(_ code: UInt16, shift: Bool) {
        guard let k = StepPage.special[code] else { return }
        var down: [String: Any] = [
            "type": k.0 == "Enter" ? "keyDown" : "rawKeyDown", "key": k.0, "code": k.1, "windowsVirtualKeyCode": k.2, "nativeVirtualKeyCode": k.2,
            "modifiers": shift ? 8 : 0,
        ]
        if k.0 == "Enter" { down["text"] = "\r" }
        send("Input.dispatchKeyEvent", down)
        send("Input.dispatchKeyEvent", ["type": "keyUp", "key": k.0, "code": k.1, "windowsVirtualKeyCode": k.2, "nativeVirtualKeyCode": k.2])
    }
}

/// Draws the page and turns mouse and keys into the page's own events.
final class StepCanvas: NSView {
    weak var page: StepPage?
    var image: NSImage?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Where the picture sits in the view (fitted, centred).
    var shown: CGRect {
        guard let s = page?.pageSize, s.width > 1 else { return bounds }
        let k = min(bounds.width / s.width, bounds.height / s.height)
        let w = s.width * k
        let h = s.height * k
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    override func draw(_ dirty: NSRect) {
        NSColor(white: 0.08, alpha: 1).setFill()
        bounds.fill()
        image?.draw(in: shown, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    /// A point in this view, in the page's own pixels.
    func pagePoint(_ e: NSEvent) -> CGPoint { pagePoint(convert(e.locationInWindow, from: nil)) }
    func pagePoint(_ v: CGPoint) -> CGPoint {
        let r = shown
        guard let s = page?.pageSize, r.width > 0 else { return v }
        return CGPoint(x: (v.x - r.minX) * s.width / r.width, y: (v.y - r.minY) * s.height / r.height)
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        MainActor.assumeIsolated { page?.mouse("mousePressed", at: pagePoint(e), clicks: e.clickCount) }
    }
    override func mouseUp(with e: NSEvent) { MainActor.assumeIsolated { page?.mouse("mouseReleased", at: pagePoint(e), clicks: e.clickCount) } }
    override func mouseDragged(with e: NSEvent) { MainActor.assumeIsolated { page?.move(to: pagePoint(e)) } }
    override func scrollWheel(with e: NSEvent) {
        MainActor.assumeIsolated { page?.wheel(at: pagePoint(e), dx: -Double(e.scrollingDeltaX), dy: -Double(e.scrollingDeltaY)) }
    }

    override func keyDown(with e: NSEvent) {
        MainActor.assumeIsolated {
            guard let page else { return }
            if e.modifierFlags.contains(.command) {
                if e.charactersIgnoringModifiers == "v", let t = NSPasteboard.general.string(forType: .string) { page.paste(t) }
                return
            }
            if StepPage.special[e.keyCode] != nil {
                page.key(e.keyCode, shift: e.modifierFlags.contains(.shift))
            } else if let t = e.characters, !t.isEmpty, t.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) {
                page.type(t)
            }
        }
    }

    /// ⌘V reaches the page even though the window has no Edit menu of its own.
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard window?.firstResponder === self, e.modifierFlags.contains(.command), e.charactersIgnoringModifiers == "v" else { return false }
        keyDown(with: e)
        return true
    }
}
