import UIKit

/// PiP 画面内容（UIKit 直接绘制，便于逐帧渲染成视频帧）
/// 布局按需求：左上时间、右上当前模型、中央实时 Token 数、底部 tok/s + 请求时长 + 网关状态
public final class PiPMonitorUIView: UIView {
    private var model = "—"
    private var provider = "—"
    private var tokens = 0
    private var tokPerSec: Double = 0
    private var elapsed = "0:00"
    private var gatewayRunning = false
    private var streaming = false
    private var now = Date()

    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .clear
    }

    public func update(model: String, provider: String, tokens: Int, tokPerSec: Double,
                       elapsed: String, gatewayRunning: Bool, streaming: Bool, now: Date) {
        self.model = model
        self.provider = provider
        self.tokens = tokens
        self.tokPerSec = tokPerSec
        self.elapsed = elapsed
        self.gatewayRunning = gatewayRunning
        self.streaming = streaming
        self.now = now
    }

    /// 供渲染器调用：把当前状态画进当前图形上下文
    public func redraw(at size: CGSize) {
        let ctx = UIGraphicsGetCurrentContext()
        ctx?.clear(CGRect(origin: .zero, size: size))

        // 背景：深蓝黑圆角
        let bg = CGRect(origin: .zero, size: size).insetBy(dx: 6, dy: 6)
        let path = UIBezierPath(roundedRect: bg, cornerRadius: 18)
        UIColor(red: 0.043, green: 0.063, blue: 0.11, alpha: 0.96).setFill()
        path.fill()
        UIColor(red: 0.23, green: 0.52, blue: 1.0, alpha: 0.35).setStroke()
        path.lineWidth = 1.5
        path.stroke()

        let timeText = Self.timeFormatter.string(from: now)
        draw(timeText, point: CGPoint(x: bg.minX + 16, y: bg.minY + 12),
             size: 15, color: UIColor(white: 1, alpha: 0.75), weight: .medium)

        let modelLine = "模型 " + model
        drawRightAligned(modelLine, rightX: bg.maxX - 16, y: bg.minY + 12, size: 14,
                         color: UIColor(red: 0.20, green: 0.85, blue: 0.92, alpha: 1), weight: .semibold,
                         maxWidth: bg.width * 0.55)

        // 中央 Token 数
        let big = Self.compact(tokens)
        drawCentered(big, centerX: bg.midX, centerY: bg.midY - 12, size: 62,
                     color: .white, weight: .bold)
        drawCentered("TOKENS", centerX: bg.midX, centerY: bg.midY + 34, size: 13,
                     color: UIColor(white: 1, alpha: 0.45), weight: .semibold)

        // 流式指示
        if streaming {
            let dotColor = UIColor(red: 0.20, green: 0.78, blue: 0.45, alpha: 1)
            dotColor.setFill()
            UIBezierPath(ovalIn: CGRect(x: bg.midX - 3, y: bg.midY + 50, width: 6, height: 6)).fill()
        }

        // 底部三列
        let y = bg.maxY - 34
        let third = bg.width / 3
        drawColumn("吞吐", String(format: "%.1f tok/s", tokPerSec), centerX: bg.minX + third * 0.5, y: y,
                   color: UIColor(red: 0.23, green: 0.52, blue: 1.0, alpha: 1))
        drawColumn("时长", elapsed, centerX: bg.midX, y: y,
                   color: UIColor(white: 1, alpha: 0.8))
        drawColumn("网关", gatewayRunning ? "运行中" : "已停止", centerX: bg.maxX - third * 0.5, y: y,
                   color: gatewayRunning ? UIColor(red: 0.20, green: 0.78, blue: 0.45, alpha: 1)
                                         : UIColor(red: 1.0, green: 0.35, blue: 0.35, alpha: 1))
    }

    public override func draw(_ rect: CGRect) {
        redraw(at: bounds.size)
    }

    // MARK: 绘制工具

    private func drawColumn(_ title: String, _ value: String, centerX: CGFloat, y: CGFloat, color: UIColor) {
        drawCentered(title, centerX: centerX, centerY: y, size: 11, color: UIColor(white: 1, alpha: 0.45), weight: .medium)
        drawCentered(value, centerX: centerX, centerY: y + 17, size: 16, color: color, weight: .semibold)
    }

    private func draw(_ text: String, point: CGPoint, size: CGFloat, color: UIColor, weight: UIFont.Weight) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color
        ]
        (text as NSString).draw(at: point, withAttributes: attrs)
    }

    private func drawCentered(_ text: String, centerX: CGFloat, centerY: CGFloat, size: CGFloat,
                              color: UIColor, weight: UIFont.Weight, monospaced: Bool = false) {
        let font = monospaced ? UIFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
                              : UIFont.systemFont(ofSize: size, weight: weight)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let str = text as NSString
        let sz = str.size(withAttributes: attrs)
        str.draw(at: CGPoint(x: centerX - sz.width / 2, y: centerY - sz.height / 2), withAttributes: attrs)
    }

    private func drawRightAligned(_ text: String, rightX: CGFloat, y: CGFloat, size: CGFloat,
                                  color: UIColor, weight: UIFont.Weight, maxWidth: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: size, weight: weight),
                                                    .foregroundColor: color]
        var str = text as NSString
        if str.size(withAttributes: attrs).width > maxWidth {
            while str.length > 4 && (str as String).count > 4 {
                str = str.substring(to: str.length - 2) as NSString
                if str.size(withAttributes: attrs).width <= maxWidth {
                    str = (str as String + "…" ) as NSString
                    break
                }
            }
        }
        let sz = str.size(withAttributes: attrs)
        str.draw(at: CGPoint(x: rightX - sz.width, y: y), withAttributes: attrs)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func compact(_ n: Int) -> String {
        switch n {
        case ..<1_000: return "\(n)"
        case ..<1_000_000: return String(format: "%.1fk", Double(n) / 1_000)
        default: return String(format: "%.2fM", Double(n) / 1_000_000)
        }
    }
}
