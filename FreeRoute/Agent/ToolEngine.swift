import Foundation
import PDFKit
import Vision
import ImageIO
import UniformTypeIdentifiers
import JavaScriptCore

/// 真实工具执行引擎。
/// 设计约束：这里没有任何"模型说它做了"的路径。每个工具要么访问真实资源
/// （URLSession / FileManager / PDFKit / Vision / ImageIO / JavaScriptCore / Foundation），
/// 要么返回明确的错误，说明本机做不到什么。ToolEngine 是聊天 UI 与 API 网关共用的
/// 唯一执行点 —— 两条入口不可能出现"一边真执行、一边假执行"。
public enum ToolEngine {
    public static func execute(_ call: ToolCall, ctx: ToolContext) async -> ToolResult {
        let started = Date()
        guard let spec = ToolCatalog.spec(call.name) else {
            return failure(call, started, .notFound("未注册的工具：\(call.name)"))
        }
        if let problem = ToolGuard.validate(spec, call.arguments) {
            return failure(call, started, .invalid(problem))
        }
        let decision = ToolGuard.check(spec, call, ctx)
        switch decision.verdict {
        case .denied:
            return failure(call, started, .denied(decision.reason))
        case .needsConfirmation:
            // 不执行；把令牌交回给调用方，由 UI 弹窗或 API 客户端再带回来。
            return ToolResult(callId: call.id, name: call.name, ok: false,
                              content: "需要用户明确授权后才能执行。确认令牌：\(decision.confirmationToken ?? "")",
                              evidence: "未执行：等待授权", durationMs: Date().timeIntervalSince(started) * 1000,
                              startedAt: started, error: decision.reason)
        case .allowed:
            break
        }
        if spec.requiresConfirmation, let token = call.argString("_confirm"), !token.isEmpty {
            // 一次性令牌由上层（AgentRunner）在真正执行后消费，这里不改动持久存储。
            _ = token
        }
        do {
            var output = try await run(spec: spec, call: call, ctx: ctx)
            output = String(output.prefix(ctx.maxResultChars))
            let truncated = output.count >= ctx.maxResultChars
            return ToolResult(callId: call.id, name: call.name, ok: true, content: output,
                              evidence: evidence(for: call.name, ctx: ctx),
                              durationMs: Date().timeIntervalSince(started) * 1000,
                              startedAt: started, truncated: truncated)
        } catch let e as ToolRuntimeError {
            return failure(call, started, e)
        } catch is CancellationError {
            return failure(call, started, .failed("工具执行被取消"))
        } catch {
            return failure(call, started, .failed(error.localizedDescription))
        }
    }

    private static func failure(_ call: ToolCall, _ started: Date, _ e: ToolRuntimeError) -> ToolResult {
        ToolResult(callId: call.id, name: call.name, ok: false, content: "工具执行失败：\(e.errorDescription ?? "未知错误")",
                   evidence: "未产生执行结果", durationMs: Date().timeIntervalSince(started) * 1000,
                   startedAt: started, error: e.errorDescription)
    }

    private static func evidence(for name: String, ctx: ToolContext) -> String {
        switch name {
        case "web.search": return "URLSession → html.duckduckgo.com（真实 HTTP 响应解析）"
        case "web.open", "http.get": return "URLSession 真实请求；URLGuard SSRF 防护=\(ctx.allowPrivateHTTP ? "放开" : "启用")"
        case "file.list", "file.read", "file.write", "file.analyze", "data.json", "data.csv", "data.excel":
            return "FileManager 授权目录=\(ctx.authorizedRoot)"
        case "image.ocr": return "Apple Vision VNRecognizeTextRequest"
        case "image.info": return "ImageIO CGImageSource / UTType"
        case "image.understand": return "Apple Vision VNClassifyImageRequest + OCR"
        case "code.js": return "JavaScriptCore JSContext 真实求值"
        case "code.run": return ctx.remoteExecutorURL == nil ? "本机 JS 沙箱；未配置远程执行器" : "远程执行器真实 HTTP 调用"
        case "code.check": return "本机静态扫描（括号/引号/行数）"
        case "time.now", "time.convert": return "Foundation Date / TimeZone / Calendar"
        case "calc.eval": return "NSExpression 白名单求值"
        case "calc.unit": return "Foundation Dimension/Unit 或固定系数换算"
        case "local.logs", "local.tokens", "local.models", "local.session":
            return "SwiftData 请求日志与本机状态快照"
        case "local.gateway", "lan.status": return "GatewayServer.snapshot()"
        case "lan.devices": return "ToolPermissionStore 设备批准表"
        default: return "本机真实执行"
        }
    }

    // MARK: 分发

    private static func run(spec: ToolSpec, call: ToolCall, ctx: ToolContext) async throws -> String {
        switch call.name {
        case "web.search":      return try await webSearch(call, ctx)
        case "web.open":        return try await openURL(call, ctx, isHTTPTool: false)
        case "http.get":        return try await openURL(call, ctx, isHTTPTool: true)
        case "file.list":       return try fileList(call)
        case "file.read":       return try fileRead(call)
        case "file.write":      return try fileWrite(call)
        case "file.analyze":    return try fileAnalyze(call)
        case "image.ocr":       return try imageOCR(call)
        case "image.info":      return try imageInfo(call)
        case "image.understand": return try await imageUnderstand(call, ctx)
        case "code.js":         return try codeJS(call)
        case "code.run":        return try await codeRun(call, ctx)
        case "code.check":      return try codeCheck(call)
        case "data.json":       return try dataJSON(call)
        case "data.csv":        return try dataCSV(call)
        case "data.excel":      return try dataExcel(call)
        case "time.now":        return try timeNow(call)
        case "time.convert":    return try timeConvert(call)
        case "calc.eval":       return try calcEval(call)
        case "calc.unit":       return try calcUnit(call)
        case "local.session":   return localSession(ctx)
        case "local.logs":      return localLogs(call, ctx)
        case "local.models":    return localModels(ctx)
        case "local.tokens":    return localTokens(ctx)
        case "local.gateway":  return localGateway(ctx)
        case "lan.devices":     return lanDevices(ctx)
        case "lan.status":      return lanStatus(ctx)
        default: throw ToolRuntimeError.notFound("未注册的工具：\(call.name)")
        }
    }

    // MARK: 联网搜索

    private static func webSearch(_ call: ToolCall, _ ctx: ToolContext) async throws -> String {
        let query = call.argString("query")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !query.isEmpty else { throw ToolRuntimeError.invalid("搜索关键词不能为空") }
        let limit = min(10, max(1, call.argInt("limit") ?? 5))
        guard var comps = URLComponents(string: "https://html.duckduckgo.com/html/") else {
            throw ToolRuntimeError.failed("无法构造搜索 URL")
        }
        comps.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = comps.url else { throw ToolRuntimeError.failed("无法构造搜索 URL") }
        var req = URLRequest(url: url)
        req.timeoutInterval = min(specTimeout("web.search"), ctx.toolTimeout)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 FreeRouteAI/2.0",
                     forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw ToolRuntimeError.failed("搜索服务返回 HTTP \(status)") }
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw ToolRuntimeError.failed("搜索响应不是可解码文本")
        }
        let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        // 用捕获组直接抓每个 result__a 锚点，再就近取 snippet —— 不依赖不稳定的块结构
        let anchors = HTMLText.captures(
            #"(?is)<a[^>]*class=\"[^\"]*result__a[^\"]*\"[^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a>"#, in: html)
        var items: [String] = []
        for a in anchors {
            guard a.count >= 3 else { continue }
            let href = a[1], titleHTML = a[2]
            let title = HTMLText.plain(titleHTML, maxChars: 180).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            // 在锚点之后的一段窗口里找 snippet
            var snippet = ""
            if let anchorRange = html.range(of: titleHTML) {
                let tail = String(html[anchorRange.upperBound...].prefix(3000))
                if let sn = HTMLText.group(#"(?is)class=\"[^\"]*result__snippet[^>]*\"[^>]*>(.*?)</"#, in: tail) {
                    snippet = HTMLText.plain(sn, maxChars: 300).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            let link = decodeDDG(href)
            items.append("[\(items.count + 1)] \(title)\n    URL: \(link)\n    摘要: \(snippet)")
            if items.count >= limit { break }
        }
        if items.isEmpty {
            // 解析不到结构化结果时如实报告，不编造
            let anyLinks = HTMLText.captures(#"href=\"(https?://[^\"]+)\""#, in: html).map { $0[1] }
            let unique = Array(NSOrderedSet(array: anyLinks.map { HTMLText.decodeEntities($0) })).prefix(limit)
            return "搜索「\(query)」：HTTP \(status)，响应 \(data.count) 字节，结构化结果解析为 0 条。\n"
                + "原始页面中的外部链接（未确认是搜索结果，需人工核对）：\n"
                + unique.enumerated().map { "[\($0.offset + 1)] \($0.element)" }.joined(separator: "\n")
        }
        return "搜索「\(query)」：HTTP \(status)，响应 \(data.count) 字节，实际解析到 \(items.count) 条结果。\n"
            + "以下来源 URL 均来自本次真实 HTTP 响应，可直接引用：\n\n" + items.joined(separator: "\n\n")
    }

    private static func decodeDDG(_ href: String) -> String {
        var s = HTMLText.decodeEntities(href)
        if s.hasPrefix("//duckduckgo.com/l/?uddg="),
           let range = s.range(of: "uddg="),
           let decoded = String(s[range.upperBound...]).split(separator: "&").first?.removingPercentEncoding {
            return decoded
        }
        return s
    }

    private static func openURL(_ call: ToolCall, _ ctx: ToolContext, isHTTPTool: Bool) async throws -> String {
        guard let raw = call.argString("url"), !raw.isEmpty else { throw ToolRuntimeError.invalid("缺少 url") }
        let url = try URLGuard.validate(raw, allowPrivate: ctx.allowPrivateHTTP)
        if !ctx.allowPrivateHTTP, let host = url.host, URLGuard.resolvedIsBlocked(host) {
            throw ToolRuntimeError.denied("DNS 解析指向本机/内网地址，已阻止：\(host)")
        }
        let maxChars = min(20_000, max(200, call.argInt("maxChars") ?? 4000))
        var req = URLRequest(url: url)
        req.timeoutInterval = min(specTimeout(isHTTPTool ? "http.get" : "web.open"), ctx.toolTimeout)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 FreeRouteAI/2.0",
                     forHTTPHeaderField: "User-Agent")
        if isHTTPTool, let headers = call.arguments["headers"]?.object {
            for (k, v) in headers {
                guard let s = v.string else { continue }
                let lower = k.lowercased()
                if lower == "host" || lower == "content-length" || lower == "authorization" { continue }
                req.setValue(s, forHTTPHeaderField: k)
            }
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        guard (200..<400).contains(status) else { throw ToolRuntimeError.failed("HTTP \(status)") }
        let mime = http?.mimeType ?? "application/octet-stream"
        if !(mime.contains("html") || mime.contains("text") || mime.contains("json") || mime.contains("xml")) {
            return "最终 URL：\(response.url?.absoluteString ?? url.absoluteString)\nHTTP \(status)\nContent-Type：\(mime)\n字节数：\(data.count)\n非文本内容，未提取正文（可用 file 工具分析已下载文件）。"
        }
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        let body = mime.contains("html") ? HTMLText.plain(text, maxChars: maxChars) : String(text.prefix(maxChars))
        return "最终 URL：\(response.url?.absoluteString ?? url.absoluteString)\nHTTP \(status)\nContent-Type：\(mime)\n响应字节数：\(data.count)\n正文（最多 \(maxChars) 字符）：\n\(body)"
    }

    private static func specTimeout(_ name: String) -> TimeInterval {
        ToolCatalog.spec(name)?.timeout ?? 20
    }

    // MARK: 文件

    private static func fileList(_ call: ToolCall) throws -> String {
        let sub = call.argString("path") ?? ""
        let dir = sub.isEmpty ? try AuthorizedFiles.root() : try AuthorizedFiles.exists(sub)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            throw ToolRuntimeError.invalid("\(sub) 不是目录")
        }
        let entries = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey])
        if entries.isEmpty { return "授权目录内无文件。\n目录：\(dir.path)\n提示：可用 file.write 生成文件，或用聊天里的「导入文件」把文件放入该目录。" }
        let lines = entries.prefix(100).map { u -> String in
            let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey])
            let size = v?.fileSize ?? 0
            let date = v?.contentModificationDate.map { AgentTime.iso($0) } ?? "-"
            let kind = (v?.isDirectory ?? false) ? "目录" : "文件"
            return "\(kind)\t\(size) B\t\(date)\t\(u.lastPathComponent)"
        }
        return "授权目录：\(dir.path)\n共 \(entries.count) 项（最多显示 100）：\n" + lines.joined(separator: "\n")
    }

    private static func fileRead(_ call: ToolCall) throws -> String {
        guard let path = call.argString("path") else { throw ToolRuntimeError.invalid("缺少 path") }
        let url = try AuthorizedFiles.exists(path)
        let maxChars = min(40_000, max(200, call.argInt("maxChars") ?? 8000))
        if url.pathExtension.lowercased() == "pdf" {
            guard let doc = PDFDocument(url: url) else { throw ToolRuntimeError.failed("PDFKit 无法打开该 PDF") }
            var text = ""
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i) { text += (page.string ?? "") + "\n" }
            }
            return "PDF：\(url.lastPathComponent)\n页数：\(doc.pageCount)\n提取字符数：\(text.count)\n\n" + String(text.prefix(maxChars))
        }
        let data = try Data(contentsOf: url)
        guard let s = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return "文件 \(url.lastPathComponent) 为二进制数据（\(data.count) 字节），无法按文本读取。可用 image.info / image.ocr / file.analyze。"
        }
        return "文件：\(url.lastPathComponent)\n字节数：\(data.count)\n字符数：\(s.count)\n\n" + String(s.prefix(maxChars))
    }

    private static func fileWrite(_ call: ToolCall) throws -> String {
        guard let path = call.argString("path"), let content = call.argString("content") else {
            throw ToolRuntimeError.invalid("缺少 path 或 content")
        }
        let url = try AuthorizedFiles.resolve(path)
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url, options: .atomic)
        return "已真实写入：\(url.lastPathComponent)\n路径：\(url.path)\n字节数：\(Data(content.utf8).count)"
    }

    private static func fileAnalyze(_ call: ToolCall) throws -> String {
        guard let path = call.argString("path") else { throw ToolRuntimeError.invalid("缺少 path") }
        let url = try AuthorizedFiles.exists(path)
        let ext = url.pathExtension.lowercased()
        let data = try Data(contentsOf: url)
        switch ext {
        case "pdf":
            guard let doc = PDFDocument(url: url) else { throw ToolRuntimeError.failed("PDFKit 无法打开") }
            var text = ""
            for i in 0..<doc.pageCount { text += (doc.page(at: i)?.string ?? "") + "\n" }
            let meta = doc.documentAttributes?.map { "\($0.key)=\($0.value)" }.joined(separator: ", ") ?? ""
            return "PDF 分析：\(url.lastPathComponent)\n字节数：\(data.count)\n页数：\(doc.pageCount)\n提取字符：\(text.count)\n元数据：\(meta)\n\n前 4000 字：\n" + String(text.prefix(4000))
        case "csv", "tsv":
            let text = String(data: data, encoding: .utf8) ?? ""
            return "CSV 分析（真实解析）\n" + CSVAnalyzer.report(ext == "tsv" ? text.replacingOccurrences(of: "\t", with: ",") : text,
                                                             source: url.lastPathComponent)
        case "json":
            return "JSON 分析（真实解析）\n" + jsonReport(AgentJSON.parse(data), source: url.lastPathComponent)
        case "xlsx", "xls":
            let sig = data.prefix(4).map { String(format: "%02x", $0) }.joined()
            return "Excel 分析：\(url.lastPathComponent)\n字节数：\(data.count)\n文件头：\(sig)（OOXML/xlsx 为 ZIP，签名 504b0304）\n"
                + "本机未内置 ZIP/DEFLATE 解压与 OOXML 单元格解析器，无法逐单元格读取；不会伪造表格内容。\n"
                + "可执行替代：把工作表导出为 .csv，再用 data.csv / file.analyze 做真实行列与数值统计。"
        default:
            let text = String(data: data, encoding: .utf8) ?? ""
            return "文件：\(url.lastPathComponent)\n字节数：\(data.count)\n扩展名：\(ext)\n"
                + "代码/文本结构（真实统计）：\n" + CodeChecker.check(text, language: ext.isEmpty ? "text" : ext)
        }
    }

    private static func jsonReport(_ v: JSONValue?, source: String) -> String {
        guard let v else { return "来源：\(source)\nJSON 解析失败：不是合法 JSON" }
        switch v {
        case .object(let o):
            let keys = o.keys.sorted()
            let types = keys.map { "\($0): \(jsonType(o[$0]))" }
            return "来源：\(source)\n顶层类型：object\n键数量：\(keys.count)\n键与类型：\n" + types.joined(separator: "\n")
        case .array(let a):
            return "来源：\(source)\n顶层类型：array\n元素数：\(a.count)\n首元素类型：\(a.first.map { jsonType($0) } ?? "无")"
        default: return "来源：\(source)\n顶层类型：\(jsonType(v))\n值：\(v.jsonString)"
        }
    }

    private static func jsonType(_ v: JSONValue?) -> String {
        guard let v else { return "nil" }
        switch v {
        case .null: return "null"; case .bool: return "bool"; case .number: return "number"
        case .string: return "string"; case .array: return "array"; case .object: return "object"
        }
    }
}
