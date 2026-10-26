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

// MARK: - Voice (pre-recorded Kokoro lines: fallback until the live voice is ready)

@MainActor
final class Voice {
    static let shared = Voice()
    private var player: AVAudioPlayer?
    var muted: Bool {
        get { UserDefaults.standard.bool(forKey: "voiceMuted") }
        set {
            UserDefaults.standard.set(newValue, forKey: "voiceMuted")
            if newValue {
                player?.stop()
                Speaker.shared.stop()
            }
        }
    }
    /// Plays a line and returns how long it lasts (0 if muted or missing).
    @discardableResult
    func play(_ key: String) -> Double {
        guard !muted, let url = Bundle.main.url(forResource: key, withExtension: "mp3") else { return 0 }
        Speaker.shared.hush()
        return Speaker.shared.enqueue(url)
    }
    func stop() { Speaker.shared.hush() }
}

// MARK: - Live voice (Kokoro, free and on this Mac): says anything, including names, in the same voice as setup.

final class Speaker: @unchecked Sendable {
    static let shared = Speaker()
    private var proc: Process?
    private var input: FileHandle?
    private var waiting: [String: (URL?, Double) -> Void] = [:]
    private let q = DispatchQueue(label: "one.speaker")
    private var buf = ""
    private(set) var ready = false
    // One always-running audio line, so Bluetooth speakers/headphones never fall asleep
    // and swallow the first words. Nothing is heard while idle (it plays silence).
    private let audio = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let fmt = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
    private var audioUp = false
    private var endsAt = Date.distantPast
    private var queue: [(String, Int)] = []  // (text, generation)
    private var gen = 0
    private var playing = false
    var dir: URL { Env.support.appendingPathComponent("voice", isDirectory: true) }
    var installed: Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent(".ready").path) }

    /// Downloads the voice once (about 350 MB), next to One's engine. Safe to call again.
    func install() async -> Bool {
        if installed { return true }
        guard let script = Bundle.main.url(forResource: "install_voice", withExtension: "sh") else { return false }
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/bash")
                p.arguments = [script.path, Env.support.path]
                p.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "TMPDIR": NSTemporaryDirectory()]
                let log = Env.support.appendingPathComponent("voice-install.log")
                FileManager.default.createFile(atPath: log.path, contents: nil)
                if let h = try? FileHandle(forWritingTo: log) {
                    p.standardOutput = h
                    p.standardError = h
                }
                do { try p.run() } catch {
                    cont.resume(returning: false)
                    return
                }
                p.waitUntilExit()
                cont.resume(returning: p.terminationStatus == 0)
            }
        }
    }

    /// Main thread. Starts (or restarts) the audio line.
    func wakeAudio() {
        if !audioUp {
            audioUp = true
            audio.attach(node)
            audio.connect(node, to: audio.mainMixerNode, format: fmt)
            NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: audio, queue: .main) { [weak self] _ in
                self?.rebuild()
            }
        }
        if !audio.isRunning {
            audio.prepare()
            try? audio.start()
        }
        if !node.isPlaying { node.play() }
        routeRate = audio.outputNode.outputFormat(forBus: 0).sampleRate
    }
    private var routeRate: Double = 0
    /// Loudness of what is queued on the audio line, by the time it's heard.
    private var track = VoiceTrack()
    /// Main thread. The voice as the person hears it right now: the speaker's own delay (Bluetooth is
    /// ~0.2 s) is taken off, so the orb moves with the sound, not with the text or the file.
    func heard() -> VoiceWave {
        guard audioUp, !track.clips.isEmpty else { return .still }
        return track.wave(at: Date().addingTimeInterval(-audio.outputNode.presentationLatency))
    }
    var state: String { "engine=\(audio.isRunning) node=\(node.isPlaying) rate=\(audio.outputNode.outputFormat(forBus: 0).sampleRate)" }
    /// Main thread. Rebuilds the audio line from scratch. Bluetooth headsets switch to "call mode" while the mic
    /// is on and back afterwards; the old line can stay bound to the call-mode output and play into nothing.
    func rebuild() {
        node.stop()
        audio.stop()
        audio.disconnectNodeOutput(node)
        audio.reset()
        audio.connect(node, to: audio.mainMixerNode, format: fmt)
        endsAt = .distantPast
        audio.prepare()
        try? audio.start()
        node.play()
        routeRate = audio.outputNode.outputFormat(forBus: 0).sampleRate
    }
    /// Main thread. Before speaking: if the output changed under us (headset mode, new device), rebuild.
    func ensureRoute() {
        guard audioUp else {
            wakeAudio()
            return
        }
        let now = audio.outputNode.outputFormat(forBus: 0).sampleRate
        if !audio.isRunning || !node.isPlaying || now != routeRate { rebuild() }
    }
    private func buffer(_ url: URL) -> AVAudioPCMBuffer? {
        guard let f = try? AVAudioFile(forReading: url),
            let inBuf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)),
            (try? f.read(into: inBuf)) != nil
        else { return nil }
        if f.processingFormat == fmt { return inBuf }
        guard let conv = AVAudioConverter(from: f.processingFormat, to: fmt) else { return nil }
        let cap = AVAudioFrameCount(Double(inBuf.frameLength) * fmt.sampleRate / f.processingFormat.sampleRate) + 2048
        guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else { return nil }
        var given = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if given {
                status.pointee = .endOfStream
                return nil
            }
            given = true
            status.pointee = .haveData
            return inBuf
        }
        return err == nil ? out : nil
    }
    /// Main thread. Queues a sound right after whatever is playing; returns its length.
    @discardableResult
    func enqueue(_ url: URL) -> Double {
        if Date() >= endsAt { ensureRoute() } else { wakeAudio() }
        guard let b = buffer(url) else { return 0 }
        let d = Double(b.frameLength) / fmt.sampleRate
        let starts = max(endsAt, Date())
        node.scheduleBuffer(b, completionHandler: nil)
        track.add(b, at: starts)
        endsAt = starts.addingTimeInterval(d)
        return d
    }
    /// Main thread. Silences now but keeps the line awake.
    func hush() {
        guard stand == nil else { return }  // self-tests never touch the audio line
        node.stop()
        track.clips = []
        endsAt = .distantPast
        wakeAudio()
    }

    func start() {
        DispatchQueue.main.async { self.wakeAudio() }
        q.async {
            guard self.proc == nil, self.installed, let script = Bundle.main.url(forResource: "speak", withExtension: "py") else { return }
            let p = Process()
            p.executableURL = self.dir.appendingPathComponent("venv/bin/python")
            p.arguments = ["-I", script.path, self.dir.path, Speaker.voiceID]
            let i = Pipe()
            let o = Pipe()
            p.standardInput = i
            p.standardOutput = o
            p.standardError = FileHandle.nullDevice
            o.fileHandleForReading.readabilityHandler = { [weak self] h in
                let d = h.availableData
                guard let self, !d.isEmpty else { return }
                self.q.async {
                    self.buf += String(decoding: d, as: UTF8.self)
                    while let nl = self.buf.firstIndex(of: "\n") {
                        let line = String(self.buf[..<nl])
                        self.buf = String(self.buf[self.buf.index(after: nl)...])
                        guard let j = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let id = j["id"] as? String else {
                            continue
                        }
                        if id == "ready" {
                            self.ready = true
                            continue
                        }
                        let cb = self.waiting.removeValue(forKey: id)
                        let url = (j["path"] as? String).map { URL(fileURLWithPath: $0) }
                        cb?(url, j["dur"] as? Double ?? 0)
                    }
                }
            }
            p.terminationHandler = { [weak self] _ in
                self?.q.async {
                    self?.proc = nil
                    self?.ready = false
                    for (_, cb) in self?.waiting ?? [:] { cb(nil, 0) }
                    self?.waiting = [:]
                }
            }
            do { try p.run() } catch { return }
            self.proc = p
            self.input = i.fileHandleForWriting
        }
    }

    /// Makes the audio for one line. Calls back with nil if the voice isn't available.
    func render(_ text: String, _ done: @escaping (URL?, Double) -> Void) {
        q.async {
            if let stand = self.stand {
                done(stand(text), 0)
                return
            }
            guard self.ready, let input = self.input else {
                done(nil, 0)
                return
            }
            let id = UUID().uuidString
            self.waiting[id] = done
            let msg = (try? JSONSerialization.data(withJSONObject: ["id": id, "text": text])) ?? Data()
            input.write(msg + Data("\n".utf8))
        }
    }
    /// Says a line now and returns its length in seconds (0 if the live voice isn't ready).
    func sayNow(_ text: String) async -> Double {
        guard ready, !Speaker.prefs.bool(forKey: "voiceMuted") else { return 0 }
        stop()
        let (url, dur): (URL?, Double) = await withCheckedContinuation { c in render(text) { c.resume(returning: ($0, $1)) } }
        guard let url else { return 0 }
        await MainActor.run { _ = self.enqueue(url) }
        return dur
    }
    /// Reads a reply aloud, sentence by sentence, starting with the first while the rest is still being made.
    private var onFirst: (() -> Void)?
    /// `started` runs when the first sentence starts playing (or right away if there's nothing to say).
    func read(_ reply: String, started: (() -> Void)? = nil) {
        guard ready || stand != nil, !Speaker.prefs.bool(forKey: "voiceMuted") else {
            started?()
            return
        }
        stop()
        let g = gen
        let parts = Speaker.spoken(reply)
        guard !parts.isEmpty else {
            started?()
            return
        }
        onFirst = started
        for sentence in parts { queue.append((sentence, g)) }
        pump()
    }
    private var pending: [(Int, URL?)] = []
    private func pump() {
        // render everything queued, play in order
        let items = queue
        queue = []
        nextIndex = 0
        var order = 0
        for (t, g) in items {
            let n = order
            order += 1
            render(t) { [weak self] url, _ in
                DispatchQueue.main.async {
                    guard let self, g == self.gen else { return }
                    self.pending.append((n, url))
                    self.pending.sort { $0.0 < $1.0 }
                    self.playNext()
                }
            }
        }
    }
    private var nextIndex = 0
    /// Sentences go straight onto the audio line in order, back to back.
    private func playNext() {
        while let k = pending.firstIndex(where: { $0.0 == nextIndex }) {
            let (_, url) = pending.remove(at: k)
            nextIndex += 1
            reached += 1
            if let url, stand == nil { enqueue(url) }
            if let f = onFirst {
                onFirst = nil
                f()
            }
        }
    }
    var talking: Bool { Date() < endsAt }
    /// Stop talking just this once (Esc, or a click on the orb while it talks): the rest of this reply's
    /// sentences are dropped and the sound stops now, with the line kept awake. Unlike the mute, nothing
    /// is remembered, the reply's text and helpers carry on, and the next reply speaks as usual.
    func hushReply() { stop() }
    /// Where the mute is read. Self-tests use their own settings, never the person's.
    static var prefs: UserDefaults { Env.selfTest ? (UserDefaults(suiteName: "ai.forjado.one.voice-test") ?? .standard) : .standard }
    /// Self-tests only: stands in for the voice process (no Kokoro, no sound).
    var stand: ((String) -> URL?)?
    /// Sentences that reached the audio line so far (self-tests count them).
    private(set) var reached = 0
    static var voiceID: String { UserDefaults.standard.string(forKey: "voiceID") ?? "af_heart" }
    /// Switch voices: restart the voice process with the new one, then say a short line in it.
    func use(voice: String, sample: String?) {
        UserDefaults.standard.set(voice, forKey: "voiceID")
        stop()
        q.async {
            self.proc?.terminate()
            self.proc = nil
            self.ready = false
            DispatchQueue.main.async {
                self.start()
                guard let sample else { return }
                Task { @MainActor in
                    for _ in 0..<40 where !Speaker.shared.ready { try? await Task.sleep(for: .milliseconds(250)) }
                    _ = await Speaker.shared.sayNow(sample)
                }
            }
        }
    }
    func stop() {
        gen += 1
        pending = []
        queue = []
        nextIndex = 0
        if let f = onFirst {
            onFirst = nil
            DispatchQueue.main.async { f() }
        }
        DispatchQueue.main.async { self.hush() }
    }

    /// What's worth saying out loud: plain sentences, no lists of links, code or long tables.
    static func spoken(_ text: String) -> [String] {
        var t = Choices.split(text).body
        t = t.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"```[\s\S]*?```"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
        for mark in ["**", "__", "`", "#", "|", ">"] { t = t.replacingOccurrences(of: mark, with: "") }
        let lines = t.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.allSatisfy { "-—=:".contains($0) } }
            .map { l -> String in
                var l = l
                if let r = l.range(of: #"^([-*•]|\d+[.)])\s+"#, options: .regularExpression) { l.removeSubrange(r) }
                if let last = l.last, !".!?:;".contains(last) { l += "." }
                return l
            }
        var out: [String] = []
        var cur = ""
        for l in lines {
            let parts = l.replacingOccurrences(of: #"([.!?])\s+"#, with: "$1\n", options: .regularExpression).components(separatedBy: "\n")
            for s in parts where !s.isEmpty {
                if cur.count + s.count < 160 {
                    cur += (cur.isEmpty ? "" : " ") + s
                } else {
                    if !cur.isEmpty { out.append(cur) }
                    cur = s
                }
                if out.count >= 8 { break }
            }
        }
        if !cur.isEmpty && out.count < 8 { out.append(cur) }
        return out
    }
}

// MARK: - Push to talk (speech → text on this Mac)

/// Hears you while you hold the orb. Speech is turned into text on the Mac when it can be.
@MainActor final class Listener: ObservableObject {
    static let shared = Listener()
    @Published var listening = false
    @Published var text = ""
    @Published var level: Double = 0
    @Published var problem: String?
    private let audio = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var want = false
    private var gotFinal = false
    private var onFinal: (() -> Void)?
    private let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    var wanting: Bool { want }
    /// Ask for permissions once at launch so pressing the key starts the mic with no waiting.
    func warm() {
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined { SFSpeechRecognizer.requestAuthorization { _ in } }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined { AVCaptureDevice.requestAccess(for: .audio) { _ in } }
    }
    func begin() {
        want = true
        problem = nil
        text = ""
        if SFSpeechRecognizer.authorizationStatus() == .authorized, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            listening = false
            startAudio()
            return  // already allowed: start right now
        }
        SFSpeechRecognizer.requestAuthorization { s in
            DispatchQueue.main.async {
                guard s == .authorized else {
                    self.fail("I need permission to hear you. Open System Settings, Privacy & Security, Speech Recognition, and turn on One.")
                    return
                }
                AVCaptureDevice.requestAccess(for: .audio) { ok in
                    DispatchQueue.main.async {
                        guard ok else {
                            self.fail("I need the microphone. Open System Settings, Privacy & Security, Microphone, and turn on One.")
                            return
                        }
                        if self.want { self.startAudio() }
                    }
                }
            }
        }
    }

    private func fail(_ msg: String) {
        problem = msg
        want = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { if self.problem == msg { self.problem = nil } }
    }

    private func startAudio() {
        guard !listening else { return }
        guard let r = recognizer, r.isAvailable else {
            fail("Talking isn't available right now. You can type instead.")
            return
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        if r.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req
        gotFinal = false
        let input = audio.inputNode
        input.removeTap(onBus: 0)
        input.installTap(
            onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0),
            block: Listener.tap(req) { lv in
                DispatchQueue.main.async { self.level = lv }
            })
        audio.prepare()
        do { try audio.start() } catch {
            input.removeTap(onBus: 0)
            fail("I couldn't use the microphone.")
            return
        }
        listening = true
        task = r.recognitionTask(
            with: req,
            resultHandler: Listener.handler { text, final in
                DispatchQueue.main.async {
                    if let text { self.text = text }
                    if final {
                        self.gotFinal = true
                        let f = self.onFinal
                        self.onFinal = nil
                        f?()
                    }
                }
            })
    }

    /// Bluetooth headsets take 1–2 s to switch into mic mode (and swallow the first words), so listen
    /// through the Mac's own microphone when the default input is Bluetooth. Replies still play on the headset.
    static func preferBuiltInMic(_ engine: AVAudioEngine) {
        func prop<T>(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector, _ v: inout T) -> Bool {
            var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var size = UInt32(MemoryLayout<T>.size)
            return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr
        }
        var def = AudioDeviceID(0)
        guard prop(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, &def) else { return }
        var transport = UInt32(0)
        _ = prop(def, kAudioDevicePropertyTransportType, &transport)
        guard transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE else { return }
        var a = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else { return }
        for id in ids {
            var t = UInt32(0)
            _ = prop(id, kAudioDevicePropertyTransportType, &t)
            guard t == kAudioDeviceTransportTypeBuiltIn else { continue }
            var sa = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var ss = UInt32(0)
            guard AudioObjectGetPropertyDataSize(id, &sa, 0, nil, &ss) == noErr, ss > 0 else { continue }
            var dev = id
            if let unit = engine.inputNode.audioUnit {
                AudioUnitSetProperty(
                    unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
            }
            return
        }
    }

    /// Built outside the class's methods so the audio thread never touches main-thread-only state.
    nonisolated private static func tap(_ req: SFSpeechAudioBufferRecognitionRequest, level: @escaping (Double) -> Void) -> AVAudioNodeTapBlock {
        return { buf, _ in
            req.append(buf)
            guard let ch = buf.floatChannelData?[0] else { return }
            let n = Int(buf.frameLength)
            var sum: Float = 0
            for i in 0..<n { sum += ch[i] * ch[i] }
            level(min(1, Double(sqrt(sum / Float(max(n, 1)))) * 14))
        }
    }
    nonisolated private static func handler(_ cb: @escaping (String?, Bool) -> Void) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        return { res, err in cb(res?.bestTranscription.formattedString, err != nil || res?.isFinal == true) }
    }

    /// Stop listening; `done` gets what was heard (empty if nothing).
    func finish(_ done: @escaping (String) -> Void) {
        want = false
        guard listening else {
            done("")
            return
        }
        listening = false
        audio.stop()
        audio.inputNode.removeTap(onBus: 0)
        for d in [0.6, 1.8] { DispatchQueue.main.asyncAfter(deadline: .now() + d) { if !self.listening { Speaker.shared.rebuild() } } }
        request?.endAudio()
        var called = false
        let complete = {
            guard !called else { return }
            called = true
            self.task?.cancel()
            self.task = nil
            self.request = nil
            self.level = 0
            done(self.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if gotFinal {
            complete()
        } else {
            onFinal = complete
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                self.onFinal = nil
                complete()
            }
        }
    }
}
