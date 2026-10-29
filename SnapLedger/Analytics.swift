//
//  Analytics.swift
//  账本 / 统计页用的聚合计算
//
//  没写进 Models.swift：那里是数据与持久化，这里是视图需要的一次性聚合，
//  分开放以后改展示逻辑不用碰存储。
//
//  ⚠️ 所有聚合都必须过 `inCurrentBook`。多账本以后，漏掉一处就会出现
//     「切到旅行账本，统计里还混着家里的开销」这种最难查的 bug。
//

import Foundation

struct CatTotal: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let emoji: String
    let amount: Double
    let count: Int
}

struct Bucket: Identifiable, Hashable {
    var id: String { key }
    let key: String
    let label: String
    let income: Double
    let expense: Double
}

struct DayGroup: Identifiable, Hashable {
    var id: String { key }
    let key: String
    let day: Date
    let records: [LedgerRecord]

    var expense: Double { records.filter { !$0.isIncome }.reduce(0) { $0 + $1.amount } }
    var income: Double { records.filter { $0.isIncome }.reduce(0) { $0 + $1.amount } }
}

/// 月历的一格
struct HeatDay: Identifiable, Hashable {
    var id: String { key }
    let key: String          // yyyy-MM-dd
    let day: Date
    let dayNumber: Int
    let expense: Double
    let income: Double
    let count: Int
    let inMonth: Bool        // 前后补位的日子是 false
    let level: Int           // 0 无 / 1~4 由浅到深
}

extension LedgerStore {

    /// 左闭右开区间内的记录，按时间倒序
    func records(from: Date, to: Date) -> [LedgerRecord] {
        let lo = from.timeIntervalSince1970 * 1000
        let hi = to.timeIntervalSince1970 * 1000
        return db.records.filter { $0.ts >= lo && $0.ts < hi && inCurrentBook($0) }
            .sorted { $0.ts > $1.ts }
    }

    func count(from: Date, to: Date) -> Int {
        let lo = from.timeIntervalSince1970 * 1000
        let hi = to.timeIntervalSince1970 * 1000
        return db.records.filter { $0.ts >= lo && $0.ts < hi && inCurrentBook($0) }.count
    }

    /// 分类合计，金额降序
    func categoryTotals(from: Date, to: Date, income: Bool) -> [CatTotal] {
        let lo = from.timeIntervalSince1970 * 1000
        let hi = to.timeIntervalSince1970 * 1000
        var map: [String: (emoji: String, amount: Double, count: Int)] = [:]
        for r in db.records where r.isIncome == income {
            let ms = r.ts
            guard ms >= lo, ms < hi, inCurrentBook(r) else { continue }
            let cur = map[r.category] ?? (r.emoji, 0, 0)
            map[r.category] = (cur.emoji, cur.amount + r.amount, cur.count + 1)
        }
        return map
            .map { CatTotal(name: $0.key, emoji: $0.value.emoji, amount: $0.value.amount, count: $0.value.count) }
            .sorted { $0.amount > $1.amount }
    }

    /// 按天分组，日期降序
    func dayGroups(from: Date, to: Date) -> [DayGroup] {
        let list = records(from: from, to: to)
        let cal = Fmt.cal
        var order: [Date] = []
        var map: [Date: [LedgerRecord]] = [:]
        for r in list {
            let day = cal.startOfDay(for: Date(timeIntervalSince1970: r.ts / 1000))
            if map[day] == nil { order.append(day) }
            map[day, default: []].append(r)
        }
        return order.map { day in
            DayGroup(key: Fmt.key(day), day: day, records: map[day] ?? [])
        }
    }

    /// 按天分桶（用于柱状趋势），范围内每一天都出一个桶，没有账的那天是 0
    func dayBuckets(from: Date, to: Date) -> [Bucket] {
        let cal = Fmt.cal
        var map: [Date: (Double, Double)] = [:]
        let lo = from.timeIntervalSince1970 * 1000
        let hi = to.timeIntervalSince1970 * 1000
        for r in db.records {
            let ms = r.ts
            guard ms >= lo, ms < hi, inCurrentBook(r) else { continue }
            let day = cal.startOfDay(for: Date(timeIntervalSince1970: ms / 1000))
            var cur = map[day] ?? (0, 0)
            if r.isIncome { cur.0 += r.amount } else { cur.1 += r.amount }
            map[day] = cur
        }
        var out: [Bucket] = []
        var cur = cal.startOfDay(for: from)
        while cur < to {
            let v = map[cur] ?? (0, 0)
            out.append(Bucket(key: Fmt.key(cur),
                              label: Fmt.dayNumber(cur),
                              income: v.0,
                              expense: v.1))
            guard let next = cal.date(byAdding: .day, value: 1, to: cur) else { break }
            cur = next
        }
        return out
    }

    /// 一天 24 个小时的桶（日视图的「分时走势」）
    func hourBuckets(on day: Date) -> [Bucket] {
        let cal = Fmt.cal
        let start = cal.startOfDay(for: day)
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return [] }
        let lo = start.timeIntervalSince1970 * 1000
        let hi = end.timeIntervalSince1970 * 1000
        var arr = Array(repeating: (0.0, 0.0), count: 24)
        for r in db.records {
            let ms = r.ts
            guard ms >= lo, ms < hi, inCurrentBook(r) else { continue }
            let h = cal.component(.hour, from: Date(timeIntervalSince1970: ms / 1000))
            guard h >= 0, h < 24 else { continue }
            if r.isIncome { arr[h].0 += r.amount } else { arr[h].1 += r.amount }
        }
        return (0..<24).map { i in
            Bucket(key: "h\(i)", label: String(format: "%02d", i),
                   income: arr[i].0, expense: arr[i].1)
        }
    }

    /// 某一年的 12 个月桶
    func yearMonthBuckets(year: Int) -> [Bucket] {
        monthlyTotals(in: year).map {
            Bucket(key: "\(year)-\($0.month)", label: "\($0.month)月",
                   income: $0.income, expense: $0.expense)
        }
    }

    // MARK: 月历

    /// 整月网格，含前后补位，行数按实际需要算（4~6 行）
    ///
    /// 分档用当月「有支出的那些天」的分位数，而不是绝对金额：
    /// 有人一个月花三千、有人花三十万，固定阈值永远有一半格子是同一个颜色。
    func monthHeat(monthOf anchor: Date) -> [HeatDay] {
        let cal = Fmt.cal
        let comps = cal.dateComponents([.year, .month], from: anchor)
        guard let monthStart = cal.date(from: comps),
              let nextMonth = cal.date(byAdding: .month, value: 1, to: monthStart),
              let daysInMonth = cal.range(of: .day, in: .month, for: monthStart)?.count
        else { return [] }

        var map: [Int: (exp: Double, inc: Double, n: Int)] = [:]
        for r in db.records {
            let d = Date(timeIntervalSince1970: r.ts / 1000)
            guard d >= monthStart, d < nextMonth, inCurrentBook(r) else { continue }
            let day = cal.component(.day, from: d)
            var cur = map[day] ?? (0, 0, 0)
            if r.isIncome { cur.inc += r.amount } else { cur.exp += r.amount }
            cur.n += 1
            map[day] = cur
        }

        let sorted = map.values.map { $0.exp }.filter { $0 > 0 }.sorted()
        let threshold = Self.heatThresholds(sorted)

        let lead = (cal.component(.weekday, from: monthStart) - cal.firstWeekday + 7) % 7
        let rows = Int(ceil(Double(lead + daysInMonth) / 7.0))
        let cells = rows * 7
        guard let gridStart = cal.date(byAdding: .day, value: -lead, to: monthStart) else { return [] }

        var out: [HeatDay] = []
        out.reserveCapacity(cells)
        let blank: (exp: Double, inc: Double, n: Int) = (0, 0, 0)
        for i in 0..<cells {
            guard let d = cal.date(byAdding: .day, value: i, to: gridStart) else { continue }
            let num = cal.component(.day, from: d)
            let inMonth = d >= monthStart && d < nextMonth
            let v = inMonth ? (map[num] ?? blank) : blank
            out.append(HeatDay(key: Fmt.key(d),
                               day: d,
                               dayNumber: num,
                               expense: v.exp,
                               income: v.inc,
                               count: v.n,
                               inMonth: inMonth,
                               level: Self.heatLevel(v.exp, threshold)))
        }
        return out
    }

    /// 样本太少时用绝对阈值兜底，否则分位数在 3 天记录上会退化成随便分
    private static func heatThresholds(_ sorted: [Double]) -> [Double] {
        guard sorted.count >= 6 else { return [80, 300, 800] }
        let last = sorted.count - 1
        func q(_ p: Double) -> Double {
            let i = Int((Double(last) * p).rounded())
            return sorted[min(max(i, 0), last)]
        }
        return [q(0.35), q(0.68), q(0.90)]
    }

    private static func heatLevel(_ v: Double, _ t: [Double]) -> Int {
        if v <= 0 { return 0 }
        if v <= t[0] { return 1 }
        if v <= t[1] { return 2 }
        if v <= t[2] { return 3 }
        return 4
    }
}
