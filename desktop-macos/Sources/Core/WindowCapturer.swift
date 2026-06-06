import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreImage
import CoreVideo
import AppKit
import ImageIO

/// 远程窗口画面采集器（2.0）。
///
/// 用 ScreenCaptureKit 采集**单个窗口**的完整画面，再在每帧上：
/// 1. 裁剪出当前视口子区域，1:1 输出像素缓冲，喂给 WebRTC 视频轨（主画面）；
/// 2. 周期性把整窗降采样为小 JPEG，作为手机端「小地图」缩略图。
///
/// 视口平移只改变裁剪原点，不重启采集流，因此响应即时。
final class WindowCapturer: NSObject, SCStreamOutput, SCStreamDelegate {
    /// 裁剪后的视口画面（1:1 像素缓冲）+ 时间戳（ns）。
    var onFrame: ((CVPixelBuffer, Int64) -> Void)?
    /// 整窗缩略图 JPEG 数据（周期性）。
    var onThumbnail: ((Data) -> Void)?
    /// 元数据：窗口像素尺寸 + 实际生效视口（窗口像素系）。
    var onMeta: ((Int, Int, CGRect) -> Void)?
    /// 窗口匹配完成后回调（frame + backingScale），供 PointerInjector 初始化。
    var onWindowReady: ((CGRect, CGFloat) -> Void)?
    /// 采集失败时回调（如未找到匹配窗口）。
    var onError: ((String) -> Void)?
    var onLog: ((String) -> Void)?

    private var stream: SCStream?
    private var streamConfig: SCStreamConfiguration?
    private let sampleQueue = DispatchQueue(label: "chatput.window-capture")
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// 期望视口尺寸（像素），来自手机；实际生效视口受窗口尺寸 clamp。
    private var desiredViewport = CGSize.zero
    /// 视口原点（窗口像素系，左上角原点）。
    private var viewportOrigin = CGPoint.zero
    /// 当前窗口像素尺寸。
    private var windowPixelSize = CGSize.zero
    /// 当前会话标识（用于缩略图帧路由）。
    private var sessionId = ""
    /// 当前窗口所在屏幕的 backing scale（retina=2）。供手机做 1:1 缩放换算。
    private(set) var backingScale: CGFloat = 2.0
    /// 当前采集窗口的 CG 全局 frame（左上原点），供触控转鼠标换算用。
    private(set) var windowFrame: CGRect = .zero
    /// 采集内容的物理像素尺寸（含 retina），供计算标题栏偏移。
    private(set) var contentPixelSize: CGSize = .zero
    /// 当前生效的视口宽/高（逻辑坐标），供重连后恢复。
    var currentViewportW: Int { Int(desiredViewport.width) }
    var currentViewportH: Int { Int(desiredViewport.height) }

    /// 最后一帧原始 CIImage + 尺寸 + 时间戳，供视口变化时立即重裁。
    private var cachedSrcImage: CIImage?
    private var cachedSrcW: CGFloat = 0
    private var cachedSrcH: CGFloat = 0
    private var cachedSrcTs: Int64 = 0
    private var viewportChanged = false
    private var lastFrameTime: CFTimeInterval = 0

    private var outputPool: CVPixelBufferPool?
    private var poolSize = CGSize.zero
    private var lastThumbTime: CFTimeInterval = 0
    private let thumbInterval: CFTimeInterval = 1.0
    private let thumbMaxEdge: CGFloat = 240
    private var frameLogCounter = 0

    private let lock = NSLock()

    // MARK: - 启停

    /// 按 app 名 + 窗口标题匹配窗口并开始采集。
    func start(sessionId: String, app: String, title: String, viewportW: Int, viewportH: Int) {
        Task { await self.startAsync(sessionId: sessionId, app: app, title: title,
                                     viewportW: viewportW, viewportH: viewportH) }
    }

    private func startAsync(sessionId: String, app: String, title: String,
                            viewportW: Int, viewportH: Int) async {
        // 先真正停掉上一条采集流（stopCapture），否则旧 SCStream 仍在系统里
        // 跑回调，多次重连会叠加多条流导致卡顿。
        await stopCaptureAsync()
        self.sessionId = sessionId
        self.desiredViewport = CGSize(width: CGFloat(max(1, viewportW)), height: CGFloat(max(1, viewportH)))
        self.viewportOrigin = .zero

        guard let window = await matchWindow(app: app, title: title) else {
            let msg = "窗口采集：未匹配到窗口 \(app) - \(title)"
            onLog?(msg)
            onError?(msg)
            return
        }

        self.windowFrame = window.frame
        let scale = backingScaleForWindow(window.frame)
        self.backingScale = scale
        let pxW = max(2, Int((window.frame.width * scale).rounded()))
        let pxH = max(2, Int((window.frame.height * scale).rounded()))
        windowPixelSize = CGSize(width: CGFloat(pxW), height: CGFloat(pxH))
        contentPixelSize = windowPixelSize
        onWindowReady?(window.frame, scale)

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = pxW
        config.height = pxH
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 5
        config.showsCursor = true
        config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(AppSettings.shared.screenFPS.value))

        streamConfig = config
        let s = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            try await s.startCapture()
            self.stream = s
            onLog?("窗口采集开始：\(app) - \(title) [\(pxW)x\(pxH)]")
        } catch {
            onLog?("窗口采集启动失败：\(error.localizedDescription)")
        }
    }

    func stop() {
        Task { await self.stopCaptureAsync() }
    }

    private func stopCaptureAsync() async {
        if let s = stream {
            try? await s.stopCapture()
        }
        stopInternal()
    }

    private func stopInternal() {
        stream = nil
        outputPool = nil
        poolSize = .zero
        windowPixelSize = .zero
    }

    /// 更新视口（逻辑坐标 points，左上角原点）。下一帧即生效。
    /// 静止画面下强制 SCStream 重采一帧 + 缓存重裁双保险。
    func setViewport(x: Int, y: Int, w: Int, h: Int) {
        lock.lock()
        desiredViewport = CGSize(width: CGFloat(max(1, w)), height: CGFloat(max(1, h)))
        viewportOrigin = CGPoint(x: CGFloat(max(0, x)), y: CGFloat(max(0, y)))
        viewportChanged = true
        lock.unlock()
        refreshFromCacheIfNeeded()
    }

    /// 用缓存帧 + 当前视口重裁输出，避免静止画面下视口拖拽不更新。
    private func refreshFromCacheIfNeeded() {
        guard viewportChanged, let src = cachedSrcImage else { return }
        let scale = backingScale
        let srcW = cachedSrcW; let srcH = cachedSrcH
        guard srcW > 0, srcH > 0 else { return }

        lock.lock()
        let physVpW = min(desiredViewport.width * scale, srcW)
        let physVpH = min(desiredViewport.height * scale, srcH)
        var physOx = viewportOrigin.x * scale
        var physOy = viewportOrigin.y * scale
        physOx = max(0, min(physOx, srcW - physVpW))
        physOy = max(0, min(physOy, srcH - physVpH))
        viewportOrigin = CGPoint(x: physOx / scale, y: physOy / scale)
        let physRect = CGRect(x: physOx, y: physOy, width: physVpW, height: physVpH)
        viewportChanged = false
        lock.unlock()

        let outputScale = AppSettings.shared.screenScale.factor
        if let out = croppedBuffer(from: src, srcHeight: srcH, rect: physRect, outputScale: outputScale) {
            onFrame?(out, Int64(CACurrentMediaTime() * 1_000_000_000))
        }
    }

    // MARK: - 窗口匹配

    /// 取窗口所在屏幕的 backing scale；混合 retina/非 retina 时按交叠面积选最匹配屏幕。
    private func backingScaleForWindow(_ winFrame: CGRect) -> CGFloat {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return 2.0 }
        // CG 全局坐标原点在左上；NSScreen.frame 原点在左下。用主屏高度翻转 Y 做交叠比较。
        let primaryHeight = screens.first?.frame.height ?? 0
        var best: (area: CGFloat, scale: CGFloat) = (0, 0)
        for s in screens {
            let f = s.frame
            let cgRect = CGRect(x: f.origin.x,
                                y: primaryHeight - (f.origin.y + f.height),
                                width: f.width, height: f.height)
            let inter = cgRect.intersection(winFrame)
            let area = inter.isNull ? 0 : inter.width * inter.height
            if area > best.area { best = (area, s.backingScaleFactor) }
        }
        if best.scale > 0 { return best.scale }
        // 窗口未与任何屏幕交叠（极少见）：取最大 scale 兜底。
        return screens.map { $0.backingScaleFactor }.max() ?? 2.0
    }

    private func matchWindow(app: String, title: String) async -> SCWindow? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true) else { return nil }
        let candidates = content.windows.filter { win in
            (win.owningApplication?.applicationName == app) && win.isOnScreen
        }
        // 优先标题完全匹配；否则取该应用最大的可见窗口。
        if let exact = candidates.first(where: { ($0.title ?? "") == title }) {
            return exact
        }
        return candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let src = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let srcW = CGFloat(CVPixelBufferGetWidth(src))
        let srcH = CGFloat(CVPixelBufferGetHeight(src))
        if windowPixelSize.width != srcW || windowPixelSize.height != srcH {
            windowPixelSize = CGSize(width: srcW, height: srcH)
        }
        let ci = CIImage(cvPixelBuffer: src)
        // 缓存原始帧供视口变化时重裁
        lastFrameTime = CACurrentMediaTime(); cachedSrcImage = ci; cachedSrcW = srcW; cachedSrcH = srcH
        cachedSrcTs = Int64(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) * 1_000_000_000)
        viewportChanged = false
        let scale = backingScale

        lock.lock()
        // 视口采用逻辑坐标（points）；裁剪时乘 backingScale 换算物理像素，保证 1:1。
        let physVpW = min(desiredViewport.width * scale, srcW)
        let physVpH = min(desiredViewport.height * scale, srcH)
        var physOx = viewportOrigin.x * scale
        var physOy = viewportOrigin.y * scale
        physOx = max(0, min(physOx, srcW - physVpW))
        physOy = max(0, min(physOy, srcH - physVpH))
        // 钳制后反推逻辑坐标，供下次拖动起点对齐。
        viewportOrigin = CGPoint(x: physOx / scale, y: physOy / scale)
        let physRect = CGRect(x: physOx, y: physOy, width: physVpW, height: physVpH)
        let appliedLogical = CGRect(x: physOx / scale, y: physOy / scale,
                                    width: physVpW / scale, height: physVpH / scale)
        lock.unlock()

        let ts = cachedSrcTs

        let outputScale = AppSettings.shared.screenScale.factor
        if let out = croppedBuffer(from: ci, srcHeight: srcH, rect: physRect, outputScale: outputScale) {
            onFrame?(out, ts)
        }
        // 上报逻辑坐标系的窗口尺寸与生效视口，手机端据此做 1:1 计算。
        onMeta?(Int(srcW / scale), Int(srcH / scale), appliedLogical)

        frameLogCounter += 1
        if frameLogCounter % 30 == 1 {
            onLog?(String(format: "frame src=%.0fx%.0f desired=%.0fx%.0f applied=(%.0f,%.0f %.0fx%.0f) scale=%.1f",
                          srcW, srcH, desiredViewport.width, desiredViewport.height,
                          appliedLogical.origin.x, appliedLogical.origin.y, appliedLogical.width, appliedLogical.height, backingScale))
        }

        let now = CACurrentMediaTime()
        if now - lastThumbTime >= thumbInterval {
            lastThumbTime = now
            if let jpeg = thumbnailJPEG(from: ci, srcW: srcW, srcH: srcH) {
                onThumbnail?(jpeg)
            }
        }
    }

    // MARK: - 裁剪 / 缩略图

    /// 把视口子区域裁出，按 outputScale 降采样后输出像素缓冲。
    private func croppedBuffer(from ci: CIImage, srcHeight: CGFloat, rect: CGRect,
                                outputScale: CGFloat) -> CVPixelBuffer? {
        let outW = Int((rect.width * outputScale).rounded())
        let outH = Int((rect.height * outputScale).rounded())
        guard outW > 0, outH > 0 else { return nil }
        guard let pool = ensurePool(width: outW, height: outH) else { return nil }

        let ciY = srcHeight - (rect.origin.y + rect.height)
        let cropRect = CGRect(x: rect.origin.x, y: ciY, width: rect.width, height: rect.height)
        var image = ci.cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y))
        if outputScale < 1.0 {
            image = image.transformed(by: CGAffineTransform(scaleX: outputScale, y: outputScale))
        }

        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb)
        guard let out = pb else { return nil }
        ciContext.render(image, to: out)
        return out
    }

    private func thumbnailJPEG(from ci: CIImage, srcW: CGFloat, srcH: CGFloat) -> Data? {
        let scale = min(1, thumbMaxEdge / max(srcW, srcH))
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let cs = CGColorSpaceCreateDeviceRGB()
        let options: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.55
        ]
        return ciContext.jpegRepresentation(of: scaled, colorSpace: cs, options: options)
    }

    private func ensurePool(width: Int, height: Int) -> CVPixelBufferPool? {
        if let pool = outputPool, poolSize == CGSize(width: width, height: height) {
            return pool
        }
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
        outputPool = pool
        poolSize = CGSize(width: width, height: height)
        return pool
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onLog?("窗口采集中断：\(error.localizedDescription)")
        stopInternal()
    }
}
