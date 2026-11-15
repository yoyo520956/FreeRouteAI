import Foundation

/// 26 个内置工具的注册表。每个 Schema 都是标准 JSON Schema object，
/// 同时用于：本机参数校验、OpenAI tools 透传、Gemini functionDeclarations、/v1/tools 能力列表。
public enum ToolCatalog {
    private static func schema(_ props: [String: JSONValue], required: [String]) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(props),
            "required": .array(required.map { JSONValue.string($0) })
        ])
    }
    private static func string(_ desc: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(desc)])
    }
    private static func number(_ desc: String) -> JSONValue {
        .object(["type": .string("number"), "description": .string(desc)])
    }
    private static func bool(_ desc: String) -> JSONValue {
        .object(["type": .string("boolean"), "description": .string(desc)])
    }
    private static func strArray(_ desc: String) -> JSONValue {
        .object(["type": .string("array"), "items": .object(["type": .string("string")]),
                 "description": .string(desc)])
    }
    private static func object(_ desc: String) -> JSONValue {
        .object(["type": .string("object"), "description": .string(desc)])
    }

    public static let all: [ToolSpec] = [
        // ── 联网搜索 ──
        ToolSpec(name: "web.search", title: "网页搜索", group: "联网搜索",
                 summary: "真实请求 DuckDuckGo HTML 搜索并解析标题、链接、摘要，返回可引用来源",
                 parameters: schema(["query": string("搜索关键词"),
                                     "limit": number("结果条数，1–10，默认 5")], required: ["query"]),
                 permission: .network, timeout: 20),
        ToolSpec(name: "web.open", title: "打开网页", group: "联网搜索",
                 summary: "真实抓取公开网页并提取正文文本，返回最终 URL 与 HTTP 状态码",
                 parameters: schema(["url": string("要打开的公开 http/https 网址"),
                                     "maxChars": number("返回正文最大字符数，默认 4000")], required: ["url"]),
                 permission: .network, timeout: 25),

        // ── 文件 ──
        ToolSpec(name: "file.list", title: "列出文件", group: "文件",
                 summary: "真实枚举授权目录内的文件、大小与修改时间",
                 parameters: schema(["path": string("相对授权目录的子路径，可空")], required: []),
                 permission: .fileRead, timeout: 10),
        ToolSpec(name: "file.read", title: "读取文件", group: "文件",
                 summary: "真实读取文件；PDF 用 PDFKit 抽取文本，文本/代码返回原文",
                 parameters: schema(["path": string("相对授权目录的文件路径"),
                                     "maxChars": number("最大字符数，默认 8000")], required: ["path"]),
                 permission: .fileRead, timeout: 15),
        ToolSpec(name: "file.write", title: "写入文件", group: "文件",
                 summary: "真实写入授权目录内的文件；需要用户明确授权的一次性确认令牌",
                 parameters: schema(["path": string("相对授权目录的文件路径"),
                                     "content": string("要写入的文本内容"),
                                     "_confirm": string("用户授权后返回的确认令牌")],
                                    required: ["path", "content"]),
                 permission: .fileWrite, requiresConfirmation: true, timeout: 10),
        ToolSpec(name: "file.analyze", title: "分析文件", group: "文件",
                 summary: "真实分析 PDF 页数与文本、CSV 行列与数值统计、JSON 键类型、代码行数与括号",
                 parameters: schema(["path": string("相对授权目录的文件路径")], required: ["path"]),
                 permission: .fileRead, timeout: 25),

        // ── 图片 ──
        ToolSpec(name: "image.ocr", title: "图片 OCR", group: "图片",
                 summary: "用 Apple Vision VNRecognizeTextRequest 真实识别图片中的文字",
                 parameters: schema(["path": string("图片文件路径")], required: ["path"]),
                 permission: .fileRead, timeout: 30),
        ToolSpec(name: "image.info", title: "图片信息", group: "图片",
                 summary: "用 ImageIO 真实读取图片像素尺寸、格式与字节数",
                 parameters: schema(["path": string("图片文件路径")], required: ["path"]),
                 permission: .fileRead, timeout: 10),
        ToolSpec(name: "image.understand", title: "图片理解", group: "图片",
                 summary: "向已配置的视觉上游模型发送图片做语义理解；未配置视觉模型时返回诚实错误",
                 parameters: schema(["path": string("图片文件路径"),
                                     "question": string("针对图片的问题")], required: ["path", "question"]),
                 permission: .fileRead, timeout: 60),

        // ── 代码 ──
        ToolSpec(name: "code.js", title: "执行 JavaScript", group: "代码",
                 summary: "在 JavaScriptCore JSContext 中真实求值并返回结果与 console 输出",
                 parameters: schema(["code": string("要执行的 JavaScript 代码")], required: ["code"]),
                 permission: .codeExec, timeout: 12),
        ToolSpec(name: "code.run", title: "执行代码", group: "代码",
                 summary: "language=javascript 时转 code.js；其他语言仅在配置了远程执行器时真实 HTTP 调用，否则明确报错",
                 parameters: schema(["language": string("javascript / python 等"),
                                     "code": string("要执行的源代码")], required: ["language", "code"]),
                 permission: .codeExec, timeout: 20),
        ToolSpec(name: "code.check", title: "代码静态检查", group: "代码",
                 summary: "真实统计行数、括号/引号平衡与常见错误线索，不执行代码",
                 parameters: schema(["code": string("要检查的源代码")], required: ["code"]),
                 permission: .none, timeout: 10),

        // ── 数据 ──
        ToolSpec(name: "data.json", title: "JSON 分析", group: "数据",
                 summary: "真实解析 JSON，返回顶层类型、键、元素数与按点路径查询的值",
                 parameters: schema(["text": string("JSON 文本（与 path 二选一）"),
                                     "path": string("授权目录内的 JSON 文件路径"),
                                     "query": string("点分隔路径，如 users.0.name")],
                                    required: []),
                 permission: .fileRead, timeout: 12),
        ToolSpec(name: "data.csv", title: "CSV 分析", group: "数据",
                 summary: "真实解析 CSV（含引号内逗号），返回行列数、表头与数值列统计",
                 parameters: schema(["text": string("CSV 文本（与 path 二选一）"),
                                     "path": string("授权目录内的 CSV 文件路径")], required: []),
                 permission: .fileRead, timeout: 15),
        ToolSpec(name: "data.excel", title: "Excel 分析", group: "数据",
                 summary: "对 CSV 做真实分析；对 .xlsx 读取文件并核实 OOXML/ZIP 签名后如实说明本机未内置 ZIP 解压",
                 parameters: schema(["path": string("授权目录内的 .csv 或 .xlsx 文件路径")], required: ["path"]),
                 permission: .fileRead, timeout: 15),

        // ── 时间 ──
        ToolSpec(name: "time.now", title: "当前时间", group: "时间",
                 summary: "真实读取系统时间并按指定 IANA 时区格式化",
                 parameters: schema(["timezone": string("IANA 时区，如 Asia/Shanghai")], required: []),
                 permission: .none, timeout: 5),
        ToolSpec(name: "time.convert", title: "时区换算", group: "时间",
                 summary: "真实用 Foundation TimeZone/Calendar 做日期时间与时区换算",
                 parameters: schema(["date": string("ISO8601 或 yyyy-MM-dd HH:mm 的日期时间"),
                                     "fromTz": string("源 IANA 时区"),
                                     "toTz": string("目标 IANA 时区")],
                                    required: ["date", "fromTz", "toTz"]),
                 permission: .none, timeout: 5),

        // ── 计算 ──
        ToolSpec(name: "calc.eval", title: "数学计算", group: "计算",
                 summary: "真实用 NSExpression 求值算术表达式（仅数字与 + - * / ^ () 及基本函数）",
                 parameters: schema(["expression": string("算术表达式，如 (12+3)*4/2")], required: ["expression"]),
                 permission: .none, timeout: 5),
        ToolSpec(name: "calc.unit", title: "单位换算", group: "计算",
                 summary: "真实用 Foundation Dimension/Unit 或固定系数做长度、质量、温度、数据单位换算",
                 parameters: schema(["value": number("数值"),
                                     "from": string("源单位"),
                                     "to": string("目标单位")], required: ["value", "from", "to"]),
                 permission: .none, timeout: 5),

        // ── HTTP ──
        ToolSpec(name: "http.get", title: "HTTP GET", group: "HTTP",
                 summary: "真实发起 HTTP GET；默认阻止回环、私网与云元数据地址，除非用户显式开启",
                 parameters: schema(["url": string("公开 http/https 地址"),
                                     "headers": object("附加请求头对象")], required: ["url"]),
                 permission: .http, timeout: 20),

        // ── 本地 ──
        ToolSpec(name: "local.session", title: "会话状态", group: "本地",
                 summary: "返回本机会话数与当前 Agent 任务状态",
                 parameters: schema([:], required: []), permission: .none, timeout: 5),
        ToolSpec(name: "local.logs", title: "请求日志", group: "本地",
                 summary: "返回最近真实请求日志（模型、耗时、状态码、Token）",
                 parameters: schema(["limit": number("条数，默认 10")], required: []),
                 permission: .none, timeout: 5),
        ToolSpec(name: "local.models", title: "模型信息", group: "本地",
                 summary: "返回本机已配置的真实模型与能力列表",
                 parameters: schema([:], required: []), permission: .none, timeout: 5),
        ToolSpec(name: "local.tokens", title: "Token 统计", group: "本地",
                 summary: "返回最近请求的真实 Token 用量与上下文估算",
                 parameters: schema([:], required: []), permission: .none, timeout: 5),
        ToolSpec(name: "local.gateway", title: "网关状态", group: "本地",
                 summary: "返回网关端口、局域网开关、连接数与累计请求数",
                 parameters: schema([:], required: []), permission: .none, timeout: 5),

        // ── 局域网 ──
        ToolSpec(name: "lan.devices", title: "授权设备", group: "局域网",
                 summary: "返回已记录的设备、批准状态与首次/最近出现时间",
                 parameters: schema([:], required: []), permission: .admin, timeout: 5),
        ToolSpec(name: "lan.status", title: "API 服务状态", group: "局域网",
                 summary: "返回网关可用端点、工具数量与当前运行状态",
                 parameters: schema([:], required: []), permission: .admin, timeout: 5)
    ]

    public static func spec(_ name: String) -> ToolSpec? { all.first { $0.name == name } }

    /// OpenAI Chat Completions `tools` 数组
    public static func openAIToolsJSON() -> JSONValue {
        .array(all.map { spec in
            .object([
                "type": .string("function"),
                "function": .object([
                    "name": .string(spec.name),
                    "description": .string(spec.summary + "（真实执行，非模拟）"),
                    "parameters": spec.parameters
                ])
            ])
        })
    }

    /// Gemini REST `functionDeclarations`：把 JSON Schema 的 type 值改成大写
    /// （Gemini 用 Type.OBJECT / Type.STRING 枚举，且不接受 $schema/additionalProperties）。
    public static func geminiFunctionDeclarationsJSON() -> JSONValue {
        .object([
            "functionDeclarations": .array(all.map { spec in
                .object([
                    "name": .string(spec.name.replacingOccurrences(of: ".", with: "_")),
                    "description": .string(spec.summary),
                    "parameters": convertSchema(spec.parameters)
                ])
            })
        ])
    }

    private static func convertSchema(_ v: JSONValue) -> JSONValue {
        switch v {
        case .object(let o):
            var out: [String: JSONValue] = [:]
            for (k, value) in o {
                if k == "type", let s = value.string {
                    let map: [String: String] = ["object": "OBJECT", "string": "STRING",
                                                "number": "NUMBER", "integer": "INTEGER",
                                                "boolean": "BOOLEAN", "array": "ARRAY"]
                    out[k] = .string(map[s] ?? s.uppercased())
                } else if k == "$schema" || k == "additionalProperties" {
                    continue
                } else {
                    out[k] = convertSchema(value)
                }
            }
            return .object(out)
        case .array(let a): return .array(a.map { convertSchema($0) })
        default: return v
        }
    }

    /// /v1/tools 能力列表
    public static func descriptors() -> [[String: Any]] {
        all.map { spec in
            ["name": spec.name, "title": spec.title, "group": spec.group,
             "summary": spec.summary, "permission": spec.permission.rawValue,
             "requires_confirmation": spec.requiresConfirmation,
             "timeout": spec.timeout, "parameters": AgentJSON.any(spec.parameters)]
        }
    }
}
