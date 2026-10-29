//
//  VisionOCR.swift
//  Vision 中文识别 + 截屏感知
//
//  比网页版的 tesseract.js 强的地方：
//  - 设备端、免费、无需下载 1.7MB 模型，识别一张截图约 200-400ms
//  - 中文识别准确率明显更高（尤其小字号、抗压缩噪点）
//
//  「双击背面」在原生 App 上的做法和网页版完全不同：
//  iOS 不允许后台监听截屏，但允许两点：
//  1. App 在前台时收到 userDidTakeScreenshotNotification
//  2. App 打开时查相册最近新增的截图（PHAsset mediaSubtypes 能精确筛出截图）
//  所以真实链路是：轻点背面 → 打开 App（快捷指令只需 1 个动作）→ 自动捞最近的截图 → 识别。
//

import Foundation
import Vision
import UIKit
import Photos

// MARK: - 识别

enum TextOCR {

    /// 把截图识别成多行文本。同步调用，请放在后台线程。
    static func recognize(_ image: UIImage) -> String {
        guard let cg = image.cgImage else { return "" }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true
        // 支付截图里「¥32.50」这种小字容易被漏，阈值放低一点
        request.minimumTextHeight = 0.006

        let handler = VNImageRequestHandler(cgImage: cg,
                                            orientation: orientation(of: image),
                                            options: [:])
        do {
            try handler.perform([request])
        } catch {
            return ""
        }

        let observations = request.results ?? []
        let items: [(String, CGRect)] = observations.compactMap { obs in
            guard let top = obs.topCandidates(1).first else { return nil }
            return (top.string, obs.boundingBox)
        }
        guard !items.isEmpty else { return "" }

        // Vision 一般已按阅读顺序返回，但同一行被拆成多段时顺序会乱。
        // 按 y 分桶（2.5% 一条），桶内按 x 升序，保证「微信支付 32.50」这种同行文本不乱。
        let sorted = items.sorted { a, b in
            let ra = Int((1 - a.1.midY) * 40)
            let rb = Int((1 - b.1.midY) * 40)
            if ra != rb { return ra < rb }
            return a.1.minX < b.1.minX
        }
        return sorted.map { $0.0 }.joined(separator: "\n")
    }

    private static func orientation(of image: UIImage) -> CGImagePropertyOrientation {
        switch image.imageOrientation {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}

// MARK: - 截屏感知

@MainActor
final class ScreenshotWatcher: ObservableObject {

    static let shared = ScreenshotWatcher()

    /// 识别出来的文字，交给聊天界面出卡片
    @Published var incoming: String?
    @Published var status: String = ""

    private var observer: NSObjectProtocol?
    private var flashTask: Task<Void, Never>?
    private let lastAssetKey = "snap.lastScreenshotAsset"

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.userDidTakeScreenshotNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.pickUp(within: 20) }
        }
    }

    /// 冷启动 / 从后台回来时调用：捞最近 2 分钟的截图
    func pickUpOnLaunch() async {
        await pickUp(within: 120)
    }

    /// 用户手动点「读取最新一张截图」
    ///
    /// 之前这里窗口只有 10 分钟、还保留了「同一张只处理一次」的去重，
    /// 于是「相册里最新截图是半小时前的」或「这张刚被自动读过」时，点了完全没反应。
    /// 手动点就是要重读：窗口放到 7 天，并且强制跳过去重。
    func pickUpNow() async {
        await pickUp(within: 7 * 24 * 3600, force: true)
    }

    private func pickUp(within seconds: TimeInterval, force: Bool = false) async {
        let auth = await Self.ensurePhotoAccess()
        guard auth == .authorized || auth == .limited else {
            flash("没有相册权限。去 设置 → 家庭记账 → 照片 里改成「全部照片」")
            return
        }
        if auth == .limited {
            flash("相册权限是「仅选中的照片」，新截图可能读不到", clearAfter: 6)
        }
        guard let asset = Self.latestScreenshot(within: seconds) else {
            flash(seconds < 3600 ? "相册里最近没有截图，先截一张再回来" : "相册里还没找到截图")
            return
        }

        // 同一张截图只自动处理一次，避免每次打开都弹同一张卡片；手动点则不受限
        if !force, UserDefaults.standard.string(forKey: lastAssetKey) == asset.localIdentifier { return }
        UserDefaults.standard.set(asset.localIdentifier, forKey: lastAssetKey)

        flash("正在识别\(Self.relative(asset.creationDate))的截图…", clearAfter: 30)
        guard let image = await Self.image(of: asset) else {
            flash("读不到这张图（可能还在 iCloud 里没下载完）", clearAfter: 6)
            return
        }
        let text = await Self.recognizeOffMain(image)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            flash("这张截图里没读到文字，换一张试试", clearAfter: 6)
            return
        }
        status = ""
        incoming = text
    }

    /// 状态提示：显示几秒后自己消失，免得一直挂在聊天顶上
    private func flash(_ s: String, clearAfter: Double = 4) {
        status = s
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(clearAfter * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            if self.status == s { self.status = "" }
        }
    }

    /// 「刚刚 / 12 分钟前 / 3 小时前 / 2 天前」
    static func relative(_ d: Date?) -> String {
        guard let d else { return "" }
        let s = -d.timeIntervalSinceNow
        if s < 60 { return "刚刚" }
        if s < 3600 { return "\(max(1, Int(s / 60))) 分钟前" }
        if s < 86_400 { return "\(Int(s / 3600)) 小时前" }
        return "\(Int(s / 86_400)) 天前"
    }

    /// Vision 同步跑 200-400ms，别卡主线程
    private static func recognizeOffMain(_ image: UIImage) async -> String {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: TextOCR.recognize(image))
            }
        }
    }

    // MARK: 相册

    static func ensurePhotoAccess() async -> PHAuthorizationStatus {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            return await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        return status
    }

    static func latestScreenshot(within seconds: TimeInterval) -> PHAsset? {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 40
        options.predicate = NSPredicate(format: "creationDate > %@",
                                        Date().addingTimeInterval(-seconds) as NSDate)

        let assets = PHAsset.fetchAssets(with: .image, options: options)
        var found: PHAsset?
        assets.enumerateObjects { asset, _, stop in
            if asset.mediaSubtypes.contains(.photoScreenshot) {
                found = asset
                stop.pointee = true
            }
        }
        return found
    }

    static func image(of asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { cont in
            // requestImage 在 iCloud 图 / 降级图上可能回调两次，重复 resume 会崩
            final class Guard {
                var done = false
            }
            let once = Guard()
            let options = PHImageRequestOptions()
            options.isSynchronous = false
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            PHImageManager.default().requestImage(for: asset,
                                                 targetSize: CGSize(width: 1600, height: 1600),
                                                 contentMode: .aspectFit,
                                                 options: options) { image, _ in
                guard !once.done else { return }
                once.done = true
                cont.resume(returning: image)
            }
        }
    }
}
