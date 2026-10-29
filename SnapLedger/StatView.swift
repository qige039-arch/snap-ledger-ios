//
//  StatView.swift
//  统计：趋势 + 分类结构
//
//  用 Swift Charts 画柱状趋势。分类排行用自绘进度条而不是饼图 ——
//  手机上饼图的小扇区几乎不可读，条形图能直接比大小。
//

import SwiftUI
import Charts

struct StatView: View {
    @ObservedObject private var store = LedgerStore.shared

    @State private var scopeIndex = 1        // 0 日 / 1 月 / 2 年
    @State private var anchor = Date()
    @State private var showIncome = false

    private let scopeTitles = ["日", "月", "年"]

    // MARK: 范围

    private var range: (start: Date, end: Date) {
        let cal = Fmt.cal
        switch scopeIndex {
        case 0:
            let s = cal.startOfDay(for: anchor)
            return (s, cal.date(byAdding: .day, value: 1, to: s) ?? s)
        case 1:
            let c = cal.dateComponents([.year, .month], from: anchor)
            let s = cal.date(from: c) ?? anchor
            return (s, cal.date(byAdding: .month, value: 1, to: s) ?? s)
        default:
            let c = cal.dateComponents([.year], from: anchor)
            let s = cal.date(from: c) ?? anchor
            return (s, cal.date(byAdding: .year, value: 1, to: s) ?? s)
        }
    }

    private var title: String {
        switch scopeIndex {
        case 0: return Fmt.dayLong(anchor)
        case 1: return Fmt.monthTitle(anchor)
        default: return Fmt.yearTitle(anchor)
        }
    }

    private var records: [LedgerRecord] {
        store.records(from: range.start, to: range.end)
    }

    private var totals: (income: Double, expense: Double) {
        store.totals(from: range.start, to: range.end)
    }

    private var cats: [CatTotal] {
        store.categoryTotals(from: range.start, to: range.end, income: showIncome)
    }

    private var focusTotal: Double {
        showIncome ? totals.income : totals.expense
    }

    private var days: Double {
        // 日均：本年/本月按已过去的天数算，避免月初显示得特别夸张
        let cal = Fmt.cal
        let now = Date()
        if now < range.start { return 1 }
        if now >= range.end {
            return Double(cal.dateComponents([.day], from: range.start, to: range.end).day ?? 1)
        }
        return Double(max(1, cal.dateComponents([.day], from: range.start, to: now).day ?? 1))
    }

    private var maxSingle: Double {
        let pool = records.filter { $0.isIncome == showIncome }
        return pool.map { $0.amount }.max() ?? 0
    }

    // MARK: 视图

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(spacing: 14) {
                    directionSwitch
                        .padding(.horizontal, 16)

                    compareRow
                        .padding(.horizontal, 16)

                    tiles
                        .padding(.horizontal, 16)

                    chartCard
                        .padding(.horizontal, 16)

                    rankingCard
                        .padding(.horizontal, 16)
                }
                .padding(.top, 10)
                .padding(.bottom, 28)
            }
            .animation(.easeOut(duration: 0.22), value: anchor)
            .animation(.easeOut(duration: 0.22), value: showIncome)
        }
        .background(Theme.bg)
        .onChange(of: store.currentBookId) { _, _ in
            anchor = Date()
        }
    }

    private var header: some View {
        VStack(spacing: 9) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("统计")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Theme.ink)
                    Text(title + " · " + (store.currentBook?.name ?? "家庭账本"))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.ink3)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                HStack(spacing: 7) {
                    navButton("chevron.left") { step(-1) }
                    navButton("chevron.right") { step(1) }
                }
            }

            ScopeBar(titles: scopeTitles, index: $scopeIndex)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .background(Theme.bg)
    }

    private func navButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.ink2)
                .frame(width: 30, height: 30)
                .background(Theme.card, in: Circle())
                .overlay(Circle().strokeBorder(Theme.line, lineWidth: 0.7))
        }
        .buttonStyle(.plain)
    }

    private func step(_ dir: Int) {
        let comp: Calendar.Component = scopeIndex == 0 ? .day : (scopeIndex == 1 ? .month : .year)
        if let d = Fmt.cal.date(byAdding: comp, value: dir, to: anchor) { anchor = d }
    }

    private var directionSwitch: some View {
        HStack(spacing: 8) {
            ForEach([false, true], id: \.self) { inc in
                let on = inc == showIncome
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { showIncome = inc }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: inc ? "arrow.down.left" : "arrow.up.right")
                            .font(.system(size: 10.5, weight: .bold))
                        Text(inc ? "收入" : "支出")
                            .font(.system(size: 13, weight: on ? .semibold : .regular))
                    }
                    .foregroundStyle(on ? Color.white : Theme.ink2)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(on ? (inc ? Theme.income : Theme.expense) : Theme.card,
                                in: Capsule())
                    .overlay(Capsule().strokeBorder(on ? Color.clear : Theme.line, lineWidth: 0.7))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    private var tiles: some View {
        HStack(spacing: 10) {
            tile(title: "总计", value: Money.currency(focusTotal))
            if scopeIndex == 0 {
                tile(title: "笔数", value: "\(records.count)")
            } else {
                tile(title: "日均", value: Money.currency(focusTotal / days))
            }
            tile(title: "最大一笔", value: maxSingle > 0 ? Money.currency(maxSingle) : "—")
        }
    }

    // MARK: 与上一期对比

    private var prevRange: (start: Date, end: Date) {
        let cal = Fmt.cal
        let comp: Calendar.Component = scopeIndex == 0 ? .day : (scopeIndex == 1 ? .month : .year)
        let s = cal.date(byAdding: comp, value: -1, to: range.start) ?? range.start
        return (s, range.start)
    }

    /// 「这个月比上个月多花了 12%」比单看一个总数有用得多
    @ViewBuilder
    private var compareRow: some View {
        let prev = showIncome ? store.totals(from: prevRange.start, to: prevRange.end).income
                              : store.totals(from: prevRange.start, to: prevRange.end).expense
        if prev > 0 {
            let diff = focusTotal - prev
            let pct = diff / prev * 100
            let up = diff > 0
            HStack(spacing: 6) {
                Image(systemName: up ? "arrow.up.right" : "arrow.down.right")
                    .font(.system(size: 10, weight: .bold))
                Text(up ? "比上一期多" : "比上一期少")
                    .font(.system(size: 12))
                Text(Money.currency(abs(diff)))
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(String(format: "(%+.0f%%)", pct))
                    .font(.system(size: 11.5, design: .rounded))
                    .monospacedDigit()
                Spacer(minLength: 0)
                Text(prevLabel)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.ink3)
            }
            // 支出涨了用红、降了用绿；收入反过来
            .foregroundStyle((up != showIncome) ? Theme.expense : Theme.income)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(((up != showIncome) ? Theme.expense : Theme.income).opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var prevLabel: String {
        switch scopeIndex {
        case 0: return "对比前一天"
        case 1: return "对比上月"
        default: return "对比去年"
        }
    }

    private func tile(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Theme.ink3)
            Text(value)
                .font(.system(size: 14.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .cardStyle(padding: 0, radius: 14)
    }

    // MARK: 趋势

    private var buckets: [Bucket] {
        // 日视图按小时分桶：一天里「几点花的钱」比「这一天总共花了多少」有用得多
        if scopeIndex == 0 { return store.hourBuckets(on: anchor) }
        if scopeIndex == 1 { return store.dayBuckets(from: range.start, to: range.end) }
        let year = Fmt.cal.component(.year, from: anchor)
        return store.yearMonthBuckets(year: year)
    }

    private var chartTitle: String {
        switch scopeIndex {
        case 0: return "分时走势"
        case 1: return "每天走势"
        default: return "每月走势"
        }
    }

    @ViewBuilder
    private var chartCard: some View {
        let data = buckets
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(chartTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                if let peak = data.max(by: { value($0) < value($1) }), value(peak) > 0 {
                    Text("最高 " + (scopeIndex == 1 ? peak.label + "日" : peak.label))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.ink3)
                }
            }

            if data.isEmpty || data.allSatisfy({ value($0) <= 0 }) {
                emptyChart
            } else {
                Chart(data) { b in
                    BarMark(
                        x: .value("时间", b.label),
                        y: .value(showIncome ? "收入" : "支出", value(b))
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: showIncome
                                ? [Theme.income, Theme.income.opacity(0.45)]
                                : [Theme.expense, Theme.expense.opacity(0.45)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .cornerRadius(3)
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                        AxisGridLine().foregroundStyle(Theme.line.opacity(0.6))
                        AxisValueLabel()
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.ink3)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                        AxisGridLine().foregroundStyle(Theme.line.opacity(0.6))
                        AxisValueLabel {
                            if let d = v.as(Double.self) {
                                Text(compact(d))
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.ink3)
                            }
                        }
                    }
                }
                .frame(height: 148)
            }
        }
        .cardStyle()
    }

    private func value(_ b: Bucket) -> Double {
        showIncome ? b.income : b.expense
    }

    private func compact(_ v: Double) -> String {
        if v >= 10000 { return String(format: "%.1f万", v / 10000) }
        if v >= 1000 { return String(format: "%.0fk", v / 1000) }
        return String(format: "%.0f", v)
    }

    private var emptyChart: some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.bar")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(Theme.ink3)
            Text("这个范围还没有\(showIncome ? "收入" : "支出")")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.ink3)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 148)
    }

    // MARK: 排行

    private var rankingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(showIncome ? "收入" : "支出")构成")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text("\(cats.count) 个分类")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.ink3)
            }

            if cats.isEmpty {
                Text("还没有数据")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.ink3)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
            } else {
                VStack(spacing: 12) {
                    ForEach(cats.prefix(9)) { c in
                        rankRow(c)
                    }
                }
            }
        }
        .cardStyle()
    }

    private func rankRow(_ c: CatTotal) -> some View {
        let ratio = focusTotal > 0 ? c.amount / focusTotal : 0
        return HStack(spacing: 11) {
            EmojiBadge(emoji: c.emoji, tint: Tint.of(c.name), size: 34, font: 16)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(c.name)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Theme.ink)
                    Text("\(c.count) 笔")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ink3)
                    Spacer()
                    Text(String(format: "%.0f%%", ratio * 100))
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.ink2)
                    Text(Money.currency(c.amount))
                        .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink)
                        .frame(width: 74, alignment: .trailing)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.line.opacity(0.75))
                        Capsule()
                            .fill(Tint.of(c.name))
                            .frame(width: max(4, geo.size.width * ratio))
                    }
                }
                .frame(height: 5)
            }
        }
    }
}
