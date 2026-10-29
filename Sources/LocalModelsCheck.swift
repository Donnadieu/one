import Foundation

/// `One --test-local-model` (preflight): the local model list, memory-sized recommendation, the small-model tool
/// warning, and discovering a real OpenAI-compatible loopback server (ONE_LOCAL_TEST_PORT) all check out.
enum LocalModelsCheck {
    static func launch() -> Bool {
        guard CommandLine.arguments.contains("--test-local-model") else { return false }
        TestWorld.enter()
        Task { @MainActor in exit(await run()) }
        return true
    }

    static func run() async -> Int32 {
        let parsed = LocalModels.modelNames(Data(#"{"data":[{"id":"test-model"},{"id":"test-model"},{"id":"another"}]}"#.utf8))
        guard parsed == ["another", "test-model"] else {
            print("local: model list ✗")
            return 1
        }
        guard LocalModels.modelNames(Data("{}".utf8)) == nil else {
            print("local: malformed model list ✗")
            return 1
        }
        guard LocalModels.recommended(forGB: 48).model == "gemma4:31b",
            LocalModels.recommended(forGB: 24).model == "qwen3:14b",
            LocalModels.recommended(forGB: 16).model == "qwen3:8b"
        else {
            print("local: memory-sized choice ✗")
            return 1
        }
        guard LocalModels.weakTools("llama3.2:3b"), !LocalModels.weakTools("gemma4:31b") else {
            print("local: tool warning ✗")
            return 1
        }
        if let raw = ProcessInfo.processInfo.environment["ONE_LOCAL_TEST_PORT"], let port = Int(raw) {
            let found = await LocalModels.discover(ports: [port])
            guard found.count == 1, found[0].models == ["fake-local"],
                found[0].baseURL == "http://127.0.0.1:\(port)/v1"
            else {
                print("local: server discovery ✗")
                return 1
            }
        }
        print("local: model list, memory choice, warning and discovery ✓")
        return 0
    }
}
