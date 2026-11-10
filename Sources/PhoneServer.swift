import CryptoKit
import Foundation
import Network

// MARK: - A tiny web server for the phone hand-off page (one page, one phone, loopback only)

/// Listens on 127.0.0.1 only. Serves exactly two paths for one room: `GET /h/<room>` (the phone page) and the
/// WebSocket `GET /ws/<room>`; everything else is 404. The first phone to open the socket is the only one: a second
/// connection is refused (single device). Reached from the phone through a short-lived tunnel (PhoneTunnel) or, in
/// the cloud, a relay; either way it only ever carries what PhoneSession sealed with the link's key.
final class PhoneServer: @unchecked Sendable {
    let room: String
    let page: String
    var socketPath: String  // `/ws/<room>`; the check's stand-in page uses `/devtools/page/<id>`
    private var listener: NWListener?
    private let q = DispatchQueue(label: "one.phone-server")
    private(set) var phone: PhoneSocket?
    var onPhone: ((PhoneSocket, [String: String]) -> Void)?
    var onRefused: ((String) -> Void)?

    init(room: String, page: String) {
        self.room = room
        self.page = page
        socketPath = "/ws/" + room
    }

    /// Starts listening; returns the port, or nil.
    func start() -> UInt16? {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 0)
        guard let l = try? NWListener(using: params) else { return nil }
        listener = l
        let ready = DispatchSemaphore(value: 0)
        l.stateUpdateHandler = { s in
            if case .ready = s { ready.signal() }
            if case .failed = s { ready.signal() }
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.start(queue: q)
        _ = ready.wait(timeout: .now() + 5)
        return l.port?.rawValue
    }
    func stop() {
        phone?.close()
        listener?.cancel()
        listener = nil
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: q)
        readHead(c, Data())
    }
    private func readHead(_ c: NWConnection, _ have: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] d, _, done, err in
            guard let self else { return }
            var buf = have
            if let d { buf.append(d) }
            if let r = buf.range(of: Data("\r\n\r\n".utf8)) {
                self.handle(c, head: String(decoding: buf[..<r.lowerBound], as: UTF8.self), rest: buf[r.upperBound...])
            } else if done || err != nil || buf.count > 16384 {
                c.cancel()
            } else {
                self.readHead(c, buf)
            }
        }
    }
    static func headers(_ head: String) -> (method: String, path: String, fields: [String: String]) {
        let lines = head.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ").map(String.init)
        var f: [String: String] = [:]
        for l in lines.dropFirst() {
            guard let i = l.firstIndex(of: ":") else { continue }
            f[l[..<i].lowercased().trimmingCharacters(in: .whitespaces)] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        return (first.first ?? "", first.count > 1 ? first[1] : "", f)
    }
    private func handle(_ c: NWConnection, head: String, rest: Data) {
        let h = Self.headers(head)
        let path = h.path.split(separator: "?").first.map(String.init) ?? h.path
        if h.method == "GET" && path == "/h/\(room)" {
            let body = Data(page.utf8)
            let hdr =
                "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\n"
                + "Referrer-Policy: no-referrer\r\nX-Frame-Options: DENY\r\n"
                + "Content-Security-Policy: default-src 'none'; img-src blob:; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self' wss: ws:\r\n"
                + "Connection: close\r\n\r\n"
            c.send(content: Data(hdr.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
            return
        }
        if h.method == "GET" && path == socketPath, h.fields["upgrade"]?.lowercased() == "websocket", let key = h.fields["sec-websocket-key"] {
            guard phone == nil else {
                onRefused?(h.fields["user-agent"] ?? "")
                c.send(
                    content: Data("HTTP/1.1 409 Conflict\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                    completion: .contentProcessed { _ in c.cancel() })
                return
            }
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            let hdr = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
            let s = PhoneSocket(c, buffer: Data(rest))
            phone = s
            c.send(content: Data(hdr.utf8), completion: .contentProcessed { _ in })
            onPhone?(s, h.fields)
            s.read()
            return
        }
        c.send(
            content: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
            completion: .contentProcessed { _ in c.cancel() })
    }
}

/// The server side of one WebSocket (RFC 6455: masked frames in, unmasked out, 2 MB max).
final class PhoneSocket: @unchecked Sendable {
    let c: NWConnection
    private var buf: Data
    var onMessage: ((Data) -> Void)?
    var onClose: (() -> Void)?
    private(set) var closed = false
    static let maxFrame = 2 << 20

    init(_ c: NWConnection, buffer: Data) {
        self.c = c
        buf = buffer
    }
    func read() {
        while let (op, payload) = Self.frame(&buf) {
            switch op {
            case 1, 2: onMessage?(payload)
            case 8: return close()
            case 9: send(payload, op: 10)
            default: break
            }
        }
        if buf.count > Self.maxFrame + 16 { return close() }
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] d, _, done, err in
            guard let self else { return }
            if let d { self.buf.append(d) }
            if done || err != nil { return self.close() }
            self.read()
        }
    }
    /// One whole frame off the front of `buf` (opcode, unmasked payload), or nil until it's all there.
    static func frame(_ buf: inout Data) -> (UInt8, Data)? {
        let b = [UInt8](buf.prefix(14))
        guard b.count >= 2 else { return nil }
        let op = b[0] & 0x0F
        let masked = b[1] & 0x80 != 0
        var len = Int(b[1] & 0x7F)
        var at = 2
        if len == 126 {
            guard b.count >= 4 else { return nil }
            len = Int(b[2]) << 8 | Int(b[3])
            at = 4
        } else if len == 127 {
            guard b.count >= 10 else { return nil }
            len = b[2..<10].reduce(0) { $0 << 8 | Int($1) }
            at = 10
        }
        guard len <= maxFrame else {
            buf.removeAll()
            return (8, Data())
        }
        let mask = masked ? Array(buf.dropFirst(at).prefix(4)) : []
        if masked { at += 4 }
        guard buf.count >= at + len else { return nil }
        var payload = [UInt8](buf.dropFirst(at).prefix(len))
        if masked { for i in payload.indices { payload[i] ^= mask[i % 4] } }
        buf = Data(buf.dropFirst(at + len))
        return (op, Data(payload))
    }
    static func encode(_ payload: Data, op: UInt8 = 2) -> Data {
        var h: [UInt8] = [0x80 | op]
        let n = payload.count
        if n < 126 {
            h.append(UInt8(n))
        } else if n < 65536 {
            h += [126, UInt8(n >> 8), UInt8(n & 0xFF)]
        } else {
            h.append(127)
            for i in (0..<8).reversed() { h.append(UInt8((n >> (8 * i)) & 0xFF)) }
        }
        return Data(h) + payload
    }
    func send(_ payload: Data, op: UInt8 = 2) {
        guard !closed else { return }
        c.send(content: Self.encode(payload, op: op), completion: .contentProcessed { _ in })
    }
    func close() {
        guard !closed else { return }
        closed = true
        c.send(content: Self.encode(Data(), op: 8), completion: .contentProcessed { [c] _ in c.cancel() })
        onClose?()
    }
}
