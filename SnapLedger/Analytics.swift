//
//  Analytics.swift
//  账本 / 统计页用的聚合计算
//
//  没写进 Models.swift：那里是数据与持久化，这里是视图需要的一次性聚合，
//  分开放以后改展示逻辑不用碰存储。
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

extension LedgerStore {

    /// 左闭右开区间内的记录，按时间倒序
    func records(from: Date, to: Date) -> [LedgerRecord] {
        let lo = from.timeIntervalSince1970 * 1000
        let hi = to.timeIntervalSince1970 * 1000
        return db.records.filter { $0.ts >= lo && $0.ts < hi }.sorted { $0.ts > $1.ts }
    }

    func count(from: Date, to: Date) -> Int {
        let lo = from.timeIntervalSince1970 * 1000
        let hi = to.timeIntervalSince1970 * 1000
        return db.records.filter { $0.ts >= lo && $0.ts < hi }.count
    }

    /// 分类合计，金额降序
    func categoryTotals(from: Date, to: Date, income: Bool) -> [CatTotal] {
        var map: [String: (emoji: String, amount: Double, count: Int)] = [:]
        for r in db.records where r.isIncome == income {
            let ms = r.ts
            guard ms >= from.timeIntervalSince1970 * 1000, ms < to.timeIntervalSince1970 * 1000 else { continue }
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
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            return DayGroup(key: f.string(from: day), day: day, records: map[day] ?? [])
        }
    }

    /// 按天分桶（用于柱状趋势），范围内每一天都出一个桶，没有账的那天是 0
    func dayBuckets(from: Date, to: Date) -> [Bucket] {
        let cal = Fmt.cal
        var map: [Date: (Double, Double)] = [:]
        for r in db.records {
            let ms = r.ts
            guard ms >= from.timeIntervalSince1970 * 1000, ms < to.timeIntervalSince1970 * 1000 else { continue }
            let day = cal.startOfDay(for: Date(timeIntervalSince1970: ms / 1000))
            var cur = map[day] ?? (0, 0)
            if r.isIncome { cur.0 += r.amount } else { cur.1 += r.amount }
            map[day] = cur
        }
        var out: [Bucket] = []
        var cur = cal.startOfDay(for: from)
        let df = DateFormatter()
        df.dateFormat = "d"
        let kf = DateFormatter()
        kf.dateFormat = "yyyy-MM-dd"
        while cur < to {
            let v = map[cur] ?? (0, 0)
            out.append(Bucket(key: kf.string(from: cur),
                              label: df.string(from: cur),
                              income: v.0,
                              expense: v.1))
            guard let next = cal.date(byAdding: .day, value: 1, to: cur) else { break }
            cur = next
        }
        return out
    }

    /// 某一年的 12 个月桶
    func yearMonthBuckets(year: Int) -> [Bucket] {
        let rows = monthlyTotals(in: year)
        return rows.map {
            Bucket(key: "\(year)-\($0.month)", label: "\($0.month)月",
                   income: $0.income, expense: $0.expense)
        }
    }
}
