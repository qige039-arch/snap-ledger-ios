//
//  RecordIntent.swift
//  App Intents —— 这是原生 App 相对 PWA 最大的体验收益
//
//  iOS 的「轻点背面」只能绑快捷指令或系统功能，绑不了第三方 App。
//  但 App 把自己的能力注册成 App Intent 之后，它会自动出现在快捷指令的动作列表里，
//  于是快捷指令只需要：
//
//      截取屏幕 → 从图片记账（本 App 的 Intent）
//
//  关键区别：变量直接作为参数传进 Intent，不再经过「拼 URL → 打开 URL」这条路，
//  所以「无法将文本转换为 URL」这类错配从根本上不存在。
//
//  参数形状对齐百事 AA 记账那条快捷指令：
//      截屏 → 文本「v2」 → 将 截屏 和 文本 发送到 App
//  第二个文本参数在它那儿是协议版本号。我们保留同样的位置：
//  用户填 v2 这类标记时当版本号忽略，填别的就当这笔账的备注。
//  这样以后要传账本、传来源，不用让所有人重新装一遍快捷指令。
//

import AppIntents
import UIKit
import Foundation
import Photos

// MARK: - 后台记账结果的回执

/// 快捷指令在后台跑完时，那个 dialog 根本不会弹出来 ——
/// 「轻点背面」触发时用户还停在付款界面，屏幕上什么都不会发生，
/// 用户就会以为「双击没反应」。
///
/// 所以后台记完必须留一张回执，等 App 回到前台再在聊天流里说一句。
/// 存 UserDefaults 而不是内存单例：Intent 跑完 App 可能立刻被挂起，
/// 内存里的东西不一定活到用户下次点开。
enum IntentReport {
    private static let key = "snap.intent.report"

    static func write(_ text: String, recordId: String? = nil) {
        var d: [String: Any] = ["text": text, "ts": Date().timeIntervalSince1970]
        if let recordId { d["recordId"] = recordId }
        UserDefaults.standard.set(d, forKey: key)
    }

    /// 取出 10 分钟内的回执，取走即清（同一句不会播两遍）。
    /// 带 recordId 说明这笔账真记上了，聊天流里要把那一条也铺出来，能点开改。
    static func takeIfFresh() -> (text: String, recordId: String?)? {
        guard let d = UserDefaults.standard.dictionary(forKey: key),
              let ts = d["ts"] as? Double,
              Date().timeIntervalSince1970 - ts < 600,
              let t = d["text"] as? String,
              !t.isEmpty else { return nil }
        UserDefaults.standard.removeObject(forKey: key)
        return (t, d["recordId"] as? String)
    }
}

// MARK: - 一句话记账

struct AddRecordIntent: AppIntent {
    static var title: LocalizedStringResource = "记一笔"
    static var description: IntentDescription = IntentDescription("从一句话里识别金额和分类，直接记到家庭账本")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "文字", description: "例如：午饭 32")
    var text: String

    init() {}

    init(text: String) {
        self.text = text
    }

    static var parameterSummary: some ParameterSummary {
        Summary("记一笔 \(\.$text)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = LedgerStore.shared
        let names = store.db.members.map { $0.name }

        guard let bill = BillParser.parseQuick(text, members: names), bill.amount > 0 else {
            return .result(dialog: IntentDialog(stringLiteral: "没认出金额。说成「午饭 32」这样就行"))
        }

        var memberId = ""
        if !bill.member.isEmpty, let m = store.db.members.first(where: { $0.name == bill.member }) {
            memberId = m.id
        }
        var record = bill.toRecord(source: "intent")
        record.member = memberId
        record.book = ScanSettings.resolvedBook()

        store.add(record)
        SyncEngine.shared.now()
        let sign = bill.isIncome ? "收入" : "支出"
        let who = bill.member.isEmpty ? "" : "\(bill.member) "
        return .result(dialog: IntentDialog(stringLiteral:
            "记好了：\(who)\(sign) \(Money.currency(bill.amount)) · \(bill.category)"))
    }
}

// MARK: - 截图直接记账（省掉「提取文本」这一步）

struct AddRecordFromImageIntent: AppIntent {
    static var title: LocalizedStringResource = "截图记账"
    static var description: IntentDescription = IntentDescription("识别截图里的金额和商户，直接记到家庭账本")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "截图", description: "选「截屏」的输出")
    var image: IntentFile

    /// 第二参数，位置和百事那条「文本 v2」一样。
    /// 填 v2 这类版本标记会被忽略；填别的会写成这笔账的备注。
    @Parameter(title: "标记或备注", description: "可选。版本标记（如 v2）会被忽略，其它文字记成备注")
    var note: String?

    init() {}

    init(image: IntentFile, note: String? = nil) {
        self.image = image
        self.note = note
    }

    static var parameterSummary: some ParameterSummary {
        Summary("把 \(\.$image) 记进账本")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // IntentFile.data 是非可选的 Data（不是 Data?），所以不能写 guard let。
        guard let ui = UIImage(data: image.data) else {
            return .result(dialog: IntentDialog(stringLiteral: "这张图读不出来"))
        }

        // 先存档再识别：识别失败时图也在，用户还能回头看看是哪张认错了
        if ScanSettings.archiveImages {
            ScanArchive.save(ui)
        }

        let text = await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: TextOCR.recognize(ui))
            }
        }
        guard !text.isEmpty else {
            return .result(dialog: IntentDialog(stringLiteral: "图里没读到文字"))
        }

        let bill = BillParser.analyze(text)
        guard bill.amount > 0 else {
            return .result(dialog: IntentDialog(stringLiteral: "读到了文字但没认出金额，可能需要手动改一下"))
        }

        var rec = bill.toRecord(source: "intent")
        rec.book = ScanSettings.resolvedBook()
        if let n = Self.meaningfulNote(note) { rec.note = n }

        LedgerStore.shared.add(rec)
        SyncEngine.shared.now()

        let sign = bill.isIncome ? "收入" : "支出"
        let who = bill.merchant.isEmpty ? bill.category : bill.merchant
        let book = LedgerStore.shared.db.books.first { $0.id == rec.book }?.name ?? "家庭账本"
        return .result(dialog: IntentDialog(stringLiteral:
            "记好了：\(sign) \(Money.currency(bill.amount)) · \(who)（\(book)）"))
    }

    /// "v2" / "V2.1" 这类纯版本标记丢掉，其余当备注
    static func meaningfulNote(_ raw: String?) -> String? {
        guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if s.lowercased().hasPrefix("v"),
           s.dropFirst().allSatisfy({ $0.isNumber || $0 == "." }) {
            return nil
        }
        return s
    }
}

// MARK: - 零参数版：自己去找最新截图
//
// 这个才是「双击背面」真正能用的那个动作。
//
// 为什么必须有它：`AddRecordFromImageIntent` 的 image 是必填参数，
// 快捷指令里必须手动插一个「截屏」再把变量连到参数上 —— 用户加完动作
// 一运行就弹「请选择截图」，体验直接断在这里。
//
// 这一版没有参数，App Shortcuts 加进去就能跑：自己去相册捞最近一张截图。
// 拦路虎只有一个 —— 相册权限。后台 Intent 弹不出授权对话框，
// 所以必须先让用户在本 App 里授权过一次（引导页第 3 步的「现在试一次」就是干这个的）。

struct AddLatestScreenshotIntent: AppIntent {
    static var title: LocalizedStringResource = "读最新截图记账"
    static var description: IntentDescription = IntentDescription(
        "从相册取最近一张截图，认出金额直接记进账本。不用在快捷指令里连线，双击手机背面就能用。")
    static var openAppWhenRun: Bool = false

    /// 和 ScreenshotWatcher 里自动识别用的是同一个 key，
    /// 两边共用去重状态，不会出现「自动读过一次、双击又记一遍」。
    private static let lastAssetKey = "snap.lastScreenshotAsset"

    /// 只认 10 分钟内的截图。太宽会把上午的图捞出来记错账。
    private static let window: TimeInterval = 600

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let auth = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard auth == .authorized || auth == .limited else {
            let msg = "还没允许访问相册。打开家庭记账 → 我的 → AI 自动记账 → 点「现在试一次」，授权之后双击背面才有用。"
            IntentReport.write(msg)
            return .result(dialog: IntentDialog(stringLiteral: "先去 App 里允许访问相册"))
        }

        guard let asset = ScreenshotWatcher.latestScreenshot(within: Self.window) else {
            let msg = "最近 10 分钟相册里没有新截图。买完东西先截个屏，再双击背面。"
            IntentReport.write(msg)
            return .result(dialog: IntentDialog(stringLiteral: "最近 10 分钟没有新截图"))
        }

        // 同一张只记一次。双击两次、或者手滑连点，不该出两笔账。
        if UserDefaults.standard.string(forKey: Self.lastAssetKey) == asset.localIdentifier {
            let msg = "这张截图刚才已经记过了，不会重复记。要记新的就先截个屏。"
            IntentReport.write(msg)
            return .result(dialog: IntentDialog(stringLiteral: "这张已经记过了"))
        }

        guard let ui = await ScreenshotWatcher.image(of: asset) else {
            let msg = "截图读不出来（可能还在 iCloud 里没下载完），稍等几秒再双击背面。"
            IntentReport.write(msg)
            return .result(dialog: IntentDialog(stringLiteral: "截图读不出来"))
        }

        UserDefaults.standard.set(asset.localIdentifier, forKey: Self.lastAssetKey)

        if ScanSettings.archiveImages {
            ScanArchive.save(ui)
        }

        let text = await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: TextOCR.recognize(ui))
            }
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let msg = "这张截图里没读到文字，可能不是账单页。换一张再试。"
            IntentReport.write(msg)
            return .result(dialog: IntentDialog(stringLiteral: "图里没读到文字"))
        }

        let bill = BillParser.analyze(text)
        guard bill.amount > 0 else {
            // 认不出金额时把这张图留着，用户回 App 能看是哪张
            let msg = "截到了，但没认出金额（可能是余额页或不常见的版式）。回记账页手动补一句更快。"
            IntentReport.write(msg)
            return .result(dialog: IntentDialog(stringLiteral: "没认出金额"))
        }

        var rec = bill.toRecord(source: "intent")
        rec.book = ScanSettings.resolvedBook()
        let saved = LedgerStore.shared.add(rec)
        SyncEngine.shared.now()

        let sign = bill.isIncome ? "收入" : "支出"
        let who = bill.merchant.isEmpty ? bill.category : bill.merchant
        let book = LedgerStore.shared.db.books.first { $0.id == saved.book }?.name ?? "家庭账本"
        let line = "双击背面记的：\(sign) \(Money.currency(bill.amount)) · \(who)，已进「\(book)」"
        IntentReport.write(line, recordId: saved.id)
        return .result(dialog: IntentDialog(stringLiteral: "记好了：\(sign) \(Money.currency(bill.amount)) · \(who)"))
    }
}

// MARK: - 注册到快捷指令 / Siri

struct SnapLedgerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        // 排第一个 = 在快捷指令 App 的「家庭记账」分组里露在最上面。
        // 零参数、双击背面直接能跑，这是主推动作。
        AppShortcut(
            intent: AddLatestScreenshotIntent(),
            phrases: [
                "用 \(.applicationName) 记最新截图",
                "\(.applicationName) 截图记账",
                "\(.applicationName) 记一下"
            ],
            shortTitle: "截图记账",
            systemImageName: "camera.viewfinder"
        )
        AppShortcut(
            intent: AddRecordFromImageIntent(),
            phrases: [
                "用 \(.applicationName) 记这张图",
                "\(.applicationName) 认这张图"
            ],
            shortTitle: "认这张图",
            systemImageName: "photo.badge.checkmark"
        )
        AppShortcut(
            intent: AddRecordIntent(),
            phrases: [
                // 注意：AppShortcut 的 phrase 里只能插值 AppEntity / AppEnum，
                // 写成 "记 \(\.$text)" 会报 "Invalid parameter type. AppEntity and AppEnum
                // are the only allowed types for text"。所以这里不带参数。
                "用 \(.applicationName) 记一笔",
                "\(.applicationName) 记账"
            ],
            shortTitle: "记一笔",
            systemImageName: "square.and.pencil"
        )
    }
}
