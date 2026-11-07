import AVFoundation
import AppKit

/// `One --test-sleep-safe` (preflight, from a test copy, scratch folder): One never ends because sound can't start.
/// 1. Apple's audio exceptions are caught (a made-up one, and a real `AVAudioPlayerNode.play()` on a line that isn't
///    running, the exact call that crashed 0.9.98 at 2:14 PM Nov 6 and 8:17 AM Nov 7).
/// 2. Launch in a dark wake (lid closed): the voice line doesn't start, every voice call is safe, the words still show.
/// 3. No sound output at all: the same, and a wake doesn't force it.
/// 4. A full wake (or a speaker showing up): the line comes back by itself (when this Mac has a speaker).
/// 5. The keeper's decisions: open One again after a crash, wait longer each time, never after a quit, put the
///    previous version back after a just-installed one fails three times (the real relaunch: tools/keeper-check.sh).
enum SleepSafeCheck {
    static func launch() -> Bool {
        guard CommandLine.arguments.contains("--test-sleep-safe") else { return false }
        TestWorld.enter()  // scratch folder, own settings; the audio line plays at volume 0
        guard ProcessInfo.processInfo.environment["ONE_SUPPORT_DIR"] != nil else {
            print("refusing: set ONE_SUPPORT_DIR to an empty folder first")
            exit(2)
        }
        Task { @MainActor in exit(await run()) }
        return true
    }

    @MainActor
    static func run() async -> Int32 {
        var fails = 0
        func check(_ name: String, _ ok: Bool) {
            print("  \(ok ? "✓" : "✗") \(name)")
            fflush(stdout)
            if !ok { fails += 1 }
        }
        func wait(_ s: Double) async { try? await Task.sleep(for: .milliseconds(Int(s * 1000))) }
        let sp = Speaker.shared
        sp.testVolume = 0

        print("1. Apple's audio exceptions are caught")
        let why = OneCatch { NSException(name: .genericException, reason: "made-up audio failure", userInfo: nil).raise() }
        check("a raised exception comes back as words, One carries on", why?.contains("made-up audio failure") == true)
        check("a block that doesn't raise comes back clean", OneCatch {} == nil)
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
        let played = AudioGate.attempt("check") {
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: fmt)
            node.play()  // the engine never started: Apple raises "player started when engine not running"
        }
        check("play() on a line that isn't running (0.9.98's crash) is caught, not fatal", !played)

        print("2. One opens in a dark wake (lid closed, no screen, no sound)")
        Awake.fake = .dark
        check("the Mac reads as asleep: no update restart, no sound", !Awake.full && !Awake.soundAllowed)
        check("the gate says why", AudioGate.blocked() == "the Mac is asleep (dark wake)")
        sp.start()  // what launch does
        await wait(1)
        check("still running after launch, the line waits instead of starting", sp.lineDown)
        let clip = Bundle.main.urls(forResourcesWithExtension: "mp3", subdirectory: nil)?.first
        check("a bundled line to play", clip != nil)
        if let clip { check("queueing a sentence plays nothing and returns 0 s (the words still show)", sp.enqueue(clip) == 0) }
        sp.ensureRoute()
        sp.rebuild()
        sp.hush()
        sp.rebuildSoon(after: 0.1, why: "check")
        sp.read("Here is a reply that would be read aloud. It has two sentences.")
        await wait(0.5)
        check("route checks, rebuilds, hush and a reply read aloud all pass quietly", sp.lineDown && !sp.talking)

        print("3. No sound output at all")
        Awake.fake = .full
        AudioGate.fakeNoDevice = true
        check("the gate says there's no sound output", AudioGate.blocked() == "no sound output")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        await wait(2.6)
        check("a wake with no speaker leaves the line down, nothing ends", sp.lineDown)

        print("4. The Mac wakes fully with a speaker")
        AudioGate.fakeNoDevice = false
        if AudioGate.outputDevice() != nil {
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
            await wait(3)
            check("the line comes back by itself after the wake", !sp.lineDown)
            if let clip { check("and plays again", sp.enqueue(clip) > 0) }
        } else {
            print("  – this machine has no sound output: coming back not checked here")
        }
        Awake.fake = nil

        print("5. The keeper")
        keeperChecks(check)
        print(fails == 0 ? "sleep safe ok" : "sleep safe FAILED (\(fails))")
        return fails == 0 ? 0 : 1
    }

    @MainActor static func keeperChecks(_ check: (String, Bool) -> Void) {
        let t0 = Date(timeIntervalSince1970: 1_794_000_000)
        var s = Keeper.State(want: true, app: "/Applications/One.app")
        func d(_ s: Keeper.State, running: Bool = false, at: Double = 0, previous: Bool = false) -> Keeper.Action {
            Keeper.decide(s, running: running, now: t0.addingTimeInterval(at), previousExists: previous)
        }
        check("One ended without being asked to: open it now", d(s) == .launch)
        check("One is open: nothing", d(s, running: true) == .nothing("One is open"))
        var quit = s
        quit.want = false
        check("they quit it: never opened against their wish", d(quit) == .nothing("One was quit on purpose"))
        check(
            "mid update swap: wait, never open half a copy",
            Keeper.decide(s, running: false, now: t0, previousExists: true, swapping: true) == .wait(30))
        s.launches = [t0]
        check("it failed to start once: waits a minute", d(s, at: 10) == .wait(50) && d(s, at: 61) == .launch)
        s.launches = [t0, t0, t0]
        check("three failed starts: waits 15 minutes", d(s, at: 60) == .wait(840))
        s.launches = Array(repeating: t0, count: 9)
        check("never more often than once an hour", d(s, at: 3599) == .wait(1) && d(s, at: 3600) == .launch)
        var upd = Keeper.State(want: true, app: "/Applications/One.app", launches: [t0, t0, t0], updatedAt: t0, updatedTo: "0.9.99")
        check("a just-installed version failed 3 times and the old one is kept: put it back", d(upd, at: 5, previous: true) == .rollBack)
        check("no previous version kept: keep trying the new one", d(upd, at: 5) == .wait(895))
        upd.badVersions = ["0.9.99"]
        check("already put back once: never again", d(upd, at: 900, previous: true) == .launch)
        upd.badVersions = []
        check("an update older than 2 days isn't put back", d(upd, at: 3 * 86400, previous: true) == .launch)
        let list: [[String: Any]] = [
            ["tag_name": "v1.1.0", "draft": false, "assets": [["name": "One.zip", "browser_download_url": "https://github.com/a/b/One.zip"]]]
        ]
        check("the updater never offers a version that was put back", Updater.pick(list, current: "1.0.0", skip: ["1.1.0"]) == nil)
        check("but offers it otherwise", Updater.pick(list, current: "1.0.0")?.0 == "1.1.0")
    }
}
