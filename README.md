# FreeRoute AI · 自由路由

> AI Gateway & Smart Router — One Gateway. Every Model. Smarter Routing.
> 运行在 iPhone 本机的 AI API 聚合、智能路由与本地网关。无账号、无注册、无登录，API Key 由你自己添加。

- Bundle ID：`com.freeroute.ai`
- 最低系统：iOS 17.0 ｜ 目标机型：iPhone SE 3（4GB）
- 开发环境：iPhone 上的 OpenMediaS（Mini S）；编译打包：GitHub Actions 云端 macOS + Xcode

## 功能一览

| 模块 | 说明 |
|---|---|
| 服务商管理 | 内置 OpenRouter / Gemini / Anthropic / Groq / Cerebras / Cloudflare Workers AI / NVIDIA NIM / Hugging Face / Ollama / OpenAI 兼容模板 + 任意自定义端点（Base URL、路径、自定义 Header、超时） |
| 密钥管理 | API Key 只进 iPhone 钥匙串，数据库仅存引用；日志脱敏；备份默认不含明文密钥 |
| 模型发现 | 真实请求各家模型目录接口（含 Gemini 分页 token），带能力、上下文、价格、免费标记、健康状态与最后刷新时间；不支持目录接口的服务商会如实显示 |
| 免费服务商目录 | 记录免费额度、限流、地区、注册与账户要求、免费模型状态与最后验证日期；不绕过任何配额限制 |
| Smart Router | SMART FREE / FAST / RELIABLE / BALANCED 四模式；六维评分（健康 25% · 免费额度 20% · 成功率 20% · 延迟 15% · 负载 10% · 能力 10%）；权重可手动调节 |
| 故障切换 | 429 冷却（尊重 `Retry-After`）、401/403 长期熔断、5xx 指数退避、超时切换、熔断器、并发闸门、有限重试；流式已输出内容后不整段重放 |
| 协议适配 | OpenAI Chat Completions / Responses、Anthropic Messages、Gemini、Ollama、SSE/NDJSON、Function Calling、结构化 JSON、Embeddings；无法无损承接的字段显式报告，不静默丢弃 |
| 本地/局域网网关 | Network.framework 监听，默认端口 3000；`/v1/models`、`/v1/chat/completions`、`/v1/responses`、`/v1/embeddings`；Bearer Token 鉴权；SSE 透传；LAN 默认关闭 |
| 实时监控 | 原生 PiP（AVSampleBufferDisplayLayer + `AVPictureInPictureController.ContentSource`）；不可用时降级为应用内悬浮监控 + Live Activity（锁屏/灵动岛） |
| 统计与日志 | Swift Charts 八张图（请求量、成功率、Token、延迟散点、模型/服务商排行、错误分布、24 小时分布）；请求日志含耗时、Token、HTTP 状态、是否切换 |
| 安全与备份 | 钥匙串存储、AES-GCM 加密备份、JSON 导入导出、可选口令 |

## 目录结构

```
FreeRoute/
  App/               入口、根视图、协调器
  Core/              共享类型、聊天协议类型、设置、全局状态
  Database/          SwiftData 实体与门面
  Security/          Keychain 封装
  Providers/         内置服务商模板 + 免费服务商目录
  ProtocolAdapters/  OpenAI 兼容 / Anthropic / Gemini / Ollama 适配器
  SmartRouter/       模式与权重、评分引擎、熔断与退避
  Gateway/           NWListener HTTP 内核、路由分发与鉴权
  Network/           URLSession 上游客户端与 SSE/NDJSON 流式解析
  PiPMonitor/        PiP 控制器、监控数据源、Live Activity、PiP 画面绘制
  LiveActivity/      ActivityAttributes（主 App 与扩展共享）
  Statistics/        统计引擎
  Logging/ Backup/   日志脱敏、备份加密
  Features/          14 个页面
  Components/        品牌视觉系统
  Resources/         Asset Catalog（AppIcon / AccentColor / LaunchBackground）
FreeRouteWidget/     Live Activity 扩展
FreeRouteTests/      单元测试（评分、熔断、适配器、网关解码、备份加密、目录完整性）
FreeRouteUITests/    UI 测试与逐屏截图
.github/workflows/   云端 macOS 构建
tools/               图标生成、静态自检、截图收集、导出配置
docs/                图标规范、构建签名说明、交付清单与已知限制
```

工程文件不入库：`project.yml` 由 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 生成 `FreeRoute.xcodeproj`，本地执行 `xcodegen generate` 即可。

## 构建

```bash
brew install xcodegen
xcodegen generate
# 模拟器（不签名）
xcodebuild build -project FreeRoute.xcodeproj -scheme FreeRoute \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
# 单元测试
xcodebuild test -project FreeRoute.xcodeproj -scheme FreeRoute \
  -destination 'platform=iOS Simulator,name=iPhone SE (3rd generation)' \
  -only-testing:FreeRouteTests CODE_SIGNING_ALLOWED=NO
```

云端构建见 [.github/workflows/ios-build.yml](.github/workflows/ios-build.yml)，详细说明在 [docs/构建与签名说明.md](docs/构建与签名说明.md)。

## 本地静态自检

开发环境是 iPhone 上的 Linux 容器，没有 Xcode，因此编译前先跑自检脚本：

```bash
python3 tools/selfcheck.py     # 括号配平、import 完整性、类型重复定义、占位实现扫描
```

## 隐私

- 不收集遥测，不上传任何数据，所有配置与日志只存本机
- API Key 与网关 Token 存于 iPhone 钥匙串
- 网关默认只监听本机；开启局域网后仍强制 Bearer Token 鉴权，且不会向调用方下发上游密钥

## 许可

MIT。各 AI 服务商名称与商标归其各自所有者。本软件不绕过任何服务商的配额与账户限制。
