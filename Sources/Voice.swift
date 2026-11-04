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
                self?.rebuildSoon(after: 0.8, why: "the output changed")
            }
        }
        if !audio.isRunning {
            useTestDevice()
            audio.prepare()
            try? audio.start()
        }
        // play() on a line that didn't start raises "player started when engine not running" and kills One
        // (0.9.83, Nov 2 04:37Z: hush → wakeAudio). A line that's down stays quiet until the next wake or rebuild.
        if audio.isRunning, !node.isPlaying { node.play() }
        if let v = testVolume { audio.mainMixerNode.outputVolume = v }
        routeRate = audio.outputNode.outputFormat(forBus: 0).sampleRate
        latency = audio.outputNode.presentationLatency
    }
    private var routeRate: Double = 0
    /// The speaker's own delay (Bluetooth is ~0.2 s), read when the line (re)starts. Never read per frame: each read
    /// is a synchronous call into the audio unit, and the orbs ask `heard()` 60 to 120 times a second.
    private var latency: Double = 0
    /// Loudness of what is queued on the audio line, by the time it's heard.
    private var track = VoiceTrack()
    /// Main thread. The voice as the person hears it right now: the speaker's own delay (Bluetooth is
    /// ~0.2 s) is taken off, so the orb moves with the sound, not with the text or the file.
    /// Touches only One's own copy of the loudness, never the audio engine: the orbs call this every frame, and the
    /// engine may be mid-change under them (a headset going into call mode for push to talk and back).
    func heard() -> VoiceWave {
        guard audioUp, let last = track.clips.last else { return .still }
        let now = Date()
        if now.timeIntervalSince(last.end) > 3 {
            track.clips = []  // everything queued has been said: nothing to follow until the next sentence
            return .still
        }
        return track.wave(at: now.addingTimeInterval(-latency))
    }
    var state: String { "engine=\(audio.isRunning) node=\(node.isPlaying) rate=\(audio.outputNode.outputFormat(forBus: 0).sampleRate)" }
    /// Main thread. Rebuilds the audio line from scratch. Bluetooth headsets switch to "call mode" while the mic
    /// is on and back afterwards; the old line can stay bound to the call-mode output and play into nothing.
    func rebuild() {
        rebuildWork?.cancel()
        rebuildWork = nil
        rebuildBy = nil
        VoiceLine.log("rebuild")
        node.stop()
        audio.stop()
        audio.disconnectNodeOutput(node)
        audio.reset()
        audio.connect(node, to: audio.mainMixerNode, format: fmt)
        endsAt = .distantPast
        useTestDevice()
        audio.prepare()
        try? audio.start()
        if audio.isRunning { node.play() }
        if let v = testVolume { audio.mainMixerNode.outputVolume = v }
        routeRate = audio.outputNode.outputFormat(forBus: 0).sampleRate
        latency = audio.outputNode.presentationLatency
    }
    private var rebuildWork: DispatchWorkItem?
    private var rebuildBy: Date?
    /// Main thread. The output is changing under the line (a Bluetooth headset switching into call mode for push to
    /// talk and back, a new device): rebuild ONCE, after it has settled, not on every step of the change. Each call
    /// can only push the rebuild later, never earlier. One used to stop, reset and restart the line up to three
    /// times within two seconds of every push to talk (the change notice, then 0.6 s and 1.8 s after letting go),
    /// while the headset was still switching; One's heap-corruption crashes came right after push to talk.
    func rebuildSoon(after s: Double, why: String) {
        let at = max(rebuildBy ?? .distantPast, Date().addingTimeInterval(s))
        guard at != rebuildBy else { return }
        VoiceLine.log("rebuild in \(String(format: "%.1f", at.timeIntervalSinceNow)) s: \(why)")
        rebuildWork?.cancel()
        rebuildBy = at
        let w = DispatchWorkItem { [weak self] in self?.rebuild() }
        rebuildWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, at.timeIntervalSinceNow), execute: w)
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
        guard audio.isRunning || stand != nil, let b = buffer(url) else { return 0 }
        let d = Double(b.frameLength) / fmt.sampleRate
        let starts = max(endsAt, Date())
        node.scheduleBuffer(b, completionHandler: nil)
        track.add(b, at: starts)
        endsAt = starts.addingTimeInterval(d)
        return d
    }
    /// Main thread. Silences now but keeps the line awake.
    func hush() {
        guard stand == nil || standPlays else {  // self-tests never touch the audio line (unless standPlays)
            endsAt = .distantPast
            return
        }
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
            try? input.write(contentsOf: msg + Data("\n".utf8))  // throws (never raises) if the voice process just died
        }
    }
    /// Says a line now and returns its length in seconds (0 if the live voice isn't ready).
    func sayNow(_ text: String) async -> Double {
        guard ready, !Speaker.prefs.bool(forKey: "voiceMuted") else { return 0 }
        await MainActor.run { self.stop() }  // the playback state belongs to the main thread (see `stop`)
        let (url, dur): (URL?, Double) = await withCheckedContinuation { c in render(text) { c.resume(returning: ($0, $1)) } }
        guard let url else { return 0 }
        await MainActor.run { _ = self.enqueue(url) }
        return dur
    }
    /// Reads a reply aloud, sentence by sentence, starting with the first while the rest is still being made.
    private var onFirst: (() -> Void)?
    /// `started` runs when the first sentence starts playing (or right away if there's nothing to say).
    func read(_ reply: String, started: (() -> Void)? = nil) {
        guard canSpeak, !Speaker.prefs.bool(forKey: "voiceMuted") else {
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
        outstanding = parts.count
        lastStep = Date()
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
            outstanding = max(0, outstanding - 1)
            lastStep = Date()
            if let url, stand == nil || standPlays { enqueue(url) }
            if stand != nil, standSecs > 0 { endsAt = max(endsAt, Date()).addingTimeInterval(standSecs) }  // self-tests: "plays" this long
            if let f = onFirst {
                onFirst = nil
                f()
            }
        }
    }
    var talking: Bool { Date() < endsAt }
    /// Sentences of the reply being read that haven't reached the audio line yet (still being made).
    private var outstanding = 0
    private var lastStep = Date.distantPast
    /// Main thread. A reply is being read: a sentence is playing OR the next ones are still being made. `talking`
    /// alone reads false in the gap between two sentences, which let notices start a new turn mid-reply.
    /// (A voice process that stops answering for 20 s doesn't hold the line forever.)
    var busy: Bool { talking || (outstanding > 0 && Date().timeIntervalSince(lastStep) < 20) }
    /// The live voice is up (or a self-test stand-in is).
    var canSpeak: Bool { ready || stand != nil }
    /// Self-tests only: how long each stand-in sentence "plays".
    var standSecs = 0.0
    /// Stop talking just this once (Esc, or a click on the orb while it talks): the rest of this reply's
    /// sentences are dropped and the sound stops now, with the line kept awake. Unlike the mute, nothing
    /// is remembered, the reply's text and helpers carry on, and the next reply speaks as usual.
    func hushReply() { stop() }
    /// Where the mute is read. Self-tests use their own settings, never the person's.
    static var prefs: UserDefaults { Env.selfTest ? (UserDefaults(suiteName: "ai.forjado.one.voice-test") ?? .standard) : .standard }
    /// Self-tests only: stands in for the voice process (no Kokoro, no sound).
    var stand: ((String) -> URL?)?
    /// Self-tests only (`--test-voice-stress`): the stand-in's sounds really play on the audio line.
    var standPlays = false
    /// Self-tests only: the line's volume (0 = runs and renders, heard by nobody).
    var testVolume: Float?
    /// Self-tests only (`--test-soak`): play on this output device instead of the default one.
    var testDevice: AudioDeviceID?
    private func useTestDevice() {
        guard var d = testDevice, let u = audio.outputNode.audioUnit else { return }
        AudioUnitSetProperty(u, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &d, UInt32(MemoryLayout<AudioDeviceID>.size))
    }
    /// Self-tests only: act as if the live voice were up (the stand-in makes the sentences), so `sayNow` runs.
    func pretendReady() { q.sync { ready = true } }
    /// Sentences that reached the audio line so far (self-tests count them).
    private(set) var reached = 0
    static var voiceID: String { UserDefaults.standard.string(forKey: "voiceID") ?? "af_heart" }
    /// Switch voices: restart the voice process with the new one, then say a short line in it.
    func use(voice: String, sample: String?) {
        UserDefaults.standard.set(voice, forKey: "voiceID")
        Task { await PhoneVoice.sync() }  // phone chats follow the new voice
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
    /// Main thread, like everything that touches the reply being read (`gen`, `pending`, `queue`, `onFirst`).
    /// `sayNow` used to call this from a background task, racing the main thread on those arrays (found by
    /// `--test-voice-stress` under the thread sanitizer). A call from anywhere else now hops to main first.
    func stop() {
        guard Thread.isMainThread else { return DispatchQueue.main.async { self.stop() } }
        gen += 1
        pending = []
        queue = []
        nextIndex = 0
        outstanding = 0
        if let f = onFirst {
            onFirst = nil
            DispatchQueue.main.async { f() }
        }
        DispatchQueue.main.async { self.hush() }
    }

    /// What's worth saying out loud: plain sentences, no lists of links, code or long tables.
    static func spoken(_ text: String) -> [String] {
        var t = Choices.split(Helpers.strip(text)).body  // no helper/stop/close/job-kind line is ever read aloud
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

/// When the voice line changed, in `hermes/logs/one-voice-line.log` (push to talk, route changes, rebuilds; a few
/// lines per push to talk). If One crashes again, Pulse's crash line can be lined up against these times.
enum VoiceLine {
    nonisolated static func log(_ line: String) {
        guard !Env.selfTest else { return }
        let f = Env.hermesHome.appendingPathComponent("logs/one-voice-line.log")
        let s = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        if let h = try? FileHandle(forWritingTo: f) {
            h.seekToEndOfFile()
            h.write(Data(s.utf8))
            try? h.close()
        } else {
            try? s.write(to: f, atomically: true, encoding: .utf8)
        }
    }
}
