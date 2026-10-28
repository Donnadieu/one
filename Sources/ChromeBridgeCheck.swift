import Foundation

// MARK: - Part of `One --test-browser`: "use my Chrome" picks the right profile and knows a real sign-in

enum ChromeBridgeCheck {
    static func run(_ expect: (Bool, String) -> Void) {
        let now = Date()
        let state = """
            {"profile": {"last_used": "Profile 2", "info_cache": {
              "Default": {"name": "Person 1", "active_time": \(now.timeIntervalSince1970 - 90 * 86400)},
              "Profile 2": {"name": "Erika", "active_time": \(now.timeIntervalSince1970 - 3600)},
              "Profile 3": {"name": "Work", "active_time": \(now.timeIntervalSince1970 - 2 * 86400)}}}}
            """
        let (last, all) = MyChrome.profiles(localState: Data(state.utf8))
        expect(last == "Profile 2" && all.count == 3, "reads Chrome's profiles and the last used one from Local State")
        let one = all.filter { $0.dir != "Profile 3" }
        if case .use(let p) = MyChrome.pick(nil, last: last, all: one, pinned: nil, now: now) {
            expect(p.dir == "Profile 2", "one profile in use this week: that one, no question")
        } else {
            expect(false, "one profile in use this week: that one, no question")
        }
        if case .ask(let ps) = MyChrome.pick(nil, last: last, all: all, pinned: nil, now: now) {
            expect(ps.map(\.name) == ["Erika", "Work"], "two profiles really in use: asks, most recent first, old ones left out")
        } else {
            expect(false, "two profiles really in use: asks")
        }
        expect(MyChrome.pick("work", last: last, all: all, pinned: nil, now: now) == .use(all[2]), "a named profile is used (by its name, any case)")
        expect(
            MyChrome.pick(nil, last: last, all: all, pinned: "Profile 3", now: now) == .use(all[2]),
            "the profile picked before is kept, no new question")
        if case .notFound = MyChrome.pick("school", last: last, all: all, pinned: nil, now: now) {
            expect(true, "an unknown profile name is said plainly")
        } else {
            expect(false, "an unknown profile name is said plainly")
        }
        expect(MyChrome.profiles(localState: nil).last == "Default", "no Local State: Chrome's default profile")
        let future = now.timeIntervalSince1970 + 86400
        let cookies: [[String: Any]] = [
            ["name": "user_session", "domain": "github.com", "expires": future],
            ["name": "SID", "domain": ".google.com", "expires": 1000.0],
            ["name": "NID", "domain": ".google.com", "expires": future],
        ]
        expect(MyChrome.candidates(cookies).map(\.host) == ["github.com"], "a site counts only with its live session cookie")
        expect(!MyChrome.rule.contains("Connections ›"), "the rule never sends them to a menu")
    }
}
