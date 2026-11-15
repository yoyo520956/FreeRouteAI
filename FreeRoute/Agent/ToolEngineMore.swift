import Foundation
import Vision
import ImageIO
import UniformTypeIdentifiers
import JavaScriptCore

/// ToolEngine 的真实执行层（第二部分）：图片、代码沙箱、数据分析、
/// 时间/单位、本地与局域网状态。所有方法只读真实资源（Vision / ImageIO /
/// JavaScriptCore / Foundation / ToolContext 快照），做不到的事返回
/// ToolRuntimeError.unsupported，绝不伪造结果。
extension ToolEngine {

    /// 本文件内的超时取值（ToolEngine.swift 中的同名私有方法不跨文件可见）
    private static func specTimeoutMore(_ name: String) -> TimeInterval {
        ToolCatalog.spec(name)?.timeout ?? 20
    }

    // MARK: 图片（Apple Vision / ImageIO 真实执行）

    static func imageOCR(_ call: ToolCall) throws -> String {
        guard let path = call.argString("path") else { throw ToolRuntimeError.invalid("缺少 path") }
        let url = try AuthorizedFiles.exists(path)
        let data = try Data(contentsOf: url)
        let handler = VNImageRequestHandler(data: data, options: [:])
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.recognitionLanguages = ["zh-Hans", "en-US"]
        req.usesLanguageCorrection = true
        try handler.perform([req])
        // VNRecognizeTextRequest 结果在 req.results
        let obs = req.results ?? []
        guard !obs.isEmpty else {
            return "OCR 引擎：Apple Vision VNRecognizeTextRequest（accurate，zh-Hans+en-US）\n文件：\(url.lastPathComponent)（\(data.count) 字节）\n结果：未识别到文字（空白图或无文本图片）。"
        }
        var lines: [String] = []
        for case let t as VNRecognizedTextObservation in obs {
            let best = t.topCandidates(1).first?.string ?? ""
            lines.append("\(String(format: "%.2f", t.confidence))\t\(best)")
        }
        lines.sort { ($0 as NSString).substring(to: 5).compare(($1 as NSString).substring(to: 5)) == .orderedDescending }
        let text = lines.map { ($0 as NSString).replacingOccurrences(of: "\t", with: ": ") }.joined(separator: "\n")
        return "OCR 引擎：Apple Vision VNRecognizeTextRequest（accurate，zh-Hans+en-US，真实识别）\n文件：\(url.lastPathComponent)（\(data.count) 字节）\n文字行数：\(obs.count)\n\n\(text)"
    }

    static func imageInfo(_ call: ToolCall) throws -> String {
        guard let path = call.argString("path") else { throw ToolRuntimeError.invalid("缺少 path") }
        let url = try AuthorizedFiles.exists(path)
        let data = try Data(contentsOf: url)
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            throw ToolRuntimeError.failed("ImageIO 无法读取图片属性（文件可能不是有效图片）")
        }
        func int(_ key: CFString) -> Int? { (props[key] as? NSNumber)?.intValue }
        let w = int(kCGImagePropertyPixelWidth) ?? 0
        let h = int(kCGImagePropertyPixelHeight) ?? 0
        let orientation = int(kCGImagePropertyOrientation) ?? 1
        let fmtID = props[kCGImagePropertyFileNumber] as? Int
        let fmt = fmtID.map { UTType($0)?.preferredFilenameExtension ?? "未知" } ?? "未知"
        let dpi = (props[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 0
        let dpiH = (props[kCGImagePropertyDPIHeight] as? NSNumber)?.doubleValue ?? 0
        return "ImageIO CGImageSource 真实读取\n文件：\(url.lastPathComponent)\n字节数：\(data.count)\n像素：\(w) × \(h)\n格式：\(fmt)\n方向：\(orientation)\nDPI：\(String(format: "%.1f", dpi)) × \(String(format: "%.1f", dpiH))"
    }

    /// 向 ctx.visualModel 指向的上游模型发真实 HTTP 图片理解请求。
    /// 未配置视觉模型时返回明确错误，不生成任何"分析"文本。
    static func imageUnderstand(_ call: ToolCall, _ ctx: ToolContext) async throws -> String {
        guard let path = call.argString("path") else { throw ToolRuntimeError.invalid("缺少 path") }
        guard let question = call.argString("question"), !question.isEmpty else {
            throw ToolRuntimeError.invalid("缺少 question")
        }
        let url = try AuthorizedFiles.exists(path)
        let data = try Data(contentsOf: url)
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue, w > 0 else {
            throw ToolRuntimeError.failed("该文件不是可解码的图片")
        }
        guard let vm = ctx.visualModel else {
            throw ToolRuntimeError.unsupported("本机未配置视觉模型，image.understand 无法执行。请先在模型中心添加并启用一个支持图片输入的模型，Agent 会自动把它接入本工具；未接入前本工具只报错、不伪造分析。")
        }
        guard data.count <= 10_000_000 else {
            throw ToolRuntimeError.invalid("图片 \(data.count) 字节，超过 10MB 上限，拒绝发送")
        }
        let b64 = data.base64EncodedString()
        var req: URLRequest
        switch vm.format {
        case .openAICompatible:
            let body: [String: Any] = [
                "model": vm.modelID,
                "max_tokens": 1024,
                "messages": [[
                    "role": "user",
                    "content": [
                        ["type": "text", "text": question],
                        ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(b64)"]]
                    ]
                ]] as Any
            ]
            req = try imageEndpointRequest(vm, body: body)
        case .geminiREST:
            var comps = URLComponents(string: vm.endpoint)
            comps?.queryItems = [URLQueryItem(name: "key", value: vm.apiKey)]
            let body: [String: Any] = [
                "contents": [[
                    "parts": [
                        ["text": question],
                        ["inline_data": ["mime_type": "image/jpeg", "data": b64]]
                    ]
                ]]
            ]
            guard let u = comps?.url else { throw ToolRuntimeError.failed("视觉端点 URL 无效") }
            req = try imageEndpointRequest(vm, body: body, url: u)
        }
        req.timeoutInterval = min(specTimeoutMore("image.understand"), ctx.toolTimeout)
        let (resp, http) = try await URLSession.shared.data(for: req)
        let status = (http as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<400).contains(status) else {
            let msg = String(data: resp, encoding: .utf8) ?? ""
            throw ToolRuntimeError.failed("视觉上游 HTTP \(status)：\(String(msg.prefix(500)))")
        }
        let json = AgentJSON.parse(resp)
        let text: String
        switch vm.format {
        case .openAICompatible:
            text = json?["choices"]?.array?.first?["message"]?.object?["content"]?.string ?? ""
        case .geminiREST:
            text = json?["candidates"]?.array?.first?["content"]?.object?["parts"]?.array?.compactMap { $0["text"]?.string }.joined() ?? ""
        }
        guard !text.isEmpty else {
            throw ToolRuntimeError.failed("视觉上游返回成功但内容为空（原始响应前 500 字符：\((String(data: resp, encoding: .utf8) ?? "").prefix(500))")
        }
        return "视觉模型：\(vm.providerName)/\(vm.modelID)（真实 HTTP 调用，HTTP \(status)）\n问题：\(question)\n图片：\(url.lastPathComponent)（\(data.count) 字节）\n回答：\n\(text)"
    }

    private static func imageEndpointRequest(_ vm: VisualModelEndpoint, body: [String: Any], url: URL? = nil) throws -> URLRequest {
        let target = url ?? URL(string: vm.endpoint)
        guard let target else { throw ToolRuntimeError.failed("视觉端点 URL 无效：\(vm.endpoint)") }
        var req = URLRequest(url: target)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if vm.format == .openAICompatible, !vm.apiKey.isEmpty {
            req.setValue("Bearer \(vm.apiKey)", forHTTPHeaderField: "Authorization")
        }
        for (k, v) in vm.customHeaders { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    // MARK: 代码（JavaScriptCore 真实求值；其他语言需远程执行器）

    static func codeJS(_ call: ToolCall) throws -> String {
        guard let code = call.argString("code"), !code.isEmpty else { throw ToolRuntimeError.invalid("缺少 code") }
        guard code.count <= 50_000 else { throw ToolRuntimeError.invalid("代码 50000 字符上限") }
        let console = JSConsole()
        guard let jsCtx = JSContext() else { throw ToolRuntimeError.failed("无法创建 JavaScriptCore 上下文") }
        jsCtx.setObject(console, forKeyedSubscript: "console" as NSString)
        // 包一层函数：用户代码里的 return 才合法；最后把 userCode 的返回值暴露给宿主
        let wrapped = "var __fr_result__ = (function userCode() {\n\(code)\n})(); __fr_result__;"
        jsCtx.evaluateScript(wrapped)
        if let ex = jsCtx.exception {
            return "JavaScriptCore 真实求值：发生异常\n位置：\(ex)\n控制台输出：\n\(console.buffer.isEmpty ? "（无）" : console.buffer)"
        }
        let raw = jsCtx.objectForKeyedSubscript("__fr_result__")
        let value: String
        switch raw {
        case nil: value = "undefined"
        case .some(let v): value = v.toString() ?? String(describing: v)
        }
        var out = "JavaScriptCore JSContext 真实求值\n返回值：\(value)"
        if !console.buffer.isEmpty { out += "\n控制台输出：\n\(console.buffer)" }
        out += "\n说明：沙箱无网络/DOM/文件系统；JSCore 不支持强制中断，死循环会占满工具超时预算。"
        return out
    }

    static func codeRun(_ call: ToolCall, _ ctx: ToolContext) async throws -> String {
        let lang = (call.argString("language") ?? "").lowercased()
        guard !lang.isEmpty else { throw ToolRuntimeError.invalid("缺少 language") }
        if lang == "javascript" || lang == "js" {
            return try codeJS(call)
        }
        guard let raw = ctx.remoteExecutorURL, !raw.isEmpty else {
            throw ToolRuntimeError.unsupported("本机不支持 \(lang) 代码执行：iOS 无法 spawn 进程或 JIT，本机只有 JavaScriptCore 的 code.js 沙箱。若需 \(lang)，请在 设置→Agent 里配置远程代码执行器（一个接受 {language, code}、返回 {stdout, stderr, exit_code} 的 HTTP 端点），配置后本工具会真实调用它。")
        }
        guard let code = call.argString("code"), !code.isEmpty else { throw ToolRuntimeError.invalid("缺少 code") }
        let url = try URLGuard.validate(raw, allowPrivate: true) // 用户显式配置的端点允许私网
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = min(specTimeoutMore("code.run"), ctx.toolTimeout)
        req.httpBody = try JSONSerialization.data(withJSONObject: ["language": lang, "code": code])
        let (resp, http) = try await URLSession.shared.data(for: req)
        let status = (http as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<400).contains(status) else {
            throw ToolRuntimeError.failed("远程执行器 HTTP \(status)：\((String(data: resp, encoding: .utf8) ?? "").prefix(500))")
        }
        return "远程执行器真实调用：\(url.host ?? url.absoluteString)（HTTP \(status)）\n语言：\(lang)\n执行器返回：\n\(String(data: resp, encoding: .utf8) ?? "")"
    }

    static func codeCheck(_ call: ToolCall) throws -> String {
        guard let code = call.argString("code"), !code.isEmpty else { throw ToolRuntimeError.invalid("缺少 code") }
        return CodeChecker.check(code, language: call.argString("language") ?? "auto")
    }

    // MARK: 数据（真实解析，不猜测）

    static func dataJSON(_ call: ToolCall) throws -> String {
        let text = call.argString("text"), p = call.argString("path")
        var source = "<内联文本>", raw: String
        if (text ?? "").isEmpty && (p ?? "").isEmpty {
            throw ToolRuntimeError.invalid("text 与 path 至少提供一个")
        }
        if let p, !p.isEmpty {
            let url = try AuthorizedFiles.exists(p)
            raw = String(data: try Data(contentsOf: url), encoding: .utf8) ?? ""
            source = url.lastPathComponent
        } else {
            raw = text ?? ""
        }
        let v = AgentJSON.parse(raw)
        guard let v else {
            return "来源：\(source)\nJSON 解析失败：不是合法 JSON（前 200 字符：\(String(raw.prefix(200)))）"
        }
        var out = "JSON 真实解析（JSONSerialization）\n" + Self.dataJSONReport(v, source: source)
        if let q = call.argString("query"), !q.isEmpty {
            let parts = q.split(separator: ".").map(String.init)
            var cur: JSONValue? = v
            for p in parts {
                if case .object(let o)? = cur { cur = o[p] }
                else if case .array(let a)? = cur, let i = Int(p), i < a.count { cur = a[i] }
                else { cur = nil; break }
            }
            out += "\n查询 \(q)：\(cur.map { AgentJSON.encode($0) } ?? "（路径不存在或类型不匹配）")"
        }
        return out
    }

    private static func dataJSONReport(_ v: JSONValue, source: String) -> String {
        switch v {
        case .object(let o):
            let keys = o.keys.sorted()
            return "来源：\(source)\n顶层类型：object\n键数量：\(keys.count)\n键与类型：\n"
                + keys.map { "\($0): \(dataJSONType(o[$0]))" }.joined(separator: "\n")
        case .array(let a):
            return "来源：\(source)\n顶层类型：array\n元素数：\(a.count)\n首元素类型：\(a.first.map { dataJSONType($0) } ?? "无")"
        case .string(let s):
            return "来源：\(source)\n顶层类型：string\n值（前 500）：\(String(s.prefix(500)))"
        case .number(let n):
            return "来源：\(source)\n顶层类型：number\n值：\(n)"
        case .bool(let b):
            return "来源：\(source)\n顶层类型：bool\n值：\(b)"
        case .null:
            return "来源：\(source)\n顶层类型：null"
        }
    }

    private static func dataJSONType(_ v: JSONValue?) -> String {
        switch v {
        case .null: return "null"; case .bool: return "bool"; case .number: return "number"
        case .string: return "string"; case .array: return "array"; case .object: return "object"
        case nil: return "missing"
        }
    }

    static func dataCSV(_ call: ToolCall) throws -> String {
        let text = call.argString("text"), p = call.argString("path")
        guard !(text ?? "").isEmpty || !(p ?? "").isEmpty else {
            throw ToolRuntimeError.invalid("text 与 path 至少提供一个")
        }
        if let p, !(p.isEmpty), (text ?? "").isEmpty {
            let url = try AuthorizedFiles.exists(p)
            let ext = url.pathExtension.lowercased()
            var raw = String(data: try Data(contentsOf: url), encoding: .utf8) ?? ""
            if ext == "tsv" { raw = raw.replacingOccurrences(of: "\t", with: ",") }
            return "CSV 真实解析（含引号内逗号状态机）\n" + CSVAnalyzer.report(raw, source: url.lastPathComponent)
        }
        return "CSV 真实解析（含引号内逗号状态机）\n" + CSVAnalyzer.report(text ?? "", source: "<内联文本>")
    }

    static func dataExcel(_ call: ToolCall) throws -> String {
        guard let p = call.argString("path") else { throw ToolRuntimeError.invalid("缺少 path") }
        let url = try AuthorizedFiles.exists(p)
        let ext = url.pathExtension.lowercased()
        if ext == "csv" || ext == "tsv" {
            var raw = String(data: try Data(contentsOf: url), encoding: .utf8) ?? ""
            if ext == "tsv" { raw = raw.replacingOccurrences(of: "\t", with: ",") }
            return "Excel 工具对 \(ext) 做真实 CSV 解析：\n" + CSVAnalyzer.report(raw, source: url.lastPathComponent)
        }
        let data = try Data(contentsOf: url)
        let sig = data.prefix(8).map { String(format: "%02x", $0) }.joined()
        let kind: String
        if sig.hasPrefix("504b0304") { kind = "OOXML ZIP 容器（.xlsx）" }
        else if sig.hasPrefix("d0cf11e0") { kind = "旧版 OLE2 复合文档（.xls）" }
        else { kind = "未知格式（文件头 \(sig)）" }
        return "Excel 分析：\(url.lastPathComponent)\n字节数：\(data.count)\n文件头签名：\(sig) → \(kind)\n"
            + "能力说明（如实）：.xlsx/.docx 本质是 ZIP+XML，本机未内置 ZIP/DEFLATE 解压器与 OOXML 单元格解析器，无法逐单元格读取，不会伪造表格内容。\n"
            + "可执行替代：把工作表另存为 .csv，再用 data.csv 或 file.analyze 做真实的行列与数值统计。"
    }

    // MARK: 时间与计算（Foundation 真实运算）

    static func timeNow(_ call: ToolCall) throws -> String {
        let tzName = call.argString("timezone") ?? ""
        let tz: TimeZone
        if tzName.isEmpty {
            tz = .current
        } else {
            guard let t = TimeZone(identifier: tzName) else {
                throw ToolRuntimeError.invalid("未知 IANA 时区：\(tzName)")
            }
            tz = t
        }
        let now = Date()
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        f.timeZone = tz
        let iso = ISO8601DateFormatter().string(from: now)
        return "系统时钟真实读取（Foundation Date）\nUTC：\(iso)\n\(tz.identifier.isEmpty ? tz.identifier : tzName)：\(f.string(from: now))\nUnix 时间戳：\(now.timeIntervalSince1970)"
    }

    static func timeConvert(_ call: ToolCall) throws -> String {
        guard let dateStr = call.argString("date"),
              let fromName = call.argString("fromTz"),
              let toName = call.argString("toTz") else {
            throw ToolRuntimeError.invalid("缺少 date / fromTz / toTz")
        }
        guard let fromTz = TimeZone(identifier: fromName) else { throw ToolRuntimeError.invalid("未知 IANA 时区：\(fromName)") }
        guard let toTz = TimeZone(identifier: toName) else { throw ToolRuntimeError.invalid("未知 IANA 时区：\(toName)") }
        var date: Date?
        for opts in [[.withInternetDateTime.union(.withFractionalSeconds), .withInternetDateTime]] as [ISO8601DateFormatter.Options] {
            let f = ISO8601DateFormatter(); f.formatOptions = opts
            if let d = f.date(from: dateStr) { date = d; break }
        }
        if date == nil {
            for fmt in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
                let f = DateFormatter()
                f.dateFormat = fmt; f.timeZone = fromTz; f.locale = Locale(identifier: "en_US_POSIX")
                if let d = f.date(from: dateStr) { date = d; break }
                f.timeZone = .current
                if let d = f.date(from: dateStr) { date = d; break }
            }
        }
        guard let date else { throw ToolRuntimeError.invalid("无法解析日期时间：\(dateStr)（支持 ISO8601 或 yyyy-MM-dd[ HH:mm[:ss]]）") }
        func render(_ tz: TimeZone) -> String {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
            f.timeZone = tz; f.locale = Locale(identifier: "en_US_POSIX")
            return f.string(from: date)
        }
        return "Foundation TimeZone/Calendar 真实换算\n输入：\(dateStr)（\(fromName)）\n→ \(toName)：\(render(toTz))\nUTC：\(ISO8601DateFormatter().string(from: date))\nUnix 时间戳：\(date.timeIntervalSince1970)"
    }

    static func calcEval(_ call: ToolCall) throws -> String {
        guard let expr = call.argString("expression") else { throw ToolRuntimeError.invalid("缺少 expression") }
        let v = try ExpressionEvaluator.evaluate(expr)
        let s = String(format: "%.10g", v)
        return "NSExpression 白名单求值（仅数字与 + - * / ^ ( ) %）\n\(expr) = \(s)"
    }

    static func calcUnit(_ call: ToolCall) throws -> String {
        guard let value = call.arguments["value"]?.number,
              let from = call.argString("from"),
              let to = call.argString("to") else {
            throw ToolRuntimeError.invalid("缺少 value / from / to")
        }
        // 单位别名表：全部指向 Foundation 官方 Dimension（Unit 的子类，支持换算）
        let units: [String: Dimension] = [
            "m": UnitLength.meters, "cm": UnitLength.centimeters, "mm": UnitLength.millimeters,
            "km": UnitLength.kilometers, "in": UnitLength.inches, "ft": UnitLength.feet,
            "yd": UnitLength.yards, "mi": UnitLength.miles, "nmi": UnitLength.nauticalMiles,
            "meter": UnitLength.meters, "centimeter": UnitLength.centimeters,
            "millimeter": UnitLength.millimeters, "kilometer": UnitLength.kilometers,
            "inch": UnitLength.inches, "foot": UnitLength.feet, "yard": UnitLength.yards,
            "mile": UnitLength.miles,
            "kg": UnitMass.kilograms, "g": UnitMass.grams, "mg": UnitMass.milligrams,
            "oz": UnitMass.ounces, "lb": UnitMass.pounds, "st": UnitMass.stones,
            "kilogram": UnitMass.kilograms, "gram": UnitMass.grams, "milligram": UnitMass.milligrams,
            "ounce": UnitMass.ounces, "pound": UnitMass.pounds, "stone": UnitMass.stones,
            "k": UnitTemperature.kelvin, "c": UnitTemperature.celsius, "f": UnitTemperature.fahrenheit,
            "kelvin": UnitTemperature.kelvin, "celsius": UnitTemperature.celsius,
            "fahrenheit": UnitTemperature.fahrenheit,
            "b": UnitInformationStorage.bytes, "kb": UnitInformationStorage.kilobytes,
            "mb": UnitInformationStorage.megabytes, "gb": UnitInformationStorage.gigabytes,
            "tb": UnitInformationStorage.terabytes,
            "kib": UnitInformationStorage.kibibytes, "mib": UnitInformationStorage.mebibytes,
            "gib": UnitInformationStorage.gibibytes, "tib": UnitInformationStorage.tebibytes,
            "bit": UnitInformationStorage.bits,
            "byte": UnitInformationStorage.bytes, "kilobyte": UnitInformationStorage.kilobytes,
            "megabyte": UnitInformationStorage.megabytes, "gigabyte": UnitInformationStorage.gigabytes,
            "terabyte": UnitInformationStorage.terabytes,
            "kibibyte": UnitInformationStorage.kibibytes, "mebibyte": UnitInformationStorage.mebibytes,
            "gibibyte": UnitInformationStorage.gibibytes, "tebibyte": UnitInformationStorage.tebibytes
        ]
        let supported = "长度：m cm mm km in ft yd mi nmi；质量：kg g mg oz lb st；温度：K C F（°C °F）；数据：B kb mb gb tb kib mib gib tib bit"
        func find(_ s: String) -> Dimension? {
            let k = s.lowercased()
            if let u = units[k] { return u }
            for (_, u) in units where u.symbol.lowercased() == k { return u }
            return nil
        }
        guard let u1 = find(from) else {
            throw ToolRuntimeError.unsupported("未知源单位「\(from)」。支持：\(supported)；数据单位 kb/mb/gb/tb 按十进制，kib/mib/gib/tib 按二进制")
        }
        guard let u2 = find(to) else {
            throw ToolRuntimeError.unsupported("未知目标单位「\(to)」。支持：\(supported)")
        }
        if !u1.isCompatible(with: u2) {
            throw ToolRuntimeError.invalid("\(from)（\(u1.symbol)）与 \(to)（\(u2.symbol)）量纲不同，无法换算")
        }
        let baseFrom = u2.converter.baseUnitValue(fromValue: value)
        let converted = u1.converter.value(fromBaseUnitValue: baseFrom)
        return "Foundation Unit/Dimension 真实换算\n\(value) \(from) = \(String(format: "%.6g", converted)) \(to)"
    }

    // MARK: 本地与局域网（全部来自 ToolContext 真实快照）

    static func localSession(_ ctx: ToolContext) -> String {
        "本机真实状态快照（由 AgentRunner 采集，非模型生成）\n会话数：\(ctx.sessionCount)\n已配置模型数：\(ctx.modelNames.count)\n已记录设备数：\(ctx.approvedDevices.count)（已批准 \(ctx.approvedDevices.filter { $0.approved }.count)）\n授权目录：\(ctx.authorizedRoot.isEmpty ? "（未指定）" : ctx.authorizedRoot)\n最近请求日志条数（内存）：\(ctx.recentLogs.count)"
    }

    static func localLogs(_ call: ToolCall, _ ctx: ToolContext) -> String {
        let limit = min(50, max(1, call.argInt("limit") ?? 10))
        guard !ctx.recentLogs.isEmpty else {
            return "本机请求日志为空（网关或聊天产生真实请求后会记录在这里，不做预设示例）。"
        }
        let lines = ctx.recentLogs.suffix(limit)
        return "最近 \(lines.count) 条真实请求日志：\n" + lines.joined(separator: "\n")
    }

    static func localModels(_ ctx: ToolContext) -> String {
        guard !ctx.modelNames.isEmpty else {
            return "本机尚未配置模型（模型中心添加服务商与模型后会出现在这里）。"
        }
        return "本机已配置模型（真实列表，共 \(ctx.modelNames.count)）：\n" + ctx.modelNames.joined(separator: "\n")
    }

    static func localTokens(_ ctx: ToolContext) -> String {
        guard !ctx.tokenSnapshot.isEmpty else {
            return "暂无 Token 统计（发生真实请求后由统计模块写入，不做预设示例）。"
        }
        let lines = ctx.tokenSnapshot.keys.sorted().map { "\($0)：\(ctx.tokenSnapshot[$0] ?? "-")" }
        return "本机 Token 统计快照（真实数值）：\n" + lines.joined(separator: "\n")
    }

    static func localGateway(_ ctx: ToolContext) -> String {
        guard !ctx.gatewaySnapshot.isEmpty else {
            return "网关未开启或状态快照为空（打开 网关 页的开关后，这里会显示端口/连接数/请求数）。"
        }
        let lines = ctx.gatewaySnapshot.keys.sorted().map { "\($0)：\(ctx.gatewaySnapshot[$0] ?? "-")" }
        return "本机 API 网关真实状态：\n" + lines.joined(separator: "\n")
    }

    static func lanDevices(_ ctx: ToolContext) -> String {
        guard !ctx.approvedDevices.isEmpty else {
            return "尚未记录任何局域网设备（有第三方客户端连接网关时会在此登记，需逐台批准后才可调用）。"
        }
        let lines = ctx.approvedDevices.map {
            "\($0.approved ? "已批准" : "待批准")\t\($0.remoteAddress)\t\($0.label)\t首见 \(AgentTime.iso($0.firstSeen))\t最近 \(AgentTime.iso($0.lastSeen))"
        }
        return "局域网设备登记（ToolPermissionStore 真实数据，共 \(ctx.approvedDevices.count) 台）：\n" + lines.joined(separator: "\n")
    }

    static func lanStatus(_ ctx: ToolContext) -> String {
        let tools = ToolCatalog.all.count
        var out = "API 网关端点（\(ctx.gatewaySnapshot["state"] ?? "未开启")）："
        for ep in ["/v1/chat/completions", "/v1/chat/completions(agent)", "/v1/completions",
                   "/v1/models", "/v1/tools", "/v1/agent/tasks/{id}", "/v1/agent/events/{id}",
                   "/v1/devices", "/v1/devices/{id}/approve", "/v1/gateway/status",
                   "/v1/prompts", "/health"] {
            out += "\n  \(ep)"
        }
        out += "\n内置工具：\(tools) 个（真实注册表 ToolCatalog）\n"
        if !ctx.gatewaySnapshot.isEmpty {
            out += ctx.gatewaySnapshot.keys.sorted().map { "\($0)：\(ctx.gatewaySnapshot[$0] ?? "-")" }.joined(separator: "\n")
        }
        return out
    }
}

// MARK: - JS 沙箱辅助

/// 极简 console 对象代理：收集 log/warn/error 输出，随结果一并返回。
/// 使用 @objc 导出方法给 JSContext 调用。
private final class JSConsole: NSObject {
    var buffer = ""
    @objc func log(_ args: JSValue) {
        buffer += args.toString() + "\n"
    }
    @objc func warn(_ args: JSValue) {
        buffer += "⚠️ " + args.toString() + "\n"
    }
    @objc func error(_ args: JSValue) {
        buffer += "❌ " + args.toString() + "\n"
    }
}
