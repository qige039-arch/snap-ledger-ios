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

// MARK: - 分段控件

/// 自绘分段控件：系统 Picker 的 .segmented 在中文字号下偏挤
///
/// 这里踩过两个坑，别再走回去：
/// 1. `.overlay(Shape)` 会吃掉内部 Button 的点击 —— 整条控件看起来「点了没反应」。
///    必须给 overlay 加 `.allowsHitTesting(false)`。
/// 2. `matchedGeometryEffect` 在 LazyVStack / 带隐式动画的 ScrollView 里会让切换帧丢掉，
///    同样表现为点了不切。改成「每段自己带背景」，靠 `.animation(value:)` 过渡，稳。
struct ScopeSegmented: View {
    let titles: [String]
    @Binding var index: Int

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(titles.indices, id: \.self) { i in
                Button {
                    guard i != index else { return }
                    index = i
                } label: {
                    Text(titles[i])
                        .font(.system(size: 14, weight: i == index ? .semibold : .regular))
                        .foregroundStyle(i == index ? Theme.ink : Theme.ink2)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background {
                            // 背景恒存在（未选中是透明），三段的命中区域才一样大
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(i == index ? Theme.card : Color.clear)
                                .shadow(color: .black.opacity(i == index ? (scheme == .dark ? 0.4 : 0.08) : 0),
                                        radius: i == index ? 3 : 0,
                                        x: 0,
                                        y: i == index ? 1 : 0)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Theme.card2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 0.7)
                .allowsHitTesting(false)
        }
        .animation(.easeOut(duration: 0.16), value: index)
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

// MARK: - 日期格式

enum Fmt {
    static let cal = Calendar.current

    static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "M月d日"
        return f.string(from: date)
    }

    /// 「10月28日 周三」
    static func dayLong(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "M月d日"
        var s = f.string(from: date)
        let wf = DateFormatter()
        wf.locale = Locale(identifier: "zh_CN")
        wf.dateFormat = "EEE"
        s += " " + wf.string(from: date)
        if cal.isDateInToday(date) { s += " · 今天" }
        else if cal.isDateInYesterday(date) { s += " · 昨天" }
        return s
    }

    static func monthTitle(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy年M月"
        return f.string(from: date)
    }

    static func yearTitle(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy年"
        return f.string(from: date)
    }

    static func hm(_ ms: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date(timeIntervalSince1970: ms / 1000))
    }

    static func mdhm(_ ms: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "M月d日 HH:mm"
        return f.string(from: Date(timeIntervalSince1970: ms / 1000))
    }
}
