//
//  BookView.swift
//  账本：日 / 月 / 年三个粒度，能翻页，能改能删
//
//  网页版是「日/月/年 + hero + 分组列表」，这里保持一致，
//  但把两件事做成了原生才有的手感：滑动翻页的动画、点击直接改账。
//

import SwiftUI

struct BookView: View {
    @ObservedObject private var store = LedgerStore.shared

    @State private var scopeIndex = 1          // 0 日 / 1 月 / 2 年
    @State private var anchor = Date()
    @State private var editing: LedgerRecord?
    @State private var showAdd = false

    private let scopeTitles = ["日", "月", "年"]

    // MARK: 时间范围

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

    private var subTitle: String {
        let n = store.count(from: range.start, to: range.end)
        return n == 0 ? "这个范围还没有账" : "共 \(n) 笔"
    }

    private var totals: (income: Double, expense: Double) {
        store.totals(from: range.start, to: range.end)
    }

    // MARK: 视图

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                LazyVStack(spacing: 14) {
                    ScopeSegmented(titles: scopeTitles, index: $scopeIndex)
                        .padding(.horizontal, 16)

                    HeroCard(label: scopeIndex == 0 ? "当日支出" : (scopeIndex == 1 ? "本月支出" : "本年支出"),
                             amount: totals.expense,
                             income: totals.income,
                             balance: totals.income - totals.expense,
                             footValue: "\(store.count(from: range.start, to: range.end))")
                        .padding(.horizontal, 16)

                    content
                }
                .padding(.top, 4)
                .padding(.bottom, 28)
            }
            .animation(.easeOut(duration: 0.22), value: anchor)
            .animation(.easeOut(duration: 0.22), value: scopeIndex)
        }
        .background(Theme.bg)
        .sheet(item: $editing) { rec in
            RecordEditor(record: rec)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showAdd) {
            RecordEditor(record: nil)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Theme.ink)
                Text(subTitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.ink3)
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                navButton("chevron.left") { step(-1) }
                navButton("chevron.right") { step(1) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .background(Theme.bg)
    }

    private func navButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.ink2)
                .frame(width: 32, height: 32)
                .background(Theme.card, in: Circle())
                .overlay(Circle().strokeBorder(Theme.line, lineWidth: 0.7))
        }
        .buttonStyle(.plain)
    }

    private func step(_ dir: Int) {
        let cal = Fmt.cal
        let comp: Calendar.Component = scopeIndex == 0 ? .day : (scopeIndex == 1 ? .month : .year)
        if let d = cal.date(byAdding: comp, value: dir, to: anchor) {
            anchor = d
        }
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if scopeIndex == 2 {
            yearList
        } else if scopeIndex == 0 {
            let groups = store.dayGroups(from: range.start, to: range.end)
            if groups.isEmpty {
                emptyState
            } else {
                ForEach(groups) { g in
                    groupCard(g, showHeader: false)
                        .padding(.horizontal, 16)
                }
            }
        } else {
            let groups = store.dayGroups(from: range.start, to: range.end)
            if groups.isEmpty {
                emptyState
            } else {
                ForEach(groups) { g in
                    groupCard(g, showHeader: true)
                        .padding(.horizontal, 16)
                }
            }
        }
    }

    /// 年视图：12 个月的可点行，点进去直接落到那个月
    private var yearList: some View {
        let year = Fmt.cal.component(.year, from: anchor)
        let buckets = store.yearMonthBuckets(year: year)
        let maxV = max(buckets.map { $0.expense }.max() ?? 0, 1)
        return VStack(spacing: 0) {
            ForEach(buckets) { b in
                let monthIndex = Int(b.key.split(separator: "-").last.map(String.init) ?? "0") ?? 0
                Button {
                    var c = DateComponents()
                    c.year = year
                    c.month = monthIndex
                    c.day = 1
                    if let d = Fmt.cal.date(from: c) {
                        anchor = d
                        scopeIndex = 1
                    }
                } label: {
                    HStack(spacing: 12) {
                        Text(b.label)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.ink)
                            .frame(width: 42, alignment: .leading)

                        // 迷你占比条：一眼看出哪个月花得多
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.line.opacity(0.7))
                                Capsule()
                                    .fill(b.expense > 0 ? Theme.brand.opacity(0.75) : Color.clear)
                                    .frame(width: max(3, geo.size.width * (b.expense / maxV)))
                            }
                        }
                        .frame(height: 6)

                        Text(b.expense > 0 ? Money.currency(b.expense) : "—")
                            .font(.system(size: 13.5, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(b.expense > 0 ? Theme.ink : Theme.ink3)
                            .frame(width: 78, alignment: .trailing)
                    }
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if b.key != buckets.last?.key {
                    Rectangle().fill(Theme.line).frame(height: 0.7).padding(.leading, 54)
                }
            }
        }
        .padding(.horizontal, 16)
        .cardStyle(padding: 6)
        .padding(.horizontal, 16)
    }

    private func groupCard(_ g: DayGroup, showHeader: Bool) -> some View {
        VStack(spacing: 0) {
            if showHeader {
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
                    if g.income > 0 {
                        Text("收 " + Money.currency(g.income))
                            .font(.system(size: 11.5, design: .rounded))
                            .foregroundStyle(Theme.income)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 11)
                .padding(.bottom, 3)
            }

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

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.ink3)
            Text("这段时间还没有账")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.ink2)
            Text("回到聊天页说一句「午饭 32」，或者点下面加一笔")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.ink3)
                .multilineTextAlignment(.center)
            Button {
                showAdd = true
            } label: {
                Text("手动记一笔")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18).padding(.vertical, 9)
                    .background(Theme.brand, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .cardStyle(padding: 0)
        .padding(.horizontal, 16)
    }
}

// MARK: - 一行记录

struct RecordLine: View {
    let record: LedgerRecord
    let memberName: String
    var onTap: (() -> Void)?

    var body: some View {
        Button {
            onTap?()
        } label: {
            HStack(spacing: 12) {
                EmojiBadge(emoji: record.emoji, tint: Tint.of(record.category))

                VStack(alignment: .leading, spacing: 2) {
                    Text(record.merchant.isEmpty ? record.category : record.merchant)
                        .font(.system(size: 14.5, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)

                    HStack(spacing: 5) {
                        Text(record.category)
                        Text("·")
                        Text(record.member.isEmpty ? "我" : memberName)
                        Text("·")
                        Text(Fmt.hm(record.ts))
                        if !record.note.isEmpty {
                            Text("·")
                            Text(record.note).lineLimit(1)
                        }
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.ink3)
                    .lineLimit(1)
                }

                Spacer(minLength: 6)

                Text((record.isIncome ? "+" : "-") + Money.currency(record.amount))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(record.isIncome ? Theme.income : Theme.ink)
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 编辑 / 新增

struct RecordEditor: View {
    let record: LedgerRecord?

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = LedgerStore.shared

    @State private var amountText: String = ""
    @State private var isIncome: Bool = false
    @State private var category: String = "其他"
    @State private var emoji: String = "📦"

    private let cols = [GridItem(.adaptive(minimum: 74), spacing: 8)]

    private var categories: [BillCategory] {
        isIncome ? BillParser.incomeCategories : BillParser.expenseCategories
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 金额
                    VStack(spacing: 6) {
                        Text(isIncome ? "收入金额" : "支出金额")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.ink3)
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("¥")
                                .font(.system(size: 22, weight: .semibold, design: .rounded))
                                .foregroundStyle(Theme.ink3)
                            TextField("0", text: $amountText)
                                .keyboardType(.decimalPad)
                                .font(.system(size: 40, weight: .bold, design: .rounded))
                                .foregroundStyle(Theme.ink)
                                .multilineTextAlignment(.center)
                                .frame(minWidth: 90)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Theme.card2, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                    ScopeSegmented(titles: ["支出", "收入"], index: Binding(
                        get: { isIncome ? 1 : 0 },
                        set: { isIncome = ($0 == 1) }
                    ))

                    Text("分类")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.ink2)

                    LazyVGrid(columns: cols, spacing: 8) {
                        ForEach(categories, id: \.name) { c in
                            let on = c.name == category
                            Button {
                                category = c.name
                                emoji = c.emoji
                            } label: {
                                VStack(spacing: 4) {
                                    Text(c.emoji).font(.system(size: 19))
                                    Text(c.name)
                                        .font(.system(size: 11.5, weight: on ? .semibold : .regular))
                                        .foregroundStyle(on ? Theme.brand : Theme.ink2)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                                .background(on ? Theme.brandSoft : Theme.card2,
                                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(on ? Theme.brand.opacity(0.55) : Theme.line,
                                                      lineWidth: on ? 1.2 : 0.7)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if record != nil {
                        Button(role: .destructive) {
                            if let r = record { store.delete(id: r.id) }
                            dismiss()
                        } label: {
                            HStack {
                                Spacer()
                                Label("删除这笔", systemImage: "trash")
                                    .font(.system(size: 14, weight: .medium))
                                Spacer()
                            }
                            .padding(.vertical, 12)
                            .background(Theme.expense.opacity(0.1),
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.expense)
                        .padding(.top, 6)
                    }
                }
                .padding(16)
            }
            .background(Theme.bg)
            .navigationTitle(record == nil ? "记一笔" : "修改")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .fontWeight(.semibold)
                        .disabled(parsedAmount <= 0)
                }
            }
            .onAppear(perform: load)
        }
    }

    private var parsedAmount: Double {
        Double(amountText.replacingOccurrences(of: ",", with: "")) ?? 0
    }

    private func load() {
        guard let r = record else { return }
        amountText = Money.plain(r.amount)
        isIncome = r.isIncome
        category = r.category
        emoji = r.emoji
    }

    private func save() {
        let v = parsedAmount
        guard v > 0 else { return }
        let type = isIncome ? "income" : "expense"
        if let r = record {
            store.update(id: r.id, amount: v, category: category, emoji: emoji, type: type)
        } else {
            var rec = LedgerRecord(ts: Date().timeIntervalSince1970 * 1000,
                                   type: type, amount: v,
                                   category: category, emoji: emoji)
            rec.member = store.selfMemberId
            store.add(rec)
        }
        dismiss()
    }
}
