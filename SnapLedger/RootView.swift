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

struct RootView: View {
    @State private var tab = 0

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
}
