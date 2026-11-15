import Foundation
import Network
import PDFKit
import Vision
import ImageIO
import UniformTypeIdentifiers
import JavaScriptCore

// MARK: - URL 安全（SSRF 防护）
// 默认拒绝回环、私网、链路本地、云元数据。用户显式开启 allowPrivateHTTP 才放行。

public enum URLGuard {
    public static func validate(_ raw: String, allowPrivate: Bool) throws -> URL {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else {
            throw ToolRuntimeError.invalid("URL 无效或缺少 http/https 协议：\(raw)")
        }
        if allowPrivate { return url }
        if isBlocked(host) {
            throw ToolRuntimeError.denied("已阻止访问本机/内网/元数据地址：\(host)")
        }
        return url
    }

    public static func isBlocked(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h == "localhost.localdomain" || h.hasSuffix(".localhost")
            || h == "metadata.google.internal" || h == "metadata" || h == "169.254.169.254"
            || h == "::1" || h == "[::1]" || h.hasSuffix(".internal") { return true }
        if isIPv4(h) { return isPrivateIPv4(h) }
        // 非 IP 的域名还需在连接前做一次解析校验（防止 DNS 重绑定到私网）
        return false
    }

    public static func resolvedIsBlocked(_ host: String) -> Bool {
        if isIPv4(host) { return isPrivateIPv4(host) }
        if isBlocked(host) { return true }
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return false }
        defer { freeaddrinfo(result) }
        var p: UnsafeMutablePointer<addrinfo>? = first
        while let cur = p {
            let sa = cur.pointee.ai_addr
            if sa?.pointee.sa_family == UInt8(AF_INET) {
                var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let addr = UnsafeMutableRawPointer(sa!).assumingMemoryBound(to: sockaddr_in.self)
                var sin = addr.pointee.sin_addr
                if inet_ntop(AF_INET, &sin, &buf, socklen_t(buf.count)) != nil {
                    let ip = String(cString: buf)
                    if isPrivateIPv4(ip) { return true }
                }
            }
            p = cur.pointee.ai_next
        }
        return false
    }

    private static func isIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { Int($0) != nil && Int($0)! >= 0 && Int($0)! <= 255 }
    }

    private static func isPrivateIPv4(_ ip: String) -> Bool {
        let p = ip.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4 else { return false }
        let (a, b) = (p[0], p[1])
        if a == 10 || a == 127 || a == 0 { return true }
        if a == 169 && b == 254 { return true }
        if a == 172 && (16...31).contains(b) { return true }
        if a == 192 && b == 168 { return true }
        if a == 100 && (64...127).contains(b) { return true }
        if a == 192 && b == 0 && p[2] == 0 { return true }
        if a == 198 && (b == 18 || b == 19) { return true }
        if a >= 224 { return true }
        return false
    }
}

public enum ToolRuntimeError: LocalizedError, Sendable {
    case invalid(String)
    case denied(String)
    case notFound(String)
    case unsupported(String)
    case timeout(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let s), .denied(let s), .notFound(let s),
             .unsupported(let s), .timeout(let s), .failed(let s): return s
        }
    }
}

// MARK: - 授权目录（路径穿越防护）

public enum AuthorizedFiles {
    public static func root() throws -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FreeRouteFiles", isDirectory: true)
        if !fm.fileExists(atPath: base.path) {
            try fm.createDirectory(at: base, withIntermediateDirectories: true)
        }
        return base
    }

    /// 只允许授权目录内的相对路径；绝对路径、..、符号链接逃逸一律拒绝。
    public static func resolve(_ relative: String) throws -> URL {
        let root = try root()
        let clean = relative.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return root }
        guard !clean.hasPrefix("/"), !clean.contains(".."), !clean.contains("\0") else {
            throw ToolRuntimeError.denied("路径必须是授权目录内的相对路径，不允许绝对路径或 ..")
        }
        let url = root.appendingPathComponent(clean).standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        guard url.path == rootPath || url.path.hasPrefix(rootPath + "/") else {
            throw ToolRuntimeError.denied("路径超出授权目录")
        }
        if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
            throw ToolRuntimeError.denied("不允许通过符号链接访问授权目录外的文件")
        }
        return url
    }

    public static func exists(_ relative: String) throws -> URL {
        let url = try resolve(relative)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ToolRuntimeError.notFound("授权目录内找不到文件：\(relative)")
        }
        return url
    }
}

// MARK: - HTML → 文本

public enum HTMLText {
    public static func plain(_ html: String, maxChars: Int) -> String {
        var s = html
        // 去 script/style/noscript（含属性形式）
        for tag in ["script", "style", "noscript", "svg"] {
            s = replacing(#"(?is)<\#(tag)\b[^>]*>.*?</\#(tag)>"#, in: s, with: " ")
        }
        s = replacing(#"(?is)<!--.*?-->"#, in: s, with: " ")
        s = replacing(#"(?is)<br\s*/?>"#, in: s, with: "\n")
        s = replacing(#"(?is)</(p|div|li|h[1-6]|tr|section|article)>"#, in: s, with: "\n")
        s = replacing(#"(?is)<[^>]+>"#, in: s, with: " ")
        s = decodeEntities(s)
        s = replacing(#"[ \t\r\f\v]+"#, in: s, with: " ")
        s = replacing(#"\n\s*\n\s*\n+"#, in: s, with: "\n\n")
        return String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxChars))
    }

    public static func decodeEntities(_ s: String) -> String {
        let map = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                   "&#39;": "'", "&apos;": "'", "&nbsp;": " ", "&#x27;": "'", "&mdash;": "—"]
        var out = s
        for (k, v) in map { out = out.replacingOccurrences(of: k, with: v) }
        // 数字实体 &#123; / &#x1F600;
        out = replacing(#"&#(x[0-9a-fA-F]+|[0-9]+);"#, in: out) { m in
            let raw = String(m.dropFirst(2).dropLast())
            let value: UInt32? = raw.hasPrefix("x") || raw.hasPrefix("X")
                ? UInt32(raw.dropFirst(), radix: 16) : UInt32(raw)
            guard let v = value, let scalar = Unicode.Scalar(v) else { return "" }
            return String(Character(scalar))
        }
        return out
    }

    public static func matches(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }

    /// 返回每条匹配的捕获组文本（group 0 为整条匹配）
    public static func captures(_ pattern: String, in text: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { i -> String in
                let r = m.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
        }
    }

    public static func group(_ pattern: String, in text: String, group: Int = 1) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > group else { return nil }
        return ns.substring(with: m.range(at: group))
    }

    private static func replacing(_ pattern: String, in text: String, with template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        return re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                           withTemplate: template)
    }

    private static func replacing(_ pattern: String, in text: String,
                                  with block: (String) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        let ns = text as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += block(ns.substring(with: m.range))
            last = m.range.location + m.range.length
        }
        out += ns.substring(with: NSRange(location: last, length: ns.length - last))
        return out
    }
}

// MARK: - CSV 解析与统计

public enum CSVAnalyzer {
    public static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 }
                    else { inQuotes = false }
                } else { field.append(c) }
            } else {
                switch c {
                case "\"": inQuotes = true
                case ",": row.append(field); field = ""
                case "\n":
                    row.append(field); field = ""
                    if !row.allSatisfy({ $0.isEmpty }) { rows.append(row) }
                    row = []
                case "\r": break
                default: field.append(c)
                }
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    public static func report(_ text: String, source: String) -> String {
        let rows = parse(text)
        guard let header = rows.first else { return "CSV 为空" }
        let dataRows = Array(rows.dropFirst())
        var out = "来源：\(source)\n行数（不含表头）：\(dataRows.count)\n列数：\(header.count)\n表头：\(header.joined(separator: " | "))"
        var stats: [String] = []
        for (idx, col) in header.enumerated() {
            let vals = dataRows.compactMap { idx < $0.count ? Double($0[idx].trimmingCharacters(in: .whitespaces)) : nil }
            if !vals.isEmpty, Double(vals.count) >= Double(max(1, dataRows.count)) * 0.5 {
                let sum = vals.reduce(0, +)
                let mean = sum / Double(vals.count)
                let minV = vals.min() ?? 0, maxV = vals.max() ?? 0
                stats.append("\(col): 数值\(vals.count)个, 求和=\(round(sum*100)/100), 均值=\(round(mean*100)/100), 最小=\(minV), 最大=\(maxV)")
            }
        }
        if !stats.isEmpty { out += "\n数值列统计：\n" + stats.joined(separator: "\n") }
        let preview = dataRows.prefix(5).map { $0.prefix(8).joined(separator: " | ") }
        if !preview.isEmpty { out += "\n前 5 行预览：\n" + preview.joined(separator: "\n") }
        return out
    }
}

// MARK: - 表达式求值（白名单后交给 NSExpression）

public enum ExpressionEvaluator {
    public static func evaluate(_ expr: String) throws -> Double {
        let e = expr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !e.isEmpty, e.count <= 200 else { throw ToolRuntimeError.invalid("表达式为空或过长") }
        // 白名单不含字母：sqrt/sin 等函数名一律不放行，避免 NSExpression 求值任意标识符
        let allowed = Set("0123456789.+-*/^()% ,.")
        guard e.allSatisfy({ allowed.contains($0) }) else {
            throw ToolRuntimeError.invalid("表达式只允许数字与 + - * / ^ ( ) % , 运算符")
        }
        let replaced = e.replacingOccurrences(of: "^", with: "**")
        let ns = NSExpression(format: replaced)
        guard let v = ns.expressionValue(with: nil, context: nil) as? NSNumber else {
            throw ToolRuntimeError.failed("表达式无法求值：\(e)")
        }
        let d = v.doubleValue
        guard d.isFinite else { throw ToolRuntimeError.failed("表达式结果不是有限数") }
        return d
    }
}

// MARK: - 代码静态检查

public enum CodeChecker {
    public static func check(_ code: String, language: String) -> String {
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
        let blanks = lines.filter { $0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        let parens = balance(code, "(", ")")
        let braces = balance(code, "{", "}")
        let brackets = balance(code, "[", "]")
        let quotesEven = code.filter { $0 == "\"" }.count % 2 == 0
        var issues: [String] = []
        if parens != 0 { issues.append("圆括号净差 \(parens)") }
        if braces != 0 { issues.append("花括号净差 \(braces)") }
        if brackets != 0 { issues.append("方括号净差 \(brackets)") }
        if !quotesEven { issues.append("双引号数量为奇数") }
        return "语言：\(language)\n总行数：\(lines.count)，非空行：\(lines.count - blanks)，字符数：\(code.count)\n"
            + "括号净差：( )=\(parens)，{ }=\(braces)，[ ]=\(brackets)；双引号成对：\(quotesEven ? "是" : "否")\n"
            + (issues.isEmpty ? "基础结构检查未发现不平衡" : "发现：\(issues.joined(separator: "；"))")
    }

    private static func balance(_ s: String, _ open: Character, _ close: Character) -> Int {
        var n = 0, inString = false, escaped = false
        for c in s {
            if escaped { escaped = false; continue }
            if c == "\\" { escaped = true; continue }
            if c == "\"" { inString.toggle(); continue }
            if inString { continue }
            if c == open { n += 1 } else if c == close { n -= 1 }
        }
        return n
    }
}
