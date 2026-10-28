//
//  ChatView.swift
//  聊天式记账主界面（对应网页版的聊天流）
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

    var id: String {
        switch self {
        case .text(let id, _, _): return id
        case .card(let id, _, _): return id
        case .record(let id, _): return id
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
    @State private var showSettings = false
    @State private var toast: String?
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                summaryBar

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(items) { item in
                                row(item).id(item.id)
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                    }
                    .onChange(of: items.count) { _, _ in
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }

                inputBar
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("家庭记账")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    syncPill
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .onAppear(perform: bootstrap)
            .onChange(of: watcher.incoming) { _, text in
                guard let t = text else { return }
                watcher.incoming = nil
                handleOCR(t)
            }
            .overlay(alignment: .top) {
                if let t = toast {
                    Text(t)
                        .font(.footnote)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.top, 8)
                        .transition(.opacity)
                }
            }
        }
    }

    // MARK: 顶部汇总

    private var summaryBar: some View {
        let cal = Calendar.current
        let now = Date()
        let start = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
        let t = store.totals(from: start, to: now.addingTimeInterval(86400))
        return HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text("本月支出").font(.caption).foregroundStyle(.secondary)
                Text(Money.currency(t.expense)).font(.title3.bold())
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("本月收入").font(.caption).foregroundStyle(.secondary)
                Text(Money.currency(t.income)).font(.title3.bold())
                    .foregroundStyle(.green)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("结余").font(.caption).foregroundStyle(.secondary)
                Text(Money.signed(t.income - t.expense))
                    .font(.subheadline.bold())
                    .foregroundStyle(t.income - t.expense >= 0 ? Color.red : Color.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    private var syncPill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(sync.state == .error ? Color.orange : (sync.state == .off ? Color.secondary : Color.green))
                .frame(width: 6, height: 6)
            Text(sync.state.label).font(.caption2).foregroundStyle(.secondary)
            if let code = store.db.sync?.code, !code.isEmpty {
                Text(code).font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 消息行

    @ViewBuilder
    private func row(_ item: ChatItem) -> some View {
        switch item {
        case .text(let id, let mine, let body):
            HStack {
                if mine { Spacer(minLength: 40) }
                Text(body)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(mine ? Color.accentColor : Color(.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(mine ? Color.white : Color.primary)
                if !mine { Spacer(minLength: 40) }
            }
            .id(id)

        case .card(let id, let bill, let savedId):
            RecordCard(bill: bill,
                       saved: savedId != nil,
                       onConfirm: { confirm(id: id, bill: bill) },
                       onDiscard: { discard(id: id) })

        case .record(_, let record):
            HStack {
                RecordRow(record: record, memberName: store.memberName(record.member))
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: 输入栏

    private var inputBar: some View {
        HStack(spacing: 8) {
            Button {
                inputFocused = false
                Task { await watcher.pickUpNow() }
            } label: {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
            }

            TextField("说一句：午饭 32", text: $input, axis: .vertical)
                .lineLimit(1...4)
                .font(.system(size: 16))      // 低于 16px 会触发 iOS 自动放大，把键盘顶乱
                .focused($inputFocused)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))

            Button {
                send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(input.trimmingCharacters(in: .whitespaces).isEmpty ? Color.secondary : Color.accentColor)
            }
            .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial)
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
            let recent = store.sortedRecords.prefix(20).reversed()
            items = recent.map { .record(id: "h\($0.id)", record: $0) }
            items.append(.text(id: "welcome", mine: false,
                               body: "记一笔就说一句话：「午饭 32」「老婆买菜 86」。截图后双击背面回来，我会自己认。"))
        }

        Task {
            await watcher.pickUpOnLaunch()
        }
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input = ""
        items.append(.text(id: UUID().uuidString, mine: true, body: text))

        let names = store.db.members.map { $0.name }
        guard let bill = BillParser.parseQuick(text, members: names) else {
            items.append(.text(id: UUID().uuidString, mine: false, body: "没听出金额。说成「午饭 32」这样试试。"))
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
        toast = "已记账"
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            toast = nil
        }
    }

    private func discard(id: String) {
        items.removeAll { $0.id == id }
    }
}

// MARK: - 待确认卡片

@MainActor
private struct RecordCard: View {
    let bill: ParsedBill
    let saved: Bool
    let onConfirm: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(bill.emoji).font(.title3)
                Text(bill.category).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text((bill.isIncome ? "+" : "-") + Money.currency(bill.amount))
                    .font(.title2.bold())
                    .foregroundStyle(bill.isIncome ? Color.green : Color.primary)
            }

            if !bill.merchant.isEmpty {
                Text(bill.merchant).font(.footnote).foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                if !bill.method.isEmpty {
                    tag(bill.method)
                }
                tag(dayString(bill.ts))
                if bill.confidence < 60 {
                    tag("识别把握不大，确认前看一眼")
                }
            }

            if saved {
                Label("已记账", systemImage: "checkmark.circle.fill")
                    .font(.footnote.bold())
                    .foregroundStyle(.green)
            } else {
                HStack(spacing: 10) {
                    Button(action: onConfirm) {
                        Text("确认记账")
                            .font(.subheadline.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 10))
                            .foregroundStyle(.white)
                    }
                    Button(action: onDiscard) {
                        Text("不要")
                            .font(.subheadline)
                            .padding(.vertical, 9).padding(.horizontal, 14)
                            .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(saved ? Color.green.opacity(0.5) : Color.clear, lineWidth: 1)
        )
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Color(.tertiarySystemGroupedBackground), in: Capsule())
            .foregroundStyle(.secondary)
    }

    private func dayString(_ ms: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "M月d日 HH:mm"
        return f.string(from: Date(timeIntervalSince1970: ms / 1000))
    }
}

// MARK: - 历史记录一行

@MainActor
private struct RecordRow: View {
    let record: LedgerRecord
    let memberName: String

    var body: some View {
        HStack(spacing: 10) {
            Text(record.emoji)
                .font(.system(size: 18))
                .frame(width: 34, height: 34)
                .background(Color(.secondarySystemGroupedBackground), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(record.merchant.isEmpty ? record.category : record.merchant)
                    .font(.subheadline)
                    .lineLimit(1)
                Text("\(record.category) · \(memberName) · \(timeString)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text((record.isIncome ? "+" : "-") + Money.currency(record.amount))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(record.isIncome ? Color.green : Color.primary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var timeString: String {
        let f = DateFormatter()
        f.dateFormat = "M/d HH:mm"
        return f.string(from: Date(timeIntervalSince1970: record.ts / 1000))
    }
}
