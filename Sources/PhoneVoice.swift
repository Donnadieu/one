import Foundation

// MARK: - Phone chats speak with the Mac's voice

/// When the engine answers out loud in a phone chat, it uses its own default voice (a cloud one) unless
/// told otherwise. One points it at the same Kokoro model and the same voice the person picked here, so
/// the assistant sounds the same everywhere and the words never leave the Mac. Any chat app the engine
/// connects to gets this, because it is the engine's one voice setting.
enum PhoneVoice {
    static let name = "one_voice"

    /// The settings line the engine runs, for the given voice.
    static func command(voiceDir: String, script: String) -> String {
        let py = (voiceDir as NSString).appendingPathComponent("venv/bin/python")
        return "'\(py)' -I '\(script)' '\(voiceDir)' {voice} {input_path} {output_path}"
    }

    /// Copies the voice script next to the voice (inside One's folder, which the engine may read) and
    /// writes the engine's voice settings when they differ. Safe to call often.
    static func sync() async {
        let dir = Speaker.shared.dir
        guard Speaker.shared.installed, !Env.selfTest,
            let src = Bundle.main.url(forResource: "speak_file", withExtension: "py")
        else { return }
        let script = dir.appendingPathComponent("speak_file.py")
        let fm = FileManager.default
        if (try? Data(contentsOf: src)) != (try? Data(contentsOf: script)) {
            try? fm.removeItem(at: script)
            try? fm.copyItem(at: src, to: script)
        }
        let want: [(String, String)] = [
            ("tts.providers.\(name).type", "command"),
            ("tts.providers.\(name).command", command(voiceDir: dir.path, script: script.path)),
            ("tts.providers.\(name).voice", Speaker.voiceID),
            ("tts.providers.\(name).output_format", "ogg"),
            ("tts.providers.\(name).voice_compatible", "true"),
            ("tts.providers.\(name).timeout", "120"),
            ("tts.provider", name),
        ]
        let cfg = (try? String(contentsOf: Env.hermesHome.appendingPathComponent("config.yaml"), encoding: .utf8)) ?? ""
        if cfg.contains("provider: \(name)") && cfg.contains("voice: \(Speaker.voiceID)") && cfg.contains(script.path) { return }
        // The engine's settings check doesn't know custom voice entries yet; --force writes them anyway.
        for (k, v) in want { _ = await hermesRun(["config", "set", "--force", k, v]) }
    }
}
