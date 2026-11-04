import Foundation
import AVKit
import AVFoundation
import CoreMedia
import UIKit
import Observation

/// 原生 PiP 实时监控：把监控视图渲染成视频帧注入 AVSampleBufferDisplayLayer，
/// 再用 AVPictureInPictureController(contentSource:) 启动系统画中画（iOS 15+）。
/// PiP 不可用时，界面提供应用内悬浮监控与 Live Activity 两条替代路径。
@MainActor
@Observable
public final class PiPController {
    public static let shared = PiPController()

    public private(set) var isActive: Bool = false
    public private(set) var isStarting: Bool = false
    public private(set) var statusText: String = "未启动"
    public private(set) var lastFrameCount: Int = 0

    private let displayLayer = AVSampleBufferDisplayLayer()
    private var pip: AVPictureInPictureController?
    private var hostWindow: UIWindow?
    private var monitorView: PiPMonitorUIView?
    private var frameTimer: Timer?
    private var silentPlayer: AVAudioPlayer?
    private var timebase: CMTimebase?
    private var frameIndex: Int = 0
    private weak var appRef: AppState?

    private let fps: Double = 5
    private let frameSize = CGSize(width: 640, height: 360)

    public init() {}

    public var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    // MARK: 启停

    public func toggle(_ app: AppState) {
        if isActive { stop() } else { start(with: app) }
    }

    public func start(with app: AppState) {
        guard !isStarting else { return }
        guard isSupported else {
            statusText = "本机不支持系统画中画"
            return
        }
        isStarting = true
        appRef = app
        Task { @MainActor in
            do {
                try await preparePiP()
                isActive = true
                statusText = "画中画运行中（\(Int(fps)) fps）"
            } catch {
                cleanup()
                statusText = "启动失败：\(error.localizedDescription)"
            }
            isStarting = false
        }
    }

    public func stop() {
        frameTimer?.invalidate()
        frameTimer = nil
        pip?.stopPictureInPicture()
        pip = nil
        displayLayer.flush()
        displayLayer.removeFromSuperlayer()
        hostWindow?.isHidden = true
        hostWindow?.rootViewController = nil
        hostWindow = nil
        monitorView = nil
        silentPlayer?.stop()
        silentPlayer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isActive = false
        statusText = "已停止"
    }

    private func cleanup() {
        frameTimer?.invalidate()
        frameTimer = nil
        pip = nil
        hostWindow?.isHidden = true
        hostWindow = nil
        isActive = false
    }

    // MARK: 准备

    private func preparePiP() async throws {
        configureAudio()
        try await makeHostWindow()

        var tb: CMTimebase?
        if CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
                                           clock: CMClock.getHostClock(),
                                           timebaseOut: &tb) == noErr, let tb {
            timebase = tb
            displayLayer.controlTimebase = tb
            CMTimebaseSetTime(tb, time: CMTimeMakeWithSeconds(0, preferredTimescale: 600))
            CMTimebaseSetRate(tb, rate: 1.0)
        }

        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: displayLayer,
                                                                playbackRate: Float(fps))
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = PictureInPictureDelegate.shared
        PictureInPictureDelegate.shared.onStop = { [weak self] in
            Task { @MainActor in self?.stop() }
        }
        pip = controller

        displayLayer.flush()
        pushFrame()
        frameTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / fps, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pushFrame() }
        }
        // 等一帧入队后再启动，避免空层导致启动失败
        try? await Task.sleep(nanoseconds: 220_000_000)
        controller.startPictureInPicture()
    }

    private func makeHostWindow() async throws {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }) ?? UIApplication.shared.connectedScenes.first as? UIWindowScene
        let host: UIWindow
        if let scene {
            host = UIWindow(windowScene: scene)
        } else {
            host = UIWindow(frame: UIScreen.main.bounds)
        }
        let root = UIViewController()
        root.view.backgroundColor = .clear
        root.modalPresentationStyle = .overFullScreen
        host.rootViewController = root
        host.windowLevel = .statusBar + 50
        host.backgroundColor = .clear

        displayLayer.videoGravity = .resizeAspect
        let layerHost = UIView(frame: CGRect(x: 0, y: 0, width: frameSize.width, height: frameSize.height))
        layerHost.backgroundColor = .clear
        layerHost.alpha = 0.02
        layerHost.isUserInteractionEnabled = false
        displayLayer.frame = layerHost.bounds
        layerHost.layer.addSublayer(displayLayer)
        root.view.addSubview(layerHost)

        host.isHidden = false
        hostWindow = host
        // 让运行循环把窗口装上屏
        try? await Task.sleep(nanoseconds: 120_000_000)
        guard host.window != nil || host.isHidden == false else { throw PiPError.noWindow }
    }

    private func configureAudio() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fr_silent.wav")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? SilentAudio.writeSilentWAV(to: url, seconds: 1.0)
        }
        if FileManager.default.fileExists(atPath: url.path) {
            silentPlayer = try? AVAudioPlayer(contentsOf: url)
            silentPlayer?.numberOfLoops = -1
            silentPlayer?.volume = 0
            silentPlayer?.play()
        }
    }

    enum PiPError: LocalizedError {
        case noWindow, noPixelBuffer
        var errorDescription: String? {
            switch self {
            case .noWindow: return "无法创建画中画承载窗口"
            case .noPixelBuffer: return "帧渲染失败"
            }
        }
    }

    // MARK: 帧生成

    private func pushFrame() {
        guard let app = appRef else { return }
        if displayLayer.status == .failed { displayLayer.flush() }
        guard displayLayer.isReadyForMoreMediaData else { return }

        let view: PiPMonitorUIView
        if let existing = monitorView {
            view = existing
        } else {
            view = PiPMonitorUIView(frame: CGRect(origin: .zero, size: frameSize))
            monitorView = view
        }
        view.update(model: app.monitor.currentModel,
                    provider: app.monitor.currentProvider,
                    tokens: app.monitor.sessionTokens,
                    tokPerSec: app.monitor.tokensPerSecond,
                    elapsed: app.monitor.elapsedText(),
                    gatewayRunning: app.monitor.gatewayRunning,
                    streaming: app.monitor.isStreaming,
                    now: Date())
        guard let pixel = renderPixelBuffer(from: view) else { return }
        append(pixel: pixel)
        frameIndex += 1
        lastFrameCount = frameIndex
    }

    private func renderPixelBuffer(from view: UIView) -> CVPixelBuffer? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: frameSize, format: format)
        let image = renderer.image { _ in
            view.redraw(at: frameSize)
        }
        guard let cg = image.cgImage else { return nil }
        let width = Int(cg.width) / 2 * 2
        let height = Int(cg.height) / 2 * 2
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let pixel = buffer else { return nil }
        CVPixelBufferLockBaseAddress(pixel, [])
        defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pixel),
                                  width: width, height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pixel),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixel
    }

    private func append(pixel buffer: CVPixelBuffer) {
        var formatDesc: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                           imageBuffer: buffer,
                                                           formatDescriptionOut: &formatDesc) == noErr,
              let formatDesc else { return }
        let seconds = Double(frameIndex) / fps
        let pts = CMTimeMakeWithSeconds(max(0, seconds), preferredTimescale: 600)
        var timing = CMSampleTimingInfo(duration: CMTimeMakeWithSeconds(1.0 / fps, preferredTimescale: 600),
                                        presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                              imageBuffer: buffer,
                                                              formatDescription: formatDesc,
                                                              sampleTiming: &timing,
                                                              sampleBufferOut: &sample)
        guard status == noErr, let sample else { return }
        displayLayer.append(sample)
    }
}

final class PictureInPictureDelegate: NSObject, AVPictureInPictureControllerDelegate {
    static let shared = PictureInPictureDelegate()
    var onStop: (() -> Void)?

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        onStop?()
    }
}

/// 静音 WAV 生成（满足 PiP 需要活跃音频会话的系统前提）
enum SilentAudio {
    static func writeSilentWAV(to url: URL, seconds: Double) throws {
        let sampleRate = 8000
        let frames = Int(seconds * Double(sampleRate))
        let dataBytes = frames * 2
        var data = Data()
        func appendString(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
        func appendU32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func appendU16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }

        appendString("RIFF")
        appendU32(UInt32(36 + dataBytes))
        appendString("WAVE")
        appendString("fmt ")
        appendU32(16)
        appendU16(1)
        appendU16(1)
        appendU32(UInt32(sampleRate))
        appendU32(UInt32(sampleRate * 2))
        appendU16(2)
        appendU16(16)
        appendString("data")
        appendU32(UInt32(dataBytes))
        data.append(Data(count: dataBytes))
        try data.write(to: url)
    }
}
