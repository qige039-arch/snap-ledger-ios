//
//  Models.swift
//  数据层：与现有 PWA 的 familysnap.v2 结构保持一致
//
//  刻意不用 SwiftData：同步引擎是手写的 LWW + 墓碑，需要按 id 做 upsert 和
//  精确控制 `at` 时间戳。SwiftData 的 @Attribute(.unique) 语义和这套合并逻辑
//  会互相打架。家庭账本几千条记录，JSON 文件足够快，而且能 1:1 移植已验证的
//  同步代码 —— 这是 v1 最重要的取舍。
//
//  ⚠️ 加字段必须手写 init(from:)，不能用合成的 Decodable：
//     合成版遇到旧 JSON 里没有的 key 会直接抛 keyNotFound，整个库解不出来，
//     用户看到的就是「升级之后账全没了」。decodeIfPresent 才是安全写法。
//

import Foundation
import Combine

// MARK: - 账本

/// 家庭账本里可以再分账本：日常、旅行、装修、生意……
/// 记录通过 `book` 字段归属，空串表示老数据（迁移时挂到默认账本）
struct LedgerBook: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var emoji: String
    var at: Double          // 最后修改时间，LWW 用
    var createdAt: Double

    init(id: String = LedgerBook.newId(),
         name: String,
         emoji: String = "🏠",
         at: Double = 1,
         createdAt: Double = Date().timeIntervalSince1970 * 1000) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.at = at
        self.createdAt = createdAt
    }

    static func newId() -> String {
        "b" + String(Int(Date().timeIntervalSince1970 * 1000), radix: 36)
            + String(UUID().uuidString.prefix(4)).lowercased()
    }

    /// 老数据迁移出来的那个账本。id 必须是固定值 —— 两台设备各自迁移时
    /// 才能对上同一个账本，不然同步过去就是两个空壳。
    static let defaultId = "b_family"

    /// 新建账本时的快捷模板
    static let presets: [(emoji: String, name: String)] = [
        ("🏠", "家庭账本"), ("✈️", "旅行"), ("🍜", "吃饭"), ("🎁", "人情"), ("🏢", "生意")
    ]
}

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
    var method: String    // 支付方式：支付宝 / 微信 / 银行卡 / 现金
    var note: String
    var member: String    // 成员的 FamilyMember.id
    var source: String    // "chat" / "ocr" / "intent" / "sync"
    var book: String      // 所属账本 LedgerBook.id

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
         source: String = "chat",
         book: String = "") {
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
        self.book = book
    }

    private enum CodingKeys: String, CodingKey {
        case id, ts, at, type, amount, category, emoji, merchant, method, note, member, source, book
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? LedgerRecord.newId()
        ts = try c.decodeIfPresent(Double.self, forKey: .ts) ?? 0
        at = try c.decodeIfPresent(Double.self, forKey: .at) ?? ts
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "expense"
        amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 0
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? "其他"
        emoji = try c.decodeIfPresent(String.self, forKey: .emoji) ?? "📦"
        merchant = try c.decodeIfPresent(String.self, forKey: .merchant) ?? ""
        method = try c.decodeIfPresent(String.self, forKey: .method) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        member = try c.decodeIfPresent(String.self, forKey: .member) ?? ""
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "chat"
        book = try c.decodeIfPresent(String.self, forKey: .book) ?? ""
    }

    static func newId() -> String {
        "r" + String(Int(Date().timeIntervalSince1970 * 1000), radix: 36)
            + String(UUID().uuidString.prefix(6)).lowercased()
    }

    var isIncome: Bool { type == "income" }
    var signedAmount: Double { isIncome ? amount : -amount }

    /// 列表里显示的主标题
    var title: String { merchant.isEmpty ? category : merchant }
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
    var kind: String      // "r" 记录 / "m" 成员 / "b" 账本
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
    var members: [FamilyMember] = []
    var tomb: [Tombstone] = []
    var books: [LedgerBook] = []
    var currentBook: String = ""
    var sync: SyncConfig? = nil

    init() {
        members = [FamilyMember(name: "我", emoji: "🙂")]
        books = [LedgerBook(id: LedgerBook.defaultId, name: "家庭账本", emoji: "🏠")]
        currentBook = LedgerBook.defaultId
    }

    private enum CodingKeys: String, CodingKey {
        case records, members, tomb, books, currentBook, sync
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        records = try c.decodeIfPresent([LedgerRecord].self, forKey: .records) ?? []
        members = try c.decodeIfPresent([FamilyMember].self, forKey: .members) ?? []
        tomb = try c.decodeIfPresent([Tombstone].self, forKey: .tomb) ?? []
        books = try c.decodeIfPresent([LedgerBook].self, forKey: .books) ?? []
        currentBook = try c.decodeIfPresent(String.self, forKey: .currentBook) ?? ""
        sync = try c.decodeIfPresent(SyncConfig.self, forKey: .sync)
    }

    /// 读盘后统一补齐：默认账本、默认成员、记录的账本归属
    mutating func normalize() {
        if books.isEmpty {
            books = [LedgerBook(id: LedgerBook.defaultId, name: "家庭账本", emoji: "🏠")]
        }
        if members.isEmpty {
            members = [FamilyMember(name: "我", emoji: "🙂")]
        }
        let fallback = books.first?.id ?? LedgerBook.defaultId
        if !books.contains(where: { $0.id == currentBook }) { currentBook = fallback }
        for i in records.indices {
            let b = records[i].book
            if b.isEmpty || !books.contains(where: { $0.id == b }) {
                records[i].book = fallback
            }
        }
        for i in members.indices where members[i].at <= 0 {
            members[i].at = 1
        }
    }
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
        var loaded = LedgerStore.load(from: url)
        loaded.normalize()
        db = loaded
    }

    // MARK: 持久化

    private static func load(from url: URL) -> LedgerDB {
        guard let data = try? Data(contentsOf: url) else { return LedgerDB() }
        guard var d = try? JSONDecoder().decode(LedgerDB.self, from: data) else {
            // 解不出来时千万别静默返回空库 —— 那会覆盖掉用户的账。
            // 把坏文件改名留档，至少还能人工救回来。
            let bak = url.deletingPathExtension().appendingPathExtension("broken.json")
            try? FileManager.default.removeItem(at: bak)
            try? FileManager.default.copyItem(at: url, to: bak)
            return LedgerDB()
        }
        for i in d.records.indices where d.records[i].at <= 0 {
            d.records[i].at = d.records[i].ts
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
        db.records.filter { inCurrentBook($0) }.sorted { $0.ts > $1.ts }
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

    func memberEmoji(_ id: String) -> String {
        db.members.first { $0.id == id }?.emoji ?? "🙂"
    }

    // MARK: 账本

    var books: [LedgerBook] {
        db.books.sorted { $0.createdAt < $1.createdAt }
    }

    var currentBookId: String { db.currentBook }

    var currentBook: LedgerBook? {
        db.books.first { $0.id == db.currentBook } ?? db.books.first
    }

    /// 记录归属哪个账本。老数据的 book 是空串，挂到第一个账本，
    /// 这样从 PWA 同步过来的记录也一定看得见，不会「消失」。
    func bookId(of r: LedgerRecord) -> String {
        if r.book.isEmpty { return db.books.first?.id ?? LedgerBook.defaultId }
        return r.book
    }

    func inCurrentBook(_ r: LedgerRecord) -> Bool {
        bookId(of: r) == currentBookId
    }

    func count(inBook id: String) -> Int {
        db.records.filter { bookId(of: $0) == id }.count
    }

    func switchBook(_ id: String) {
        guard db.books.contains(where: { $0.id == id }) else { return }
        guard db.currentBook != id else { return }
        db.currentBook = id
        persist()
    }

    @discardableResult
    func addBook(name: String, emoji: String) -> LedgerBook {
        let now = Date().timeIntervalSince1970 * 1000
        var b = LedgerBook(name: name.trimmingCharacters(in: .whitespaces).isEmpty ? "新账本" : name,
                           emoji: emoji.isEmpty ? "📒" : emoji,
                           at: now,
                           createdAt: now)
        b.at = now
        db.books.append(b)
        db.currentBook = b.id
        persist()
        SyncEngine.shared.dirty()
        return b
    }

    func renameBook(id: String, name: String, emoji: String) {
        guard let i = db.books.firstIndex(where: { $0.id == id }) else { return }
        let n = name.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { db.books[i].name = n }
        if !emoji.isEmpty { db.books[i].emoji = emoji }
        db.books[i].at = Date().timeIntervalSince1970 * 1000
        persist()
        SyncEngine.shared.dirty()
    }

    /// 删账本会连里面的记录一起删（带墓碑，另一台手机同样消失）。
    /// 最后一个账本不允许删 —— 否则整个界面没有落点。
    @discardableResult
    func deleteBook(id: String) -> Bool {
        guard db.books.count > 1 else { return false }
        let fallback = db.books.first?.id ?? LedgerBook.defaultId
        var doomed: [String] = []
        // 先把 id 收集出来，再一次性删。不能在 removeAll 的闭包里调 self.bookId：
        // 那会在 db.records 的写访问还没结束时再读 db.books，触发独占性检查崩溃。
        for r in db.records {
            let owner = r.book.isEmpty ? fallback : r.book
            if owner == id { doomed.append(r.id) }
        }
        if !doomed.isEmpty {
            let set = Set(doomed)
            db.records.removeAll { set.contains($0.id) }
            for rid in doomed { settleTomb(kind: "r", id: rid) }
        }
        db.books.removeAll { $0.id == id }
        settleTomb(kind: "b", id: id)
        if db.currentBook == id {
            db.currentBook = db.books.first?.id ?? LedgerBook.defaultId
        }
        persist()
        SyncEngine.shared.dirty()
        return true
    }

    // MARK: 写

    @discardableResult
    func add(_ record: LedgerRecord) -> LedgerRecord {
        var r = record
        if r.member.isEmpty { r.member = selfMemberId }
        if r.book.isEmpty { r.book = currentBookId }
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
                note: String? = nil,
                method: String? = nil,
                ts: Double? = nil,
                book: String? = nil) {
        guard let i = db.records.firstIndex(where: { $0.id == id }) else { return }
        if let v = amount { db.records[i].amount = v }
        if let v = category { db.records[i].category = v }
        if let v = emoji { db.records[i].emoji = v }
        if let v = type { db.records[i].type = v }
        if let v = note { db.records[i].note = v }
        if let v = method { db.records[i].method = v }
        if let v = ts { db.records[i].ts = v }
        if let v = book, !v.isEmpty { db.records[i].book = v }
        db.records[i].at = Date().timeIntervalSince1970 * 1000
        persist()
        SyncEngine.shared.dirty()
    }

    /// 换账本（在编辑页里可以把一笔挪到别的账本）
    func moveToBook(recordId: String, bookId: String) {
        guard let i = db.records.firstIndex(where: { $0.id == recordId }) else { return }
        db.records[i].book = bookId
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

    /// 改昵称/头像。at 必须跟着变，否则同步时会被对方的旧数据盖回去。
    func updateMember(id: String, name: String, emoji: String) {
        guard let i = db.members.firstIndex(where: { $0.id == id }) else { return }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { db.members[i].name = String(n.prefix(12)) }
        if !emoji.isEmpty { db.members[i].emoji = emoji }
        db.members[i].at = Date().timeIntervalSince1970 * 1000
        persist()
        SyncEngine.shared.dirty()
    }

    // MARK: 统计

    /// 同一时间范围内的收支合计
    func totals(from: Date, to: Date, member: String? = nil) -> (income: Double, expense: Double) {
        let lo = from.timeIntervalSince1970 * 1000
        let hi = to.timeIntervalSince1970 * 1000
        var inc = 0.0, exp = 0.0
        for r in db.records where r.ts >= lo && r.ts < hi {
            guard inCurrentBook(r) else { continue }
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
        return db.records
            .filter { $0.ts >= lo && $0.ts < hi && inCurrentBook($0) }
            .sorted { $0.ts > $1.ts }
    }

    /// 按月分组的汇总，返回 [(月起始日, 收入, 支出)]
    func monthlyTotals(in year: Int) -> [(month: Int, income: Double, expense: Double)] {
        let cal = Calendar.current
        var out: [(Int, Double, Double)] = Array(repeating: (0, 0, 0), count: 12)
        for r in db.records {
            guard inCurrentBook(r) else { continue }
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
