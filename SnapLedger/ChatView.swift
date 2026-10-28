//
//  ChatView.swift
//  聊天式记账主界面
//
//  一次记账的信息流：
//      输入「午饭 32」→ 出一张待确认卡片 → 点「确认记账」→ 变成已记账的记录
//  截图流：
//      轻点背面 → 打开 App → 自动捞到最新的截图 → 识别 → 同上出卡片
//
//  刻意保留「先出卡片、再确认」这一步：OCR 和解析不可能 100% 准，
//  让用户点一下的成本远低于让用户去改一笔错账。
//

import SwiftUI

enum ChatItem: Identifiable {
    case text(id: String, mine: Bool, body: String)
    case card(id: String, bill: ParsedBill, savedId: String?)
    case record(id: String, record: LedgerRecord)
    case tip(id: String, body: String)

    var id: String {
        switch self {
        case .text(let id, _, _): return id
        case .card(let id, _, _): return id
        case .record(let id, _): return id
        case .tip(let id, _): return id
        }
    }
}

@MainActor
struct ChatView: View {
    @ObservedObject private var store = LedgerStore.shared
    @ObservedObject private var sync = SyncEngine.shared
    @StateObject private var watcher = ScreenshotWatcher.shared

    @State private var items: [ChatItem] = []
    @State private var input: String = ""
    @State private var toast: String?
    @State private var showAllRecords = false
    @FocusState private var inputFocused: Bool

    private var monthTotals: (income: Double, expense: Double) {
        let cal = Fmt.cal
        let start = cal.date(from: cal.dateComponents([.year, .month], from: Date())) ?? Date()
        return store.totals(from: start, to: Date().addingTimeInterval(86400))
    }

    private var monthCount: Int {
        let cal = Fmt.cal
        let start = cal.date(from: cal.dateComponents([.year, .month], from: Date())) ?? Date()
        return store.count(from: start, to: Date().addingTimeInterval(86400))
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        monthHero
                            .padding(.horizontal, 16)
                            .padding(.top, 8)

                        if !watcher.status.isEmpty {
                            statusBubble(watcher.status)
                        }

                        ForEach(items) { item in
                            row(item).id(item.id)
                        }

                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.bottom, 14)
                }
                .onChange(of: items.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.22)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(Theme.bg)
        .safeAreaInset(edge: .bottom, spacing: 0) { inputBar }
        .onAppear(perform: bootstrap)
        .onChange(of: watcher.incoming) { _, text in
            guard let t = text else { return }
            watcher.incoming = nil
            handleOCR(t)
        }
        .overlay(alignment: .top) {
            if let t = toast {
                Text(t)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Theme.ink.opacity(0.9), in: Capsule())
                    .padding(.top, 6)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .sheet(isPresented: $showAllRecords) {
            AllRecordsSheet()
        }
    }

    // MARK: 顶栏

    private var topBar: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("家庭记账")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Theme.ink)
                HStack(spacing: 5) {
                    Circle()
                        .fill(syncColor)
                        .frame(width: 5.5, height: 5.5)
                    Text(syncText)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ink3)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Button {
                showAllRecords = true
            } label: {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.ink2)
                    .frame(width: 34, height: 34)
                    .background(Theme.card, in: Circle())
                    .overlay(Circle().strokeBorder(Theme.line, lineWidth: 0.7))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .padding(.top, 2)
        .background(Theme.bg)
    }

    private var syncColor: Color {
        switch sync.state {
        case .error: return Theme.expense
        case .off: return Theme.ink3
        case .syncing: return .orange
        case .idle: return Theme.income
        }
    }

    private var syncText: String {
        let code = store.db.sync?.code ?? ""
        if code.isEmpty { return "未连接家庭账本 · 数据只在本机" }
        return "\(code) · \(sync.state.label)"
    }

    // MARK: 本月卡

    private var monthHero: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(monthLabel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("¥")
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.85))
                        Text(Money.plain(monthTotals.expense))
                            .font(.system(size: 33, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                    }
                    Text("本月支出")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.72))
                }

                Spacer(minLength: 6)

                VStack(alignment: .trailing, spacing: 6) {
                    miniStat("收入", Money.currency(monthTotals.income))
                    miniStat("结余", Money.signed(monthTotals.income - monthTotals.expense))
                    miniStat("笔数", "\(monthCount)")
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                Theme.hero
                Circle().fill(.white.opacity(0.10))
                    .frame(width: 170, height: 170)
                    .offset(x: 112, y: -74)
                Circle().fill(.white.opacity(0.07))
                    .frame(width: 90, height: 90)
                    .offset(x: 52, y: 84)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var monthLabel: String {
        let f = DateFormatter()
        f.dateFormat = "M月"
        return f.string(from: Date()) + " · 家庭账本"
    }

    private func miniStat(_ k: String, _ v: String) -> some View {
        HStack(spacing: 6) {
            Text(k)
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.7))
            Text(v)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(.white.opacity(0.16), in: Capsule())
    }

    // MARK: 消息行

    @ViewBuilder
    private func row(_ item: ChatItem) -> some View {
        switch item {
        case .text(_, let mine, let body):
            HStack(alignment: .bottom, spacing: 8) {
                if mine { Spacer(minLength: 46) } else { assistantAvatar }
                Text(body)
                    .font(.system(size: 14.5))
                    .foregroundStyle(mine ? Color.white : Theme.ink)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                    .background {
                        if mine {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Theme.hero)
                        } else {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Theme.card)
                                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(Theme.line, lineWidth: 0.7))
                        }
                    }
                if !mine { Spacer(minLength: 30) }
            }
            .padding(.horizontal, 16)

        case .tip(_, let body):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lightbulb")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.brand)
                    .padding(.top, 2)
                Text(body)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Theme.brandSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 16)

        case .card(let id, let bill, let savedId):
            RecordCard(bill: bill,
                       saved: savedId != nil,
                       onConfirm: { confirm(id: id, bill: bill) },
                       onDiscard: { discard(id: id) })
                .padding(.horizontal, 16)

        case .record(_, let record):
            RecordLine(record: record, memberName: store.memberName(record.member))
                .padding(.horizontal, 12)
                .cardStyle(padding: 0, radius: 14)
                .padding(.horizontal, 16)
        }
    }

    private var assistantAvatar: some View {
        Text("🪄")
            .font(.system(size: 14))
            .frame(width: 26, height: 26)
            .background(Theme.brandSoft, in: Circle())
    }

    private func statusBubble(_ s: String) -> some View {
        HStack(spacing: 7) {
            ProgressView().controlSize(.mini)
            Text(s)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.ink2)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.card, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 0.7))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
    }

    // MARK: 输入栏

    private var inputBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.line).frame(height: 0.7)

            HStack(alignment: .bottom, spacing: 9) {
                Button {
                    inputFocused = false
                    Task { await watcher.pickUpNow() }
                } label: {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Theme.brand)
                        .frame(width: 36, height: 36)
                        .background(Theme.brandSoft, in: Circle())
                }
                .buttonStyle(.plain)

                TextField("说一句：午饭 32", text: $input, axis: .vertical)
                    .lineLimit(1...4)
                    .font(.system(size: 16))      // 低于 16px 会触发 iOS 自动放大，把键盘顶乱
                    .foregroundStyle(Theme.ink)
                    .focused($inputFocused)
                    .padding(.horizontal, 13).padding(.vertical, 9)
                    .background(Theme.card2, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous)
                        .strokeBorder(Theme.line, lineWidth: 0.7))

                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background {
                            if canSend {
                                Circle().fill(Theme.hero)
                            } else {
                                Circle().fill(Theme.ink3.opacity(0.4))
                            }
                        }
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Theme.bg)
        }
    }

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: 动作

    private func bootstrap() {
        watcher.start()
        sync.onAnnounce = { rec in
            items.append(.text(id: "a\(rec.id)", mine: false,
                               body: "\(store.memberName(rec.member)) 记了一笔：\(rec.category) \(Money.currency(rec.amount))"))
        }
        sync.bootstrap()

        if items.isEmpty {
            let recent = store.sortedRecords.prefix(6).reversed()
            for r in recent {
                items.append(.record(id: "h\(r.id)", record: r))
            }
            items.append(.text(id: "welcome", mine: false,
                               body: "说一句话就能记，比如「午饭 32」「老婆买菜 86」。"))

            items.append(.tip(id: "tip1",
                              body: "付款截图后双击手机背面回来，我会自己找到那张图认出来。也可以点左下角相册按钮手动读。"))
        }

        Task { await watcher.pickUpOnLaunch() }
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input = ""
        items.append(.text(id: UUID().uuidString, mine: true, body: text))

        let names = store.db.members.map { $0.name }
        guard let bill = BillParser.parseQuick(text, members: names) else {
            items.append(.text(id: UUID().uuidString, mine: false,
                               body: "没听出金额。说成「午饭 32」这样试试。"))
            return
        }
        items.append(.card(id: UUID().uuidString, bill: bill, savedId: nil))
    }

    private func handleOCR(_ text: String) {
        let bill = BillParser.analyze(text)
        if bill.amount <= 0 {
            items.append(.text(id: UUID().uuidString, mine: false,
                               body: "截图读到了，但没认出金额。可能是余额页或不常见的版式，手动说一句更快。"))
            return
        }
        items.append(.card(id: UUID().uuidString, bill: bill, savedId: nil))
    }

    private func confirm(id: String, bill: ParsedBill) {
        var rec = bill.toRecord(source: bill.lines.count > 1 ? "ocr" : "chat")
        if rec.member.isEmpty { rec.member = store.selfMemberId }
        let saved = store.add(rec)
        if let i = items.firstIndex(where: { $0.id == id }) {
            items[i] = .card(id: id, bill: bill, savedId: saved.id)
        }
        withAnimation { toast = "已记账 · \(saved.category) \(Money.currency(saved.amount))" }
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            withAnimation { toast = nil }
        }
    }

    private func discard(id: String) {
        withAnimation { items.removeAll { $0.id == id } }
    }
}

// MARK: - 待确认卡片

@MainActor
private struct RecordCard: View {
    let bill: ParsedBill
    let saved: Bool
    let onConfirm: () -> Void
    let onDiscard: () -> Void

    private var tint: Color { Tint.of(bill.category) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(bill.emoji)
                    .font(.system(size: 24))
                    .frame(width: 48, height: 48)
                    .background(tint.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(bill.merchant.isEmpty ? bill.category : bill.merchant)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text(bill.category)
                        Text("·")
                        Text(Fmt.mdhm(bill.ts))
                        if !bill.method.isEmpty {
                            Text("·")
                            Text(bill.method)
                        }
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.ink3)
                    .lineLimit(1)
                }

                Spacer(minLength: 6)

                Text((bill.isIncome ? "+" : "-") + Money.currency(bill.amount))
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(bill.isIncome ? Theme.income : Theme.ink)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            }
            .padding(14)

            if bill.confidence < 60 && !saved {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                    Text("识别把握不大，确认前看一眼金额")
                        .font(.system(size: 11.5))
                    Spacer()
                }
                .foregroundStyle(Color.orange)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }

            Rectangle().fill(Theme.line).frame(height: 0.7)

            if saved {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                    Text("已记账")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("可在账本页修改")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.ink3)
                }
                .foregroundStyle(Theme.income)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
            } else {
                HStack(spacing: 10) {
                    Button(action: onDiscard) {
                        Text("不要")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.ink2)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Theme.card2, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Button(action: onConfirm) {
                        Text("确认记账")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Theme.brand, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .padding(12)
            }
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(saved ? Theme.income.opacity(0.45) : Theme.line,
                              lineWidth: saved ? 1.2 : 0.7)
        )
        .shadow(color: .black.opacity(0.05), radius: 10, x: 0, y: 4)
    }
}

// MARK: - 全部记录

struct AllRecordsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = LedgerStore.shared
    @State private var editing: LedgerRecord?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    let groups = store.dayGroups(from: Date(timeIntervalSince1970: 0),
                                                 to: Date().addingTimeInterval(86400))
                    ForEach(groups) { g in
                        VStack(spacing: 0) {
                            HStack {
                                Text(Fmt.dayLong(g.day))
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(Theme.ink2)
                                Spacer()
                                if g.expense > 0 {
                                    Text("支 " + Money.currency(g.expense))
                                        .font(.system(size: 11.5, design: .rounded))
                                        .foregroundStyle(Theme.ink3)
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.top, 11)
                            .padding(.bottom, 3)

                            VStack(spacing: 0) {
                                ForEach(g.records) { r in
                                    RecordLine(record: r, memberName: store.memberName(r.member)) {
                                        editing = r
                                    }
                                    if r.id != g.records.last?.id {
                                        Rectangle().fill(Theme.line).frame(height: 0.7).padding(.leading, 64)
                                    }
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.bottom, 6)
                        }
                        .cardStyle(padding: 0)
                    }

                    if store.db.records.isEmpty {
                        Text("还没有账目")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.ink3)
                            .padding(.top, 40)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Theme.bg)
            .navigationTitle("全部记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(item: $editing) { rec in
                RecordEditor(record: rec)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }
}
