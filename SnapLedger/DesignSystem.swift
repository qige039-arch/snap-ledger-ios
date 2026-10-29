//
//  DesignSystem.swift
//  颜色 / 字体 / 卡片 / 通用组件
//
//  设计语言对齐网页版：浅灰底 + 白卡 + 青绿主色，收支用红绿区分。
//  颜色全部走 dynamic，深色模式自动切换，不靠 .preferredColorScheme 硬顶。
//

import SwiftUI

// MARK: - 动态颜色

extension Color {
    /// 用十六进制分别给浅色 / 深色两套值，避免在 View 里到处写 if colorScheme == .dark
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { trait in
            let hex = trait.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255.0,
                green: CGFloat((hex >> 8) & 0xFF) / 255.0,
                blue: CGFloat(hex & 0xFF) / 255.0,
                alpha: 1.0
            )
        })
    }
}

// MARK: - 主题

enum Theme {
    static let brand = Color.dynamic(light: 0x0F9D8C, dark: 0x22C3AC)
    static let brandDeep = Color.dynamic(light: 0x0A7A6C, dark: 0x16A291)
    static let brandSoft = Color.dynamic(light: 0xE6F5F2, dark: 0x14312E)

    static let expense = Color.dynamic(light: 0xE5544B, dark: 0xF0685E)
    static let income = Color.dynamic(light: 0x0F9D6E, dark: 0x2ECB88)

    static let bg = Color.dynamic(light: 0xF2F3F5, dark: 0x0E1013)
    static let card = Color.dynamic(light: 0xFFFFFF, dark: 0x181B20)
    static let card2 = Color.dynamic(light: 0xFAFBFC, dark: 0x1F232A)

    static let ink = Color.dynamic(light: 0x14161A, dark: 0xF2F4F7)
    static let ink2 = Color.dynamic(light: 0x5C6472, dark: 0xA2AAB6)
    static let ink3 = Color.dynamic(light: 0x9BA2AE, dark: 0x6B7380)
    static let line = Color.dynamic(light: 0xEBEDF0, dark: 0x262B33)

    static var hero: LinearGradient {
        LinearGradient(colors: [brand, brandDeep],
                       startPoint: .topLeading,
                       endPoint: .bottomTrailing)
    }

    /// 收入方向的渐变，用在结余为正的角标上
    static var incomeGradient: LinearGradient {
        LinearGradient(colors: [income, Color.dynamic(light: 0x12B87E, dark: 0x3FE09B)],
                       startPoint: .topLeading,
                       endPoint: .bottomTrailing)
    }
}

// MARK: - 分类配色

enum Tint {
    /// 给每个分类一个色相，让列表和统计不只是一片灰
    static func of(_ category: String) -> Color {
        switch category {
        case "餐饮": return Color.dynamic(light: 0xE8763C, dark: 0xF5A05E)
        case "交通": return Color.dynamic(light: 0x2F7BE0, dark: 0x6BA8F5)
        case "购物": return Color.dynamic(light: 0xC4519B, dark: 0xE07FBE)
        case "日用": return Color.dynamic(light: 0x38A169, dark: 0x5FCB8C)
        case "娱乐": return Color.dynamic(light: 0x8B5CF6, dark: 0xAB8BFA)
        case "医疗": return Color.dynamic(light: 0xE0453E, dark: 0xF0685E)
        case "居住": return Color.dynamic(light: 0x0F9D8C, dark: 0x22C3AC)
        case "通讯": return Color.dynamic(light: 0x1E88A8, dark: 0x4FBAD5)
        case "学习": return Color.dynamic(light: 0x9A7B2E, dark: 0xD2B45E)
        case "人情": return Color.dynamic(light: 0xD9534F, dark: 0xEE807B)
        case "宠物": return Color.dynamic(light: 0xB07D2E, dark: 0xD9A85C)
        case "工资": return Color.dynamic(light: 0x0F9D6E, dark: 0x2ECB88)
        case "奖金": return Color.dynamic(light: 0xB8860B, dark: 0xE8BE5C)
        case "红包": return Color.dynamic(light: 0xE2473D, dark: 0xF0685E)
        case "退款": return Color.dynamic(light: 0x5C6472, dark: 0xA2AAB6)
        case "理财": return Color.dynamic(light: 0x2F7BE0, dark: 0x6BA8F5)
        default:   return Color.dynamic(light: 0x8A93A0, dark: 0x9BA2AE)
        }
    }
}

// MARK: - 卡片

struct CardStyle: ViewModifier {
    var padding: CGFloat = 14
    var radius: CGFloat = 18
    var flat: Bool = false

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.line, lineWidth: 0.7)
            )
            .shadow(color: Color.black.opacity(flat ? 0 : 0.045),
                    radius: flat ? 0 : 12, x: 0, y: flat ? 0 : 4)
    }
}

extension View {
    func cardStyle(padding: CGFloat = 14, radius: CGFloat = 18, flat: Bool = false) -> some View {
        modifier(CardStyle(padding: padding, radius: radius, flat: flat))
    }
}

// MARK: - 金额

/// 金额统一走 rounded + 等宽数字，列表滚动时不会左右抖
struct MoneyText: View {
    let value: Double
    var size: CGFloat = 17
    var weight: Font.Weight = .semibold
    var signed: Bool = false
    var color: Color = Theme.ink
    var showCurrency: Bool = false

    var body: some View {
        Text(display)
            .font(.system(size: size, weight: weight, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(color)
    }

    /// body 里不能写 let + return（ViewBuilder 不允许显式 return），拆出来
    private var display: String {
        let base = signed ? Money.signed(value) : Money.plain(abs(value))
        return showCurrency ? "¥" + base : base
    }
}

// MARK: - 分段切换

/// 日 / 月 / 年 与 支出 / 收入 用的切换条
///
/// 这里踩过太多坑，写下结论：**不要用 Button + 背景块**做这种控件。
/// 之前那版（Button + matchedGeometryEffect + overlay 描边）在 LazyVStack 里
/// 会出现「点了第三个不生效」，改了三次都没根治。现在只用「文字 + onTapGesture +
/// 整块 contentShape」，命中区域就是肉眼看到的那一块，没有额外图层抢事件。
/// 另外这两条切换条一律放在 ScrollView **外面**（页头固定），不再受列表手势影响。
struct ScopeBar: View {
    let titles: [String]
    @Binding var index: Int
    var fill: Color = Theme.brand

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(titles.enumerated()), id: \.offset) { i, title in
                Text(title)
                    .font(.system(size: 13.5, weight: i == index ? .semibold : .regular))
                    .foregroundStyle(i == index ? Color.white : Theme.ink2)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .background {
                        Capsule().fill(i == index ? fill : Color.clear)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard i != index else { return }
                        index = i
                    }
            }
        }
        .padding(3)
        .background(Theme.card2, in: Capsule())
        .overlay {
            Capsule().strokeBorder(Theme.line, lineWidth: 0.7).allowsHitTesting(false)
        }
        .animation(.easeOut(duration: 0.16), value: index)
    }
}

// MARK: - 紧凑切换（卡头右上角用）

/// 卡头里的小号切换条（支出/收入/结余、柱状/曲线、排序方式）
///
/// 和 ScopeBar 同一套做法：文字 + contentShape + onTapGesture。
/// 宽度跟着文字走，不满占一行 —— 放进卡头右侧刚好。
struct CompactSeg: View {
    let titles: [String]
    @Binding var index: Int
    var fill: Color = Theme.brand

    var body: some View {
        HStack(spacing: 1) {
            ForEach(Array(titles.enumerated()), id: \.offset) { i, title in
                Text(title)
                    .font(.system(size: 11.5, weight: i == index ? .semibold : .regular))
                    .foregroundStyle(i == index ? Color.white : Theme.ink2)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background {
                        Capsule().fill(i == index ? fill : Color.clear)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard i != index else { return }
                        index = i
                    }
            }
        }
        .padding(2)
        .background(Theme.card2, in: Capsule())
        .overlay {
            Capsule().strokeBorder(Theme.line, lineWidth: 0.7).allowsHitTesting(false)
        }
        .animation(.easeOut(duration: 0.16), value: index)
    }
}

// MARK: - 统计小卡

/// 汇总网格里的一格：小标题 + 大金额，可选一个小角标
struct StatCell: View {
    let title: String
    let value: String
    var color: Color = Theme.ink
    var note: String?
    var noteColor: Color = Theme.ink3
    var showsCurrency: Bool = true
    /// 负号要放在 ¥ 前面（-¥320），不能走进数字里变成 ¥-320
    var sign: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.ink3)
                if let note {
                    Text(note)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(noteColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(noteColor.opacity(0.10),
                                    in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                Spacer(minLength: 0)
            }

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                if !sign.isEmpty {
                    Text(sign)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(color)
                }
                if showsCurrency {
                    Text("¥")
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(color.opacity(0.75))
                }
                Text(value)
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
            }
        }
        // 网格里同一行两格高度必须一致，否则视觉上是歪的
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .cardStyle(padding: 0, radius: 15)
    }
}

// MARK: - 图标底座

struct EmojiBadge: View {
    let emoji: String
    var tint: Color = Theme.brand
    var size: CGFloat = 38
    var font: CGFloat = 18

    var body: some View {
        Text(emoji)
            .font(.system(size: font))
            .frame(width: size, height: size)
            .background(tint.opacity(0.14),
                        in: RoundedRectangle(cornerRadius: size * 0.34, style: .continuous))
    }
}

// MARK: - 小标签

struct TagView: View {
    let text: String
    var color: Color = Theme.ink2
    var filled: Bool = false

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(filled ? Color.white : color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background {
                if filled {
                    Capsule().fill(color)
                } else {
                    Capsule().fill(color.opacity(0.12))
                }
            }
    }
}

// MARK: - 顶部汇总大卡

/// 账本 / 统计页共用：渐变底，支出大字，两列副信息
struct HeroCard: View {
    let label: String
    let amount: Double
    var income: Double?
    var balance: Double?
    var footTitle: String = "结余"
    var footValue: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.82))

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("¥")
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                Text(Money.plain(amount))
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
            .padding(.top, 1)

            Rectangle()
                .fill(.white.opacity(0.18))
                .frame(height: 0.8)
                .padding(.vertical, 12)

            HStack(spacing: 0) {
                if let inc = income {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("收入")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.72))
                        Text(Money.currency(inc))
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let bal = balance {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(footTitle)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.72))
                        Text(Money.signed(bal))
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let fv = footValue {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("笔数")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.72))
                        Text(fv)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                Theme.hero
                // 右上角两个光晕，避免大面积纯色显得廉价
                Circle()
                    .fill(.white.opacity(0.10))
                    .frame(width: 160, height: 160)
                    .offset(x: 96, y: -86)
                Circle()
                    .fill(.white.opacity(0.07))
                    .frame(width: 96, height: 96)
                    .offset(x: 40, y: 78)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

// MARK: - 撤销条

/// 删除后的 4 秒反悔期。做成组件是因为账本页、聊天页、全部记录页都要用，
/// 三处各写一遍必然文案和间距走形。
struct UndoBar: View {
    let text: String
    var onUndo: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "trash")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.expense)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.ink2)
                .lineLimit(1)
            Spacer(minLength: 6)
            Button(action: onUndo) {
                Text("撤销")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.brand)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Theme.card)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.line).frame(height: 0.7)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line).frame(height: 0.7)
        }
    }
}

// MARK: - 日期格式

/// DateFormatter 创建一次要几十微秒，列表里每行都 new 一次是卡顿的主要来源。
/// 全部缓存成 static，只改配置不再重建。
enum Fmt {
    static let cal = Calendar.current

    private static func make(_ pattern: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = pattern
        return f
    }

    private static let fKey = make("yyyy-MM-dd")
    private static let fDayNum = make("d")
    private static let fMD = make("M月d日")
    private static let fWeek = make("EEE")
    private static let fYM = make("yyyy年M月")
    private static let fY = make("yyyy年")
    private static let fHM = make("HH:mm")
    private static let fMDHM = make("M月d日 HH:mm")

    /// 2026-10-29，和月历格子的 key 同源
    static func key(_ date: Date) -> String { fKey.string(from: date) }

    static func dayNumber(_ date: Date) -> String { fDayNum.string(from: date) }

    static func dayKey(_ date: Date) -> String { fMD.string(from: date) }

    /// 「10月28日 周三」
    static func dayLong(_ date: Date) -> String {
        var s = fMD.string(from: date)
        s += " " + fWeek.string(from: date)
        if cal.isDateInToday(date) { s += " · 今天" }
        else if cal.isDateInYesterday(date) { s += " · 昨天" }
        return s
    }

    static func monthTitle(_ date: Date) -> String { fYM.string(from: date) }

    static func yearTitle(_ date: Date) -> String { fY.string(from: date) }

    static func hm(_ ms: Double) -> String {
        fHM.string(from: Date(timeIntervalSince1970: ms / 1000))
    }

    static func mdhm(_ ms: Double) -> String {
        fMDHM.string(from: Date(timeIntervalSince1970: ms / 1000))
    }
}
