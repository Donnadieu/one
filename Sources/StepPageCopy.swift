import Foundation

// MARK: - The window opens on the helper's very page, not on its address
//
// Many steps exist only as the answer to a form the helper sent: DocuSign's "Enter the code sent to your phone"
// (smsverification-entercode) holds its state in the page itself (hidden invite and anti-forgery fields). Opening
// that address again (a reload, a new tab, the window on the same profile) is a plain GET and lands on a log-in or
// sign-up page: Omar saw that on Nov 11 2026 (0.9.58 to 0.9.112), and keeping the cookies alone didn't help.
// So before the hidden browser closes, One keeps a still copy of that page (`snapshotJS`) and the window shows it at
// its real address: when Chrome asks for that address, the window's own DevTools socket answers with the copy
// (Fetch.fulfillRequest), once, and lets go. Everything after (the code typed, Verify, the next page) is the real
// site, with the same sign-ins (kept through the close). The same thing brings the window's last page back into the
// hidden browser for the helper. A page its address brings back just opens by its address, as before.
enum StepPageCopy {
    struct Page: Equatable {
        let url: String
        let html: String
    }

    /// Which steps reopen the kept page: a robot check, a passkey or a security key reload fine (and a check must be
    /// the site's own fresh challenge), so they open their address as before.
    static func keeps(_ kind: String) -> Bool { !HumanCheck.watchesCookie(kind) && kind != "passkey" && kind != "security_key" }

    /// The page in that tab, when it can't be opened again by its address: a page reached by sending a form (its
    /// navigation says `form_submit`, or Chrome has no copy of it to give, as for any form answer), kept as it is on
    /// screen. Nil for a page its address brings back (the window just opens the address, as before).
    static func keep(port: Int, target: String) async -> Page? {
        guard let s = socket(port: port, target: target) else { return nil }
        defer { s.cancel(with: .normalClosure, reason: nil) }
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(15))
            s.cancel(with: .goingAway, reason: nil)
        }
        defer { watchdog.cancel() }
        _ = await HumanCheck.cdpCall(s, id: 1, "Page.enable")
        guard let tree = await HumanCheck.cdpCall(s, id: 2, "Page.getFrameTree"),
            let f = (tree["frameTree"] as? [String: Any])?["frame"] as? [String: Any], let fid = f["id"] as? String,
            let url = f["url"] as? String, url.hasPrefix("http")
        else { return nil }
        let h = await HumanCheck.cdpCall(s, id: 3, "Page.getNavigationHistory")
        let entries = h?["entries"] as? [[String: Any]] ?? []
        let at = h?["currentIndex"] as? Int ?? -1
        let sent = entries.indices.contains(at) && entries[at]["transitionType"] as? String == "form_submit"
        let cached = await HumanCheck.cdpCall(s, id: 4, "Page.getResourceContent", ["frameId": fid, "url": url]) != nil
        guard sent || !cached else { return nil }
        let r = await HumanCheck.cdpCall(s, id: 5, "Runtime.evaluate", ["expression": snapshotJS, "returnByValue": true])
        guard let html = (r?["result"] as? [String: Any])?["value"] as? String, html.count > 200 else { return nil }
        return Page(url: url, html: html)
    }

    /// The page as it is now, as a still copy: what's typed and picked kept in its fields, its scripts left out (they
    /// would draw the page a second time), relative links kept on the site. Its forms still send to the site
    /// itself. Proved on DocuSign's sign-up, Nov 12 2026: the copy showed "Check your email" once, a code typed in
    /// it and Next went to the site and moved on to "Secure your account" (a fresh load of the address showed the
    /// sign-up form; the page's own scripts drew the code step twice).
    static let snapshotJS = #"""
        (() => {
          for (const e of document.querySelectorAll('input')) {
            if (e.type === 'checkbox' || e.type === 'radio') { if (e.checked) e.setAttribute('checked', ''); else e.removeAttribute('checked'); }
            else if (e.type !== 'file' && e.type !== 'password') e.setAttribute('value', e.value);
          }
          for (const e of document.querySelectorAll('textarea')) e.textContent = e.value;
          for (const e of document.querySelectorAll('select')) for (const o of e.options) { if (o.selected) o.setAttribute('selected', ''); else o.removeAttribute('selected'); }
          const d = document.documentElement.cloneNode(true);
          // Styles a script wrote straight into the page's style sheets (no text in their <style> tag) come along too,
          // or the copy shows unstyled (Nov 12 2026: DocuSign's logo filled the window and the code box was out of view).
          const live = document.querySelectorAll('style'), copy = d.querySelectorAll('style');
          live.forEach((el, i) => {
            try { const t = Array.from(el.sheet ? el.sheet.cssRules : [], (r) => r.cssText).join('\n'); if (copy[i] && t.length > el.textContent.length) copy[i].textContent = t; } catch (e) {}
          });
          try {
            const extra = Array.from(document.adoptedStyleSheets || [], (sh) => Array.from(sh.cssRules, (r) => r.cssText).join('\n')).join('\n');
            if (extra) { const st = document.createElement('style'); st.textContent = extra; (d.querySelector('head') || d).append(st); }
          } catch (e) {}
          for (const s of d.querySelectorAll('script')) s.remove();
          const b = document.createElement('base'); b.href = location.href;
          const h = d.querySelector('head'); if (h) h.prepend(b);
          return '<!DOCTYPE html>' + d.outerHTML;
        })()
        """#

    /// The tab's address right now (the page the person ended on in the window).
    static func address(port: Int, target: String) async -> String? {
        guard let s = socket(port: port, target: target) else { return nil }
        defer { s.cancel(with: .normalClosure, reason: nil) }
        let r = await HumanCheck.cdpCall(s, id: 1, "Runtime.evaluate", ["expression": "location.href", "returnByValue": true])
        return (r?["result"] as? [String: Any])?["value"] as? String
    }

    /// The first ordinary page of a browser (the window's one tab), by its DevTools list.
    static func firstPage(port: Int) -> String? {
        guard let u = URL(string: "http://127.0.0.1:\(port)/json/list"), let d = try? Data(contentsOf: u),
            let l = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]]
        else { return nil }
        return l.first { $0["type"] as? String == "page" && !(($0["url"] as? String) ?? "").hasPrefix("chrome-extension:") }?["id"] as? String
    }

    /// Shows `page` in that tab at its own address: Chrome's request for it is answered with the kept page, once.
    /// True when the tab ended up on that address.
    static func show(_ page: Page, port: Int, target: String) async -> Bool {
        guard let s = socket(port: port, target: target) else { return false }
        defer { s.cancel(with: .normalClosure, reason: nil) }
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(20))
            s.cancel(with: .goingAway, reason: nil)
        }
        defer { watchdog.cancel() }
        guard await HumanCheck.cdpCall(s, id: 1, "Fetch.enable", ["patterns": [["urlPattern": "*", "resourceType": "Document"]]]) != nil,
            send(s, id: 2, "Page.navigate", ["url": page.url])
        else { return false }
        var answered = false
        var next = 10
        for _ in 0..<400 where !answered {
            guard let m = try? await s.receive() else { break }
            var text = ""
            if case .string(let t) = m { text = t } else if case .data(let d) = m { text = String(decoding: d, as: UTF8.self) }
            guard let j = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
                j["method"] as? String == "Fetch.requestPaused",
                let p = j["params"] as? [String: Any], let rid = p["requestId"] as? String
            else { continue }
            next += 1
            let asked = ((p["request"] as? [String: Any])?["url"] as? String) ?? ""
            if same(asked, page.url) {
                _ = send(
                    s, id: next, "Fetch.fulfillRequest",
                    [
                        "requestId": rid, "responseCode": 200,
                        "responseHeaders": [
                            ["name": "Content-Type", "value": "text/html; charset=utf-8"], ["name": "Cache-Control", "value": "no-store"],
                        ],
                        "body": Data(page.html.utf8).base64EncodedString(),
                    ])
                answered = true
            } else {
                _ = send(s, id: next, "Fetch.continueRequest", ["requestId": rid])
            }
        }
        _ = await HumanCheck.cdpCall(s, id: next + 1, "Fetch.disable")
        guard answered else { return false }
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(300))
            let r = await HumanCheck.cdpCall(
                s, id: next + 2, "Runtime.evaluate", ["expression": "location.href + '|' + document.readyState", "returnByValue": true])
            if let v = (r?["result"] as? [String: Any])?["value"] as? String, v.hasSuffix("|complete") || v.hasSuffix("|interactive") {
                // The box the person came for, in view and ready to type in.
                _ = await HumanCheck.cdpCall(s, id: next + 3, "Runtime.evaluate", ["expression": focusJS, "returnByValue": true])
                return same(String(v.split(separator: "|").first ?? ""), page.url)
            }
            next += 1
        }
        return false
    }

    static let focusJS = #"""
        (() => {
          const ok = (e) => e.type !== 'hidden' && !e.disabled && e.getClientRects().length > 0;
          const all = Array.from(document.querySelectorAll('input')).filter(ok);
          const e = all.find((i) => (i.autocomplete || '').includes('one-time-code'))
            || all.find((i) => /code|otp|passcode|verification/i.test(i.name + ' ' + i.id + ' ' + (i.getAttribute('aria-label') || '')))
            || all.find((i) => ['text', 'tel', 'email', 'password', 'number', ''].includes(i.type));
          if (e) { e.scrollIntoView({ block: 'center' }); e.focus(); }
          return !!e;
        })()
        """#

    /// Two addresses of the same page (Chrome may drop a trailing "#").
    static func same(_ a: String, _ b: String) -> Bool { a == b || a.split(separator: "#").first == b.split(separator: "#").first }

    static func socket(port: Int, target: String) -> URLSessionWebSocketTask? {
        guard !target.isEmpty, let u = URL(string: "ws://127.0.0.1:\(port)/devtools/page/\(target)") else { return nil }
        let t = URLSession(configuration: .ephemeral).webSocketTask(with: u)
        t.maximumMessageSize = 64 << 20
        t.resume()
        return t
    }

    @discardableResult static func send(_ s: URLSessionWebSocketTask, id: Int, _ method: String, _ params: [String: Any]) -> Bool {
        guard let d = try? JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params]) else { return false }
        s.send(.string(String(decoding: d, as: UTF8.self))) { _ in }
        return true
    }
}

/// Keeps every page the site sends to the window's tab, exactly as sent (Network.getResponseBody of each main
/// document), so the hidden browser gets the person's last page back with its own scripts working: a still copy
/// (no scripts) of DocuSign's next step couldn't send its phone number (its script fills a hidden field).
final class StepPageWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var socket: URLSessionWebSocketTask?
    private var pages: [String: StepPageCopy.Page] = [:]
    private var waiting: [Int: String] = [:]  // getResponseBody call id -> its address
    private var documents: [String: String] = [:]  // request id -> address
    private var next = 1000

    func start(port: Int, target: String) {
        guard let s = StepPageCopy.socket(port: port, target: target) else { return }
        socket = s
        StepPageCopy.send(s, id: 1, "Network.enable", ["maxResourceBufferSize": 16 << 20, "maxTotalBufferSize": 64 << 20])
        listen(s)
    }

    func stop() {
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
    }

    /// The page the site last sent for that address, if one came while the window was up.
    func page(_ url: String) -> StepPageCopy.Page? {
        lock.lock()
        defer { lock.unlock() }
        return pages.first { StepPageCopy.same($0.key, url) }?.value
    }

    private func listen(_ s: URLSessionWebSocketTask) {
        s.receive { [weak self] r in
            guard let self, case .success(let m) = r else { return }
            var text = ""
            if case .string(let t) = m { text = t } else if case .data(let d) = m { text = String(decoding: d, as: UTF8.self) }
            if let j = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] { self.handle(j, s) }
            self.listen(s)
        }
    }

    private func handle(_ j: [String: Any], _ s: URLSessionWebSocketTask) {
        lock.lock()
        defer { lock.unlock() }
        let p = j["params"] as? [String: Any] ?? [:]
        switch j["method"] as? String {
        case "Network.responseReceived":
            if p["type"] as? String == "Document", let id = p["requestId"] as? String,
                let u = (p["response"] as? [String: Any])?["url"] as? String, u.hasPrefix("http")
            {
                documents[id] = u
            }
        case "Network.loadingFinished":
            if let id = p["requestId"] as? String, let u = documents.removeValue(forKey: id) {
                next += 1
                waiting[next] = u
                StepPageCopy.send(s, id: next, "Network.getResponseBody", ["requestId": id])
            }
        default:
            if let id = j["id"] as? Int, let u = waiting.removeValue(forKey: id), let r = j["result"] as? [String: Any],
                var body = r["body"] as? String
            {
                if r["base64Encoded"] as? Bool == true, let d = Data(base64Encoded: body) { body = String(decoding: d, as: UTF8.self) }
                if body.count > 200 { pages[u] = StepPageCopy.Page(url: u, html: body) }
            }
        }
    }
}
