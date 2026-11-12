import AppKit
import SwiftUI

/// `One --qa-handoff` (tools/handoff-qa.sh): One's half of a hand-off for a live QA run on a real site (DocuSign's
/// sign-up, Nov 2026), on a throwaway hidden Chrome (its own port and scratch profile, never the shared browsers).
/// It keeps that hidden browser up exactly as One does and shows the real hand-off cards (HumanStepCard: the code box,
/// Show the window, the real Chrome window with One's card beside it). The engine half runs the site in that browser
/// and calls hand_off; the person answers here as they would in One. Stops when `<support>/quit` appears.
@MainActor
enum HandoffQA {
    static var window: NSWindow?

    static func launch() -> Bool {
        let env = ProcessInfo.processInfo.environment
        // Started through Launch Services (LSEnvironment), so it runs outside the folder lock like the real One.
        guard CommandLine.arguments.contains("--qa-handoff") || env["ONE_TEST_MODE"] == "--qa-handoff" else { return false }
        if let log = env["ONE_CHECK_LOG"] {
            freopen(log, "a", stdout)
            setvbuf(stdout, nil, _IOLBF, 0)
        }
        TestWorld.enter()
        guard let port = env["ONE_QA_PORT"].flatMap(Int.init), ![9223, 9224, 9333].contains(port), let profile = env["ONE_QA_PROFILE"] else {
            print("refusing: run tools/handoff-qa.sh (a throwaway port and profile, never a shared browser)")
            exit(2)
        }
        NSApp.setActivationPolicy(.regular)
        BrowserKeeper.planOverride = BrowserKeeper.Plan(port: port, profile: profile, headless: true)
        BrowserKeeper.lastStart = nil
        BrowserKeeper.tend()
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 380), styleMask: [.titled, .resizable, .miniaturizable], backing: .buffered,
            defer: false)
        w.title = "One: live hand-off test"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: HandoffQAView(m: Model.shared).environment(\.colorScheme, .dark))
        w.center()
        w.orderFrontRegardless()
        window = w
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                Model.shared.tendHumanSteps()
                BrowserKeeper.tend()
                if FileManager.default.fileExists(atPath: Env.support.appendingPathComponent("quit").path) { exit(0) }
                // `<support>/show`: the tester's tap on the first card's Show the window (for a run with nobody at the Mac).
                let show = Env.support.appendingPathComponent("show")
                if FileManager.default.fileExists(atPath: show.path), let a = Model.shared.humanSteps.first {
                    try? FileManager.default.removeItem(at: show)
                    print("tester: Show the window on \(a.id) (\(a.kind))")
                    Model.shared.showHumanStep(a)
                }
                let done = Env.support.appendingPathComponent("done")
                if FileManager.default.fileExists(atPath: done.path), let a = HumanCheck.active {
                    try? FileManager.default.removeItem(at: done)
                    print("tester: Done on \(a.id)")
                    Model.shared.answerHumanStep(a.id, "done")
                }
            }
        }
        print("qa ready: hidden browser on \(port)")
        fflush(stdout)
        return true
    }
}

struct HandoffQAView: View {
    @ObservedObject var m: Model
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Live hand-off test, on a throwaway browser").font(.caption).foregroundStyle(.secondary)
            if m.humanSteps.isEmpty { Text("Nothing to do yet.").foregroundStyle(.secondary) }
            ForEach(m.humanSteps) { a in HumanStepCard(a: a) { m.answerHumanStep(a.id, $0) } }
            Spacer(minLength: 0)
        }
        .padding(16).frame(minWidth: 520, minHeight: 340, alignment: .topLeading)
    }
}
