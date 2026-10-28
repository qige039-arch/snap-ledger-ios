//
//  CalendarHeat.swift
//  账本页的月历热力卡
//
//  为什么要有它：列表回答的是「我花了多少」，日历回答的是「哪天没记 / 哪天超了」。
//  空白格本身就是最强的提醒——这是列表给不出的信息。
//
//  和百事 AA 那张日历的三处不同：
//   1. 一格只放「日期 + 支出」，收入退成右上角绿点（或纯收入日的淡绿底），
//      密度降下来，小屏才看得清；
//   2. 颜色走品牌支出红，不用紫色；
//   3. 深浅按当月分位数分档，而不是绝对金额。
//

import SwiftUI

struct MonthHeatCalendar: View {
    let anchor: Date
    @Binding var selectedKey: String?
    var onPick: (HeatDay) -> Void

    @ObservedObject private var store = LedgerStore.shared
    @Environment(\.colorScheme) private var scheme

    private var days: [HeatDay] { store.monthHeat(monthOf: anchor) }

    var body: some View {
        let list = days
        VStack(spacing: 0) {
            titleRow(list)
            weekdayRow
                .padding(.top, 10)
                .padding(.bottom, 5)
            grid(list)
            legend
                .padding(.top, 10)
        }
        .cardStyle(padding: 12)
    }

    // MARK: 头部

    private func titleRow(_ list: [HeatDay]) -> some View {
        HStack(spacing: 6) {
            Text("每日支出")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.ink2)
            Spacer(minLength: 6)
            Text("日均 " + Money.currency(dailyAvg(list)))
                .font(.system(size: 11.5, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.ink3)
        }
    }

    private var weekdayRow: some View {
        HStack(spacing: gridGap) {
            ForEach(weekdaySymbols, id: \.self) { s in
                Text(s)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.ink3)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func grid(_ list: [HeatDay]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: gridGap), count: 7),
                  spacing: gridGap) {
            ForEach(list) { d in
                cell(d)
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 4) {
            Text("少")
                .font(.system(size: 10))
                .foregroundStyle(Theme.ink3)
            ForEach([1, 2, 3, 4], id: \.self) { lv in
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(Theme.expense.opacity(alpha(lv)))
                    .frame(width: 9, height: 9)
            }
            Text("多")
                .font(.system(size: 10))
                .foregroundStyle(Theme.ink3)
            Spacer(minLength: 8)
            Text("点一天看当天明细")
                .font(.system(size: 10))
                .foregroundStyle(Theme.ink3)
        }
    }

    // MARK: 单元格

    private func cell(_ d: HeatDay) -> some View {
        let today = Fmt.cal.isDateInToday(d.day)
        let selected = selectedKey == d.key
        let mixed = d.expense > 0 && d.income > 0

        return Button {
            onPick(d)
        } label: {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 0) {
                    Text("\(d.dayNumber)")
                        .font(.system(size: 11.5,
                                      weight: today ? .bold : .medium,
                                      design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(numberColor(d, today: today))

                    Text(amountText(d))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(amountColor(d))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.top, 1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(fillColor(d),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                if mixed {
                    Circle()
                        .fill(Theme.income)
                        .frame(width: 4.5, height: 4.5)
                        .padding(4)
                }
            }
            .frame(height: 46)
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(strokeColor(today: today, selected: selected),
                                  lineWidth: today || selected ? 1.6 : 0)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText(d))
    }

    // MARK: 取值

    private let gridGap: CGFloat = 4

    private func alpha(_ level: Int) -> Double {
        let table: [Double] = scheme == .dark
            ? [0, 0.20, 0.34, 0.52, 0.88]
            : [0, 0.10, 0.22, 0.38, 0.88]
        return table[max(0, min(4, level))]
    }

    private func fillColor(_ d: HeatDay) -> Color {
        if d.level > 0 { return Theme.expense.opacity(alpha(d.level)) }
        if d.income > 0 { return Theme.income.opacity(scheme == .dark ? 0.22 : 0.13) }
        return Color.clear
    }

    private func strokeColor(today: Bool, selected: Bool) -> Color {
        if today { return Theme.brand }
        if selected { return Theme.ink2.opacity(0.55) }
        return Color.clear
    }

    private func numberColor(_ d: HeatDay, today: Bool) -> Color {
        if d.level >= 4 { return .white }
        if today { return Theme.brand }
        if !d.inMonth { return Theme.ink3.opacity(0.55) }
        if d.level == 0 && d.income > 0 { return Theme.income }
        return Theme.ink
    }

    private func amountColor(_ d: HeatDay) -> Color {
        if !d.inMonth { return .clear }
        if d.level >= 4 { return .white.opacity(0.92) }
        if d.level == 0 && d.income > 0 { return Theme.income }
        return Theme.ink2
    }

    private func amountText(_ d: HeatDay) -> String {
        guard d.inMonth else { return "" }
        if d.expense > 0 { return "-" + short(d.expense) }
        if d.income > 0 { return "+" + short(d.income) }
        return ""
    }

    /// 格子只有 44pt 宽，四位数以上必须缩写，否则一定被挤成省略号
    private func short(_ v: Double) -> String {
        if v >= 10000 { return String(format: "%.1f万", v / 10000) }
        if v >= 100 { return String(format: "%.0f", v) }
        if v == v.rounded() { return String(format: "%.0f", v) }
        return String(format: "%.1f", v)
    }

    private func dailyAvg(_ list: [HeatDay]) -> Double {
        let cal = Fmt.cal
        let total = list.reduce(0.0) { $0 + ($1.inMonth ? $1.expense : 0) }
        let now = Date()
        let isThisMonth = cal.component(.year, from: anchor) == cal.component(.year, from: now)
            && cal.component(.month, from: anchor) == cal.component(.month, from: now)
        let n = isThisMonth
            ? cal.component(.day, from: now)
            : list.filter { $0.inMonth }.count
        return total / Double(max(1, n))
    }

    private var weekdaySymbols: [String] {
        let base = ["日", "一", "二", "三", "四", "五", "六"]
        let f = Fmt.cal.firstWeekday - 1
        guard f > 0, f < 7 else { return base }
        return Array(base[f...]) + Array(base[..<f])
    }

    private func accessibilityText(_ d: HeatDay) -> String {
        var parts = [Fmt.dayKey(d.day)]
        if d.count == 0 {
            parts.append("没有记录")
        } else {
            if d.expense > 0 { parts.append("支出 " + Money.plain(d.expense) + " 元") }
            if d.income > 0 { parts.append("收入 " + Money.plain(d.income) + " 元") }
            parts.append("\(d.count) 笔")
        }
        return parts.joined(separator: "，")
    }
}
