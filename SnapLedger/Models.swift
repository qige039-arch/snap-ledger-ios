//
//  Models.swift
//  数据层：与现有 PWA 的 familysnap.v2 结构保持一致
//
//  刻意不用 SwiftData：同步引擎是手写的 LWW + 墓碑，需要按 id 做 upsert 和
//  精确控制 `at` 时间戳。SwiftData 的 @Attribute(.unique) 语义和这套合并逻辑
//  会互相打架。家庭账本几千条记录，JSON 文件足够快，而且能 1:1 移植已验证的
//  同步代码 —— 这是 v1 最重要的取舍。
//

import Foundation
import Combine

// MARK: - 记录

struct LedgerRecord: Codable, Identifiable, Hashable {
    var id: String
    var ts: Double        // 业务发生时间（毫秒）
    var at: Double        // 最后修改时间（毫秒），LWW 决胜用
    var type: String      // "expense" / "income"
    var amount: Double
    var category: String
    var emoji: String
    var merchant: String
    var method: String
    var note: String
    var member: String    // 成员的 FamilyMember.id
    var source: String    // "chat" / "ocr" / "intent" / "sync"

    init(id: String = LedgerRecord.newId(),
         ts: Double = Date().timeIntervalSince1970 * 1000,
         at: Double? = nil,
         type: String,
         amount: Double,
         category: String,
         emoji: String = "📦",
         merchant: String = "",
         method: String = "",
         note: String = "",
         member: String = "",
         source: String = "chat") {
        self.id = id
        self.ts = ts
        self.at = at ?? ts
        self.type = type
        self.amount = amount
        self.category = category
        self.emoji = emoji
        self.merchant = merchant
        self.method = method
        self.note = note
        self.member = member
        self.source = source
    }

    static func newId() -> String {
        "r" + String(Int(Date().timeIntervalSince1970 * 1000), radix: 36)
            + String(UUID().uuidString.prefix(6)).lowercased()
    }

    var isIncome: Bool { type == "income" }
    var signedAmount: Double { isIncome ? amount : -amount }
}

// MARK: - 成员

struct FamilyMember: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var emoji: String
    var at: Double

    init(id: String = "m" + UUID().uuidString.prefix(8).lowercased(),
         name: String,
         emoji: String = "🙂",
         at: Double = 1) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.at = at
    }
}

// MARK: - 墓碑

struct Tombstone: Codable, Hashable {
    var kind: String      // "r" / "m"
    var id: String
    var at: Double
}

// MARK: - 同步配置

struct SyncConfig: Codable {
    var code: String = ""
    var lastRev: Int = 0
    var pushedAt: Double = 0
    var lastSyncAt: Double = 0
    var selfMemberId: String = ""
    var remoteRecords: Int = 0
    var deviceId: String = ""

    var isOn: Bool { !code.isEmpty }
}

// MARK: - 整库

struct LedgerDB: Codable {
    var records: [LedgerRecord] = []
    var members: [FamilyMember] = [FamilyMember(name: "我", emoji: "🙂")]
    var tomb: [Tombstone] = []
    var sync: SyncConfig? = nil
}

// MARK: - Store

@MainActor
final class LedgerStore: ObservableObject {
    static let shared = LedgerStore()

    @Published private(set) var db: LedgerDB

    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("ledger.json")
        fileURL = url
        db = LedgerStore.load(from: url)
    }

    // MARK: 持久化

    private static func load(from url: URL) -> LedgerDB {
        guard let data = try? Data(contentsOf: url) else { return LedgerDB() }
        guard var d = try? JSONDecoder().decode(LedgerDB.self, from: data) else { return LedgerDB() }
        // 老数据补齐 at
        for i in d.records.indices where d.records[i].at == 0 {
            d.records[i].at = d.records[i].ts
        }
        for i in d.members.indices where d.members[i].at == 0 {
            d.members[i].at = 1
        }
        return d
    }

    /// 立即原子写盘。同步引擎与记账都在主线程，直接写即可。
    func persist() {
        let snapshot = db
        let url = fileURL
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: url, options: .atomic)
        } catch {
            print("[store] 写盘失败: \(error)")
        }
    }

    /// 攒一下再写，避免连续编辑时反复落盘
    func quietPersist() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.persist() }
        }
    }

    /// 同步引擎合并时需要对整个库做原地修改
    func mutate(_ block: (inout LedgerDB) -> Void) {
        block(&db)
    }

    // MARK: 读

    var sortedRecords: [LedgerRecord] {
        db.records.sorted { $0.ts > $1.ts }
    }

    var selfMemberId: String {
        if let id = db.sync?.selfMemberId, !id.isEmpty { return id }
        return db.members.first?.id ?? ""
    }

    var selfMember: FamilyMember? {
        db.members.first { $0.id == selfMemberId }
    }

    func memberName(_ id: String) -> String {
        db.members.first { $0.id == id }?.name ?? (id.isEmpty ? "我" : "成员")
    }

    // MARK: 写

    @discardableResult
    func add(_ record: LedgerRecord) -> LedgerRecord {
        var r = record
        if r.member.isEmpty { r.member = selfMemberId }
        r.at = Date().timeIntervalSince1970 * 1000
        db.records.append(r)
        persist()
        SyncEngine.shared.dirty()
        return r
    }

    func update(id: String,
                amount: Double? = nil,
                category: String? = nil,
                emoji: String? = nil,
                type: String? = nil,
                note: String? = nil) {
        guard let i = db.records.firstIndex(where: { $0.id == id }) else { return }
        if let v = amount { db.records[i].amount = v }
        if let v = category { db.records[i].category = v }
        if let v = emoji { db.records[i].emoji = v }
        if let v = type { db.records[i].type = v }
        if let v = note { db.records[i].note = v }
        db.records[i].at = Date().timeIntervalSince1970 * 1000
        persist()
        SyncEngine.shared.dirty()
    }

    func delete(id: String) {
        guard let i = db.records.firstIndex(where: { $0.id == id }) else { return }
        db.records.remove(at: i)
        settleTomb(kind: "r", id: id)
        persist()
        SyncEngine.shared.dirty()
    }

    /// 删除必须留墓碑，否则另一台手机会把记录同步回来
    func settleTomb(kind: String, id: String) {
        if db.tomb.contains(where: { $0.kind == kind && $0.id == id }) { return }
        db.tomb.append(Tombstone(kind: kind, id: id, at: Date().timeIntervalSince1970 * 1000))
        if db.tomb.count > 3000 { db.tomb = Array(db.tomb.suffix(3000)) }
    }

    /// 撤销删除：撤掉墓碑、把记录放回去。
    /// 必须刷新 at（= 本次修改时间），否则同步时 LWW 会把这条当成旧数据，
    /// 被另一台手机上的墓碑再删一次。
    func restore(_ record: LedgerRecord) {
        db.tomb.removeAll { $0.kind == "r" && $0.id == record.id }
        guard !db.records.contains(where: { $0.id == record.id }) else {
            persist()
            SyncEngine.shared.dirty()
            return
        }
        var r = record
        r.at = Date().timeIntervalSince1970 * 1000
        db.records.append(r)
        persist()
        SyncEngine.shared.dirty()
    }

    func setMembers(_ list: [FamilyMember]) {
        db.members = list
        persist()
    }

    // MARK: 统计

    /// 同一时间范围内的收支合计
    func totals(from: Date, to: Date, member: String? = nil) -> (income: Double, expense: Double) {
        let lo = from.timeIntervalSince1970 * 1000
        let hi = to.timeIntervalSince1970 * 1000
        var inc = 0.0, exp = 0.0
        for r in db.records where r.ts >= lo && r.ts < hi {
            if let m = member, !m.isEmpty, r.member != m { continue }
            if r.isIncome { inc += r.amount } else { exp += r.amount }
        }
        return (inc, exp)
    }

    /// 按天分组（当天起的账单列表用）
    func records(on day: Date) -> [LedgerRecord] {
        let cal = Calendar.current
        let lo = cal.startOfDay(for: day).timeIntervalSince1970 * 1000
        let hi = lo + 86400 * 1000
        return db.records.filter { $0.ts >= lo && $0.ts < hi }.sorted { $0.ts > $1.ts }
    }

    /// 按月分组的汇总，返回 [(月起始日, 收入, 支出)]
    func monthlyTotals(in year: Int) -> [(month: Int, income: Double, expense: Double)] {
        let cal = Calendar.current
        var out: [(Int, Double, Double)] = Array(repeating: (0, 0, 0), count: 12)
        for r in db.records {
            let d = Date(timeIntervalSince1970: r.ts / 1000)
            let comps = cal.dateComponents([.year, .month], from: d)
            guard comps.year == year, let m = comps.month, m >= 1, m <= 12 else { continue }
            if r.isIncome { out[m - 1].1 += r.amount } else { out[m - 1].2 += r.amount }
        }
        return out.enumerated().map { (month: $0.offset + 1, income: $0.element.1, expense: $0.element.2) }
    }
}

// MARK: - 金额格式化

enum Money {
    static func plain(_ v: Double) -> String {
        if v == v.rounded() { return String(format: "%.0f", v) }
        return String(format: "%.2f", v)
    }

    /// 带符号，用于结余显示（不能取绝对值，否则 -320 会显示成 320）
    static func signed(_ v: Double) -> String {
        let s = plain(abs(v))
        if v > 0 { return "+" + s }
        if v < 0 { return "-" + s }
        return s
    }

    static func currency(_ v: Double) -> String { "¥" + plain(v) }
}
