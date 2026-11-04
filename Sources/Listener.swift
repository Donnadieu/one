import AVFoundation
import AppKit
import CoreAudio
import Speech
import SwiftUI

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
        VoiceLine.log("push to talk: listening")
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
        VoiceLine.log("push to talk: let go")
        // The headset leaves call mode over the next second or two: the line is rebuilt once, after that (Speaker.rebuildSoon).
        Speaker.shared.rebuildSoon(after: 1.8, why: "push to talk ended")
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
