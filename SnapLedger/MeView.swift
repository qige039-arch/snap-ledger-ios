//
//  MeView.swift
//  我的：身份、家庭账本、截图权限、关于
//
//  用卡片而不是 Form：Form 的分组灰底和这里的卡片风格打架，
//  且家庭账本那一块需要更醒目的展示（邀请码要能一眼看清、一键复制）。
//

import SwiftUI
import UIKit
import Photos

struct MeView: View {
    @ObservedObject private var store = LedgerStore.shared
    @ObservedObject private var sync = SyncEngine.shared

    @State private var joinCode = ""
    @State private var busy = false
    @State private var err: String?
    @State private var photoStatus = "读取中…"
    @State private var showAbout = false
    @State private var showService = false
    @State private var showCodeCopied = false

    private var code: String { store.db.sync?.code ?? "" }

    private var monthTotals: (income: Double, expense: Double) {
        let cal = Fmt.cal
        let start = cal.date(from: cal.dateComponents([.year, .month], from: Date())) ?? Date()
        return store.totals(from: start, to: Date().addingTimeInterval(86400))
    }

    private var monthCount: Int {
        let cal = Fmt.cal
        let start = cal.date(from: cal.dateComponents([.year, .month], from: Date())) ?? Date()
        return store.count(from: start, to: Date().addingTimeInterval(86400))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                profileCard
                familyCard
                captureCard
                identityCard
                serviceCard
                aboutCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 28)
        }
        .background(Theme.bg)
        .task { await refreshPhotoStatus() }
        .alert("出错了", isPresented: Binding(get: { err != nil }, set: { if !$0 { err = nil } })) {
            Button("好") { err = nil }
        } message: {
            Text(err ?? "")
        }
        .sheet(isPresented: $showAbout) { AboutSheet() }
        .sheet(isPresented: $showService) {
            ServiceSheet {
                // 改完地址/分享码，已连家庭的话立刻重连一次，不用等 45 秒轮询
                if store.db.sync?.isOn == true { sync.now() }
            }
        }
    }

    // MARK: 头像卡

    private var profileCard: some View {
        let me = store.selfMember
        return VStack(spacing: 14) {
            HStack(spacing: 13) {
                Text(me?.emoji ?? "🙂")
                    .font(.system(size: 27))
                    .frame(width: 54, height: 54)
                    .background(.white.opacity(0.22),
                                in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(me?.name ?? "我")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                    Text(store.db.members.count > 1
                         ? "家庭账本 · \(store.db.members.count) 位成员"
                         : "家庭账本")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.8))
                }
                Spacer()
            }

            Rectangle().fill(.white.opacity(0.18)).frame(height: 0.8)

            HStack(spacing: 0) {
                heroCell("本月支出", Money.currency(monthTotals.expense))
                heroCell("本月收入", Money.currency(monthTotals.income))
                heroCell("记账笔数", "\(monthCount)")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                Theme.hero
                Circle().fill(.white.opacity(0.10))
                    .frame(width: 150, height: 150)
                    .offset(x: 110, y: -80)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func heroCell(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(k)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.72))
            Text(v)
                .font(.system(size: 14.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 家庭账本

    private var familyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            cardTitle("家庭账本", icon: "person.2.fill")

            if code.isEmpty {
                Text("两台手机要用同一个账本，先在一台上创建，拿到 6 位邀请码，另一台输入加入。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    run { try await sync.createFamily() }
                } label: {
                    HStack {
                        if busy { ProgressView().controlSize(.small) }
                        Text("创建新的家庭账本").font(.system(size: 14, weight: .semibold))
                        Spacer()
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .background(Theme.brand, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(busy)

                HStack(spacing: 8) {
                    TextField("输入 6 位邀请码", text: $joinCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.system(size: 15, design: .monospaced))
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(Theme.card2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Theme.line, lineWidth: 0.7))

                    Button {
                        run { try await sync.joinFamily(joinCode) }
                    } label: {
                        Text("加入")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16).padding(.vertical, 11)
                            .background(joinCode.trimmingCharacters(in: .whitespaces).count >= 4 ? Theme.brand : Theme.ink3,
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(busy || joinCode.trimmingCharacters(in: .whitespaces).count < 4)
                }
            } else {
                // 邀请码是第一优先级信息，单独一块大号等宽字
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("邀请码")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.ink3)
                        Text(code)
                            .font(.system(size: 21, weight: .bold, design: .monospaced))
                            .foregroundStyle(Theme.ink)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button {
                        UIPasteboard.general.string = code
                        withAnimation { showCodeCopied = true }
                        Task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            withAnimation { showCodeCopied = false }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: showCodeCopied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 11, weight: .semibold))
                            Text(showCodeCopied ? "已复制" : "复制")
                                .font(.system(size: 12.5, weight: .medium))
                        }
                        .foregroundStyle(Theme.brand)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Theme.brandSoft, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(12)
                .background(Theme.card2, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                HStack(spacing: 7) {
                    Circle()
                        .fill(stateColor)
                        .frame(width: 7, height: 7)
                    Text(sync.state.label)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.ink2)
                    Text("·")
                        .foregroundStyle(Theme.ink3)
                    Text("本机 \(store.db.records.count) 条")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.ink3)
                    Spacer()
                    Button {
                        sync.now()
                    } label: {
                        Text("立即同步")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Theme.brand)
                    }
                    .buttonStyle(.plain)
                }

                if !sync.message.isEmpty {
                    Text(sync.message)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.expense)
                }

                Button(role: .destructive) {
                    sync.leaveFamily()
                } label: {
                    Text("离开这个账本")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.expense)
                }
                .buttonStyle(.plain)
            }
        }
        .cardStyle()
    }

    private var stateColor: Color {
        switch sync.state {
        case .error: return Theme.expense
        case .off: return Theme.ink3
        case .syncing: return Color.orange
        case .idle: return Theme.income
        }
    }

    // MARK: 服务设置

    private var serviceCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            cardTitle("服务设置", icon: "antenna.radiowaves.left.and.right")

            Button {
                showService = true
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("同步服务器")
                            .font(.system(size: 13.5))
                            .foregroundStyle(Theme.ink)
                        Text(APIConfig.baseString.replacingOccurrences(of: "https://", with: "")
                             + " · " + APIConfig.gate)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.ink3)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.ink3)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if sync.state == .error {
                Text("同步失败时先点这里：创建家庭报 403、同步一直连不上，几乎都是地址或入口分享码不对。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.expense)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .cardStyle()
    }

    // MARK: 截图

    private var captureCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            cardTitle("截图识别", icon: "camera.viewfinder")

            HStack {
                Text("相册权限")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text(photoStatus)
                    .font(.system(size: 12.5))
                    .foregroundStyle(photoStatus.contains("仅选中") || photoStatus == "已拒绝" ? Theme.expense : Theme.ink2)
            }

            if photoStatus.contains("仅选中") || photoStatus == "已拒绝" {
                Text("新截图读不到，需要到「设置 → 家庭记账 → 照片」改成允许访问所有照片。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Text("去设置")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.brand)
                }
                .buttonStyle(.plain)
            }

            Rectangle().fill(Theme.line).frame(height: 0.7)

            Button {
                Task {
                    await ScreenshotWatcher.shared.pickUpNow()
                    photoStatus = await statusText()
                }
            } label: {
                HStack {
                    Text("立即读取最新一张截图")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.ink3)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text("双击背面打开本 App 时，会自动读最近 2 分钟内的截图并识别，图不出手机。")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .cardStyle()
    }

    // MARK: 身份

    private var identityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            cardTitle("身份", icon: "person.crop.circle")

            HStack(spacing: 8) {
                ForEach(store.db.members) { m in
                    let on = m.id == store.selfMemberId
                    Button {
                        sync.setSelfMember(m.id)
                    } label: {
                        HStack(spacing: 5) {
                            Text(m.emoji).font(.system(size: 14))
                            Text(m.name)
                                .font(.system(size: 13, weight: on ? .semibold : .regular))
                                .foregroundStyle(on ? Theme.brand : Theme.ink2)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(on ? Theme.brandSoft : Theme.card2,
                                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(on ? Theme.brand.opacity(0.5) : Theme.line, lineWidth: on ? 1.2 : 0.7))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }

            if store.db.members.count < 2 {
                Text("另一台手机加入后会在这里出现对方。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.ink3)
            }
        }
        .cardStyle()
    }

    // MARK: 关于

    private var aboutCard: some View {
        VStack(spacing: 0) {
            Button {
                showAbout = true
            } label: {
                HStack {
                    Label("关于与数据说明", systemImage: "info.circle")
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.ink3)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .cardStyle()
    }

    private func cardTitle(_ t: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.brand)
            Text(t)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(Theme.ink)
        }
    }

    // MARK: 工具

    private func run(_ work: @escaping () async throws -> String) {
        busy = true
        Task {
            do {
                _ = try await work()
                busy = false
            } catch {
                busy = false
                err = error.localizedDescription
            }
        }
    }

    private func statusText() async -> String {
        switch await ScreenshotWatcher.ensurePhotoAccess() {
        case .authorized: return "允许访问所有照片"
        case .limited: return "仅选中的照片"
        case .denied, .restricted: return "已拒绝"
        case .notDetermined: return "未询问"
        @unknown default: return "未知"
        }
    }

    private func refreshPhotoStatus() async {
        photoStatus = await statusText()
    }
}

// MARK: - 服务设置

/// 发布域名和入口分享码都可能在下次重新发布时变掉，做成可改的，
/// 免得为一行配置重新走一遍「改代码 → 云端编译 → 侧载」。
struct ServiceSheet: View {
    var onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var base = APIConfig.baseString
    @State private var gate = APIConfig.gate
    @State private var tested: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    field(title: "服务地址",
                          hint: "发布链接的域名，不带路径",
                          text: $base,
                          keyboard: .URL,
                          mono: true)

                    field(title: "入口分享码",
                          hint: "发布链接上 ?sharecode= 后面那一串，10 位左右；不是 6 位家庭码",
                          text: $gate,
                          keyboard: .asciiCapable,
                          mono: true)

                    Text("创建家庭账本时 App 还没有家庭码，只能靠这个分享码过网关的校验。填错了会一直报 403。")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)

                    if let tested {
                        Text(tested)
                            .font(.system(size: 12.5))
                            .foregroundStyle(tested.hasPrefix("连接正常") ? Theme.income : Theme.expense)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 10) {
                        Button {
                            save()
                        } label: {
                            Text("保存")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Theme.brand,
                                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)

                        Button {
                            base = APIConfig.defaultBase
                            gate = APIConfig.defaultGate
                            tested = nil
                        } label: {
                            Text("恢复默认")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Theme.ink2)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .background(Theme.card2,
                                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        Task { await probe() }
                    } label: {
                        Text("先测一下")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.brand)
                    }
                    .buttonStyle(.plain)
                }
                .padding(18)
            }
            .background(Theme.bg)
            .navigationTitle("服务设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private func field(title: String, hint: String, text: Binding<String>,
                       keyboard: UIKeyboardType, mono: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink3)
            TextField("", text: text)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: mono ? 13 : 14, design: mono ? .monospaced : .default))
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(Theme.card2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.line, lineWidth: 0.7))
            Text(hint)
                .font(.system(size: 11))
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 用「加入一个不存在的家庭」探活：既能验证网关放行（不是 403），又不会往服务器写数据。
    /// 只读输入的临时值，不落盘——测完点取消，原配置不受影响。
    @MainActor
    private func probe() async {
        let b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let g = gate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let root = URL(string: b) else {
            tested = "地址格式不对"
            return
        }
        var comps = URLComponents(url: root.appendingPathComponent("/api/family/join"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "sharecode", value: g)]
        guard let url = comps.url else {
            tested = "地址格式不对"
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 12
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["code": "ZZZZZZ"])

        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 403 {
                tested = "网关拒绝（403）：入口分享码不对"
            } else if code >= 400 {
                tested = "服务器返回 \(code)"
            } else {
                tested = "连接正常，可以保存"
            }
        } catch {
            tested = "连不上：\(error.localizedDescription)"
        }
    }

    @MainActor
    private func save() {
        APIConfig.save(base: base, gate: gate)
        onSaved()
        dismiss()
    }
}

// MARK: - 关于

struct AboutSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("数据在哪")
                            .font(.system(size: 14, weight: .semibold))
                        Text("账目主要存在这台手机上（应用支持目录下的 ledger.json）。开启家庭账本后，服务器只做两台手机之间的交换，不做备份。所以换手机前请先在另一台上确认账目已同步过来。")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("图片不会上传")
                            .font(.system(size: 14, weight: .semibold))
                        Text("识别用 iOS 自带的 Vision 框架，全部在设备端完成。只有识别出来的文字和最终账目会参与同步。")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("识别把握不大的时候")
                            .font(.system(size: 14, weight: .semibold))
                        Text("待确认卡片上会出现「识别把握不大」的提示，确认前看一眼金额。账单里的「余额」「原价」不会被当成支出，但版式特殊的截图仍可能认错，直接在账本页点那笔改掉即可。")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("快捷指令怎么配")
                            .font(.system(size: 14, weight: .semibold))
                        Text("本 App 已把「记一笔」和「从图片记账」注册成快捷指令动作。去「快捷指令」新建一个：截取屏幕 → 从图片记账。然后绑定到 设置 → 辅助功能 → 触控 → 轻点背面 → 轻点两下。全程只需两个动作，不需要拼链接。")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack {
                        Text("版本")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.ink3)
                        Spacer()
                        Text(versionText)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Theme.ink2)
                    }
                    .padding(.top, 4)
                }
                .padding(18)
            }
            .background(Theme.bg)
            .navigationTitle("关于")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private var versionText: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}
