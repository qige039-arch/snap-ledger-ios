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

    /// 和零参数那个一致：记完要让用户看见，别在后台闷着
    static var openAppWhenRun: Bool = true

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

    func perform() async throws -> some IntentResult {
        // 和零参数版同一个道理：perform 可能在独立进程里跑，
        // 在那儿识别、写库会随进程回收蒸发，还会和前台 App 的数据库互相覆盖。
        // 所以这里只把图写进沙盒接力文件（同一 App 共享容器），敲一下门就走。
        // 真正的识别由前台 ScanCoordinator 接手（它优先读这个接力文件）。
        do {
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let url = dir.appendingPathComponent("incoming-scan.jpg")
            try? FileManager.default.removeItem(at: url)
            try image.data.write(to: url, options: .atomic)
        } catch {
            IntentReport.write("截图传不过来（\(error.localizedDescription)），在 App 里手动选图试试。")
            return .result()
        }

        if let n = Self.meaningfulNote(note) {
            UserDefaults.standard.set(n, forKey: "snap.relay.note")
        } else {
            UserDefaults.standard.removeObject(forKey: "snap.relay.note")
        }

        let auth = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if auth == .denied || auth == .restricted {
            IntentReport.write("相册权限被关掉了。到 iOS 设置 → 家庭记账 → 照片 → 改成「完全访问」。")
        }

        ScanPending.mark()
        return .result()
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

// MARK: - 零参数版：双击背面，打开 App 记这一笔
//
// 这个才是「双击背面」真正能用的那个动作。
//
// 为什么必须有它：`AddRecordFromImageIntent` 的 image 是必填参数，
// 快捷指令里必须手动插一个「截屏」再把变量连到参数上 —— 用户加完动作
// 一运行就弹「请选择截图」，体验直接断在这里。
//
// 这一版没有参数，App Shortcuts 加进去就能跑。
//
// ## 为什么 openAppWhenRun = true
//
// 上一版是后台跑的：用户双击背面，屏幕上什么都不会发生，账却已经记上了。
// 用户的原话是「双击背面，直接就可以跳转到我的记账app，然后记录下这一笔」——
// 他要的是看得见的过程：App 弹到前台，界面上说「正在读最新截图」，
// 然后那张待确认卡片出现。
//
// 所以这个 Intent 自己不识别、不记账，只做一件事：留一张票据（ScanPending），
// 然后让 App 前台的 ScreenshotWatcher 走完整的识别链路 ——
// 用户能看到过程、能当场改分类、能撤销。后台静默记账做不到这些。
//
// 拦路虎只有一个 —— 相册权限。系统不允许后台弹授权框，
// 所以必须先让用户在本 App 里授权过一次（引导页第 3 步的「现在试一次」就是干这个的）。

struct AddLatestScreenshotIntent: AppIntent {
    static var title: LocalizedStringResource = "读最新截图记账"
    static var description: IntentDescription = IntentDescription(
        "打开本 App，从相册取最近一张截图认出金额记进账本。不用在快捷指令里连线，双击手机背面就能用。")

    /// 双击背面要跳到 App 里，用户才看得见账记到哪儿去了
    static var openAppWhenRun: Bool = true

    init() {}

    func perform() async throws -> some IntentResult {
        // 这个动作自己什么都不做：不找图、不识别、更不碰数据库。
        // 它只负责两件事 —— 把 App 拉到前台（openAppWhenRun），和敲一下门。
        //
        // 为什么不在 perform 里直接调 ScanCoordinator（v1.0 就是这么干的）：
        // perform 有可能被 iOS 放进独立进程执行，进程里的 async Task 会随
        // perform 返回被回收 —— 识别刚开头就蒸发，表现就是「App 跳过来了，
        // 卡在正在读，然后没有然后」。而且在独立进程里写账本文件，
        // 会和前台 App 的内存数据库互相覆盖，是数据隐患。
        //
        // 正确姿势：Intent 只留信号（UserDefaults 票据 + Darwin 跨进程广播），
        // 由 App 进程里的 ScanCoordinator 接手 —— 那儿有完整生命周期，
        // 数据库、UI、同步都在同一个进程里。
        let auth = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if auth == .denied || auth == .restricted {
            // 拒绝状态连门都不用敲，直接把原因带回去（聊天页的回执会显示这句）
            IntentReport.write("相册权限被关掉了。到 iOS 设置 → 家庭记账 → 照片 → 改成「完全访问」，再双击背面。")
            ScanPending.mark()
            return .result()
        }

        ScanPending.mark()
        return .result()
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
