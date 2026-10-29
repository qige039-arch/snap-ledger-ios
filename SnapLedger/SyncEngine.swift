//
//  SyncEngine.swift
//  家庭账本同步 —— 从 sync.js 移植
//
//  协议（不要改，改了就和 PWA 不互通了）：
//    POST /api/sync  { code, lastRev, deviceId, entities: [...] }
//    → { rev, reset, accepted, entities: [...] }
//
//  四个关键设计：
//  1. 本地永远是完整账本，云端只是交换站。没网照常记账。
//  2. 上传走 pushedAt 水位线（回退 15 分钟容忍时钟抖动），下载走服务端单调 rev。
//  3. 冲突按实体 at 时间戳 Last-Write-Wins；删除靠墓碑传播，否则对方会把记录同步回来。
//  4. 服务端数据丢了（重新发布 / 清库）→ reset=true，游标和水位线归零，下一轮全量补传。
//
//  好处：App 和 PWA 可以同时连同一个家庭码，两台手机上的账本混着用也没问题。
//

import Foundation
import Combine

// MARK: - 配置

enum APIConfig {
    /// 服务地址。默认是当前发布出来的临时域名，重新发布会变。因为要上架/长期自用，
    /// 建议后面迁到自己的一台轻量云主机，不要长期依赖它。
    static let defaultBase = "https://snap-ledger-70556.app.workbuddy.host"

    /// 发布链接上的 `?sharecode=`。网关要求**每一个**请求都带上它，否则一律 403。
    /// 注意：它不是 6 位家庭码，两者完全不同（一个是 10 位，一个是 6 位），
    /// 早先「用家庭码顶替 sharecode」的写法正是创建家庭时报 403 的直接原因。
    static let defaultGate = "JSXYDYYTKI"

    private static let baseKey = "snap.api.base"
    private static let gateKey = "snap.api.gate"

    /// 允许在「我的 → 服务设置」里改，改完立刻生效，不用重新编译（免费签名 7 天到期前很关键）
    static var baseString: String {
        let v = UserDefaults.standard.string(forKey: baseKey) ?? ""
        return v.isEmpty ? defaultBase : v
    }

    static var gate: String {
        let v = UserDefaults.standard.string(forKey: gateKey) ?? ""
        return v.isEmpty ? defaultGate : v
    }

    static var base: URL { URL(string: baseString) ?? URL(string: defaultBase)! }

    static var isCustom: Bool {
        baseString != defaultBase || gate != defaultGate
    }

    static func save(base: String, gate: String) {
        let b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let g = gate.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(b == defaultBase ? "" : b, forKey: baseKey)
        UserDefaults.standard.set(g == defaultGate ? "" : g, forKey: gateKey)
    }

    static func reset() {
        UserDefaults.standard.set("", forKey: baseKey)
        UserDefaults.standard.set("", forKey: gateKey)
    }
}

// MARK: - 报文

struct SyncEntity: Codable {
    var kind: String = ""     // "r" 记录 / "m" 成员 / "b" 账本
    var id: String = ""
    var at: Double? = nil
    var ts: Double? = nil
    var type: String? = nil
    var amount: Double? = nil
    var category: String? = nil
    var emoji: String? = nil
    var merchant: String? = nil
    var method: String? = nil
    var note: String? = nil
    var member: String? = nil
    var source: String? = nil
    var book: String? = nil       // 记录所属账本
    var name: String? = nil       // 成员 / 账本名
    var deleted: Int? = nil
    var r: Int? = nil

    enum CodingKeys: String, CodingKey {
        case kind, id, at, ts, type, amount, category, emoji, merchant
        case method, note, member, source, book, name, deleted
        case r = "_r"
    }
}

struct SyncRequest: Encodable {
    var code: String
    var lastRev: Int
    var deviceId: String
    var entities: [SyncEntity]
}

struct SyncResponse: Decodable {
    var type: String?
    var rev: Int?
    var reset: Bool?
    var accepted: Int?
    var firstRev: Int?
    var entities: [SyncEntity]?
}

struct FamilyResponse: Decodable {
    var type: String?
    var code: String?
    var rev: Int?
    var message: String?
}

enum SyncError: LocalizedError {
    case server(String)
    case badResponse
    case offline
    case gate

    var errorDescription: String? {
        switch self {
        case .server(let m): return m
        case .badResponse: return "服务器返回异常"
        case .offline: return "没有网络"
        case .gate: return "服务拒绝了请求（403）：入口分享码不对或已失效。到「我的 → 服务设置」贴上新的分享码。"
        }
    }
}

// MARK: - 状态

enum SyncState: Equatable {
    case off, idle, syncing, error

    var label: String {
        switch self {
        case .off: return "未连接"
        case .idle: return "已同步"
        case .syncing: return "同步中"
        case .error: return "同步失败"
        }
    }
}

// MARK: - 引擎

@MainActor
final class SyncEngine: ObservableObject {
    static let shared = SyncEngine()

    @Published private(set) var state: SyncState = .off
    @Published private(set) var message: String = ""

    /// 对方刚记的账，交给聊天界面播报
    var onAnnounce: ((LedgerRecord) -> Void)?

    private var quietSyncs = 0
    private var pollTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var running = false

    private let store = LedgerStore.shared

    private init() {}

    // MARK: 生命周期

    func bootstrap() {
        if store.db.sync?.isOn == true {
            state = .idle
            startPolling()
            schedule(0.8)
        } else {
            state = .off
        }
    }

    func dirty() {
        guard store.db.sync?.isOn == true else { return }
        schedule(1.5)
    }

    func now() {
        Task { await run() }
    }

    private func schedule(_ delay: TimeInterval) {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.run()
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 45_000_000_000)
                guard !Task.isCancelled else { break }
                await self?.run()
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        debounceTask?.cancel()
        debounceTask = nil
    }

    // MARK: 主流程

    private func run() async {
        guard store.db.sync?.isOn == true else {
            state = .off
            return
        }
        if running { return }        // 单飞：避免两次 sync 交叉写
        running = true
        state = .syncing
        defer { running = false }

        do {
            for _ in 0..<3 {
                guard let cfg = store.db.sync else { break }
                let payload = collect()
                let req = SyncRequest(code: cfg.code,
                                      lastRev: cfg.lastRev,
                                      deviceId: cfg.deviceId,
                                      entities: payload)
                let res: SyncResponse = try await post("/api/sync", req)

                if res.reset == true {
                    // 服务端重建过，游标和水位线一起归零，下一轮全量补传
                    store.mutate { d in
                        d.sync?.lastRev = 0
                        d.sync?.pushedAt = 0
                    }
                    quietSyncs = max(quietSyncs, 1)
                }

                let fresh = apply(res.entities ?? [])

                let topAt = payload.compactMap { $0.at }.max() ?? 0
                store.mutate { d in
                    // 不能写成 d.sync?.pushedAt = max(d.sync?.pushedAt ?? 0, topAt)：
                    // 左边是 inout 访问，右边同时读同一个属性，Swift 独占性检查会报
                    // "overlapping accesses to 'd.sync'"。先取出来再写。
                    let prevPushed = d.sync?.pushedAt ?? 0
                    d.sync?.lastRev = res.rev ?? 0
                    d.sync?.pushedAt = max(prevPushed, topAt)
                    d.sync?.lastSyncAt = Date().timeIntervalSince1970 * 1000
                }
                store.persist()

                if quietSyncs == 0 {
                    announce(fresh)
                }

                if res.reset != true { break }
            }
            if quietSyncs > 0 { quietSyncs -= 1 }
            state = .idle
            message = ""
        } catch {
            let ns = error as NSError
            let offline = (ns.domain == NSURLErrorDomain)
            state = offline ? .idle : .error
            message = offline ? "没有网络，稍后自动重试" : error.localizedDescription
        }
    }

    /// 对方刚记的账，在聊天里说一声（30 分钟内的、不是自己记的，最多 3 条）
    private func announce(_ fresh: [LedgerRecord]) {
        guard let cb = onAnnounce else { return }
        let cutoff = Date().timeIntervalSince1970 * 1000 - 30 * 60 * 1000
        let mine = store.selfMemberId
        fresh.filter { $0.at > cutoff && $0.member != mine }
            .sorted { $0.at > $1.at }
            .prefix(3)
            .forEach { cb($0) }
    }

    // MARK: 上传

    private func collect() -> [SyncEntity] {
        let db = store.db
        let watermark = db.sync?.pushedAt ?? 0
        let line = watermark > 0 ? watermark - 15 * 60 * 1000 : 0
        var out: [SyncEntity] = []

        for r in db.records where watermark == 0 || r.at >= line {
            var e = SyncEntity()
            e.kind = "r"
            e.id = r.id
            e.at = r.at
            e.ts = r.ts
            e.type = r.type
            e.amount = r.amount
            e.category = r.category
            e.emoji = r.emoji
            e.merchant = r.merchant
            e.method = r.method
            e.note = r.note
            e.member = r.member
            e.source = r.source
            e.book = r.book
            out.append(e)
        }

        // 账本本身也要同步，否则另一台手机上只有「家庭账本」，记录会被挂到默认账本里
        for b in db.books {
            var e = SyncEntity()
            e.kind = "b"
            e.id = b.id
            e.at = b.at
            e.ts = b.createdAt
            e.name = b.name
            e.emoji = b.emoji
            out.append(e)
        }

        for m in db.members {
            var e = SyncEntity()
            e.kind = "m"
            e.id = m.id
            e.at = m.at
            e.name = m.name
            e.emoji = m.emoji
            out.append(e)
        }

        for t in db.tomb.suffix(800) {
            var e = SyncEntity()
            e.kind = t.kind
            e.id = t.id
            e.at = t.at
            e.deleted = 1
            if t.kind == "r" {
                e.ts = t.at
                e.type = "expense"
                e.amount = 0
                e.category = ""
                e.emoji = ""
                e.merchant = ""
                e.method = ""
                e.note = ""
                e.member = ""
                e.source = ""
            }
            out.append(e)
        }
        return out
    }

    // MARK: 合并

    /// 返回本地没有过的新记录（用于聊天播报）
    private func apply(_ list: [SyncEntity]) -> [LedgerRecord] {
        guard !list.isEmpty else { return [] }

        var fresh: [LedgerRecord] = []
        store.mutate { db in
            for e in list {
                // 账本
                if e.kind == "b" {
                    if e.deleted == 1 {
                        db.books.removeAll { $0.id == e.id }
                        if !db.tomb.contains(where: { $0.kind == "b" && $0.id == e.id }) {
                            db.tomb.append(Tombstone(kind: "b", id: e.id,
                                                     at: e.at ?? Date().timeIntervalSince1970 * 1000))
                        }
                    } else if let i = db.books.firstIndex(where: { $0.id == e.id }) {
                        if (e.at ?? 0) > db.books[i].at {
                            db.books[i].name = e.name ?? db.books[i].name
                            db.books[i].emoji = e.emoji ?? db.books[i].emoji
                            db.books[i].at = e.at ?? db.books[i].at
                        }
                    } else {
                        db.books.append(LedgerBook(id: e.id,
                                                   name: e.name ?? "账本",
                                                   emoji: e.emoji ?? "📒",
                                                   at: e.at ?? 1,
                                                   createdAt: e.ts ?? (e.at ?? 1)))
                    }
                    continue
                }

                if e.kind == "m" {
                    if e.deleted == 1 {
                        db.members.removeAll { $0.id == e.id }
                    } else if let i = db.members.firstIndex(where: { $0.id == e.id }) {
                        if (e.at ?? 0) > db.members[i].at {
                            db.members[i].name = e.name ?? db.members[i].name
                            db.members[i].emoji = e.emoji ?? db.members[i].emoji
                            db.members[i].at = e.at ?? db.members[i].at
                        }
                    } else {
                        db.members.append(FamilyMember(id: e.id,
                                                       name: e.name ?? "成员",
                                                       emoji: e.emoji ?? "🙂",
                                                       at: e.at ?? 1))
                    }
                    continue
                }

                if e.deleted == 1 {
                    db.records.removeAll { $0.id == e.id }
                    if !db.tomb.contains(where: { $0.kind == "r" && $0.id == e.id }) {
                        db.tomb.append(Tombstone(kind: "r", id: e.id,
                                                 at: e.at ?? Date().timeIntervalSince1970 * 1000))
                    }
                    continue
                }

                let rec = LedgerRecord(id: e.id,
                                       ts: e.ts ?? e.at ?? Date().timeIntervalSince1970 * 1000,
                                       at: e.at ?? Date().timeIntervalSince1970 * 1000,
                                       type: e.type == "income" ? "income" : "expense",
                                       amount: e.amount ?? 0,
                                       category: e.category ?? "其他",
                                       emoji: e.emoji ?? "📦",
                                       merchant: e.merchant ?? "",
                                       method: e.method ?? "",
                                       note: e.note ?? "",
                                       member: e.member ?? "",
                                       source: e.source ?? "sync",
                                       book: e.book ?? "")

                if let i = db.records.firstIndex(where: { $0.id == e.id }) {
                    if rec.at > db.records[i].at {
                        db.records[i] = rec
                    }
                } else {
                    db.records.append(rec)
                    fresh.append(rec)
                }
            }

            // 对方把账本删光了（或者服务端数据重建）：兜一个默认账本，
            // 否则界面没有落点、记账会写进空账本 id。
            if db.books.isEmpty {
                db.books = [LedgerBook(id: LedgerBook.defaultId, name: "家庭账本", emoji: "🏠")]
            }
            if !db.books.contains(where: { $0.id == db.currentBook }) {
                db.currentBook = db.books.first?.id ?? LedgerBook.defaultId
            }
        }
        return fresh
    }

    // MARK: 家庭

    func createFamily() async throws -> String {
        let res: FamilyResponse = try await post("/api/family/new", ["deviceId": deviceId()])
        guard let code = res.code, !code.isEmpty else {
            throw SyncError.server(res.message ?? "创建失败")
        }
        await start(code)
        return code
    }

    func joinFamily(_ input: String) async throws -> String {
        let code = input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let res: FamilyResponse = try await post("/api/family/join", ["code": code])
        guard let c = res.code, !c.isEmpty else {
            throw SyncError.server(res.message ?? "没找到这个家庭账本")
        }
        await start(c)
        return c
    }

    private func start(_ code: String) async {
        let prev = store.db.sync?.selfMemberId ?? ""
        // ⚠️ mutate 里是 &db 的独占访问，闭包内不能再调 self 上会读 store.db 的方法
        //    （比如 deviceId()），否则触发 "Simultaneous accesses" 崩溃。先在外面取好。
        let dev = deviceId()
        store.mutate { d in
            var cfg = SyncConfig()
            cfg.code = code
            cfg.deviceId = dev
            cfg.selfMemberId = prev.isEmpty ? (d.members.first?.id ?? "") : prev
            d.sync = cfg
            if d.members.isEmpty {
                d.members = [FamilyMember(name: "我", emoji: "🙂")]
            }
            if d.books.isEmpty {
                d.books = [LedgerBook(id: LedgerBook.defaultId, name: "家庭账本", emoji: "🏠")]
            }
            if d.currentBook.isEmpty || !d.books.contains(where: { $0.id == d.currentBook }) {
                d.currentBook = d.books.first?.id ?? LedgerBook.defaultId
            }
        }
        store.persist()
        quietSyncs = 1
        state = .syncing
        startPolling()
        await run()
    }

    func leaveFamily() {
        store.mutate { $0.sync = nil }
        store.persist()
        stopPolling()
        state = .off
        message = ""
    }

    func setSelfMember(_ id: String) {
        store.mutate { $0.sync?.selfMemberId = id }
        store.persist()
    }

    // MARK: 网络

    private func post<T: Decodable, B: Encodable>(_ path: String, _ body: B) async throws -> T {
        var comps = URLComponents(url: APIConfig.base.appendingPathComponent(path),
                                  resolvingAgainstBaseURL: false)!
        // 网关要求每个请求都带 sharecode，包括「创建家庭」这种还没有家庭码的请求。
        // 早先只在已连家庭时才带，于是第一次创建必然 403。
        var items = comps.queryItems ?? []
        items.removeAll { $0.name == "sharecode" }
        items.append(URLQueryItem(name: "sharecode", value: APIConfig.gate))
        comps.queryItems = items
        guard let url = comps.url else { throw SyncError.badResponse }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw SyncError.badResponse }

        if http.statusCode == 403 { throw SyncError.gate }
        if http.statusCode >= 400 {
            let j = try? JSONDecoder().decode(FamilyResponse.self, from: data)
            throw SyncError.server(j?.message ?? "HTTP \(http.statusCode)")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw SyncError.server("返回格式无法解析")
        }
    }

    private func deviceId() -> String {
        if let id = store.db.sync?.deviceId, !id.isEmpty { return id }
        let key = "snap.device.id"
        if let saved = UserDefaults.standard.string(forKey: key), !saved.isEmpty { return saved }
        let made = "d" + UUID().uuidString.prefix(12).lowercased()
        UserDefaults.standard.set(made, forKey: key)
        return made
    }
}
