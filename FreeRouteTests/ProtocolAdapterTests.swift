import XCTest
@testable import FreeRoute

/// 协议适配器：URL 构造、鉴权头、请求体、SSE 解析
final class ProtocolAdapterTests: XCTestCase {
    private func provider(_ kind: ProviderKind, _ proto: ProviderProtocolType, base: String,
                          headers: [String: String] = [:],
                          requestPath: String? = nil, modelsPath: String? = nil) -> Provider {
        Provider(kind: kind, name: kind.displayName, protocolType: proto, baseURL: base,
                 requestPath: requestPath, modelsPath: modelsPath, customHeaders: headers,
                 keys: [APIKeyRef(keychainRef: "test/" + kind.rawValue)])
    }

    private let req: ChatRequest = {
        ChatRequest(model: "gpt-test", messages: [
            ChatMessage(role: .system, content: "你是助手"),
            ChatMessage(role: .user, content: "你好")
        ], maxTokens: 128, stream: false)
    }()

    // MARK: OpenAI 兼容

    func testOpenAICompatibleURLAndAuth() throws {
        let p = provider(.groq, .openaiCompatible, base: "https://api.groq.com/openai/v1/")
        let call = try AdapterFactory.adapter(for: .openaiCompatible)
            .chatCall(provider: p, apiKey: "gsk_secret", request: req)
        XCTAssertEqual(call.url.absoluteString, "https://api.groq.com/openai/v1/chat/completions")
        XCTAssertEqual(call.method, "POST")
        XCTAssertEqual(call.headers["Authorization"], "Bearer gsk_secret")
        XCTAssertEqual(call.headers["Content-Type"], "application/json")
        let body = String(data: call.body ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("\"gpt-test\""))
        XCTAssertTrue(body.contains("你好"))
    }

    func testOpenRouterSendsAttributionHeaders() throws {
        let p = provider(.openrouter, .openaiCompatible, base: "https://openrouter.ai/api/v1")
        let call = try AdapterFactory.adapter(for: .openaiCompatible)
            .chatCall(provider: p, apiKey: "sk-or", request: req)
        XCTAssertEqual(call.headers["X-Title"], "FreeRoute AI")
        XCTAssertNotNil(call.headers["HTTP-Referer"])
    }

    func testCustomHeadersMerged() throws {
        let p = provider(.custom, .openaiCompatible, base: "https://x.invalid/v1",
                         headers: ["X-Custom": "abc"])
        let call = try AdapterFactory.adapter(for: .openaiCompatible)
            .chatCall(provider: p, apiKey: "k", request: req)
        XCTAssertEqual(call.headers["X-Custom"], "abc")
    }

    func testCloudflareAccountIDSubstitution() throws {
        let p = provider(.cloudflare, .openaiCompatible,
                         base: "https://api.cloudflare.com/client/v4/accounts/{account_id}/ai/v1",
                         headers: ["CF-Account-Id": "acc123"])
        let call = try AdapterFactory.adapter(for: .openaiCompatible)
            .modelsCall(provider: p, apiKey: "kf")
        XCTAssertTrue(call.url.absoluteString.contains("accounts/acc123/ai"),
                      "account_id 占位符必须被替换，实际：\(call.url.absoluteString)")
    }

    func testInvalidBaseURLThrows() {
        let p = provider(.custom, .openaiCompatible, base: "不是网址")
        XCTAssertThrowsError(try AdapterFactory.adapter(for: .openaiCompatible)
            .chatCall(provider: p, apiKey: "k", request: req))
    }

    // MARK: Anthropic

    func testAnthropicSystemIsTopLevelAndHeader() throws {
        let p = provider(.anthropic, .anthropic, base: "https://api.anthropic.com")
        let call = try AdapterFactory.adapter(for: .anthropic)
            .chatCall(provider: p, apiKey: "sk-ant", request: req)
        XCTAssertEqual(call.headers["x-api-key"], "sk-ant")
        XCTAssertEqual(call.headers["anthropic-version"]?.hasPrefix("2023"), true)
        let body = String(data: call.body ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("\"system\""), "system 应作为顶层字段")
        XCTAssertFalse(body.contains("\"role\":\"system\""), "messages 里不应再出现 system 角色")
    }

    func testAnthropicSSEParsing() throws {
        let p = provider(.anthropic, .anthropic, base: "https://api.anthropic.com")
        let adapter = AdapterFactory.adapter(for: .anthropic)
        // SSE 里 event: 与 data: 是两行，按行喂给解析器
        XCTAssertNil(adapter.parseStreamLine("event: content_block_delta", provider: p),
                     "event: 行只标注类型，不该产出内容")
        let line = "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"片段\"}}"
        let piece = adapter.parseStreamLine(line, provider: p)
        XCTAssertEqual(piece?.text, "片段")
        let doneLine = "data: {\"type\":\"message_stop\"}"
        XCTAssertEqual(adapter.parseStreamLine(doneLine, provider: p)?.isDone, true)
    }

    // MARK: Gemini

    func testGeminiURLContainsModelAndStreamAction() throws {
        let p = provider(.gemini, .gemini, base: "https://generativelanguage.googleapis.com/v1beta")
        var r = req
        r.model = "gemini-2.0-flash"
        r.stream = true
        let call = try AdapterFactory.adapter(for: .gemini)
            .chatCall(provider: p, apiKey: "AIza", request: r)
        let url = call.url.absoluteString
        XCTAssertTrue(url.contains("models/gemini-2.0-flash:streamGenerateContent"), url)
        // 密钥走 x-goog-api-key 头，不进 URL —— 避免把 key 落进代理与崩溃日志
        XCTAssertEqual(call.headers["x-goog-api-key"], "AIza")
        XCTAssertFalse(url.contains("AIza"), "密钥不应出现在 URL 里")
    }

    func testGeminiNonStreamUsesGenerateContent() throws {
        let p = provider(.gemini, .gemini, base: "https://generativelanguage.googleapis.com/v1beta")
        var r = req
        r.model = "gemini-2.0-flash"
        r.stream = false
        let call = try AdapterFactory.adapter(for: .gemini)
            .chatCall(provider: p, apiKey: "AIza", request: r)
        XCTAssertTrue(call.url.absoluteString.contains("generateContent"))
    }

    func testGeminiStreamParsing() throws {
        let p = provider(.gemini, .gemini, base: "https://generativelanguage.googleapis.com")
        let adapter = AdapterFactory.adapter(for: .gemini)
        // alt=sse：每个 data: 是一个 JSON 对象
        let objLine = "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"你好\"}]}}]}"
        XCTAssertEqual(adapter.parseStreamLine(objLine, provider: p)?.text, "你好")
        // 兼容网关下发数组包裹的形状
        let arrLine = "data: [{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"世界\"}]}}]}]"
        XCTAssertEqual(adapter.parseStreamLine(arrLine, provider: p)?.text, "世界")
    }

    // MARK: Ollama

    func testOllamaURLAndNDJSON() throws {
        let p = provider(.ollama, .ollama, base: "http://127.0.0.1:11434")
        let call = try AdapterFactory.adapter(for: .ollama)
            .chatCall(provider: p, apiKey: "", request: req)
        XCTAssertEqual(call.url.absoluteString, "http://127.0.0.1:11434/api/chat")
        let adapter = AdapterFactory.adapter(for: .ollama)
        let line = "{\"message\":{\"content\":\"部分\"},\"done\":false}"
        XCTAssertEqual(adapter.parseStreamLine(line, provider: p)?.text, "部分")
        let done = "{\"done\":true,\"eval_count\":7,\"prompt_eval_count\":3}"
        let piece = adapter.parseStreamLine(done, provider: p)
        XCTAssertEqual(piece?.isDone, true)
        XCTAssertEqual(piece?.usage?.totalTokens, 10)
    }

    // MARK: 有损字段必须报告，不得静默丢弃

    func testLossyNotesReportUnsupportedFields() {
        var r = req
        r.toolsJSON = "[{\"type\":\"function\"}]"
        r.responseFormatJSON = "{\"type\":\"json_object\"}"
        let geminiNotes = AdapterFactory.adapter(for: .gemini).lossyNotes(for: r)
        XCTAssertFalse(geminiNotes.isEmpty, "Gemini 无法无损承接的字段必须报告")
        let ollamaNotes = AdapterFactory.adapter(for: .ollama).lossyNotes(for: r)
        XCTAssertFalse(ollamaNotes.isEmpty)
    }

    // MARK: 模型目录解析

    func testParseOpenAIModelList() throws {
        let p = provider(.groq, .openaiCompatible, base: "https://api.groq.com/openai/v1")
        let json = """
        {"data":[{"id":"llama-3.3-70b","object":"model","context_length":131072,
                  "owned_by":"groq","pricing":{"prompt":"0.00059","completion":"0.00079"}}]}
        """.data(using: .utf8)!
        let models = try AdapterFactory.adapter(for: .openaiCompatible).parseModels(provider: p, data: json)
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models.first?.modelID, "llama-3.3-70b")
        XCTAssertEqual(models.first?.contextLength, 131072)
    }

    func testParseGeminiModelList() throws {
        let p = provider(.gemini, .gemini, base: "https://generativelanguage.googleapis.com/v1beta")
        let json = """
        {"models":[{"name":"models/gemini-2.0-flash","displayName":"Gemini 2.0 Flash",
                    "inputTokenLimit":1048576,"supportedGenerationMethods":["generateContent"]}]}
        """.data(using: .utf8)!
        let models = try AdapterFactory.adapter(for: .gemini).parseModels(provider: p, data: json)
        XCTAssertEqual(models.first?.modelID, "gemini-2.0-flash")
        XCTAssertEqual(models.first?.contextLength, 1048576)
    }

    // MARK: 非流式响应解析

    func testParseOpenAIChatResponse() throws {
        let p = provider(.groq, .openaiCompatible, base: "https://api.groq.com/openai/v1")
        let json = """
        {"id":"chatcmpl-1","model":"llama-3.3-70b","choices":[{"index":0,
          "message":{"role":"assistant","content":"回答"},"finish_reason":"stop"}],
          "usage":{"prompt_tokens":11,"completion_tokens":5,"total_tokens":16}}
        """.data(using: .utf8)!
        let resp = try AdapterFactory.adapter(for: .openaiCompatible).parseChat(provider: p, data: json)
        XCTAssertEqual(resp.text, "回答")
        XCTAssertEqual(resp.usage?.totalTokens, 16)
        XCTAssertEqual(resp.finishReason, "stop")
    }

    func testOpenAISSEDoneSentinel() throws {
        let p = provider(.cerebras, .openaiCompatible, base: "https://api.cerebras.ai/v1")
        let adapter = AdapterFactory.adapter(for: .openaiCompatible)
        XCTAssertEqual(adapter.parseStreamLine("data: [DONE]", provider: p)?.isDone, true)
        let piece = adapter.parseStreamLine("data: {\"choices\":[{\"delta\":{\"content\":\"ab\"}}]}", provider: p)
        XCTAssertEqual(piece?.text, "ab")
        XCTAssertNil(adapter.parseStreamLine("", provider: p))
        XCTAssertNil(adapter.parseStreamLine(": keep-alive", provider: p))
    }
}
