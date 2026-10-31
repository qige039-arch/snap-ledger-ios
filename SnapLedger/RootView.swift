//
//  RootView.swift
//  四个 tab：记账 / 账本 / 统计 / 我的
//
//  网页版也是这四页。原生版多给了一样东西：账本页点一条就能改，
//  因为「记完了发现有错」是记账工具最高频的后续动作。
//

import SwiftUI

/// 「双击背面 → 打开 App → 记这一笔」的交接票据
///
/// 正常情况下用不上：`openAppWhenRun = true` 的 Intent 就在 App 进程里，
/// 它直接调 `ScanCoordinator.shared`。票据是给「Intent 跑在独立进程」那种情况兜底的 ——
/// 那时它摸不到 App 内存里的单例，而 UserDefaults 是同一个沙盒，两边都能读写。
///
/// 打的是时间戳而不是 Bool：连着双击两次，第二张截图也要能记。
enum ScanPending {
    private static let key = "snap.scan.pending"

    /// 有效时长。超过这个时间的票据当作过期 —— 用户可能双击完就把手机揣兜里了，
    /// 十分钟后再打开 App 不该突然蹦出一笔账。
    private static let window: TimeInterval = 180

    static func mark() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: key)
        // 同进程（perform 跑在主 App 进程里）直接喊一嗓子；
        // 独立进程传不过来的情况，由 App 侧的票据轮询兜住（armPolling）。
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
    @ObservedObject private var scanner = ScanCoordinator.shared
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
        // 双击背面后把记账页翻出来 —— 这一步不能交给聊天页自己做，
        // 它可能还没挂载（用户当时停在「我的」页）。
        .onChange(of: scanner.focusChat) { _, _ in tab = 0 }
        // 进度和结果浮在最上面，不管当前在哪个 tab 都看得见。
        // 之前只在聊天页里显示，而用户双击完可能还停在别的页 —— 于是像「没反应」。
        .overlay(alignment: .top) {
            if !scanner.banner.isEmpty {
                HStack(spacing: 7) {
                    Image(systemName: scanner.banner.hasPrefix("已记账") ? "checkmark.circle.fill" : "sparkle")
                        .font(.system(size: 12, weight: .semibold))
                    Text(scanner.banner)
                        .font(.system(size: 12.5, weight: .medium))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Theme.ink.opacity(0.92), in: Capsule())
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.2), value: scanner.banner)
        .onAppear {
            consumeScanPending()
            scanner.armPolling()
        }
        // App 已经在后台时被双击背面拉起，RootView 不会重建，onAppear 不会再来一次，
        // 所以还得盯着 scenePhase。
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                consumeScanPending()
                scanner.armPolling()
            }
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
                ScanCoordinator.shared.scanFromShortcut()
            }
        }
    }

    /// 双击背面留下的票据：切到记账页，并让它马上去读那张截图。
    ///
    /// 这一层是兜底。真正干活的是 `ScanCoordinator` —— Intent 在 App 进程内直接调它，
    /// 不会再出现「票留下来了，但取票的钩子已经跑过去了」那种时差错位。
    private func consumeScanPending() {
        guard ScanPending.takeIfFresh() else { return }
        tab = 0
        ScanCoordinator.shared.scanFromShortcut()
    }
}
