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
    @State private var addDate: Date?          // 从空格子补账时带上的日期
    @State private var heatPick: String?       // 日历上选中的那格
    @State private var missingDay: Date?       // 点了却没有任何记录的那天
    @State private var undoRecord: LedgerRecord?   // 刚删掉的，给 4 秒反悔期
    @State private var undoTimer: Task<Void, Never>?

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

            if undoRecord != nil {
                undoBar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            ScrollViewReader { proxy in
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

                        if scopeIndex == 1 {
                            MonthHeatCalendar(anchor: anchor, selectedKey: $heatPick) { d in
                                pickDay(d, proxy: proxy)
                            }
                            .padding(.horizontal, 16)
                        }

                        content
                    }
                    .padding(.top, 4)
                    .padding(.bottom, 28)
                }
                // 只给翻页加隐式动画。scopeIndex 的动画交给 ScopeSegmented 自己做，
                // 两处同时上动画会和 LazyVStack 的项目增删打架，切换看起来像「没反应」。
                .animation(.easeOut(duration: 0.22), value: anchor)
            }
        }
        .background(Theme.bg)
        .onChange(of: anchor) { _, _ in
            heatPick = nil
            missingDay = nil
        }
        .onChange(of: scopeIndex) { _, _ in
            heatPick = nil
            missingDay = nil
        }
        .sheet(item: $editing) { rec in
            RecordEditor(record: rec)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showAdd, onDismiss: { addDate = nil }) {
            RecordEditor(record: nil, presetDate: addDate)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: 删除 / 撤销

    /// 删完不弹窗、不打断，只在顶部留 4 秒反悔期
    private var undoBar: some View {
        HStack(spacing: 9) {
            Image(systemName: "trash")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.expense)
            Text("已删除这笔账")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.ink2)
            Spacer(minLength: 6)
            Button {
                undoDelete()
            } label: {
                Text("撤销")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.brand)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Theme.card)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line).frame(height: 0.7)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func remove(_ r: LedgerRecord) {
        store.delete(id: r.id)
        withAnimation(.easeOut(duration: 0.2)) { undoRecord = r }
        undoTimer?.cancel()
        undoTimer = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.2)) { undoRecord = nil }
            }
        }
    }

    private func undoDelete() {
        guard let r = undoRecord else { return }
        store.restore(r)
        undoTimer?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { undoRecord = nil }
    }

    // MARK: 点日历某一格

    private func pickDay(_ d: HeatDay, proxy: ScrollViewProxy) {
        // 前后补位的日子：直接翻到那个月，不折腾滚动
        if !d.inMonth {
            anchor = d.day
            heatPick = nil
            missingDay = nil
            return
        }

        heatPick = d.key
        missingDay = nil

        let groups = store.dayGroups(from: range.start, to: range.end)
        if groups.contains(where: { $0.key == d.key }) {
            withAnimation(.easeInOut(duration: 0.28)) {
                proxy.scrollTo(d.key, anchor: .top)
            }
        } else {
            // 这天是空的——比起什么都不发生，直接把「补一笔」摆到面前
            missingDay = d.day
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                withAnimation(.easeInOut(duration: 0.28)) {
                    proxy.scrollTo("missing", anchor: .top)
                }
            }
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

            if let md = missingDay {
                missingCard(md).id("missing")
            }

            if groups.isEmpty {
                emptyState
            } else {
                ForEach(groups) { g in
                    groupCard(g, showHeader: true)
                        .padding(.horizontal, 16)
                        .id(g.key)
                }
            }
        }
    }

    /// 点了日历上的空白格：不弹窗、不报错，直接给一条补账入口
    private func missingCard(_ day: Date) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar.badge.plus")
                .font(.system(size: 17, weight: .light))
                .foregroundStyle(Theme.expense)
                .frame(width: 38, height: 38)
                .background(Theme.expense.opacity(0.1),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(Fmt.dayLong(day) + " 没有记录")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.ink)
                Text("是漏记了，还是这天真的没花钱？")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.ink3)
            }

            Spacer(minLength: 6)

            Button {
                addDate = day
                showAdd = true
            } label: {
                Text("补一笔")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Theme.brand, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .cardStyle(padding: 12)
        .padding(.horizontal, 16)
    }

    /// 年视图：12 个月的可点行，点进去直接落到那个月
    private var yearList: some View {
        let year = Fmt.cal.component(.year, from: anchor)
        let buckets = store.yearMonthBuckets(year: year)
        let maxV = max(buckets.map { $0.expense }.max() ?? 0, 1)
        return VStack(spacing: 0) {
            HStack {
                Text("12 个月支出")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.ink2)
                Spacer()
                Text("点一个月看明细")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink3)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)

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
                    RecordLine(record: r,
                               memberName: store.memberName(r.member),
                               onTap: { editing = r },
                               onDelete: { remove(r) })
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
    var onDelete: (() -> Void)?

    @State private var dx: CGFloat = 0
    private let actionWidth: CGFloat = 76

    var body: some View {
        ZStack(alignment: .trailing) {
            // 左滑露出来的删除按钮，垫在行下面
            if let del = onDelete {
                Button {
                    closeRow()
                    del()
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: "trash")
                            .font(.system(size: 15, weight: .semibold))
                        Text("删除")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.white)
                    .frame(width: actionWidth)
                    .frame(maxHeight: .infinity)
                    .background(Theme.expense)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            rowBody
        }
        .clipped()
    }

    /// 只有可删的行才挂手势和长按菜单（聊天里的只读记录不挂，免得出现空菜单）
    @ViewBuilder
    private var rowBody: some View {
        if let del = onDelete {
            rowButton
                .background(Theme.card)
                .offset(x: dx)
                .simultaneousGesture(swipe)
                .contextMenu {
                    Button(role: .destructive) { del() } label: {
                        Label("删除这笔", systemImage: "trash")
                    }
                }
        } else {
            rowButton
        }
    }

    private var rowButton: some View {
        Button {
            closeRow()
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

    /// 只接管水平方向，竖直方向留给 ScrollView，否则列表就划不动了
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { g in
                guard onDelete != nil else { return }
                guard abs(g.translation.width) > abs(g.translation.height) * 1.3 else { return }
                dx = min(0, max(-actionWidth, g.translation.width))
            }
            .onEnded { g in
                guard onDelete != nil else { return }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                    dx = (g.translation.width < -actionWidth * 0.4) ? -actionWidth : 0
                }
            }
    }

    private func closeRow() {
        guard dx != 0 else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { dx = 0 }
    }
}

// MARK: - 编辑 / 新增

struct RecordEditor: View {
    let record: LedgerRecord?
    var presetDate: Date? = nil     // 从日历空格子补账时，把日期定在那天

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = LedgerStore.shared

    @State private var amountText: String = ""
    @State private var isIncome: Bool = false
    @State private var category: String = "其他"
    @State private var emoji: String = "📦"
    @State private var showDeleteConfirm = false

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
                        if let d = presetDate, record == nil {
                            Text("补记 " + Fmt.dayLong(d))
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(Theme.brand)
                        }
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

                    // 删除放在这——之前贴在页面最底部，半屏高度时根本看不到，
                    // 用户会以为「没有删除功能」
                    if record != nil {
                        Button {
                            showDeleteConfirm = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "trash")
                                    .font(.system(size: 12, weight: .semibold))
                                Text("删除这笔")
                                    .font(.system(size: 13.5, weight: .medium))
                            }
                            .foregroundStyle(Theme.expense)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Theme.expense.opacity(0.09),
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

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
            .confirmationDialog("删除这笔账？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    if let r = record { store.delete(id: r.id) }
                    dismiss()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("删除后另一台手机上的这一笔也会一起消失。")
            }
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
            var rec = LedgerRecord(ts: stamp(), type: type, amount: v,
                                   category: category, emoji: emoji)
            rec.member = store.selfMemberId
            store.add(rec)
        }
        dismiss()
    }

    /// 补账时用那天的日期 + 此刻的时分秒，否则一律记成现在
    private func stamp() -> Double {
        let now = Date()
        guard record == nil, let d = presetDate else {
            return now.timeIntervalSince1970 * 1000
        }
        let cal = Fmt.cal
        let t = cal.dateComponents([.hour, .minute, .second], from: now)
        var c = cal.dateComponents([.year, .month, .day], from: d)
        c.hour = t.hour
        c.minute = t.minute
        c.second = t.second
        return (cal.date(from: c) ?? now).timeIntervalSince1970 * 1000
    }
}
