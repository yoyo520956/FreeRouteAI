import SwiftUI
import Foundation

/// 聊天界面：支持 SSE 流式、工具调用/结果可展开卡片、Markdown 渲染
struct ChatView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    let initialModel: String          // 形如 "providerID/modelID" 或 "modelID"
    let initialGoal: String?
    let initialMessages: [ChatMessage]?

    @State private var messages: [ChatDisplayMessage] = []
    @State private var inputText: String = ""
    @State private var isStreaming = false
    @State private var currentStreamTask: Task<Void, Never>?
    @State private var errorText: String?
    @State private var showError = false
    @State private var scrollProxy: ScrollViewProxy?
    @State private var cancellableToken = UUID()

    private var gatewayToken: String { app.gatewayToken }
    private var gatewayBase: String { app.gateway.status.loopbackAddress }

    var body: some View {
        ZStack {
            FRBackground()
            VStack(spacing: 0) {
                // 消息列表
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(messages) { msg in
                                ChatBubble(message: msg)
                                    .id(msg.id)
                            }
                            if isStreaming {
                                TypingIndicator()
                                    .id("typing")
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .padding(.bottom, 8)
                    }
                    .onAppear { scrollProxy = proxy }
                    .onChange(of: messages.count) { _, _ in
                        scrollToBottom(proxy)
                    }
                    .onChange(of: isStreaming) { _, new in
                        if new { scrollToBottom(proxy) }
                    }
                }

                Divider().opacity(0.3)

                // 输入栏
                HStack(alignment: .bottom, spacing: 8) {
                    TextField(isStreaming ? "正在生成…" : "发送消息（Enter 发送，Shift+Enter 换行）",
                              text: $inputText, axis: .vertical)
                        .font(.system(size: 15))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(Color(.secondarySystemGroupedBackground))
                        )
                        .disabled(isStreaming)
                        .lineLimit(1...5)
                        .onSubmit { send() }

                    Button {
                        send()
                    } label: {
                        Image(systemName: isStreaming ? "stop.circle.fill" : "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(isStreaming ? FRDesign.err : FRDesign.accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isStreaming)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.regularMaterial)
            }
            .navigationTitle(initialMessages == nil ? "新对话" : "聊天")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isStreaming {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .alert("错误", isPresented: $showError) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorText ?? "未知错误")
            }
            .task {
                await setupInitial()
            }
            .onDisappear {
                currentStreamTask?.cancel()
            }
        }
    }

    // MARK: 初始化

    private func setupInitial() async {
        if let initial = initialMessages {
            messages = initial.map { ChatDisplayMessage(from: $0) }
        } else {
            // 空对话，显示欢迎提示
            let welcome = ChatDisplayMessage(
                role: .assistant,
                content: "你好！我是 FreeRoute AI。\n\n• 选择一个模型后即可开始对话\n• 支持工具调用（搜索、文件、代码、图片等）\n• SSE 实时流式响应\n\n请在输入框发送第一条消息。",
                toolCalls: nil,
                toolResults: nil
            )
            messages = [welcome]
        }
    }

    // MARK: 发送消息（SSE）

    private func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        cancellableToken = UUID() // 新一轮取消令牌

        // 用户消息入列
        let userMsg = ChatDisplayMessage(role: .user, content: text)
        messages.append(userMsg)
        scrollToBottom()

        // 开启流式任务
        currentStreamTask = Task { @MainActor in
            isStreaming = true
            defer { isStreaming = false }

            var assistantMsg = ChatDisplayMessage(role: .assistant, content: "")
            messages.append(assistantMsg)
            let msgIndex = messages.count - 1

            do {
                let url = URL(string: "\(gatewayBase)/v1/chat/completions")!
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("Bearer \(gatewayToken)", forHTTPHeaderField: "Authorization")
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                req.setValue("1", forHTTPHeaderField: "X-FreeRoute-Agent") // 启用 Agent 模式

                // 构建消息历史（转为 OpenAI 格式）
                let history = messages.dropLast().map { m -> [String: Any] in
                    var dict: [String: Any] = ["role": m.role.rawValue]
                    if !m.content.isEmpty { dict["content"] = m.content }
                    if let calls = m.toolCalls, !calls.isEmpty {
                        dict["tool_calls"] = calls.map { c in
                            ["id": c.id, "type": "function",
                             "function": ["name": c.name, "arguments": c.arguments.jsonString]]
                        }
                    }
                    if let tr = m.toolResults?.first {
                        dict["role"] = "tool"
                        dict["tool_call_id"] = tr.callId
                        dict["name"] = tr.name
                        dict["content"] = tr.content
                    }
                    return dict
                }

                let body: [String: Any] = [
                    "model": initialModel,
                    "messages": history,
                    "stream": true,
                    "freeroute": ["agent": true]
                ]
                req.httpBody = try JSONSerialization.data(withJSONObject: body)

                let (stream, resp) = try await URLSession.shared.bytes(for: req)
                guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    throw URLError(.badServerResponse, userInfo: ["status": status])
                }

                var buffer = ""
                var currentToolCalls: [ToolCallTurn] = []
                var currentToolResults: [ToolResultTurn] = []
                var accumulatingText = ""
                var inToolCall = false
                var toolCallBuffer = ""

                for try await line in stream.lines {
                    if Task.isCancelled { break }
                    if line.hasPrefix("data:") {
                        let data = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        if data == "[DONE]" { break }
                        guard let json = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any] else { continue }

                        // 解析 SSE chunk
                        if let choices = json["choices"] as? [[String: Any]], let first = choices.first {
                            if let delta = first["delta"] as? [String: Any] {
                                // 普通文本
                                if let content = delta["content"] as? String {
                                    accumulatingText += content
                                    assistantMsg.content = accumulatingText
                                    messages[msgIndex] = assistantMsg
                                }
                                // 工具调用开始/进行中
                                if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                                    for tc in toolCalls {
                                        let idx = (tc["index"] as? Int) ?? 0
                                        while currentToolCalls.count <= idx { currentToolCalls.append(ToolCallTurn(name: "", arguments: .object([:]))) }
                                        if let id = tc["id"] as? String { currentToolCalls[idx].id = id }
                                        if let fn = tc["function"] as? [String: Any] {
                                            if let name = fn["name"] as? String { currentToolCalls[idx].name = name }
                                            if let args = fn["arguments"] as? String {
                                                // 增量拼接
                                                var existing = ""
                                                if case .string(let s)? = currentToolCalls[idx].arguments[key: "raw"] {
                                                    existing = s
                                                }
                                                let merged = existing + args
                                                currentToolCalls[idx].arguments = .object([
                                                    "raw": .string(merged)
                                                ])
                                            }
                                        }
                                    }
                                    inToolCall = true
                                }
                            }
                            if let finish = first["finish_reason"] as? String, finish == "tool_calls" {
                                // 工具调用完成，准备执行
                                assistantMsg.toolCalls = currentToolCalls.filter { !$0.name.isEmpty }
                                messages[msgIndex] = assistantMsg
                            }
                        }

                        // freeroute 扩展事件（工具结果）
                        if let fr = json["freeroute"] as? [String: Any] {
                            if let event = fr["event"] as? [String: Any],
                               let kind = event["kind"] as? String, kind == "tool_result",
                               let name = event["tool_name"] as? String,
                               let callId = event["tool_call_id"] as? String,
                               let content = event["detail"] as? String {
                                let ok = event["ok"] as? Bool ?? true
                                currentToolResults.append(ToolResultTurn(callId: callId, name: name, content: content, ok: ok))
                                assistantMsg.toolResults = currentToolResults
                                messages[msgIndex] = assistantMsg
                            }
                        }

                        scrollToBottom()
                    }
                }

                // 流结束：若有工具调用未执行（非 Agent 模式），需本地执行
                // 这里 Agent 模式下工具由服务端执行并通过 freeroute.event 回传结果
                // 非 Agent 模式下 tool_calls 只会出现在最后一个 chunk，需本地执行

            } catch {
                if !Task.isCancelled {
                    errorText = error.localizedDescription
                    showError = true
                    // 显示错误气泡
                    let errMsg = ChatDisplayMessage(
                        role: .assistant,
                        content: "⚠️ 请求失败：\(error.localizedDescription)",
                        toolCalls: nil, toolResults: nil
                    )
                    if messages.indices.contains(msgIndex) {
                        messages[msgIndex] = errMsg
                    } else {
                        messages.append(errMsg)
                    }
                }
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy? = nil) {
        let target = scrollProxy ?? proxy
        if let last = messages.last {
            target?.scrollTo(last.id, anchor: .bottom)
        } else if isStreaming {
            target?.scrollTo("typing", anchor: .bottom)
        }
    }
}

// MARK: - 显示层消息模型（含工具调用/结果）

struct ChatDisplayMessage: Identifiable, Equatable {
    var id = UUID()
    var role: ChatRole
    var content: String
    var toolCalls: [ToolCallTurn]?
    var toolResults: [ToolResultTurn]?

    init(role: ChatRole, content: String, toolCalls: [ToolCallTurn]? = nil, toolResults: [ToolResultTurn]? = nil) {
        self.role = role; self.content = content; self.toolCalls = toolCalls; self.toolResults = toolResults
    }

    init(from msg: ChatMessage) {
        self.role = msg.role
        self.content = msg.content
        self.toolCalls = msg.toolCalls
        self.toolResults = msg.toolResult.map { [$0] }
    }
}

// MARK: - 气泡视图

struct ChatBubble: View {
    let message: ChatDisplayMessage

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.role == .user { Spacer(minLength: 40) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
                // 角色标签
                if message.role != .tool {
                    Text(message.role.rawValue.capitalized)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color(.tertiarySystemFill)))
                }

                // 正文
                if !message.content.isEmpty {
                    Text(message.content)
                        .font(.system(size: 15))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(message.role == .user ? FRDesign.accent.opacity(0.18) : Color(.secondarySystemGroupedBackground))
                        )
                        .foregroundStyle(message.role == .user ? .primary : .primary)
                }

                // 工具调用卡片
                if let calls = message.toolCalls, !calls.isEmpty {
                    ForEach(calls, id: \.id) { call in
                        ToolCallCard(call: call)
                    }
                }

                // 工具结果卡片
                if let results = message.toolResults, !results.isEmpty {
                    ForEach(results, id: \.callId) { result in
                        ToolResultCard(result: result)
                    }
                }
            }

            if message.role != .user { Spacer(minLength: 40) }
        }
    }
}

// MARK: - 工具调用卡片（可展开）

struct ToolCallCard: View {
    let call: ToolCallTurn
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(FRDesign.accent)
                Text(call.name)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                Spacer()
                Text(call.id.prefix(8) + "…")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                Button { expanded.toggle() } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10).fill(FRDesign.accent.opacity(0.10)))

            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    Text("参数")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(call.arguments.jsonString)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(.tertiarySystemFill)))
                }
                .padding(.horizontal, 10).padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: expanded)
    }
}

// MARK: - 工具结果卡片（可展开）

struct ToolResultCard: View {
    let result: ToolResultTurn
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: result.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(result.ok ? FRDesign.ok : FRDesign.err)
                Text(result.name)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                Spacer()
                Text(result.callId.prefix(8) + "…")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                Button { expanded.toggle() } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10).fill(result.ok ? FRDesign.ok.opacity(0.10) : FRDesign.err.opacity(0.10)))

            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    Text("结果")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(result.content)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(.tertiarySystemFill)))
                }
                .padding(.horizontal, 10).padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: expanded)
    }
}

// MARK: - 正在输入指示器

struct TypingIndicator: View {
    @State private var phase = 0
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(FRDesign.accent).frame(width: 8, height: 8)
                .scaleEffect(phase == 0 ? 1.2 : 0.8)
            Circle().fill(FRDesign.accent).frame(width: 8, height: 8)
                .scaleEffect(phase == 1 ? 1.2 : 0.8)
            Circle().fill(FRDesign.accent).frame(width: 8, height: 8)
                .scaleEffect(phase == 2 ? 1.2 : 0.8)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.5).repeatForever()) {
                phase = (phase + 1) % 3
            }
        }
    }
}

// MARK: - ToolCallTurn/ToolResultTurn 的 JSON 扩展（仅用于显示）

extension ToolCallTurn {
    var jsonString: String {
        arguments.jsonString
    }
}