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
    @State private var fallbackOpen = false
    @State private var copied = false
    @State private var fileURL: URL?
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

                    stepCard(1, title: "获取快捷指令",
                             text: "点下面的按钮，把「截图记账」装进快捷指令。第一次装如果提示「无法验证签名」，先到 设置 → 快捷指令 打开「允许不受信任的快捷指令」。") {
                        VStack(spacing: 9) {
                            primaryButton("安装快捷指令", icon: "arrow.down.circle.fill") {
                                installShortcut()
                            }

                            // App 自己注册的系统动作：一键把「截图记账」加到快捷指令库里，
                            // 不用签名、不用信任开关，比传文件稳。
                            ShortcutsLink()
                                .shortcutsLinkStyle(.automatic)

                            Text("上面是系统的一键添加，下面是这个 App 的招牌动作")
                                .font(.system(size: 10.5))
                                .foregroundStyle(Theme.ink3)

                            Button {
                                withAnimation { fallbackOpen.toggle() }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(fallbackOpen ? "收起手工配置" : "装不上？手工配只要两步")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(Theme.brand)
                                    Image(systemName: fallbackOpen ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(Theme.brand)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 2)

                            if fallbackOpen { fallbackSteps }
                        }
                    }

                    stepCard(2, title: "设置触发方式",
                             text: "设置 → 辅助功能 → 触控 → 轻点背面 → 轻点两下，选「截图记账」。之后在任何界面双击手机背面，就会自动截屏并记上。") {
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

                    stepCard(3, title: "开始使用",
                             text: "在任何 App 里双击手机背面，系统会截图并发给本 App 识别。认出来的账会先出一张待确认卡片，看一眼金额点「确认记账」就行 —— 认错了也来得及改。") {
                        VStack(spacing: 8) {
                            Button {
                                Task { await tryNow() }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "camera.viewfinder")
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
                            }
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
            .sheet(item: Binding(get: { fileURL.map(ShareFile.init) },
                                 set: { if $0 == nil { fileURL = nil } })) { f in
                ShareSheet(items: [f.url])
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
                Text("截个屏，账就记上了。\n不用打开 App，不用输金额。")
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

    // MARK: 手工配置兜底

    private var fallbackSteps: some View {
        VStack(alignment: .leading, spacing: 7) {
            stepLine("1", "新建快捷指令，添加动作「截取屏幕」")
            stepLine("2", "再添加动作「打开 URL」，地址填下面这串")
            copyRow("snapledger://scan")
            Text("它会让 App 打开并自动读相册里最新那张截图，不用手动选图、也不用连线。")
                .font(.system(size: 11))
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

    private func installShortcut() {
        // bundle 里用 ASCII 文件名（SnapScan.shortcut）避开构建链上的编码坑，
        // 拷出来再改成中文名，用户看到的还是「截图记账」。
        guard let url = Bundle.main.url(forResource: "SnapScan", withExtension: "shortcut") else {
            flash("这个包里没带快捷指令文件，用上面的「添加到快捷指令」")
            return
        }
        // 先拷到临时目录并换个名字：直接分享 bundle 里的只读文件，
        // 有些接收方（文件 App）会因为源路径不可写而失败。
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("截图记账.shortcut")
        try? FileManager.default.removeItem(at: tmp)
        do {
            try FileManager.default.copyItem(at: url, to: tmp)
            fileURL = tmp
        } catch {
            flash("导出失败：\(error.localizedDescription)")
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

/// `.sheet(item:)` 需要一个 Identifiable，URL 本身不满足，包一层
private struct ShareFile: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
