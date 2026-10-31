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

private enum MeRoute: Identifiable {
    case about
    case selfMember
    case share
    case service
    case importData
    case scanGuide

    var id: String {
        switch self {
        case .about: return "about"
        case .selfMember: return "self"
        case .share: return "share"
        case .service: return "service"
        case .importData: return "import"
        case .scanGuide: return "scan"
        }
    }
}

struct MeView: View {
    @ObservedObject private var store = LedgerStore.shared
    @ObservedObject private var sync = SyncEngine.shared
    @ObservedObject private var scanner = ScanCoordinator.shared
    /// 点「立即读取最新一张截图」要有反馈，否则用户点了觉得没反应
    @ObservedObject private var watcher = ScreenshotWatcher.shared

    @State private var joinCode = ""
    @State private var busy = false
    @State private var err: String?
    @State private var photoStatus = "读取中…"
    @State private var photoLatest = ""
    @State private var route: MeRoute?
    @State private var shareURL: URL?
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
                scanCard
                identityCard
                dataCard
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
        // 5 个 sheet 合并成一条路由。同一个 view 上挂多个 .sheet 时，
        // SwiftUI 会争抢 presentation，症状就是「点了没反应」—— 账本页已经栽过一次。
        .sheet(item: $route) { r in
            switch r {
            case .about:
                AboutSheet()
            case .selfMember:
                MemberSheet(member: store.selfMember)
            case .share:
                if let u = shareURL { ShareSheet(items: [u]) }
            case .service:
                ServiceSheet {
                    // 改完地址/分享码，已连家庭的话立刻重连一次，不用等 45 秒轮询
                    if store.db.sync?.isOn == true { sync.now() }
                }
            case .importData:
                ImportSheet()
            case .scanGuide:
                ScanGuideView()
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
                    HStack(spacing: 5) {
                        Text(me?.name ?? "我")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                        Image(systemName: "pencil")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    Text(store.db.members.count > 1
                         ? "家庭账本 · \(store.db.members.count) 位成员"
                         : "点这里改名字和头像")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.8))
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture { route = .selfMember }

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
                route = .service
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

    // MARK: 截图 / AI 自动记账

    private var scanCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                cardTitle("AI 自动记账", icon: "wand.and.stars")
                Spacer()
                TagView(text: "推荐", color: Theme.brand)
            }

            Text("双击手机背面截个屏，账就记上了 —— 不用先打开 App，也不用输金额。")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                route = .scanGuide
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text("去设置（3 步配好）")
                        .font(.system(size: 13.5, weight: .semibold))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 13)
                .padding(.vertical, 11)
                .background(Theme.hero, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Rectangle().fill(Theme.line).frame(height: 0.7)

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

            // 诊断行：双击背面说「没有截图」时，这一行能直接看出是权限、还是图没进相册
            if !photoLatest.isEmpty {
                HStack {
                    Text("相册里最新一张")
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    Text(photoLatest)
                        .font(.system(size: 12.5))
                        .foregroundStyle(photoLatest.contains("不是截图") ? Theme.expense : Theme.ink2)
                }
            }

            Button {
                // 走 ScanCoordinator：它不依赖聊天页有没有挂载，识别的结果直接入账，
                // 进度和原因也一并回传（这里和记账页同时能看到）。
                ScanCoordinator.shared.scanLatestManually()
                Task {
                    photoStatus = await statusText()
                    photoLatest = await latestText()
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

            // 识别过程/失败原因要看得见，不然点了像没反应
            if !scanner.banner.isEmpty {
                Text(scanner.banner)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if !watcher.status.isEmpty {
                Text(watcher.status)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text("双击背面会跳到本 App，自动读刚截的那张图并记上，图不出手机。")
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
                    HStack(spacing: 5) {
                        Text(m.emoji).font(.system(size: 14))
                        Text(m.name)
                            .font(.system(size: 13, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? Theme.brand : Theme.ink2)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(on ? Theme.brandSoft : Theme.card2,
                                in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(on ? Theme.brand.opacity(0.5) : Theme.line, lineWidth: on ? 1.2 : 0.7))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // 点自己 = 改资料，点对方 = 认领「这是我」
                        if on { route = .selfMember } else { sync.setSelfMember(m.id) }
                    }
                }
                Spacer(minLength: 0)
            }

            Rectangle().fill(Theme.line).frame(height: 0.7)

            Button {
                route = .selfMember
            } label: {
                HStack {
                    Text("我的昵称与头像")
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    Text("\(store.selfMember?.emoji ?? "🙂") \(store.selfMember?.name ?? "我")")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.ink3)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.ink3)
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if store.db.members.count < 2 {
                Text("另一台手机加入后会在这里出现对方；两台手机各自改自己的名字，改完会同步过去。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("点自己那枚可以改名字；点对方那枚表示「那是我」，之后记的账就挂在那个名字下。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .cardStyle()
    }

    // MARK: 关于

    private var aboutCard: some View {
        VStack(spacing: 0) {
            Button {
                route = .about
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

    // MARK: 数据

    /// 免费签名 7 天到期就装不上新包，换手机也要重来 —— 一定要能导出。
    /// CSV 带 BOM，Excel / 数字都能直接正确识别中文。
    private var dataCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            cardTitle("数据", icon: "externaldrive")

            HStack {
                Text("本机账目")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text("\(store.db.records.count) 笔 · \(store.books.count) 个账本")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.ink3)
            }

            Rectangle().fill(Theme.line).frame(height: 0.7)

            Button {
                if let u = makeCSV() {
                    shareURL = u
                    route = .share
                }
            } label: {
                HStack {
                    Text("导出 CSV")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.brand)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Rectangle().fill(Theme.line).frame(height: 0.7)

            Button {
                route = .importData
            } label: {
                HStack {
                    Text("导入账单")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    Text("CSV / 粘贴表格")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.ink3)
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.brand)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text("导出的文件可以发给自己、存网盘，用 Excel 或「数字」打开。重装 App 之前建议先导一份。换手机或想把手写表格搬进来，走「导入账单」。")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .cardStyle()
    }

    private func makeCSV() -> URL? {
        var bookNames: [String: String] = [:]
        for b in store.db.books { bookNames[b.id] = b.name }

        var lines = ["日期,时间,类型,分类,金额,支付方式,成员,账本,备注"]
        for r in store.db.records.sorted(by: { $0.ts < $1.ts }) {
            let d = Date(timeIntervalSince1970: r.ts / 1000)
            let row = [
                Fmt.key(d),
                Fmt.hm(r.ts),
                r.isIncome ? "收入" : "支出",
                r.category,
                Money.plain(r.amount),
                r.method,
                store.memberName(r.member),
                bookNames[r.book] ?? bookNames[LedgerBook.defaultId] ?? "",
                r.note
            ].map { csvField($0) }.joined(separator: ",")
            lines.append(row)
        }

        let csv = "\u{FEFF}" + lines.joined(separator: "\r\n")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("家庭记账-\(Fmt.key(Date())).csv")
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            err = "导出失败：\(error.localizedDescription)"
            return nil
        }
    }

    private func csvField(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
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
        photoLatest = await latestText()
    }

    /// 相册里最新的一张图是什么时候的、是不是截图。
    /// 双击背面报「没有截图」时，看这一行就能分清是权限问题还是图没进相册。
    private func latestText() async -> String {
        guard let a = ScreenshotWatcher.newestImage(), let d = a.creationDate else {
            return "读不到图片"
        }
        let shot = a.mediaSubtypes.contains(.photoScreenshot)
        return ScreenshotWatcher.relative(d) + (shot ? "（截图）" : "（不是截图）")
    }
}

// MARK: - 我的昵称

struct MemberSheet: View {
    var member: FamilyMember?

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = LedgerStore.shared

    @State private var name = ""
    @State private var emoji = "🙂"
    @State private var loaded = false

    private let emojis = ["🙂", "😀", "😎", "🐱", "🐶", "🐰", "🐻", "🦊", "🐳", "🍀", "🌻", "🍑"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(spacing: 10) {
                        Text(emoji).font(.system(size: 44))
                        TextField("你的昵称", text: $name)
                            .font(.system(size: 18, weight: .semibold))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 11)
                            .background(Theme.card2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Theme.line, lineWidth: 0.7))
                        Text("最多 12 个字。两台手机各自改自己的，改完会同步给对方。")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.ink3)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)

                    Text("头像")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.ink2)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 8)], spacing: 8) {
                        ForEach(emojis, id: \.self) { e in
                            Text(e)
                                .font(.system(size: 22))
                                .frame(maxWidth: .infinity)
                                .frame(height: 46)
                                .background(e == emoji ? Theme.brandSoft : Theme.card2,
                                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(e == emoji ? Theme.brand.opacity(0.5) : Theme.line,
                                                  lineWidth: e == emoji ? 1.2 : 0.7))
                                .contentShape(Rectangle())
                                .onTapGesture { emoji = e }
                        }
                    }
                }
                .padding(16)
            }
            .background(Theme.bg)
            .navigationTitle("我的资料")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .fontWeight(.semibold)
                        .disabled(member == nil || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                name = member?.name ?? "我"
                emoji = member?.emoji ?? "🙂"
            }
        }
    }

    private func save() {
        guard let m = member else { return }
        store.updateMember(id: m.id, name: name, emoji: emoji)
        dismiss()
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
                        Text("回到「我的」，点「AI 自动记账 → 去设置」，那里有四步图文，装快捷指令、绑轻点背面、选账本都在一页里，配完就能用。")
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

// MARK: - 系统分享

/// 导出 CSV 之后走系统的分享面板：AirDrop / 微信 / 存文件 / 邮件都行，
/// 比自己拼一个导出页省事，也不用申请额外权限。
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
