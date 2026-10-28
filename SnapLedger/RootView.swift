//
//  RootView.swift
//  四个 tab：记账 / 账本 / 统计 / 我的
//
//  网页版也是这四页。原生版多给了一样东西：账本页点一条就能改，
//  因为「记完了发现有错」是记账工具最高频的后续动作。
//

import SwiftUI

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
    }
}
