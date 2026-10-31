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
    private var isPicking = false
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

    /// 用户手动点「读取最新一张截图」
    ///
    /// 窗口放到 7 天并强制跳过去重 —— 手动点就是要重读，
    /// 之前卡 10 分钟窗口 + 去重，导致「相册里最新截图是半小时前的」时点了完全没反应。
    ///
    /// 「双击背面」那条不走这里 —— 它由 `ScanCoordinator` 直接执行，不依赖任何视图。
    /// 这里只服务两个自己点的入口：聊天页左下角菜单、以及系统截屏后的自动识别。
    func pickUpNow() async {
        await pickUp(within: 7 * 24 * 3600, force: true)
    }

    private func pickUp(within seconds: TimeInterval, force: Bool = false) async {
        // 串行化：双击背面和「刚截屏」的自动读可能同时到，两条都在跑会弹两张一样的卡片。
        // 后来的一趟要排队等，不能直接丢掉 —— 丢掉的那趟如果是双击，用户就白双击了。
        var waited = 0
        while isPicking, waited < 50 {
            try? await Task.sleep(nanoseconds: 120_000_000)
            waited += 1
        }
        isPicking = true
        defer { isPicking = false }

        let auth = await Self.ensurePhotoAccess()
        guard auth == .authorized || auth == .limited else {
            flash("没有相册权限。iOS 设置 → 家庭记账 → 照片 → 选「完全访问」", clearAfter: 8)
            return
        }

        // 三轮回查，每轮隔 0.7 秒。
        // 刚截的图写进相册有几百毫秒到一两秒的延迟，一次查不到就下结论会冤枉用户
        // （v0.8 的「最近 10 分钟没有截图」就是这么来的）。
        // 第一轮只认带截图标记的图，之后放宽到任意图片 ——
        // 快捷指令「截取屏幕」动作存出来的图不带 photoScreenshot 标记。
        flash("正在找刚截的那张图…", clearAfter: 30)
        var asset: PHAsset?
        for attempt in 0..<3 {
            asset = Self.latestScreenshot(within: seconds, allowAnyImage: attempt > 0)
            if asset != nil { break }
            if attempt < 2 {
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }

        guard let asset else {
            flash(Self.noShotHint(seconds: seconds, auth: auth), clearAfter: 12)
            return
        }

        // 同一张截图只自动处理一次，避免每次打开都弹同一张卡片；手动点则不受限
        if !force, UserDefaults.standard.string(forKey: lastAssetKey) == asset.localIdentifier {
            flash("这张截图刚才已经记过了。要记新的就先截个屏", clearAfter: 6)
            return
        }
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

    /// 找不到图时说清楚是哪一种「找不到」，别只甩一句「没有截图」
    static func noShotHint(seconds: TimeInterval, auth: PHAuthorizationStatus) -> String {
        if auth == .limited {
            return "相册权限是「仅选中的照片」，看不到新截图。iOS 设置 → 家庭记账 → 照片 → 改成「完全访问」。"
        }
        let span = seconds < 3600 ? "\(max(1, Int(seconds / 60))) 分钟" : "\(Int(seconds / 86_400)) 天"
        if let newest = newestImage(), let d = newest.creationDate {
            return "相册里最新的一张图是\(relative(d))的，不在最近 \(span)里。先把截图存进相册，或者点左下角相册按钮手动选。"
        }
        return "相册里读不到任何图片。到 iOS 设置 → 家庭记账 → 照片，确认选了「完全访问」。"
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
    static func recognizeOffMain(_ image: UIImage) async -> String {
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

    /// 找窗口内最近的一张截图
    ///
    /// - Parameter allowAnyImage: 找不到带「截图」标记的图时，是否接受窗口内任意一张图。
    ///   必须有这一档：快捷指令的「截取屏幕」动作存出来的图**不带** `photoScreenshot` 标记，
    ///   只按标记找会一张都找不到 —— 用户看到的就是「没有截图」，但他明明刚截过。
    static func latestScreenshot(within seconds: TimeInterval, allowAnyImage: Bool = false) -> PHAsset? {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 60
        options.predicate = NSPredicate(format: "creationDate > %@",
                                        Date().addingTimeInterval(-seconds) as NSDate)

        let assets = PHAsset.fetchAssets(with: .image, options: options)
        var shot: PHAsset?
        var any: PHAsset?
        assets.enumerateObjects { asset, _, stop in
            if any == nil { any = asset }
            if asset.mediaSubtypes.contains(.photoScreenshot) {
                shot = asset
                stop.pointee = true
            }
        }
        return shot ?? (allowAnyImage ? any : nil)
    }

    /// 相册里最新的一张图（不限时间）。只为在「找不到」时给出可读的原因。
    static func newestImage() -> PHAsset? {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 1
        return PHAsset.fetchAssets(with: .image, options: options).firstObject
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
