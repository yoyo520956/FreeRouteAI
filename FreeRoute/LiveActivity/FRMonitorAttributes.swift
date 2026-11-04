import Foundation
import ActivityKit

/// Live Activity 数据模型（同一文件同时编译进主 App 与 Widget 扩展，字段必须完全一致）
public struct FRMonitorAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// 当前模型
        public var model: String
        /// 累计 Token
        public var tokens: Int
        /// 实时吞吐 tok/s
        public var tokensPerSecond: Double
        /// 是否正在流式输出
        public var streaming: Bool
        /// 网关是否运行
        public var gatewayRunning: Bool
        /// 更新时间
        public var updatedAt: Date
        /// 网关地址。放在 ContentState 而不是固定属性里：
        /// DynamicIsland 闭包给的 ActivityViewContext 只保证有 .state，
        /// 取固定属性要走 context.activity.attributes，实测该 SDK 上没有 activity 成员。
        public var gatewayURL: String

        public init(model: String, tokens: Int, tokensPerSecond: Double,
                    streaming: Bool, gatewayRunning: Bool, updatedAt: Date = Date(),
                    gatewayURL: String = "http://127.0.0.1:3000") {
            self.model = model
            self.tokens = tokens
            self.tokensPerSecond = tokensPerSecond
            self.streaming = streaming
            self.gatewayRunning = gatewayRunning
            self.updatedAt = updatedAt
            self.gatewayURL = gatewayURL
        }
    }
}
