import Foundation

/// 真实上游请求执行器：非流式 fetch + 流式 SSE/NDJSON 逐行解析
public final class UpstreamClient: Sendable {
    public static let shared = UpstreamClient()

    private let session: URLSession
    public init(session: URLSession? = nil) {
        if let session { self.session = session; return }
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 600
        cfg.waitsForConnectivity = false
        cfg.httpAdditionalHeaders = nil
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: cfg)
    }

    // MARK: 非流式

    /// 执行请求并校验状态码；401/403/429/5xx 会转成 UpstreamError
    public func data(for call: UpstreamCall, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        let req = call.urlRequest(timeout: timeout)
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw UpstreamError.network("响应不是 HTTP")
            }
            if !(200..<300).contains(http.statusCode) {
                let body = String(data: data.prefix(800), encoding: .utf8) ?? ""
                let msg = Self.extractMessage(from: data) ?? body
                throw UpstreamError.http(status: http.statusCode, message: msg.isEmpty ? "HTTP \(http.statusCode)" : msg)
            }
            return (data, http)
        } catch let e as UpstreamError {
            throw e
        } catch let e as URLError {
            if e.code == .timedOut { throw UpstreamError.timeout }
            if e.code == .cancelled { throw AppError.cancel }
            throw UpstreamError.network(e.localizedDescription)
        }
    }

    /// 429 的 Retry-After 秒数
    public static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        if let v = response.value(forHTTPHeaderField: "Retry-After"), let s = Double(v) { return s }
        if let v = response.value(forHTTPHeaderField: "retry-after"), let s = Double(v) { return s }
        return nil
    }

    static func extractMessage(from data: Data) -> String? {
        guard let root = FRJSON.object(data) else { return nil }
        if let m = root["error"]?.object?["message"]?.string { return m }
        if let m = root["error"]?.string { return m }
        if let m = root["message"]?.string { return m }
        if let m = root["error"]?.object?["type"]?.string { return m }
        return nil
    }

    // MARK: 流式

    /// 逐行产出上游流式内容（已按适配器解析为 StreamPiece）
    public func stream(call: UpstreamCall, timeout: TimeInterval,
                       adapter: ProtocolAdapter, provider: Provider) -> AsyncThrowingStream<StreamPiece, Error> {
        AsyncThrowingStream { continuation in
            let task = session.dataTask(with: call.urlRequest(timeout: timeout))
            let delegate = StreamingDelegate(continuation: continuation, adapter: adapter, provider: provider)
            let holder = SessionDelegateHolder(delegate: delegate)
            task.resume()
            continuation.onTermination = { _ in
                task.cancel()
                _ = holder
            }
        }
    }

    /// 用 URLSession 的 bytes API（更稳：自动按行缓冲）
    public func streamLines(call: UpstreamCall, timeout: TimeInterval,
                            adapter: ProtocolAdapter, provider: Provider) -> AsyncThrowingStream<StreamPiece, Error> {
        AsyncThrowingStream { continuation in
            let req = call.urlRequest(timeout: timeout)
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: req)
                    guard let http = response as? HTTPURLResponse else {
                        throw UpstreamError.network("响应不是 HTTP")
                    }
                    if !(200..<300).contains(http.statusCode) {
                        var body = Data()
                        for try await b in bytes { body.append(b) }
                        let msg = Self.extractMessage(from: body) ?? String(data: body.prefix(600), encoding: .utf8) ?? ""
                        throw UpstreamError.http(status: http.statusCode, message: msg.isEmpty ? "HTTP \(http.statusCode)" : msg)
                    }
                    var sawDone = false
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        if line.isEmpty { continue }
                        guard let piece = adapter.parseStreamLine(line, provider: provider) else { continue }
                        if piece.isDone { sawDone = true; continuation.yield(piece); break }
                        continuation.yield(piece)
                    }
                    if !sawDone { continuation.yield(StreamPiece(isDone: true)) }
                    continuation.finish()
                } catch let e as UpstreamError {
                    continuation.finish(throwing: e)
                } catch is CancellationError {
                    continuation.finish(throwing: AppError.cancel)
                } catch let e as URLError {
                    if e.code == .timedOut { continuation.finish(throwing: UpstreamError.timeout) }
                    else if e.code == .cancelled { continuation.finish(throwing: AppError.cancel) }
                    else { continuation.finish(throwing: UpstreamError.network(e.localizedDescription)) }
                } catch {
                    continuation.finish(throwing: UpstreamError.network(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// 保留 delegate 引用的盒子（供旧式 dataTask 路径使用）
private final class SessionDelegateHolder: @unchecked Sendable {
    let delegate: StreamingDelegate
    init(delegate: StreamingDelegate) { self.delegate = delegate }
}

private final class StreamingDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let continuation: AsyncThrowingStream<StreamPiece, Error>.Continuation
    private let adapter: ProtocolAdapter
    private let provider: Provider
    private var buffer = Data()
    private var statusCode = 0

    init(continuation: AsyncThrowingStream<StreamPiece, Error>.Continuation,
         adapter: ProtocolAdapter, provider: Provider) {
        self.continuation = continuation
        self.adapter = adapter
        self.provider = provider
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse { statusCode = http.statusCode }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if statusCode != 0 && !(200..<300).contains(statusCode) { return }
        buffer.append(data)
        while let idx = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<idx)
            buffer.removeSubrange(buffer.startIndex...idx)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            if let piece = adapter.parseStreamLine(line, provider: provider) {
                continuation.yield(piece)
                if piece.isDone { continuation.finish(); return }
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            if (error as? URLError)?.code == .cancelled { continuation.finish(throwing: AppError.cancel); return }
            if statusCode != 0 && !(200..<300).contains(statusCode) {
                continuation.finish(throwing: UpstreamError.http(status: statusCode, message: "HTTP \(statusCode)"))
            } else {
                continuation.finish(throwing: UpstreamError.network(error.localizedDescription))
            }
            return
        }
        continuation.yield(StreamPiece(isDone: true))
        continuation.finish()
    }
}
