//
//  StatView.swift
//  统计：汇总网格 + 趋势图 + 分类分布
//
//  版式参考了成熟记账 App 的做法，但只借「层级」不借「密度」：
//
//  1. 汇总拆成 2×2 网格（支出 / 收入 / 结余 / 日均），一格一个数字。
//     一个大卡里塞三个数字，眼睛找不到落点；拆开后扫一眼就有结论。
//  2. 趋势图下面挂「最低 / 最高」两张小卡。柱状图告诉你形状，
//     极值告诉你「最该看的那一天是哪天」—— 这是列表和饼图都给不了的信息。
//  3. 分类行做成：彩色圆形图标 + 名字/金额 + 占比·笔数 + 同色进度条。
//     饼图在手机上小扇区几乎不可读，条形能直接比大小。
//
//  所有切换控件都用 CompactSeg（Text + contentShape + onTapGesture），
//  不用 Button/matchedGeometryEffect —— 那套在本项目里反复出现过「点了没反应」。
//

import SwiftUI
import Charts

struct StatView: View {
    @ObservedObject private var store = LedgerStore.shared

    @State private var scopeIndex = 1        // 0 日 / 1 月 / 2 年
    @State private var anchor = Date()

    @State private var series = 0            // 趋势：0 支出 / 1 收入 / 2 结余
    @State private var chartStyle = 0        // 0 柱状 / 1 曲线
    @State private var breakdownIncome = false
    @State private var sortByAmount = true

    private let scopeTitles = ["日", "月", "年"]
    private let seriesTitles = ["支出", "收入", "结余"]

    // MARK: - 区间

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

    private var balance: Double { totals.income - totals.expense }

    private var expenseCount: Int { records.filter { !$0.isIncome }.count }
    private var incomeCount: Int { records.filter { $0.isIncome }.count }

    private var days: Double {
        // 日均按已过去的天数算，否则月初第一天的数字会特别夸张
        let cal = Fmt.cal
        let now = Date()
        if now < range.start { return 1 }
        if now >= range.end {
            return Double(cal.dateComponents([.day], from: range.start, to: range.end).day ?? 1)
        }
        return Double(max(1, cal.dateComponents([.day], from: range.start, to: now).day ?? 1))
    }

    // MARK: - 视图

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(spacing: 12) {
                    summaryGrid
                    compareRow
                    trendCard
                    breakdownCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .animation(.easeOut(duration: 0.22), value: anchor)
        }
        .background(Theme.bg)
        .onChange(of: store.currentBookId) { _, _ in anchor = Date() }
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

    // MARK: - 汇总网格

    private var summaryGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                            GridItem(.flexible(), spacing: 10)],
                  spacing: 10) {
            StatCell(title: "支出",
                     value: Money.grouped(totals.expense),
                     color: Theme.expense,
                     note: "\(expenseCount) 笔")

            StatCell(title: "收入",
                     value: Money.grouped(totals.income),
                     color: Theme.income,
                     note: "\(incomeCount) 笔")

            StatCell(title: "结余",
                     value: Money.grouped(abs(balance)),
                     color: balance < 0 ? Theme.expense : Theme.ink,
                     sign: balance < 0 ? "-" : "")

            if scopeIndex == 0 {
                StatCell(title: "笔数",
                         value: "\(records.count)",
                         showsCurrency: false)
            } else {
                StatCell(title: "日均支出",
                         value: Money.grouped(totals.expense / days))
            }
        }
    }

    // MARK: - 与上一期对比

    private var prevRange: (start: Date, end: Date) {
        let cal = Fmt.cal
        let comp: Calendar.Component = scopeIndex == 0 ? .day : (scopeIndex == 1 ? .month : .year)
        let s = cal.date(byAdding: comp, value: -1, to: range.start) ?? range.start
        return (s, range.start)
    }

    /// 「这个月比上个月多花了 12%」比单看一个总数有用得多
    @ViewBuilder
    private var compareRow: some View {
        let prev = store.totals(from: prevRange.start, to: prevRange.end).expense
        if prev > 0 && totals.expense > 0 {
            let diff = totals.expense - prev
            let pct = diff / prev * 100
            let up = diff > 0
            let tone = up ? Theme.expense : Theme.income
            HStack(spacing: 6) {
                Image(systemName: up ? "arrow.up.right" : "arrow.down.right")
                    .font(.system(size: 10, weight: .bold))
                Text(up ? "支出比上一期多" : "支出比上一期少")
                    .font(.system(size: 12))
                Text("¥" + Money.grouped(abs(diff)))
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(String(format: "(%.0f%%)", abs(pct)))
                    .font(.system(size: 11.5, design: .rounded))
                    .monospacedDigit()
                Spacer(minLength: 0)
                Text(prevLabel)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.ink3)
            }
            .foregroundStyle(tone)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(tone.opacity(0.08),
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

    // MARK: - 趋势

    private var buckets: [Bucket] {
        // 日视图按小时分桶：一天里「几点花的钱」比「这一天总共花了多少」有用
        if scopeIndex == 0 { return store.hourBuckets(on: anchor) }
        if scopeIndex == 1 { return store.dayBuckets(from: range.start, to: range.end) }
        let year = Fmt.cal.component(.year, from: anchor)
        return store.yearMonthBuckets(year: year)
    }

    private func value(_ b: Bucket) -> Double {
        switch series {
        case 1: return b.income
        case 2: return b.income - b.expense
        default: return b.expense
        }
    }

    private var seriesName: String {
        switch series {
        case 1: return "收入"
        case 2: return "结余"
        default: return "支出"
        }
    }

    private var seriesColor: Color {
        switch series {
        case 1: return Theme.income
        case 2: return Theme.brand
        default: return Theme.expense
        }
    }

    private var barGradient: LinearGradient {
        LinearGradient(colors: [seriesColor, seriesColor.opacity(0.42)],
                       startPoint: .top, endPoint: .bottom)
    }

    private var areaGradient: LinearGradient {
        LinearGradient(colors: [seriesColor.opacity(0.26), seriesColor.opacity(0.015)],
                       startPoint: .top, endPoint: .bottom)
    }

    /// Y 轴上下留白：顶 18%，负值（结余）再往下 25%
    private var yLow: Double {
        let lo = buckets.map { value($0) }.min() ?? 0
        return lo < 0 ? lo * 1.25 : 0
    }

    private var yHigh: Double {
        let hi = buckets.map { value($0) }.max() ?? 0
        return hi <= 0 ? 1 : hi * 1.18
    }

    private var chartEmpty: Bool {
        buckets.isEmpty || buckets.allSatisfy { value($0) == 0 }
    }

    private var trendCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Text(seriesName + (series == 2 ? "走势" : "趋势"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 4)
                CompactSeg(titles: seriesTitles, index: $series, fill: seriesColor)
            }

            if chartEmpty {
                emptyChart
            } else {
                chart

                CompactSeg(titles: ["柱状", "曲线"], index: $chartStyle)
                    .frame(maxWidth: .infinity, alignment: .center)

                extremeRow
            }
        }
        .cardStyle()
    }

    private var chart: some View {
        Chart(buckets) { b in
            if chartStyle == 0 {
                BarMark(x: .value("时间", b.label),
                        y: .value("金额", value(b)))
                    .foregroundStyle(barGradient)
                    .cornerRadius(3)
            } else {
                AreaMark(x: .value("时间", b.label),
                         yStart: .value("底", yLow),
                         yEnd: .value("金额", value(b)))
                    .foregroundStyle(areaGradient)
                    .interpolationMethod(.catmullRom)

                LineMark(x: .value("时间", b.label),
                         y: .value("金额", value(b)))
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    .foregroundStyle(seriesColor)
            }
        }
        .chartYScale(domain: yLow...yHigh)
        .chartXAxis {
            // ⚠️ 字符串分类轴不认 desiredCount：不给具体值它会把 30 个日期全画上，
            // 挤成一条黑线。必须像下面这样显式给刻度。
            AxisMarks(values: xTicks) { v in
                AxisGridLine().foregroundStyle(Theme.line.opacity(0.55))
                AxisValueLabel {
                    if let s = v.as(String.self) {
                        Text(xText(s))
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.ink2)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                AxisGridLine().foregroundStyle(Theme.line.opacity(0.55))
                AxisValueLabel {
                    if let d = v.as(Double.self) {
                        Text(compact(d))
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.ink2)
                    }
                }
            }
        }
        // 绘图区铺一层极浅的同色底，柱子的「高度」更容易读，也更接近参考版式
        .chartPlotStyle { plot in
            plot.background(seriesColor.opacity(0.045))
        }
        .frame(height: 148)
    }

    /// X 轴刻度：等距挑 6 个
    ///
    /// 桶是字符串标签（"1"…"31" / "00"…"23" / "1月"…），Charts 对这类分类轴
    /// 不做自动抽稀，`desiredCount` 会被忽略，结果 30 个标签全画上去叠成一团。
    private var xTicks: [String] {
        let labels = buckets.map { $0.label }
        guard labels.count > 7 else { return labels }
        let want = 6
        let step = max(2, Int((Double(labels.count) / Double(want)).rounded()))
        var out: [String] = []
        var i = 0
        while i < labels.count {
            out.append(labels[i])
            i += step
        }
        return out
    }

    private func xText(_ s: String) -> String {
        switch scopeIndex {
        case 0: return s + "时"
        case 1: return s + "日"
        default: return s        // 年视图 label 已经是「5月」
        }
    }

    private func compact(_ v: Double) -> String {
        let abs_v = abs(v)
        if abs_v >= 10000 { return String(format: "%.1f万", v / 10000) }
        if abs_v >= 1000 { return String(format: "%.0fk", v / 1000) }
        return String(format: "%.0f", v)
    }

    private var emptyChart: some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.bar")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(Theme.ink3)
            Text("这个范围还没有\(seriesName)")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.ink3)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 148)
    }

    // MARK: - 极值

    private struct ExVal {
        let amount: Double
        let caption: String
    }

    /// 只统计有数的桶：把 0 算进「最低」会永远得到「某个没花钱的日子」
    private var extremePair: (low: ExVal, high: ExVal)? {
        let list = buckets.filter { value($0) != 0 }
        guard
            let lo = list.min(by: { value($0) < value($1) }),
            let hi = list.max(by: { value($0) < value($1) })
        else { return nil }
        return (ExVal(amount: value(lo), caption: caption(lo)),
                ExVal(amount: value(hi), caption: caption(hi)))
    }

    private func caption(_ b: Bucket) -> String {
        switch scopeIndex {
        case 0:
            return b.label + ":00"
        case 1:
            // key 形如 2026-10-09
            let parts = b.key.split(separator: "-")
            if parts.count == 3, let m = Int(parts[1]), let d = Int(parts[2]) {
                return "\(m)月\(d)日"
            }
            return b.label
        default:
            let y = Fmt.cal.component(.year, from: anchor)
            return "\(y)年" + b.label
        }
    }

    private func extremeTitle(_ high: Bool) -> String {
        switch scopeIndex {
        case 0: return high ? "最多的一小时" : "最少的一小时"
        case 1: return (high ? "单日最高" : "单日最低") + seriesName
        default: return high ? "最高的月份" : "最低的月份"
        }
    }

    private var singleUnitWord: String {
        switch scopeIndex {
        case 0: return "小时"
        case 1: return "日子"
        default: return "月份"
        }
    }

    @ViewBuilder
    private var extremeRow: some View {
        if let pair = extremePair {
            if pair.low.caption == pair.high.caption {
                // 整个范围只有一天有账：两张一模一样的卡没有任何信息量，合成一张
                extremeCell(title: "唯一有\(seriesName)的" + singleUnitWord,
                            amount: pair.high.amount,
                            caption: pair.high.caption)
            } else {
                HStack(spacing: 10) {
                    extremeCell(title: extremeTitle(false),
                                amount: pair.low.amount,
                                caption: pair.low.caption)
                    extremeCell(title: extremeTitle(true),
                                amount: pair.high.amount,
                                caption: pair.high.caption)
                }
            }
        }
    }

    private func extremeCell(title: String, amount: Double, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.ink3)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Text((amount < 0 ? "-¥" : "¥") + Money.grouped(abs(amount)))
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(amount < 0 ? Theme.expense : Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.68)

            Text(caption)
                .font(.system(size: 10))
                .foregroundStyle(Theme.ink3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Theme.card2,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - 分类分布

    private var breakdownTotal: Double {
        breakdownIncome ? totals.income : totals.expense
    }

    private var sortedCats: [CatTotal] {
        let base = store.categoryTotals(from: range.start, to: range.end, income: breakdownIncome)
        if sortByAmount {
            return base.sorted { $0.amount > $1.amount }
        }
        return base.sorted { $0.count > $1.count }
    }

    private var shownCats: [CatTotal] { Array(sortedCats.prefix(12)) }

    private var breakdownCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text((breakdownIncome ? "收入" : "支出") + "分布")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 4)
                CompactSeg(titles: ["支出", "收入"],
                           index: Binding(get: { breakdownIncome ? 1 : 0 },
                                          set: { breakdownIncome = ($0 == 1) }),
                           fill: breakdownIncome ? Theme.income : Theme.expense)
            }

            sortBar
                .padding(.top, 10)

            if shownCats.isEmpty {
                emptyBreakdown
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(shownCats.enumerated()), id: \.element.id) { i, c in
                        rankRow(c)
                        if i < shownCats.count - 1 {
                            Rectangle()
                                .fill(Theme.line)
                                .frame(height: 0.6)
                                .padding(.leading, 51)
                        }
                    }
                }
                .padding(.top, 2)
            }

            if sortedCats.count > shownCats.count {
                Text("还有 \(sortedCats.count - shownCats.count) 个分类没显示（金额较小）")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.ink3)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 10)
            }
        }
        .cardStyle()
    }

    private var sortBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 9.5, weight: .bold))
                Text(sortByAmount ? "占比 · 高→低" : "笔数 · 多→少")
                    .font(.system(size: 11.5, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(Theme.ink2)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Theme.card2, in: Capsule())
            .overlay {
                Capsule().strokeBorder(Theme.line, lineWidth: 0.7).allowsHitTesting(false)
            }
            .contentShape(Capsule())
            .onTapGesture {
                withAnimation(.easeOut(duration: 0.18)) { sortByAmount.toggle() }
            }

            Spacer(minLength: 4)

            Text("共 \(sortedCats.count) 个分类")
                .font(.system(size: 11))
                .foregroundStyle(Theme.ink3)
        }
    }

    private func rankRow(_ c: CatTotal) -> some View {
        let ratio = breakdownTotal > 0 ? c.amount / breakdownTotal : 0
        let tint = Tint.of(c.name)

        return HStack(alignment: .top, spacing: 11) {
            Text(c.emoji)
                .font(.system(size: 19))
                .frame(width: 40, height: 40)
                .background(tint.opacity(0.14), in: Circle())

            VStack(spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(c.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Text("¥" + Money.grouped(c.amount))
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                }

                HStack(spacing: 0) {
                    Text(String(format: "%.1f%%", ratio * 100))
                        .monospacedDigit()
                    Text(" · 共 \(c.count) 笔")
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.ink3)
                .frame(maxWidth: .infinity, alignment: .leading)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.line)
                        Capsule()
                            .fill(tint)
                            .frame(width: max(3, geo.size.width * ratio))
                    }
                }
                .frame(height: 4)
            }
        }
        .padding(.vertical, 10)
    }

    private var emptyBreakdown: some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.pie")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Theme.ink3)
            Text("这个范围还没有\(breakdownIncome ? "收入" : "支出")")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.ink3)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
    }
}
