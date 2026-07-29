import Foundation

/// Location of the herdr server's control socket.
enum HerdrPaths {
    static var socketPath: String {
        if let override = ProcessInfo.processInfo.environment["HERDR_SOCKET_PATH"], !override.isEmpty {
            return override
        }
        let config = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".config")
        return (config as NSString).appendingPathComponent("herdr/herdr.sock")
    }
}

/// Thin line-delimited-JSON client over herdr's unix domain socket.
///
/// The protocol is one JSON object per line: requests carry `{id, method, params}`,
/// replies carry the same `id` plus `result` or `error`, and subscription events
/// arrive unsolicited as `{event, data}`.
enum HerdrSocket {

    private static func connect(timeout: TimeInterval = 5) -> Int32? {
        let path = HerdrPaths.socketPath
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxLen else { return nil }
        withUnsafeMutablePointer(to: &addr.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: maxLen) { dst in
                _ = path.withCString { strcpy(dst, $0) }
            }
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        // A server restart can close the socket between connect() and send().
        // Suppress SIGPIPE so that becomes an ordinary transport failure instead
        // of terminating the whole Touch Bar process.
        var noSigPipe: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe,
                         socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            close(fd)
            return nil
        }

        if timeout > 0 {
            var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv,
                       socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv,
                       socklen_t(MemoryLayout<timeval>.size))
        }

        let ok = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        if !ok { close(fd); return nil }
        return fd
    }

    private static func writeLine(_ fd: Int32, _ object: [String: Any]) -> Bool {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return false }
        data.append(0x0A)
        return data.withUnsafeBytes { buf -> Bool in
            var sent = 0
            let base = buf.bindMemory(to: UInt8.self).baseAddress!
            while sent < data.count {
                let n = send(fd, base + sent, data.count - sent, 0)
                if n < 0, errno == EINTR { continue }
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }

    /// Blocking request/response on a short-lived connection.
    /// Returns the `result` object, or nil on any transport/protocol failure.
    @discardableResult
    static func request(_ method: String, _ params: [String: Any] = [:]) -> [String: Any]? {
        guard let fd = connect() else { return nil }
        defer { close(fd) }
        guard writeLine(fd, ["id": "tb", "method": method, "params": params]) else { return nil }

        let reader = LineReader(fd: fd)
        // Skip any events that race in ahead of our reply.
        while let line = reader.next() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if obj["id"] as? String == "tb" {
                if obj["error"] != nil {
                    Log.debug("\(method) request was rejected")
                    return nil
                }
                return obj["result"] as? [String: Any]
            }
        }
        return nil
    }

    /// Opens a long-lived subscription. Blocks the calling thread, invoking
    /// `onEvent` for each event. The handler returns false when its filter set
    /// needs to be rebuilt; the return value distinguishes that from a dropped
    /// or rejected connection.
    @discardableResult
    static func subscribe(_ subscriptions: [[String: Any]],
                          onEvent: @escaping ([String: Any]) -> Bool) -> Bool {
        // No receive timeout: an idle subscription may legitimately stay quiet.
        guard let fd = connect(timeout: 0) else { return false }
        defer { close(fd) }
        guard writeLine(fd, ["id": "sub", "method": "events.subscribe",
                             "params": ["subscriptions": subscriptions]]) else { return false }

        let reader = LineReader(fd: fd)
        while let line = reader.next() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if obj["error"] != nil {
                Log.warn("event subscription was rejected")
                return false
            }
            if obj["event"] != nil, !onEvent(obj) { return true }
        }
        return false
    }
}

/// Buffers socket bytes and hands back one newline-terminated line at a time.
private final class LineReader {
    private let fd: Int32
    private var buffer = Data()
    private var eof = false

    init(fd: Int32) { self.fd = fd }

    func next() -> String? {
        while true {
            if let idx = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<idx)
                buffer.removeSubrange(buffer.startIndex...idx)
                if line.isEmpty { continue }
                return String(data: line, encoding: .utf8)
            }
            if eof { return nil }

            var chunk = [UInt8](repeating: 0, count: 16384)
            let n = recv(fd, &chunk, chunk.count, 0)
            if n < 0, errno == EINTR { continue }
            if n <= 0 { eof = true; return nil }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }
}
