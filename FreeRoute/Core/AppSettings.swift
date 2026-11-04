import Foundation
import SwiftUI

/// 应用设置（UserDefaults 持久化；密钥/Tokens 不入此处）
public struct AppSettings: Codable, Hashable, Sendable {
    public var themeRaw: String = ThemeMode.system.rawValue
    public var defaultRouterModeRaw: String = RouterMode.smartFree.rawValue
    public var gatewayPort: Int = 3000
    public var gatewayLANEnabled: Bool = false
    public var maxConcurrentRequests: Int = 3
    public var logRetentionDays: Int = 14
    public var defaultTimeout: Double = 60
    public var autoStartGateway: Bool = false
    public var enableLiveActivity: Bool = true
    public var enableFloatingMonitor: Bool = true
    public var maskedLogs: Bool = true
    public var languageRaw: String = "zh-Hans"

    public init() {}

    public var theme: ThemeMode {
        get { ThemeMode(rawValue: themeRaw) ?? .system }
        set { themeRaw = newValue.rawValue }
    }
    public var defaultRouterMode: RouterMode {
        get { RouterMode(rawValue: defaultRouterModeRaw) ?? .smartFree }
        set { defaultRouterModeRaw = newValue.rawValue }
    }
}

public enum ThemeMode: String, Codable, CaseIterable, Sendable {
    case system, light, dark
    public var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

public enum SettingsStore {
    private static let key = "freeroute.settings.v1"

    public static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s
    }

    public static func save(_ settings: AppSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
