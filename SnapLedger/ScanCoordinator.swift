//
//  ScanCoordinator.swift
//  「双击背面 → 认这张图 → 记上」这条链路的唯一执行者
//
//  为什么要从视图里搬出来：
//
//  v0.9 的链路是 Intent 打一张票据（UserDefaults + 通知），RootView 收到后
//  切 tab 并通过 ScanRelay 通知 ChatView，ChatView 的 onChange 再去读图。
//  中间每一环都依赖「视图已经挂载、订阅已经注册」——
//
//    · `openAppWhenRun = true` 的顺序是「先起 App，再跑 perform」。
//      App 冷启动要几百毫秒，而 Intent 的 perform 在 App 一到前台就跑了。
//      NotificationCenter.post 极可能早于 RootView 的 .onReceive 注册 —— 那一嗓子没人听见。
//    · UserDefaults 那张票本来兜得住，可 RootView 只在 onAppear / scenePhase 变化时取，
//      而这两个钩子都已经过去了。票就静静躺着，直到下次切前台。
//    · 就算票被取到，ChatView 的 .onChange(of: relay.pending) 也要求它已经挂载。
//
//  用户看到的就是：「跳到 App 了，显示正在读刚截的那张图，然后没有然后」。
//
//  现在把这些动作全部收进一个常驻单例：Intent 自己（就在 App 进程里）直接调它，
//  不依赖任何视图状态。识别完直接把账写进 LedgerStore，再把「记了哪一笔」
//  发布出去，聊天页什么时候挂载、什么时候来取都行 —— 晚到也不会漏。
//

import SwiftUI
import Photos

@MainActor
final class ScanCoordinator: ObservableObject {

    static let shared = ScanCoordinator()

    /// 聊天页顶上那行字：进度、以及「为什么没记上」
    @Published private(set) var banner: String = ""

    /// 刚记上去的记录 id。聊天页取走后铺成记录行（能点开改、能左滑删）。
    @Published private(set) var pendingRecordIds: [String] = []

    /// 每变一次表示「该把记账页翻出来了」。
    /// 用计数而不是 Bool：连着双击两次也要各切一次（用户可能中途切去看了别的页）。
    @Published private(set) var focusChat = 0

    /// 同一张截图只认一次，两条入口共用
    private static let lastAssetKey = "snap.lastScreenshotAsset"

    private var busy = false
    private var lastStart = Date.distantPast
    private var bannerTask: Task<Void, Never>?

    private init() {}

    // MARK: 入口

    /// 双击背面 / 快捷指令 / snapledger://scan
    ///
    /// 窗口 30 分钟：用户截完图可能先看了眼账单才双击。
    /// 不去重之外放宽窗口会记错账，所以窗口放宽、去重保留。
    func scanFromShortcut() {
        focusChat += 1
        Task { await scan(window: 1800, force: false, fromShortcut: true) }
    }

    /// 自己点「立即读取最新一张截图」：窗口 7 天，并强制跳过去重 —— 手动点就是要重读。
    func scanLatestManually() {
        Task { await scan(window: 7 * 24 * 3600, force: true, fromShortcut: false) }
    }

    /// 聊天页来取「刚才记了哪几笔」
    func drainPendingRecords() -> [String] {
        let ids = pendingRecordIds
        pendingRecordIds = []
        return ids
    }

    // MARK: 主流程

    private func scan(window: TimeInterval, force: Bool, fromShortcut: Bool) async {
        // 一次双击会从两条路进来（Intent 直接调 + UserDefaults 票据），
        // 所以两头都堵：正在跑就返回；同一瞬间的重复请求也丢掉。
        if busy { return }
        if fromShortcut, Date().timeIntervalSince(lastStart) < 2 { return }
        busy = true
        lastStart = Date()
        defer { busy = false }

        say("正在找刚截的那张图…", keep: 40)

        let auth = await ScreenshotWatcher.ensurePhotoAccess()
        guard auth == .authorized || auth == .limited else {
            say("没有相册权限。到 iOS 设置 → 家庭记账 → 照片，改成「完全访问」", keep: 14)
            return
        }

        // 四轮回查，每轮 0.6 秒。刚截的图写进相册有几百毫秒到一两秒的延迟，
        // 查一次就下结论会冤枉用户。第一轮只认带截图标记的，之后放宽到任意图片 ——
        // 快捷指令「截取屏幕」动作存出来的图不带 photoScreenshot 标记。
        var asset: PHAsset?
        for attempt in 0..<4 {
            asset = ScreenshotWatcher.latestScreenshot(within: window, allowAnyImage: attempt > 0)
            if asset != nil { break }
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
        guard let asset else {
            say(ScreenshotWatcher.noShotHint(seconds: window, auth: auth), keep: 14)
            return
        }

        if !force, UserDefaults.standard.string(forKey: Self.lastAssetKey) == asset.localIdentifier {
            say("这张截图刚才已经记过了。要记新的就先截个屏", keep: 8)
            return
        }
        UserDefaults.standard.set(asset.localIdentifier, forKey: Self.lastAssetKey)

        say("正在识别\(ScreenshotWatcher.relative(asset.creationDate))的截图…", keep: 40)
        // 读图要带超时：图还在 iCloud 里没下载完时，`requestImage` 的回调可能一直不来，
        // 界面就永远停在「正在识别」上 —— 用户看到的就是「卡住了，然后没有然后」。
        guard let image = await Self.imageWithTimeout(asset, seconds: 12) else {
            say("这张图读不出来（可能还在 iCloud 里没下载完），过几秒再双击一次", keep: 12)
            return
        }
        if ScanSettings.archiveImages {
            _ = ScanArchive.save(image)
        }

        let text = await ScreenshotWatcher.recognizeOffMain(image)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            say("这张图里没读到文字。确认是付款/账单页再试，也可以点左下角相册按钮手动选", keep: 14)
            return
        }

        let bill = BillParser.analyze(text)
        guard bill.amount > 0 else {
            say("文字读到了，但没认出金额（可能是余额页或不常见的版式）。手动说一句「午饭 32」更快", keep: 14)
            return
        }

        var rec = bill.toRecord(source: "intent")
        rec.book = ScanSettings.resolvedBook()
        if rec.member.isEmpty { rec.member = LedgerStore.shared.selfMemberId }
        let saved = LedgerStore.shared.add(rec)
        SyncEngine.shared.now()

        pendingRecordIds.append(saved.id)
        say("已记账 · \(saved.category) \(Money.currency(saved.amount))，点一下能改", keep: 10)
    }

    // MARK: 提示

    /// 给「可能永不回调」的系统 API 加一道闸。
    ///
    /// `PHImageManager.requestImage` 在图片还在 iCloud、且当前没有网络时会一直不回调。
    /// 没有这道闸，界面就停在「正在识别…」上不动 —— 看上去就是卡死。
    private static func imageWithTimeout(_ asset: PHAsset, seconds: Double) async -> UIImage? {
        await withTaskGroup(of: UIImage?.self) { group in
            group.addTask { await ScreenshotWatcher.image(of: asset) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func say(_ s: String, keep: Double) {
        banner = s
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(keep * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            if self.banner == s { self.banner = "" }
        }
    }
}
