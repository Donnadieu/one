import Foundation

/// `One --test-gateway`: proves a second One (a test copy, a render, `make check`) can't stop the
/// engine helper the person's live One is using. Run with ONE_SUPPORT_DIR set to an empty folder.
enum GatewayCheck {
    static func run() -> Int32 {
        var fails = 0
        func check(_ name: String, _ ok: Bool) {
            print("  \(ok ? "✓" : "✗") \(name)")
            if !ok { fails += 1 }
        }
        func spawn(_ args: [String]) -> Process? {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = ["-c", "import time; time.sleep(120)"] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return nil }
            usleep(300_000)
            return p
        }
        func record(_ p: Process) {
            try? "{\"pid\": \(p.processIdentifier)}".write(to: GatewayGuard.pidFile, atomically: true, encoding: .utf8)
        }
        check("runs as a command-line tool (never starts the engine from the window)", Env.commandLine)

        // A healthy gateway whose engine (here: this process) is alive and isn't being replaced.
        guard let live = spawn(["gateway", "run", "--quiet"]) else {
            print("gateway check: couldn't start a stand-in")
            return 1
        }
        record(live)
        check("reads the gateway's arguments", GatewayGuard.arguments(of: live.processIdentifier).contains("gateway"))
        check("knows who started it", GatewayGuard.parent(of: live.processIdentifier) == getpid())
        Engine.stopStrayGateway(caller: "test second start")
        check("a second engine start leaves a healthy gateway running", live.isRunning)
        Engine.stopStrayGateway(previousEngine: 999_999, caller: "test other engine")
        check("replacing some other engine leaves it running", live.isRunning)
        Engine.stopStrayGateway(previousEngine: getpid(), caller: "test own restart")
        usleep(300_000)
        check("restarting its own engine does stop it", !live.isRunning)

        // pid reused by something that isn't a gateway.
        if let other = spawn(["not-a-gateway"]) {
            record(other)
            Engine.stopStrayGateway(previousEngine: getpid(), caller: "test reused pid")
            check("a reused pid that isn't a gateway is never touched", other.isRunning)
            other.terminate()
        }
        try? FileManager.default.removeItem(at: GatewayGuard.pidFile)
        check("dropped turn is recognised", Engine.dropped("error: Gateway shutting down", text: "", gatewayBefore: nil))
        check("a real error is not retried", !Engine.dropped("error: Internal error", text: "", gatewayBefore: nil))
        check("phone chat: a set bot token keeps the helper running", Messenger.wanted("# x\n" + Messenger.tokenKey + "=123:abc\n"))
        check("phone chat: a commented or empty token does not", !Messenger.wanted("# " + Messenger.tokenKey + "=123\n" + Messenger.tokenKey + "=\n"))
        check(
            "phone chat: never starts from a test copy",
            {
                Messenger.tend()
                return Messenger.proc == nil
            }())
        print(fails == 0 ? "gateway ok" : "gateway: \(fails) failed")
        return fails == 0 ? 0 : 1
    }
}
