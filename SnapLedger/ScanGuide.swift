//
//  ScanGuide.swift
//  AI 自动记账的引导页 + 两个设置项
//
//  结构是照着百事 AA 记账的「首次使用设置」抄的：四张编号卡片，
//  1 获取快捷指令 / 2 设置触发方式 / 3 开始使用 / 4 记账设置。
//  抄的是信息顺序，视觉换成本 App 的青绿 + 白卡，不抄它的紫色。
//
//  和上一版的区别（这才是关键）：
//  - 上一版只教用户「打开 URL」，动作要自己拼，参数错误没有任何提示；
//  - 这一版把 App 自己的能力注册成系统动作（App Intents），
//    快捷指令里能直接搜到「截图记账」，截图作为参数直传，不经过 URL。
//  - 第 4 步的「选择账本 / 图片自动存档」也是百事有而我们没有的。
//

import SwiftUI
import UIKit
import AppIntents

// MARK: - 记账设置

/// 「AI 自动记账」相关的两个开关，都放 UserDefaults。
///
/// 为什么不放进 LedgerDB：这些是「这台手机怎么工作」的偏好，
/// 不是账目数据，不该跟着 LWW 同步到另一台手机上去。
enum ScanSettings {
    private static let bookKey = "snap.scan.book"
    private static let archiveKey = "snap.scan.archive"

    /// 快捷指令记的账默认落到哪个账本。空 = 跟随「当前账本」。
    static var defaultBookId: String {
        get { UserDefaults.standard.string(forKey: bookKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: bookKey) }
    }

    /// 识别过的截图是否留在 App 里。
    ///
    /// 默认开：百事也是默认开。存档只写本 App 的沙盒目录，
    /// 不进系统相册 —— 相册里突然多出一堆截图会让人很恼火。
    static var archiveImages: Bool {
        get {
            // bool(forKey:) 对没写过的 key 返回 false，
            // 想让默认值是 true 必须先判「有没有写过」。
            if UserDefaults.standard.object(forKey: archiveKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: archiveKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: archiveKey) }
    }

    /// 真正生效的账本 id：设过且账本还在就用它，否则退回当前账本。
    ///
    /// 账本可能被另一台手机删掉（同步过来就没了），所以每次都要复核一遍，
    /// 不能直接信任存下来的 id。
    @MainActor
    static func resolvedBook() -> String {
        let db = LedgerStore.shared.db
        let want = defaultBookId
        if !want.isEmpty, db.books.contains(where: { $0.id == want }) { return want }
        if !db.currentBook.isEmpty, db.books.contains(where: { $0.id == db.currentBook }) {
            return db.currentBook
        }
        return db.books.first?.id ?? LedgerBook.defaultId
    }
}

// MARK: - 截图存档

/// 把识别过的截图压一份留在沙盒里，方便回头核对「当时那笔是怎么认出来的」。
enum ScanArchive {
    private static let folder = "scan-archive"

    static var dir: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent(folder, isDirectory: true)
        if !FileManager.default.fileExists(atPath: d.path) {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        return d
    }

    /// 长边压到 1200、JPEG 0.72：一张手机截图约 100–180KB，
    /// 一天十张也就 1.5MB，留一年不会撑爆。
    @discardableResult
    static func save(_ image: UIImage) -> Bool {
        let w = image.size.width
        let h = image.size.height
        guard w > 0, h > 0 else { return false }

        let maxSide: CGFloat = 1200
        let scale = min(1, maxSide / max(w, h))
        let size = CGSize(width: (w * scale).rounded(), height: (h * scale).rounded())

        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        let small = UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let data = small.jpegData(compressionQuality: 0.72) else { return false }

        let name = "scan-\(Int(Date().timeIntervalSince1970 * 1000)).jpg"
        do {
            try data.write(to: dir.appendingPathComponent(name), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func stats() -> (count: Int, bytes: Int) {
        let keys: [URLResourceKey] = [.fileSizeKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir,
                                                                     includingPropertiesForKeys: keys) else {
            return (0, 0)
        }
        var total = 0
        for u in items {
            total += (try? u.resourceValues(forKeys: Set(keys)).fileSize) ?? 0
        }
        return (items.count, total)
    }

    /// 只清自己这个目录里的文件，绝不碰别的地方
    static func clear() {
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir,
                                                                     includingPropertiesForKeys: nil) else { return }
        for u in items {
            try? FileManager.default.removeItem(at: u)
        }
    }

    static func humanSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.0f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
    }
}

// MARK: - 引导页

@MainActor
struct ScanGuideView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = LedgerStore.shared
    @ObservedObject private var watcher = ScreenshotWatcher.shared

    @State private var bookId = ""
    @State private var archiveOn = ScanSettings.archiveImages
    @State private var archiveCount = 0
    @State private var archiveBytes = 0
    @State private var phoneSteps = false
    @State private var advancedOpen = false
    @State private var copied = false
    @State private var toast: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 13) {
                    banner

                    Text("首次使用设置")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Theme.brand)
                        .padding(.top, 4)

                    stepCard(1, title: "添加「截图记账」到快捷指令",
                             text: "点下面的按钮，把本 App 的动作加进快捷指令。加完不用编辑 —— 它没有参数，双击背面直接把 App 拉起来，自己去相册找刚截的那张图。") {
                        VStack(spacing: 10) {
                            ShortcutsLink()
                                .shortcutsLinkStyle(.automatic)

                            Text("按钮点不动或者列表是空的？把 App 从后台划掉、重开一次再进来 —— 系统要重新索引一次动作。")
                                .font(.system(size: 10.5))
                                .foregroundStyle(Theme.ink3)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)

                            Rectangle().fill(Theme.line).frame(height: 0.7)

                            Button {
                                openShortcutsApp()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.up.forward.app")
                                        .font(.system(size: 12.5))
                                    Text("打开快捷指令 App，搜「家庭记账」")
                                        .font(.system(size: 12.5, weight: .medium))
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(Theme.ink3)
                                }
                                .foregroundStyle(Theme.brand)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Button {
                                withAnimation { advancedOpen.toggle() }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(advancedOpen ? "收起进阶用法" : "进阶：从快捷指令里指定任意一张图")
                                        .font(.system(size: 11.5, weight: .medium))
                                        .foregroundStyle(Theme.ink3)
                                    Image(systemName: advancedOpen ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(Theme.ink3)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if advancedOpen { advancedSteps }
                        }
                    }

                    stepCard(2, title: "设置触发方式",
                             text: "设置 → 辅助功能 → 触控 → 轻点背面 → 轻点两下，选「截图记账」。之后在任何界面双击手机背面，本 App 会自己弹到前台，把刚截的那张图认出来、记上。") {
                        VStack(spacing: 8) {
                            Button {
                                withAnimation { phoneSteps.toggle() }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "play.circle")
                                        .font(.system(size: 13))
                                    Text(phoneSteps ? "收起步骤" : "查看详细步骤")
                                        .font(.system(size: 13, weight: .medium))
                                }
                                .foregroundStyle(Theme.ink)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Theme.card2, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .strokeBorder(Theme.line, lineWidth: 0.7))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if phoneSteps { phoneStepsList }

                            Button {
                                openSystemSettings()
                            } label: {
                                Text("打开系统设置")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(Theme.brand)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    stepCard(3, title: "先在这里授权相册",
                             text: "这一步别跳过。读截图要先允许访问照片，在这里点一次授权好，双击背面时就直接进入识别，不会先被系统弹窗拦住。") {
                        VStack(spacing: 8) {
                            Button {
                                Task { await tryNow() }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "checkmark.shield")
                                        .font(.system(size: 12.5))
                                    Text("现在试一次（读最新一张截图）")
                                        .font(.system(size: 13, weight: .medium))
                                }
                                .foregroundStyle(Theme.brand)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Theme.brandSoft, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if !watcher.status.isEmpty {
                                Text(watcher.status)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Theme.ink2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Text("点完它会把最后一张截图认出来，并在聊天页出一张待确认卡片（手动点的不替你拍板）。认得出来，说明双击背面同样能成。")
                                .font(.system(size: 10.5))
                                .foregroundStyle(Theme.ink3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    stepCard(4, title: "记账设置",
                             text: "指定截屏记到哪个账本，以及要不要把图留着备查。") {
                        VStack(spacing: 0) {
                            bookRow
                            Rectangle().fill(Theme.line).frame(height: 0.7).padding(.vertical, 10)
                            archiveRow
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 28)
            }
            .background(Theme.bg)
            .navigationTitle("AI 自动记账")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear {
                bookId = ScanSettings.defaultBookId
                refreshArchive()
            }
            .overlay(alignment: .bottom) {
                if let t = toast {
                    Text(t)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(Theme.ink.opacity(0.9), in: Capsule())
                        .padding(.bottom, 18)
                        .transition(.opacity)
                }
            }
        }
    }

    // MARK: 顶部插画

    private var banner: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(.white.opacity(0.20))
                    .frame(width: 66, height: 66)
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 27, weight: .medium))
                    .foregroundStyle(.white)
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                    .offset(x: 24, y: -23)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("什么是 AI 自动记账？")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                Text("截个屏，双击手机背面，\nApp 自己弹出来把这一笔记上。")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                Theme.hero
                Circle()
                    .fill(.white.opacity(0.10))
                    .frame(width: 150, height: 150)
                    .offset(x: 118, y: -70)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: 编号卡片

    private func stepCard<C: View>(_ n: Int,
                                   title: String,
                                   text: String,
                                   @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 10) {
                Text("\(n)")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Theme.brand, in: Circle())

                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text(text)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.ink2)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(padding: 15, radius: 18)
    }

    private func primaryButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Theme.hero, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 进阶用法

    private var advancedSteps: some View {
        VStack(alignment: .leading, spacing: 8) {
            stepLine("1", "快捷指令里加「截屏」（或「选择照片」，挑相册里任意一张）")
            stepLine("2", "再加本 App 的「认这张图」，把上一步的结果连到「截图」参数")
            Text("适合想记某张旧账单、或者把别的 App 转发来的图也记上账的情况。日常双击背面用不着这一步。")
                .font(.system(size: 11))
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)

            Rectangle().fill(Theme.line).frame(height: 0.7)

            Text("老办法（仍然可用）：截屏 → 打开 URL → 下面这串")
                .font(.system(size: 11))
                .foregroundStyle(Theme.ink3)
            copyRow("snapledger://scan")
            Text("它会打开 App 并自动读最新截图。好处是两个动作配完就能跨手机照抄，坏处是会切到 App 前台。")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .background(Theme.card2, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func stepLine(_ n: String, _ s: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(n)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.brand)
                .frame(width: 14, height: 14)
                .background(Theme.brandSoft, in: Circle())
            Text(s)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func copyRow(_ s: String) -> some View {
        Button {
            UIPasteboard.general.string = s
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
        } label: {
            HStack(spacing: 6) {
                Text(s)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.brand)
                Spacer(minLength: 4)
                Text(copied ? "已复制" : "复制")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(copied ? Theme.income : Theme.ink3)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var phoneStepsList: some View {
        VStack(alignment: .leading, spacing: 7) {
            stepLine("1", "打开「设置」，往下找到「辅助功能」")
            stepLine("2", "「触控」→ 滑到最下面「轻点背面」")
            stepLine("3", "「轻点两下」→ 在快捷指令列表里选刚才建的那个")
            Text("选完之后，随时双击手机背面就能记账 —— 刷到快递签收、付款成功的界面当场截，比事后补记省事得多。")
                .font(.system(size: 11))
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(Theme.card2, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    // MARK: 记账设置

    private var bookRow: some View {
        HStack {
            Image(systemName: "book.closed")
                .font(.system(size: 13))
                .foregroundStyle(Theme.ink3)
                .frame(width: 18)
            Text("选择账本")
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.ink)
            Spacer()
            Menu {
                Button {
                    ScanSettings.defaultBookId = ""
                    bookId = ""
                } label: {
                    HStack {
                        Text("跟随当前账本")
                        if bookId.isEmpty { Image(systemName: "checkmark") }
                    }
                }
                ForEach(store.books) { b in
                    Button {
                        ScanSettings.defaultBookId = b.id
                        bookId = b.id
                    } label: {
                        HStack {
                            Text("\(b.emoji) \(b.name)")
                            if bookId == b.id { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(bookLabel)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.ink3)
                }
            }
        }
    }

    private var bookLabel: String {
        if bookId.isEmpty {
            return "跟随当前账本（\(store.currentBook?.name ?? "家庭账本")）"
        }
        if let b = store.books.first(where: { $0.id == bookId }) { return "\(b.emoji) \(b.name)" }
        return "跟随当前账本"
    }

    private var archiveRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $archiveOn) {
                HStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.ink3)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AI 记账图片自动存档")
                            .font(.system(size: 13.5))
                            .foregroundStyle(Theme.ink)
                        Text("存在本 App 里，不进系统相册")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.ink3)
                    }
                }
            }
            .tint(Theme.brand)
            .onChange(of: archiveOn) { _, on in
                ScanSettings.archiveImages = on
                refreshArchive()
            }

            if archiveCount > 0 {
                HStack(spacing: 6) {
                    Text("已存档 \(archiveCount) 张 · \(ScanArchive.humanSize(archiveBytes))")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ink3)
                    Spacer()
                    Button {
                        ScanArchive.clear()
                        refreshArchive()
                        flash("已清空存档")
                    } label: {
                        Text("清空")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Theme.expense)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: 动作

    /// 直接跳快捷指令 App。
    ///
    /// 这里原本是「导出 .shortcut 文件 → 分享面板」。那条路是死的：
    /// iOS 15 起快捷指令导入必须签名，未签名的 .shortcut 通过文件或分享打开
    /// 一律提示「无法验证」，而当年那个「允许不受信任的快捷指令」开关也已经被系统移除。
    /// 换句话说，用户点那个按钮注定失败，还找不到原因。
    /// 现在只留系统原生那条路：App Shortcuts（ShortcutsLink / 在快捷指令里搜 App 名）。
    private func openShortcutsApp() {
        guard let url = URL(string: "shortcuts://") else { return }
        UIApplication.shared.open(url) { ok in
            if !ok { flash("没有找到「快捷指令」App，它可能被删掉了") }
        }
    }

    private func openSystemSettings() {
        // 深链到「辅助功能」是私有 scheme，侧载能用、上架会被拒；
        // 打不开就退回到本 App 的设置页，不让用户卡在一句「打不开」上。
        if let deep = URL(string: "App-Prefs:root=ACCESSIBILITY&path=TOUCH_REACHABILITY_TITLE"),
           UIApplication.shared.canOpenURL(deep) {
            UIApplication.shared.open(deep)
            return
        }
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    private func tryNow() async {
        await watcher.pickUpNow()
        if watcher.status.isEmpty { flash("认出来了，回记账页看卡片") }
    }

    private func refreshArchive() {
        let s = ScanArchive.stats()
        archiveCount = s.count
        archiveBytes = s.bytes
    }

    private func flash(_ s: String) {
        withAnimation { toast = s }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation { toast = nil }
        }
    }
}
