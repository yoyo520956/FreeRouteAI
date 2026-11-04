import Foundation
import Network

/// 网关状态
public struct GatewayStatus: Codable, Hashable, Sendable {
    public var isRunning: Bool = false
    public var port: Int = 3000
    public var lanEnabled: Bool = false
    public var lanAddress: String?
    public var loopbackAddress: String = "http://127.0.0.1:3000"
    public var connectionCount: Int = 0
    public var totalRequests: Int = 0
    public var startedAt: Date?
    public var lastError: String?

    public init() {}
}

/// 网关请求（已解析）
public struct GatewayRequest: Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    public var headers: [String: String]
    public var body: Data

    public func jsonBody<T: Decodable>(_ type: T.Type) throws -> T {
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        return try dec.decode(type, from: body)
    }
}

/// 一次 HTTP 交换（可持续写 SSE）
public final class HTTPExchange: @unchecked Sendable {
    fileprivate let conn: NWConnection
    fileprivate let serverRef: GatewayServer
    fileprivate var headSent = false
    fileprivate var isStreaming = false
    private let lock = NSLock()

    fileprivate init(conn: NWConnection, server: GatewayServer) {
        self.conn = conn
        self.serverRef = server
    }

    private func markHead(_ streaming: Bool) {
        lock.lock(); headSent = true; isStreaming = streaming; lock.unlock()
    }
    private var alreadyHead: Bool {
        lock.lock(); defer { lock.unlock() }; return headSent
    }

    /// 发送非流式 JSON
    public func json(_ object: Any, status: Int = 200) {
        guard !alreadyHead else { return }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])) ?? Data("{}".utf8)
        serverRef.writeHead(conn: conn, status: status, headers: ["Content-Type": "application/json; charset=utf-8",
                                                                  "Content-Length": "\(data.count)",
                                                                  "Connection": "close"], body: data, streaming: false)
        markHead(false)
    }

    /// 发送原始数据
    public func raw(_ data: Data, status: Int = 200, contentType: String = "application/octet-stream") {
        guard !alreadyHead else { return }
        serverRef.writeHead(conn: conn, status: status,
                            headers: ["Content-Type": contentType, "Content-Length": "\(data.count)", "Connection": "close"],
                            body: data, streaming: false)
        markHead(false)
    }

    public func error(_ message: String, status: Int = 400, type: String = "invalid_request_error") {
        json(["error": ["message": message, "type": type, "code": NSNull()]], status: status)
    }

    /// 开始 SSE（先发响应头，之后可多次 sseLine）
    public func beginSSE(status: Int = 200) {
        guard !alreadyHead else { return }
        serverRef.writeHead(conn: conn, status: status,
                            headers: ["Content-Type": "text/event-stream; charset=utf-8",
                                      "Cache-Control": "no-cache",
                                      "X-Accel-Buffering": "no",
                                      "Connection": "keep-alive"],
                            body: Data(), streaming: true)
        markHead(true)
    }

    /// 写一行 SSE（自动补 data: 与空行）
    public func sseLine(_ payload: String) {
        if !alreadyHead { beginSSE() }
        let text = payload.hasPrefix("data:") ? payload : "data: \(payload)\n\n"
        conn.send(content: Data(text.utf8), completion: .contentProcessed { _ in })
    }

    /// 写原始 SSE（自行控制格式，用于 [DONE]）
    public func sseRaw(_ payload: String) {
        if !alreadyHead { beginSSE() }
        conn.send(content: Data(payload.utf8), completion: .contentProcessed { _ in })
    }

    /// 结束并关闭连接
    public func finish() {
        conn.send(content: nil, contentContext: .finalMessage, isComplete: true,
                  completion: .contentProcessed { [weak self] _ in
            self?.serverRef.closeAndForget(self?.conn)
        })
    }

    public var remoteDescription: String { conn.endpoint.debugDescription }
}

/// 本地 / 局域网 HTTP 网关（Network.framework，OpenAI 兼容接口）
public final class GatewayServer: @unchecked Sendable {
    private var listener: NWListener?
    private let stateQueue = DispatchQueue(label: "com.freeroute.gateway.state")
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var requestCount = 0
    private var startedAtValue: Date?

    public let statusHandler: @Sendable (GatewayStatus) -> Void
    public let requestHandler: @Sendable (GatewayRequest, HTTPExchange) -> Void
    public let isLANEnabled: @Sendable () -> Bool
    public let portProvider: @Sendable () -> Int

    public init(statusHandler: @escaping @Sendable (GatewayStatus) -> Void,
                requestHandler: @escaping @Sendable (GatewayRequest, HTTPExchange) -> Void,
                isLANEnabled: @escaping @Sendable () -> Bool,
                portProvider: @escaping @Sendable () -> Int) {
        self.statusHandler = statusHandler
        self.requestHandler = requestHandler
        self.isLANEnabled = isLANEnabled
        self.portProvider = portProvider
    }

    // MARK: 启停

    public func start() {
        stopInternal()
        let port = portProvider()
        let lan = isLANEnabled()
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointEvaluation = true
            params.requiredLocalEndpoint = .workload
            params.allowLocalNetworkAccess = true
            let nwPort = NWEndpoint.Port(rawValue: UInt16(max(1, min(65535, port)))) ?? 3000
            let listener = try NWListener(using: params, on: nwPort)
            listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.stateQueue.sync { self.startedAtValue = Date() }
                    self.publish(running: true, port: port, lan: lan, error: nil)
                case .failed(let e):
                    self.publish(running: false, port: port, lan: lan, error: e.localizedDescription)
                case .cancelled:
                    self.publish(running: false, port: port, lan: lan, error: nil)
                default:
                    break
                }
            }
            listener.start(queue: stateQueue)
            listener.stateUpdateHandler?(.ready)
            self.listener = listener
        } catch {
            publish(running: false, port: port, lan: lan, error: error.localizedDescription)
        }
    }

    public func stop() {
        stopInternal()
        publish(running: false, port: portProvider(), lan: isLANEnabled(), error: nil)
    }

    private func stopInternal() {
        stateQueue.sync {
            listener?.cancel()
            listener = nil
            for (_, c) in connections { c.cancel() }
            connections.removeAll()
            startedAtValue = nil
        }
    }

    private func publish(running: Bool, port: Int, lan: Bool, error: String?) {
        var s = GatewayStatus()
        s.isRunning = running
        s.port = port
        s.lanEnabled = lan
        s.loopbackAddress = "http://127.0.0.1:\(port)"
        s.lanAddress = lan ? Self.lanIPAddress().map { "http://\($0):\(port)" } : nil
        s.connectionCount = stateQueue.sync { connections.count }
        s.totalRequests = stateQueue.sync { requestCount }
        s.startedAt = stateQueue.sync { startedAtValue }
        s.lastError = error
        statusHandler(s)
    }

    public func snapshot() -> GatewayStatus {
        var s = GatewayStatus()
        s.isRunning = stateQueue.sync { listener != nil }
        s.port = portProvider()
        s.lanEnabled = isLANEnabled()
        s.loopbackAddress = "http://127.0.0.1:\(s.port)"
        s.lanAddress = s.lanEnabled ? Self.lanIPAddress().map { "http://\($0):\(s.port)" } : nil
        s.connectionCount = stateQueue.sync { connections.count }
        s.totalRequests = stateQueue.sync { requestCount }
        s.startedAt = stateQueue.sync { startedAtValue }
        return s
    }

    /// 主动刷新一次状态（连接数变化时）
    public func refreshStatus() {
        publish(running: stateQueue.sync { listener != nil }, port: portProvider(), lan: isLANEnabled(), error: nil)
    }

    /// 本机局域网 IPv4
    public static func lanIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let flags = Int32(p.pointee.ifa_flags)
            if let addrPtr = p.pointee.ifa_addr {
                let addr = addrPtr.pointee
                let upRunning = (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING)
                if upRunning, !(flags & IFF_LOOPBACK != 0), addr.sa_family == UInt8(AF_INET) {
                    let name = String(cString: p.pointee.ifa_name)
                    if name.hasPrefix("en") || name.hasPrefix("awdl") {
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        if getnameinfo(addrPtr, socklen_t(addr.sa_len), &hostname, socklen_t(hostname.count),
                                       nil, 0, NI_NUMERICHOST) == 0 {
                            let ip = String(cString: hostname)
                            if name == "en0" { freeifaddrs(ifaddr); return ip }
                            address = address ?? ip
                        }
                    }
                }
            }
            ptr = p.pointee.ifa_next
        }
        freeifaddrs(ifaddr)
        return address
    }

    // MARK: 连接处理

    private func accept(_ conn: NWConnection) {
        stateQueue.sync { connections[ObjectIdentifier(conn)] = conn }
        conn.start(queue: stateQueue)
        refreshStatus()
        readRequest(conn, buffer: Data())
    }

    fileprivate func closeAndForget(_ conn: NWConnection?) {
        guard let conn else { return }
        conn.cancel()
        stateQueue.sync { connections[ObjectIdentifier(conn)] = nil }
        refreshStatus()
    }

    fileprivate func writeHead(conn: NWConnection, status: Int, headers: [String: String], body: Data, streaming: Bool) {
        let reason = HTTPReason.text(for: status)
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        let payload = Data(head.utf8) + (streaming ? Data() : body)
        conn.send(content: payload, completion: .contentProcessed { [weak self] _ in
            if !streaming { self?.closeAndForget(conn) }
        })
    }

    private func readRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if error != nil {
                self.closeAndForget(conn)
                return
            }
            if let req = self.parse(buf) {
                self.stateQueue.sync { self.requestCount += 1 }
                let exchange = HTTPExchange(conn: conn, server: self)
                self.requestHandler(req, exchange)
            } else if isComplete {
                let ex = HTTPExchange(conn: conn, server: self)
                ex.error("请求不完整", status: 400)
            } else if buf.count > 2_097_152 {
                let ex = HTTPExchange(conn: conn, server: self)
                ex.error("请求体过大", status: 413)
            } else {
                self.readRequest(conn, buffer: buf)
            }
        }
    }

    private func parse(_ data: Data) -> GatewayRequest? {
        guard let range = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headData = data.subdata(in: data.startIndex..<range.lowerBound)
        guard let head = String(data: headData, encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return nil }
        let method = parts[0]
        let target = parts[1]
        var path = target
        var query: [String: String] = [:]
        if let q = target.range(of: "?") {
            path = String(target[..<q.lowerBound])
            for pair in String(target[q.upperBound...]).components(separatedBy: "&") {
                let kv = pair.components(separatedBy: "=")
                if kv.count == 2 { query[kv[0]] = kv[1].removingPercentEncoding ?? kv[1] }
            }
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let c = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<c].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        let bodyStart = range.upperBound
        let expected = Int(headers["content-length"] ?? "0") ?? 0
        if expected > data.count - bodyStart { return nil }
        let body = data.subdata(in: bodyStart..<(bodyStart + expected))
        return GatewayRequest(method: method, path: path, query: query, headers: headers, body: body)
    }
}

enum HTTPReason {
    static func text(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 408: return "Request Timeout"
        case 409: return "Conflict"
        case 413: return "Payload Too Large"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }
}
