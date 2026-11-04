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

        public init(model: String, tokens: Int, tokensPerSecond: Double,
                    streaming: Bool, gatewayRunning: Bool, updatedAt: Date = Date()) {
            self.model = model
            self.tokens = tokens
            self.tokensPerSecond = tokensPerSecond
            self.streaming = streaming
            self.gatewayRunning = gatewayRunning
            self.updatedAt = updatedAt
        }
    }

    /// 固定属性：网关地址
    public var gatewayURL: String

    public init(gatewayURL: String) {
        self.gatewayURL = gatewayURL
    }
}
