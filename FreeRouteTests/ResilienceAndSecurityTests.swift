import XCTest
@testable import FreeRoute

/// 熔断、退避、备份加密、密钥掩码、网关解析
final class ResilienceAndSecurityTests: XCTestCase {
    // MARK: 熔断器

    func testRateLimitOpensCircuitWithCooldown() {
        let b = CircuitBreaker()
        let cd = b.recordFailure(key: "k1", error: .http(status: 429, message: "slow down"))
        XCTAssertGreaterThan(cd, 0, "429 必须产生冷却")
        XCTAssertFalse(b.isAvailable(key: "k1"))
        XCTAssertEqual(b.displayState(for: "k1"), .cooldown)
    }

    func testUnauthorizedUsesLongCooldown() {
        let b = CircuitBreaker()
        let cd = b.recordFailure(key: "k2", error: .http(status: 401, message: "bad key"))
        XCTAssertGreaterThanOrEqual(cd, 3600, "401 属于需要人工换密钥的长期熔断")
    }

    func testRetryAfterHonoured() {
        let b = CircuitBreaker()
        let cd = b.recordFailure(key: "k3", error: .http(status: 429, message: ""), retryAfter: 42)
        XCTAssertEqual(cd, 42, accuracy: 0.01, "必须尊重上游 Retry-After")
    }

    func testSuccessClosesCircuit() {
        let b = CircuitBreaker()
        b.recordFailure(key: "k4", error: .timeout)
        b.recordSuccess(key: "k4")
        XCTAssertTrue(b.isAvailable(key: "k4"))
        XCTAssertEqual(b.snapshot(for: "k4").failureCount, 0)
    }

    func testBackoffIsBoundedAndFinite() {
        let policy = BackoffPolicy(maxAttempts: 3, baseDelay: 1, maxDelay: 8)
        XCTAssertNotNil(policy.delay(afterAttempt: 0))
        XCTAssertNotNil(policy.delay(afterAttempt: 1))
        XCTAssertNil(policy.delay(afterAttempt: 2), "达到上限必须停止重试，禁止无限重试")
        for i in 0..<10 {
            if let d = policy.delay(afterAttempt: i) {
                XCTAssertLessThanOrEqual(d, 10.5)
            }
        }
    }

    // MARK: 上游错误分类

    func testErrorClassification() {
        XCTAssertTrue(UpstreamError.http(status: 401, message: "").isUnauthorized)
        XCTAssertTrue(UpstreamError.http(status: 403, message: "").isForbidden)
        XCTAssertTrue(UpstreamError.http(status: 429, message: "").isRateLimited)
        XCTAssertTrue(UpstreamError.http(status: 503, message: "").isServerError)
        XCTAssertTrue(UpstreamError.timeout.isRetryable)
        XCTAssertEqual(UpstreamError.http(status: 404, message: "").status, 404)
    }

    // MARK: 备份加密

    func testBackupEncryptRoundTrip() throws {
        let svc = BackupService()
        let plain = Data("自由路由备份内容 token=123".utf8)
        let enc = try svc.encrypt(plain, passphrase: "正确口令")
        XCTAssertTrue(svc.isEncrypted(enc))
        XCTAssertNotEqual(String(data: enc, encoding: .utf8)?.contains("自由路由") ?? true, true)
        let dec = try svc.decrypt(enc, passphrase: "正确口令")
        XCTAssertEqual(dec, plain)
    }

    func testBackupWrongPassphraseFails() throws {
        let svc = BackupService()
        let enc = try svc.encrypt(Data("secret".utf8), passphrase: "right")
        XCTAssertThrowsError(try svc.decrypt(enc, passphrase: "wrong"))
    }

    func testBackupRejectsForeignFormat() {
        let svc = BackupService()
        XCTAssertFalse(svc.isEncrypted(Data("{\"app\":\"其他软件\"}".utf8)))
    }

    func testSnapshotExcludesPlaintextKeysByDefault() throws {
        let svc = BackupService()
        let p = Provider(kind: .custom, name: "测试源", protocolType: .openaiCompatible,
                         baseURL: "https://x.invalid/v1",
                         keys: [APIKeyRef(keychainRef: "ref1")])
        let data = try svc.makeSnapshot(providers: [p], models: [], logs: [], settings: AppSettings(),
                                        includeKeys: false, keyReader: { _ in "sk-super-secret-value" })
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("sk-super-secret-value"), "默认导出绝不允许包含明文密钥")
        XCTAssertTrue(text.contains("测试源"))
    }

    // MARK: Keychain 掩码

    func testKeychainMaskHidesMiddle() {
        let m = KeychainStore.mask("sk-abcdef1234567890")
        XCTAssertFalse(m.contains("abcdef123456"))
        XCTAssertTrue(m.hasPrefix("sk-"))
        XCTAssertTrue(m.hasSuffix("7890"))
        XCTAssertEqual(KeychainStore.mask(""), "未设置")
    }

    // MARK: 网关请求解码

    func testGatewayChatRequestDecoding() throws {
        let json = """
        {"model":"gpt-4o-mini","messages":[{"role":"system","content":"a"},{"role":"user","content":[{"type":"text","text":"b"}]}],
         "max_tokens":64,"stop":"END","stream":true,"temperature":0.3}
        """.data(using: .utf8)!
        let input = try JSONDecoder.freeroute.decode(ChatIn.self, from: json)
        XCTAssertEqual(input.model, "gpt-4o-mini")
        XCTAssertEqual(input.messages.count, 2)
        XCTAssertEqual(input.messages[1].content?.text, "b")
        XCTAssertEqual(input.maxTokens, 64)
        XCTAssertEqual(input.stream, true)
        XCTAssertEqual(input.stop?.values, ["END"])
    }

    func testGatewayResponsesInputDecoding() throws {
        let json = """
        {"model":"m","instructions":"系统","input":[{"role":"user","content":"你好"}]}
        """.data(using: .utf8)!
        let input = try JSONDecoder.freeroute.decode(ResponsesIn.self, from: json)
        XCTAssertEqual(input.instructions, "系统")
        XCTAssertEqual(input.input.items.first?.content, "你好")
    }

    func testGatewayStringInputDecoding() throws {
        let json = "{\"model\":\"m\",\"input\":\"一段文本\"}".data(using: .utf8)!
        let input = try JSONDecoder.freeroute.decode(EmbedIn.self, from: json)
        XCTAssertEqual(input.input.items.first?.content, "一段文本")
    }

    // MARK: 格式化

    func testFormatting() {
        XCTAssertEqual(FRFormat.compact(999), "999")
        XCTAssertEqual(FRFormat.compact(1500), "1.5k")
        XCTAssertEqual(FRFormat.ms(1500), "1.50s")
        XCTAssertEqual(FRFormat.percent(0.9876), "98.8%")
        XCTAssertEqual(FRFormat.context(8192), "8K")
        XCTAssertEqual(FRFormat.context(nil), "—")
    }

    // MARK: 免费目录完整性（防止编造额度信息）

    func testFreeCatalogEntriesAreDocumented() {
        XCTAssertFalse(ProviderCatalog.freeProviders.isEmpty)
        for info in ProviderCatalog.freeProviders {
            XCTAssertFalse(info.name.isEmpty)
            XCTAssertTrue(info.baseURL.hasPrefix("https://") || info.baseURL.hasPrefix("http://"),
                          "\(info.name) 的 Base URL 不合法")
            XCTAssertFalse(info.quotaNote.isEmpty, "\(info.name) 缺少免费额度说明")
            XCTAssertFalse(info.lastVerifiedISO.isEmpty, "\(info.name) 缺少最后验证日期")
            XCTAssertFalse(info.docsURL.isEmpty, "\(info.name) 缺少文档链接")
        }
    }

    func testBuiltinProvidersMatchRequirementList() {
        let kinds = Set(ProviderCatalog.builtins.map { $0.kind })
        for required in [ProviderKind.openrouter, .gemini, .anthropic, .groq, .cerebras,
                         .cloudflare, .nvidia, .huggingface, .ollama, .openai] {
            XCTAssertTrue(kinds.contains(required), "缺少内置服务商 \(required.displayName)")
        }
        for p in ProviderCatalog.builtins {
            XCTAssertTrue(p.baseURL.hasPrefix("https://") || p.baseURL.hasPrefix("http://"))
            XCTAssertTrue(p.keys.isEmpty, "内置模板不得包含任何密钥")
        }
    }

    func testOfficialEndpointsAreCorrect() {
        func url(_ kind: ProviderKind) -> String {
            ProviderCatalog.builtins.first { $0.kind == kind }?.baseURL ?? ""
        }
        XCTAssertEqual(url(.openrouter), "https://openrouter.ai/api/v1")
        XCTAssertEqual(url(.anthropic), "https://api.anthropic.com")
        XCTAssertEqual(url(.groq), "https://api.groq.com/openai/v1")
        XCTAssertEqual(url(.cerebras), "https://api.cerebras.ai/v1")
        XCTAssertEqual(url(.nvidia), "https://integrate.api.nvidia.com/v1")
        XCTAssertEqual(url(.ollama), "http://127.0.0.1:11434")
    }
}
