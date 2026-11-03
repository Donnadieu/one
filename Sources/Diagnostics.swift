import Foundation

/// Command-line checks that run before the app starts (each returns at once unless its flag is given).
enum Diagnostics {
    static func main(_ args: [String]) {
        GlassCheck.main(args)  // `--test-glass`: home's glass lets the desktop through like the design
        VoiceStress.main(args)  // `--test-voice-stress`: the real audio line under load (sanitizer builds)
        Pulse.cli(args)  // `--crash-line <pid>`: the one-line crash summary Pulse logs after a crash
    }
}
