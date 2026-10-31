//
//  RootView.swift
//  四个 tab：记账 / 账本 / 统计 / 我的
//
//  网页版也是这四页。原生版多给了一样东西：账本页点一条就能改，
//  因为「记完了发现有错」是记账工具最高频的后续动作。
//

import SwiftUI

/// 快捷指令「打开 URL → snapledger://scan」的落点
///
/// 用自增计数器而不是 Bool：连续两次扫码都要能触发，
/// 而 Bool 置 true 之后第二次就不再变化了。
final class ScanRelay: ObservableObject {
    static let shared = ScanRelay()
    @Published private(set) var pending = 0

    func request() { pending += 1 }
}

/// 「双击背面 → 打开 App → 记这一笔」的交接票据
///
/// 为什么不能只用 `ScanRelay`：`openAppWhenRun = true` 的 Intent 有可能运行在
/// 系统的独立进程里，那时它摸不到 App 内存里的单例。UserDefaults 是同一个沙盒，
/// 两边都能读写，所以借它传话。
///
/// 打的是时间戳而不是 Bool：连着双击两次，第二张截图也要能记。
enum ScanPending {
    private static let key = "snap.scan.pending"

    /// 有效时长。超过这个时间的票据当作过期 —— 用户可能双击完就把手机揣兜里了，
    /// 十分钟后再打开 App 不该突然蹦出一笔账。
    private static let window: TimeInterval = 180

    static func mark() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: key)
        // `openAppWhenRun = true` 的顺序是「先起 App，再跑 perform」，
        // 也就是说 RootView.onAppear / scenePhase 都已经过去了才打上这张票。
        // 光靠 UserDefaults 会一直躺到下次切前台，所以同进程再喊一嗓子。
        NotificationCenter.default.post(name: .snapScanRequested, object: nil)
    }

    /// 取走票据（取一次就清），过期的直接丢弃
    static func takeIfFresh() -> Bool {
        let ts = UserDefaults.standard.double(forKey: key)
        guard ts > 0 else { return false }
        UserDefaults.standard.removeObject(forKey: key)
        return Date().timeIntervalSince1970 - ts < window
    }
}

extension Notification.Name {
    /// 进程内：「双击背面要读截图了」。跨进程的情况由 UserDefaults 那张票兜住。
    static let snapScanRequested = Notification.Name("snap.scan.requested")
}

struct RootView: View {
    @State private var tab = 0
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $tab) {
            ChatView()
                .tabItem { Label("记账", systemImage: "bubble.left.and.bubble.right.fill") }
                .tag(0)

            BookView()
                .tabItem { Label("账本", systemImage: "list.bullet.rectangle") }
                .tag(1)

            StatView()
                .tabItem { Label("统计", systemImage: "chart.bar.fill") }
                .tag(2)

            MeView()
                .tabItem { Label("我的", systemImage: "person.crop.circle") }
                .tag(3)
        }
        .tint(Theme.brand)
        .onAppear { consumeScanPending() }
        // App 已经在后台时被双击背面拉起，RootView 不会重建，onAppear 不会再来一次，
        // 所以还得盯着 scenePhase。
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { consumeScanPending() }
        }
        // 同进程的通知：App 是先起来、Intent 后跑完，上面两个钩子都会错过
        .onReceive(NotificationCenter.default.publisher(for: .snapScanRequested)) { _ in
            consumeScanPending()
        }
        .onOpenURL { url in
            // 只认自己的 scheme，别家 App 的回调一律忽略
            guard url.scheme?.lowercased() == "snapledger" else { return }
            let host = (url.host ?? "").lowercased()
            let path = url.path.lowercased()
            if host == "scan" || path.contains("scan") {
                tab = 0
                ScanRelay.shared.request()
            }
        }
    }

    /// 双击背面留下的票据：切到记账页，并让它马上去读那张截图
    private func consumeScanPending() {
        guard ScanPending.takeIfFresh() else { return }
        tab = 0
        ScanRelay.shared.request()
    }
}
