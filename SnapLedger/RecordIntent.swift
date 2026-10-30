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

// MARK: - 注册到快捷指令 / Siri

struct SnapLedgerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddRecordFromImageIntent(),
            phrases: [
                "用 \(.applicationName) 记这张截图",
                "\(.applicationName) 截图记账"
            ],
            shortTitle: "截图记账",
            systemImageName: "camera.viewfinder"
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
