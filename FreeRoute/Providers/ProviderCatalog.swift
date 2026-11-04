import Foundation

// MARK: - 免费服务商目录元数据（最后验证：2026-11-04；额度/限流会变，界面必须展示该日期）

public struct FreeProviderInfo: Identifiable, Codable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var homepage: String
    public var signupURL: String
    public var baseURL: String
    public var protocolType: ProviderProtocolType
    public var defaultModelsPath: String?
    public var defaultRequestPath: String?
    public var defaultEmbeddingsPath: String?
    public var freeTier: Bool
    public var quotaNote: String
    public var rateLimitNote: String
    public var regionNote: String
    public var registrationNote: String
    public var accountNote: String
    public var freeModelsNote: String
    public var docsURL: String
    public var lastVerifiedISO: String

    public init(name: String, homepage: String, signupURL: String, baseURL: String,
                protocolType: ProviderProtocolType, defaultModelsPath: String? = nil,
                defaultRequestPath: String? = nil, defaultEmbeddingsPath: String? = nil,
                freeTier: Bool, quotaNote: String, rateLimitNote: String, regionNote: String,
                registrationNote: String, accountNote: String, freeModelsNote: String,
                docsURL: String, lastVerifiedISO: String = "2026-11-04") {
        self.name = name; self.homepage = homepage; self.signupURL = signupURL; self.baseURL = baseURL
        self.protocolType = protocolType; self.defaultModelsPath = defaultModelsPath
        self.defaultRequestPath = defaultRequestPath; self.defaultEmbeddingsPath = defaultEmbeddingsPath
        self.freeTier = freeTier; self.quotaNote = quotaNote; self.rateLimitNote = rateLimitNote
        self.regionNote = regionNote; self.registrationNote = registrationNote
        self.accountNote = accountNote; self.freeModelsNote = freeModelsNote
        self.docsURL = docsURL; self.lastVerifiedISO = lastVerifiedISO
    }

    public var quota: FreeQuotaInfo {
        FreeQuotaInfo(
            hasFreeTier: freeTier,
            quotaNote: quotaNote,
            rateLimitNote: rateLimitNote,
            regionNote: regionNote,
            registrationNote: registrationNote,
            accountNote: accountNote,
            freeModelsNote: freeModelsNote,
            lastVerifiedISO: lastVerifiedISO
        )
    }

    public func toProvider(kind: ProviderKind) -> Provider {
        Provider(
            kind: kind,
            name: name,
            protocolType: protocolType,
            baseURL: baseURL,
            requestPath: defaultRequestPath,
            modelsPath: defaultModelsPath,
            embeddingsPath: defaultEmbeddingsPath,
            customHeaders: [:],
            timeout: 60,
            enabled: true,
            notes: "来自免费服务商目录；验证日期 \(lastVerifiedISO)",
            freeQuota: quota
        )
    }
}

/// 内置服务商模板（应用内置 + 用户可改）
public enum ProviderCatalog {
    public static let verifiedISO = "2026-11-04"

    public static let builtins: [Provider] = [
        Provider(kind: .openrouter, name: "OpenRouter", protocolType: .openaiCompatible,
                 baseURL: "https://openrouter.ai/api/v1", requestPath: "/chat/completions",
                 modelsPath: "/models", embeddingsPath: "/embeddings",
                 notes: "聚合多服务商；模型名带 :free 后缀的为免费模型",
                 freeQuota: FreeQuotaInfo(hasFreeTier: true,
                     quotaNote: "免费模型按模型单独限额（常见为每日数百次请求量级）",
                     rateLimitNote: "常见 20 次/分钟；具体以模型页显示为准",
                     regionNote: "全球", registrationNote: "需注册免费账号",
                     accountNote: "在 openrouter.ai/settings/keys 创建 API Key",
                     freeModelsNote: "模型名含 :free 后缀的才是免费",
                     lastVerifiedISO: verifiedISO)),

        Provider(kind: .gemini, name: "Google Gemini", protocolType: .gemini,
                 baseURL: "https://generativelanguage.googleapis.com",
                 requestPath: "/v1beta/models/{model}:generateContent",
                 modelsPath: "/v1beta/models",
                 notes: "Google AI Studio；需 Gemini API Key",
                 freeQuota: FreeQuotaInfo(hasFreeTier: true,
                     quotaNote: "AI Studio 免费层按模型给 RPD/TPM 配额",
                     rateLimitNote: "Flash 类常见 10~15 RPM / 每分钟 100 万级 TPM 量级",
                     regionNote: "部分国家/地区不可用", registrationNote: "需 Google 账号",
                     accountNote: "在 aistudio.google.com/apikey 创建 Key",
                     freeModelsNote: "gemini-*-flash 系列通常在免费层内",
                     lastVerifiedISO: verifiedISO)),

        Provider(kind: .anthropic, name: "Anthropic", protocolType: .anthropic,
                 baseURL: "https://api.anthropic.com", requestPath: "/v1/messages",
                 modelsPath: "/v1/models",
                 notes: "Claude 官方 API；需要 Anthropic Console 账户余额",
                 freeQuota: FreeQuotaInfo(hasFreeTier: false,
                     quotaNote: "无免费额度，Console 新账户通常有少量试用额度",
                     rateLimitNote: "按账户等级（RPM/TPM）",
                     regionNote: "需支持地区的账户与网络",
                     registrationNote: "需注册 Anthropic Console",
                     accountNote: "在 console.anthropic.com 创建 API Key",
                     freeModelsNote: "无免费模型",
                     lastVerifiedISO: verifiedISO)),

        Provider(kind: .groq, name: "Groq", protocolType: .openaiCompatible,
                 baseURL: "https://api.groq.com/openai/v1", requestPath: "/chat/completions",
                 modelsPath: "/models", embeddingsPath: "/embeddings",
                 notes: "OpenAI 兼容；推理速度快",
                 freeQuota: FreeQuotaInfo(hasFreeTier: true,
                     quotaNote: "Free/Lite 层按模型给每日请求量与每月请求量额度",
                     rateLimitNote: "常见 30~100 RPM（随模型变化）",
                     regionNote: "全球", registrationNote: "需注册 GroqCloud 账号",
                     accountNote: "在 console.groq.com/keys 创建 Key",
                     freeModelsNote: "llama-3.x / qwen 等开源模型在免费层可用",
                     lastVerifiedISO: verifiedISO)),

        Provider(kind: .cerebras, name: "Cerebras", protocolType: .openaiCompatible,
                 baseURL: "https://api.cerebras.ai/v1", requestPath: "/chat/completions",
                 modelsPath: "/models",
                 notes: "OpenAI 兼容；wafer 级推理",
                 freeQuota: FreeQuotaInfo(hasFreeTier: true,
                     quotaNote: "开发者免费层有每月请求量额度（量级为每月数千次）",
                     rateLimitNote: "常见 30~60 RPM",
                     regionNote: "全球", registrationNote: "需注册 Cerebras Cloud",
                     accountNote: "在 cloud.cerebras.ai 创建 Key",
                     freeModelsNote: "llama-3.1-8b / qwen-3-32b 等常在免费层",
                     lastVerifiedISO: verifiedISO)),

        Provider(kind: .cloudflare, name: "Cloudflare Workers AI", protocolType: .openaiCompatible,
                 baseURL: "https://api.cloudflare.com/client/v4/accounts/{account_id}/ai",
                 requestPath: "/v1/chat/completions", modelsPath: "/v1/models",
                 notes: "需把 {account_id} 替换为你的 Account ID；密钥为 Workers AI Token",
                 freeQuota: FreeQuotaInfo(hasFreeTier: true,
                     quotaNote: "每日免费神经元额度（10,000 neurons/天 量级）",
                     rateLimitNote: "按账户层级",
                     regionNote: "全球", registrationNote: "需 Cloudflare 账号",
                     accountNote: "在 dashboard.cloudflare.com 创建 Workers AI Token，并填入 Account ID",
                     freeModelsNote: "@cf/ 前缀模型常可用",
                     lastVerifiedISO: verifiedISO)),

        Provider(kind: .nvidia, name: "NVIDIA NIM", protocolType: .openaiCompatible,
                 baseURL: "https://integrate.api.nvidia.com/v1", requestPath: "/chat/completions",
                 modelsPath: "/models",
                 notes: "OpenAI 兼容；开发者免费额度",
                 freeQuota: FreeQuotaInfo(hasFreeTier: true,
                     quotaNote: "build.nvidia.com 提供免费开发额度（量级为数千次调用）",
                     rateLimitNote: "常见 40 RPM",
                     regionNote: "全球", registrationNote: "需 NVIDIA Developer 账号",
                     accountNote: "在 build.nvidia.com 生成 Key",
                     freeModelsNote: "多数开源模型可试跑",
                     lastVerifiedISO: verifiedISO)),

        Provider(kind: .huggingface, name: "Hugging Face Inference Providers", protocolType: .openaiCompatible,
                 baseURL: "https://router.huggingface.co/v1", requestPath: "/chat/completions",
                 modelsPath: "/models",
                 notes: "OpenAI 兼容路由；Token 以 hf_ 开头",
                 freeQuota: FreeQuotaInfo(hasFreeTier: true,
                     quotaNote: "免费账户有每月 Inference Credits（小额）",
                     rateLimitNote: "按账户用量与提供商",
                     regionNote: "全球", registrationNote: "需 Hugging Face 账号",
                     accountNote: "在 huggingface.co/settings/tokens 创建 Read token",
                     freeModelsNote: "部分小模型可经由免费额度调用",
                     lastVerifiedISO: verifiedISO)),

        Provider(kind: .ollama, name: "Ollama（本地）", protocolType: .ollama,
                 baseURL: "http://127.0.0.1:11434", requestPath: "/api/chat",
                 modelsPath: "/api/tags",
                 notes: "本机或局域网 Ollama；完全免费、不消耗额度",
                 freeQuota: FreeQuotaInfo(hasFreeTier: true,
                     quotaNote: "无额度限制，取决于本机算力",
                     rateLimitNote: "受本机硬件限制",
                     regionNote: "本机 127.0.0.1",
                     registrationNote: "无需注册",
                     accountNote: "无需 API Key",
                     freeModelsNote: "已 pull 的本地模型全部免费",
                     lastVerifiedISO: verifiedISO)),

        Provider(kind: .openai, name: "OpenAI 兼容（自填）", protocolType: .openaiCompatible,
                 baseURL: "https://api.openai.com/v1", requestPath: "/chat/completions",
                 modelsPath: "/models", embeddingsPath: "/embeddings",
                 notes: "任何 OpenAI 兼容端点均可复制此模板修改 Base URL",
                 freeQuota: FreeQuotaInfo(hasFreeTier: false,
                     quotaNote: "取决于所填服务商",
                     rateLimitNote: "取决于所填服务商",
                     regionNote: "取决于所填服务商",
                     registrationNote: "取决于所填服务商",
                     accountNote: "填入对应 API Key",
                     freeModelsNote: "取决于所填服务商",
                     lastVerifiedISO: verifiedISO))
    ]

    /// 全球免费 AI API 服务商目录（界面展示 + 一键添加）
    public static let freeProviders: [FreeProviderInfo] = [
        FreeProviderInfo(name: "OpenRouter", homepage: "https://openrouter.ai",
            signupURL: "https://openrouter.ai/keys", baseURL: "https://openrouter.ai/api/v1",
            protocolType: .openaiCompatible, defaultModelsPath: "/models", defaultRequestPath: "/chat/completions",
            defaultEmbeddingsPath: "/embeddings", freeTier: true,
            quotaNote: "免费模型按模型单独限额",
            rateLimitNote: "常见 20 次/分钟",
            regionNote: "全球", registrationNote: "需注册免费账号",
            accountNote: "openrouter.ai/settings/keys 创建 Key",
            freeModelsNote: "模型名含 :free 的才是免费",
            docsURL: "https://openrouter.ai/docs"),

        FreeProviderInfo(name: "Google AI Studio (Gemini)", homepage: "https://aistudio.google.com",
            signupURL: "https://aistudio.google.com/apikey", baseURL: "https://generativelanguage.googleapis.com",
            protocolType: .gemini, defaultModelsPath: "/v1beta/models",
            defaultRequestPath: "/v1beta/models/{model}:generateContent", freeTier: true,
            quotaNote: "免费层按模型给 RPD/TPM",
            rateLimitNote: "Flash 类常见 10~15 RPM",
            regionNote: "部分地区不可用", registrationNote: "需 Google 账号",
            accountNote: "aistudio.google.com/apikey 创建 Key",
            freeModelsNote: "gemini-*-flash 通常免费",
            docsURL: "https://ai.google.dev/gemini-api/docs"),

        FreeProviderInfo(name: "Groq", homepage: "https://groq.com",
            signupURL: "https://console.groq.com/keys", baseURL: "https://api.groq.com/openai/v1",
            protocolType: .openaiCompatible, defaultModelsPath: "/models", defaultRequestPath: "/chat/completions",
            defaultEmbeddingsPath: "/embeddings", freeTier: true,
            quotaNote: "Free 层按模型给每日/每月请求额度",
            rateLimitNote: "常见 30~100 RPM",
            regionNote: "全球", registrationNote: "需注册 GroqCloud",
            accountNote: "console.groq.com/keys 创建 Key",
            freeModelsNote: "llama / qwen 开源模型常免费",
            docsURL: "https://console.groq.com/docs"),

        FreeProviderInfo(name: "Cerebras", homepage: "https://cerebras.ai",
            signupURL: "https://cloud.cerebras.ai", baseURL: "https://api.cerebras.ai/v1",
            protocolType: .openaiCompatible, defaultModelsPath: "/models", defaultRequestPath: "/chat/completions",
            freeTier: true,
            quotaNote: "开发者免费层每月请求额度（数千次量级）",
            rateLimitNote: "常见 30~60 RPM",
            regionNote: "全球", registrationNote: "需注册 Cerebras Cloud",
            accountNote: "cloud.cerebras.ai 创建 Key",
            freeModelsNote: "llama-3.1-8b / qwen 系列常见",
            docsURL: "https://inference-docs.cerebras.ai"),

        FreeProviderInfo(name: "Cloudflare Workers AI", homepage: "https://workers.ai",
            signupURL: "https://dash.cloudflare.com/profile/api-tokens", baseURL: "https://api.cloudflare.com/client/v4/accounts/{account_id}/ai",
            protocolType: .openaiCompatible, defaultModelsPath: "/v1/models", defaultRequestPath: "/v1/chat/completions",
            freeTier: true,
            quotaNote: "10,000 neurons/天 量级免费额度",
            rateLimitNote: "按账户层级",
            regionNote: "全球", registrationNote: "需 Cloudflare 账号",
            accountNote: "创建 Workers AI Token + 填 Account ID",
            freeModelsNote: "@cf/ 前缀模型",
            docsURL: "https://developers.cloudflare.com/workers-ai/"),

        FreeProviderInfo(name: "NVIDIA NIM", homepage: "https://build.nvidia.com",
            signupURL: "https://build.nvidia.com", baseURL: "https://integrate.api.nvidia.com/v1",
            protocolType: .openaiCompatible, defaultModelsPath: "/models", defaultRequestPath: "/chat/completions",
            freeTier: true,
            quotaNote: "免费开发额度（数千次调用量级）",
            rateLimitNote: "常见 40 RPM",
            regionNote: "全球", registrationNote: "需 NVIDIA Developer 账号",
            accountNote: "build.nvidia.com 生成 Key",
            freeModelsNote: "多数开源模型可试跑",
            docsURL: "https://docs.api.nvidia.com/nim"),

        FreeProviderInfo(name: "Hugging Face Inference Providers", homepage: "https://huggingface.co/inference-providers",
            signupURL: "https://huggingface.co/settings/tokens", baseURL: "https://router.huggingface.co/v1",
            protocolType: .openaiCompatible, defaultModelsPath: "/models", defaultRequestPath: "/chat/completions",
            freeTier: true,
            quotaNote: "每月免费 Inference Credits（小额）",
            rateLimitNote: "按账户与上游提供商",
            regionNote: "全球", registrationNote: "需 Hugging Face 账号",
            accountNote: "settings/tokens 创建 Read token",
            freeModelsNote: "部分小模型可用免费额度",
            docsURL: "https://huggingface.co/docs/inference-providers"),

        FreeProviderInfo(name: "Ollama（自托管）", homepage: "https://ollama.com",
            signupURL: "https://ollama.com/download", baseURL: "http://127.0.0.1:11434",
            protocolType: .ollama, defaultModelsPath: "/api/tags", defaultRequestPath: "/api/chat",
            freeTier: true,
            quotaNote: "无额度限制",
            rateLimitNote: "受本机算力限制",
            regionNote: "本机", registrationNote: "无需注册",
            accountNote: "无需 Key",
            freeModelsNote: "本地已 pull 模型全部免费",
            docsURL: "https://github.com/ollama/ollama/blob/main/docs/api.md"),

        FreeProviderInfo(name: "Mistral AI La Plateforme", homepage: "https://console.mistral.ai",
            signupURL: "https://console.mistral.ai/api-keys", baseURL: "https://api.mistral.ai/v1",
            protocolType: .openaiCompatible, defaultModelsPath: "/models", defaultRequestPath: "/chat/completions",
            defaultEmbeddingsPath: "/embeddings", freeTier: true,
            quotaNote: "实验层有免费模型",
            rateLimitNote: "常见 1~2 次/秒",
            regionNote: "全球", registrationNote: "需注册",
            accountNote: "console.mistral.ai/api-keys 创建 Key",
            freeModelsNote: "带 experimental 标记的免费模型",
            docsURL: "https://docs.mistral.ai/api/"),

        FreeProviderInfo(name: "SiliconFlow 硅基流动", homepage: "https://siliconflow.cn",
            signupURL: "https://cloud.siliconflow.cn", baseURL: "https://api.siliconflow.cn/v1",
            protocolType: .openaiCompatible, defaultModelsPath: "/models", defaultRequestPath: "/chat/completions",
            defaultEmbeddingsPath: "/embeddings", freeTier: true,
            quotaNote: "部分模型免费（标注 free 标签）",
            rateLimitNote: "免费模型常见 1000 RPM 量级",
            regionNote: "中国大陆可用", registrationNote: "需注册（手机号）",
            accountNote: "cloud.siliconflow.cn 创建 Key",
            freeModelsNote: "模型列表中标注 free 的模型",
            docsURL: "https://docs.siliconflow.cn"),

        FreeProviderInfo(name: "阿里云百炼 DashScope", homepage: "https://bailian.console.aliyun.com",
            signupURL: "https://bailian.console.aliyun.com", baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            protocolType: .openaiCompatible, defaultModelsPath: "/models", defaultRequestPath: "/chat/completions",
            defaultEmbeddingsPath: "/embeddings", freeTier: true,
            quotaNote: "新用户有免费试用额度（按模型）",
            rateLimitNote: "免费额度内常见 500 RPM 量级",
            regionNote: "中国大陆", registrationNote: "需阿里云账号",
            accountNote: "百炼控制台创建 API Key",
            freeModelsNote: "qwen-turbo 等有免费额度模型",
            docsURL: "https://help.aliyun.com/zh/model-studio/"),

        FreeProviderInfo(name: "腾讯混元", homepage: "https://cloud.tencent.com/product/hunyuan",
            signupURL: "https://cloud.tencent.com", baseURL: "https://api.hunyuan.cloud.tencent.com/v1",
            protocolType: .openaiCompatible, defaultModelsPath: "/models", defaultRequestPath: "/chat/completions",
            freeTier: true,
            quotaNote: "部分模型有免费额度",
            rateLimitNote: "按模型与账户",
            regionNote: "中国大陆", registrationNote: "需腾讯云账号",
            accountNote: "腾讯云 API 密钥服务创建 Key",
            freeModelsNote: "标注免费额度的模型",
            docsURL: "https://cloud.tencent.com/document/product/1729"),

        FreeProviderInfo(name: "SambaNova Cloud", homepage: "https://sambanova.ai",
            signupURL: "https://cloud.sambanova.ai", baseURL: "https://api.sambanova.ai/v1",
            protocolType: .openaiCompatible, defaultModelsPath: "/models", defaultRequestPath: "/chat/completions",
            freeTier: true,
            quotaNote: "开发者计划提供免费调用",
            rateLimitNote: "常见 20~60 RPM",
            regionNote: "全球", registrationNote: "需注册",
            accountNote: "cloud.sambanova.ai 创建 Key",
            freeModelsNote: "Llama-3.2 等部分模型免费",
            docsURL: "https://docs.sambanova.ai"),

        FreeProviderInfo(name: "GitHub Models", homepage: "https://github.com/marketplace/models",
            signupURL: "https://github.com/settings/tokens", baseURL: "https://models.github.ai/inference",
            protocolType: .openaiCompatible, defaultModelsPath: "/models", defaultRequestPath: "/chat/completions",
            freeTier: true,
            quotaNote: "免费层有每日请求上限（按模型不同）",
            rateLimitNote: "常见 15~150 RPM",
            regionNote: "需支持 GitHub Models 的地区", registrationNote: "需 GitHub 账号",
            accountNote: "创建具备 models:read 权限的 PAT",
            freeModelsNote: "catalog 中的开源模型",
            docsURL: "https://docs.github.com/github-models")
    ]

    /// 目录条目 → ProviderKind 的映射（用于一键添加时选择适配器类型）
    public static func kind(for info: FreeProviderInfo) -> ProviderKind {
        switch info.name {
        case "OpenRouter": return .openrouter
        case "Google AI Studio (Gemini)": return .gemini
        case "Groq": return .groq
        case "Cerebras": return .cerebras
        case "Cloudflare Workers AI": return .cloudflare
        case "NVIDIA NIM": return .nvidia
        case "Hugging Face Inference Providers": return .huggingface
        case "Ollama（自托管）": return .ollama
        default: return .custom
        }
    }
}
