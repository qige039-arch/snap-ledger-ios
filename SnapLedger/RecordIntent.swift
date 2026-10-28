//
//  RecordIntent.swift
//  App Intents —— 这是原生 App 相对 PWA 最大的体验收益
//
//  iOS 的「轻点背面」只能绑快捷指令或系统功能，绑不了第三方 App。
//  但 App 把自己的能力注册成 App Intent 之后，它会自动出现在快捷指令的动作列表里，
//  于是快捷指令只需要：
//
//      截取屏幕 → 从图像中提取文本 → 记一笔（本 App 的 Intent）
//
//  甚至两步就够：截取屏幕 → 从图片记账（识别和解析都在 App 里做）。
//
//  关键区别：变量直接作为参数传进 Intent，不再经过「拼 URL → 打开 URL」这条路，
//  所以「无法将文本转换为 URL」这类错配从根本上不存在。
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

        store.add(record)
        let sign = bill.isIncome ? "收入" : "支出"
        let who = bill.member.isEmpty ? "" : "\(bill.member) "
        return .result(dialog: IntentDialog(stringLiteral:
            "记好了：\(who)\(sign) \(Money.currency(bill.amount)) · \(bill.category)"))
    }
}

// MARK: - 截图直接记账（省掉「提取文本」这一步）

struct AddRecordFromImageIntent: AppIntent {
    static var title: LocalizedStringResource = "从图片记账"
    static var description: IntentDescription = IntentDescription("识别截图里的金额和商户，直接记账")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "截图", description: "选「截屏」的输出")
    var image: IntentFile

    init() {}

    init(image: IntentFile) {
        self.image = image
    }

    static var parameterSummary: some ParameterSummary {
        Summary("从 \(\.$image) 记账")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let data = image.data, let ui = UIImage(data: data) else {
            return .result(dialog: IntentDialog(stringLiteral: "这张图读不出来"))
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

        LedgerStore.shared.add(bill.toRecord(source: "intent"))
        let sign = bill.isIncome ? "收入" : "支出"
        let who = bill.merchant.isEmpty ? bill.category : bill.merchant
        return .result(dialog: IntentDialog(stringLiteral:
            "记好了：\(sign) \(Money.currency(bill.amount)) · \(who)"))
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
                "用 \(.applicationName) 记一笔",
                "\(.applicationName) 记 \(\.$text)"
            ],
            shortTitle: "记一笔",
            systemImageName: "square.and.pencil"
        )
    }
}
