//
//  ParserTests.swift
//  解析引擎回归测试 —— 用例从网页版的 testdata/test-parse.js 与 test-quick.js 移植
//
//  这几条不是「随便写的样例」，每一条都对应一次真实踩坑，删掉就等于把坑踩回去：
//  - 收款方 → 被认成收入
//  - 支付成功 \n 时间 → 年份被当金额
//  - 余额 / 原价 → 被当成本次实付
//
//  用法：Xcode → File → New → Target → Unit Testing Bundle，命名 SnapLedgerTests，
//  把这个文件加进去，Cmd+U 跑。
//

import XCTest
@testable import SnapLedger

final class ParserTests: XCTestCase {

    // MARK: 截图文字

    private struct Case {
        let name: String
        let text: String
        let amount: Double
        let type: String
        let category: String
        let merchant: String?
        let method: String?
    }

    private let cases: [Case] = [
        Case(name: "微信单行付款（收款方不能被当收入）",
             text: "微信支付 支付成功 收款方 美团外卖 -32.50 2026-10-28 12:06",
             amount: 32.5, type: "expense", category: "餐饮", merchant: "美团外卖", method: "微信"),

        Case(name: "多行付款（年份不能被劫持）",
             text: "微信支付\n美团外卖\n-32.50\n支付成功\n2026-10-28 12:06",
             amount: 32.5, type: "expense", category: "餐饮", merchant: "美团外卖", method: "微信"),

        Case(name: "支付成功下一行是支付时间",
             text: "-32.50\n支付成功\n支付时间 2026年10月28日 12:06",
             amount: 32.5, type: "expense", category: "其他", merchant: nil, method: nil),

        Case(name: "工资到账",
             text: "工资到账 +8000 2026-10-25",
             amount: 8000, type: "income", category: "工资", merchant: nil, method: nil),

        Case(name: "退款优先判收入",
             text: "退款到账 -68.00",
             amount: 68, type: "income", category: "退款", merchant: nil, method: nil),

        Case(name: "银行短信（余额不能被当支出）",
             text: "招商银行 您尾号1234的账户 支出 128.00元 余额 5012.30元",
             amount: 128, type: "expense", category: "其他", merchant: nil, method: "银行卡"),

        Case(name: "支付宝账单",
             text: "支付宝\n肯德基\n-45.00\n交易成功\n2026-10-27 19:02",
             amount: 45, type: "expense", category: "餐饮", merchant: "肯德基", method: "支付宝"),

        Case(name: "话费充值",
             text: "中国移动\n充值成功\n话费充值 ¥50.00\n微信支付\n2026-10-19 10:00",
             amount: 50, type: "expense", category: "通讯", merchant: nil, method: "微信"),

        Case(name: "余额降权",
             text: "支付成功 实付 25.80 余额 1200.00",
             amount: 25.8, type: "expense", category: "其他", merchant: nil, method: nil),

        Case(name: "原价降权",
             text: "原价 199.00 实付 79.00",
             amount: 79, type: "expense", category: "其他", merchant: nil, method: nil),

        Case(name: "淘宝订单",
             text: "淘宝\n订单金额 268.00\n支付成功\n2026-10-20 21:10",
             amount: 268, type: "expense", category: "购物", merchant: nil, method: nil),

        Case(name: "滴滴打车",
             text: "滴滴出行\n-23.40\n支付成功",
             amount: 23.4, type: "expense", category: "交通", merchant: nil, method: nil),

        Case(name: "医院门诊",
             text: "-156.00\n市第一人民医院\n门诊缴费",
             amount: 156, type: "expense", category: "医疗", merchant: nil, method: nil),

        Case(name: "酒店（娱乐词表）",
             text: "如家酒店\n-420.00",
             amount: 420, type: "expense", category: "娱乐", merchant: nil, method: nil),

        Case(name: "零金额不该出现",
             text: "支付成功 请稍候",
             amount: 0, type: "expense", category: "其他", merchant: nil, method: nil)
    ]

    func testAnalyze() {
        for c in cases {
            let r = BillParser.analyze(c.text)
            XCTAssertEqual(r.amount, c.amount, accuracy: 0.001, "\(c.name)：金额")
            XCTAssertEqual(r.type, c.type, "\(c.name)：收支方向")
            XCTAssertEqual(r.category, c.category, "\(c.name)：分类")
            if let m = c.merchant {
                XCTAssertEqual(r.merchant, m, "\(c.name)：商户")
            }
            if let m = c.method {
                XCTAssertEqual(r.method, m, "\(c.name)：支付方式")
            }
        }
    }

    // MARK: 口语短句

    private struct QuickCase {
        let name: String
        let text: String
        let amount: Double
        let type: String
        let category: String
        var member: String? = nil
    }

    private let quickCases: [QuickCase] = [
        QuickCase(name: "昨天午饭", text: "昨天午饭 32", amount: 32, type: "expense", category: "餐饮"),
        QuickCase(name: "带成员的买菜", text: "老婆买菜 86", amount: 86, type: "expense", category: "日用", member: "老婆"),
        QuickCase(name: "工资", text: "工资 12000", amount: 12000, type: "income", category: "工资"),
        QuickCase(name: "咖啡", text: "咖啡 22", amount: 22, type: "expense", category: "餐饮"),
        QuickCase(name: "打车小数", text: "打车 28.5", amount: 28.5, type: "expense", category: "交通"),
        // 「买书」单独出现会落到「其他」——词表里只有「书店/图书」，这是已知缺口，不是回归
        QuickCase(name: "日期不能被当金额", text: "10月28日 书店买书 45", amount: 45, type: "expense", category: "学习"),
        QuickCase(name: "收到红包", text: "收到红包 200", amount: 200, type: "income", category: "红包"),
        QuickCase(name: "超市", text: "超市 158.6", amount: 158.6, type: "expense", category: "日用"),
        QuickCase(name: "口头记一笔", text: "记一笔 晚饭 68", amount: 68, type: "expense", category: "餐饮"),
        QuickCase(name: "退货退款", text: "退货退款 45.9", amount: 45.9, type: "income", category: "退款")
    ]

    func testParseQuick() {
        for c in quickCases {
            guard let r = BillParser.parseQuick(c.text, members: ["我", "老婆"]) else {
                XCTFail("\(c.name)：解析返回 nil")
                continue
            }
            XCTAssertEqual(r.amount, c.amount, accuracy: 0.001, "\(c.name)：金额")
            XCTAssertEqual(r.type, c.type, "\(c.name)：收支方向")
            XCTAssertEqual(r.category, c.category, "\(c.name)：分类")
            if let m = c.member {
                XCTAssertEqual(r.member, m, "\(c.name)：成员")
            }
        }
    }

    func testQuickReturnsNilWithoutNumber() {
        XCTAssertNil(BillParser.parseQuick("今天天气不错", members: []))
        XCTAssertNil(BillParser.parseQuick("   ", members: []))
    }

    // MARK: 时间

    func testDateFromScreenshot() {
        let r = BillParser.analyze("微信支付\n-32.50\n支付成功\n2026-10-28 12:06")
        let d = Date(timeIntervalSince1970: r.ts / 1000)
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: d)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 10)
        XCTAssertEqual(comps.day, 28)
    }
}
