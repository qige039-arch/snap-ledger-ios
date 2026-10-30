//
//  BookView.swift
//  账本：日 / 月 / 年三个粒度，能翻页，能改能删，能管多个账本
//
//  这一版改了三件事（都是真机上暴露出来的）：
//   1. 日/月/年 切换条移出 ScrollView，放在固定页头。之前它在 LazyVStack 里，
//      点「年」经常没反应 —— 这类「点击被列表吃掉」的问题只有挪出去才断根。
//   2. 账本可建可改可删可切（旅行、装修、生意分开记），记录带 book 归属。
//   3. 编辑页补了时间、支付方式、备注、所属账本 —— 记错了不能改时间是很要命的。
//

import SwiftUI

/// 账本页只有一个呈现出口
///
/// ⚠️ 之前同一个 view 上挂了三个 `.sheet(...)`（改、加、账本），这在 SwiftUI 里
/// 是有名的坑：多个 sheet 修饰符互相抢 presentation，表现就是「点了没任何反应」。
/// 合并成一个 `.sheet(item:)` 之后这条路只有一条，行为确定。
private enum BookRoute: Identifiable {
    case add(Date?)
    case edit(LedgerRecord)
    case books

    var id: String {
        switch self {
        case .add(let d): return "add-" + (d.map { Fmt.key($0) } ?? "now")
        case .edit(let r): return "edit-" + r.id
        case .books: return "books"
        }
    }
}

struct BookView: View {
    @ObservedObject private var store = LedgerStore.shared

    @State private var scopeIndex = 1          // 0 日 / 1 月 / 2 年
    @State private var anchor = Date()
    @State private var route: BookRoute?
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
        return n == 0 ? "还没有账" : "共 \(n) 笔"
    }

    private var totals: (income: Double, expense: Double) {
        store.totals(from: range.start, to: range.end)
    }

    // MARK: 视图

    var body: some View {
        VStack(spacing: 0) {
            header

            if let r = undoRecord {
                UndoBar(text: "已删除 \(r.category) \(Money.currency(r.amount))") {
                    undoDelete()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        HeroCard(label: scopeIndex == 0 ? "当日支出" : (scopeIndex == 1 ? "本月支出" : "本年支出"),
                                 amount: totals.expense,
                                 income: totals.income,
                                 balance: totals.income - totals.expense,
                                 footValue: "\(store.count(from: range.start, to: range.end))")
                            .padding(.horizontal, 16)
                            .id("top")

                        if scopeIndex == 1 {
                            MonthHeatCalendar(anchor: anchor, selectedKey: $heatPick) { d in
                                pickDay(d, proxy: proxy)
                            }
                            .padding(.horizontal, 16)
                        }

                        content
                    }
                    .padding(.top, 10)
                    .padding(.bottom, 28)
                }
                // 只给翻页留动画。scopeIndex 的动画交给页头的 ScopeBar 自己，
                // 两处同时上动画会和 LazyVStack 的增删打架。
                .animation(.easeOut(duration: 0.22), value: anchor)
                // 切粒度后回到顶部：不然停在上面一屏的滚动位置，看起来像「点了没反应」
                .onChange(of: scopeIndex) { _, _ in
                    proxy.scrollTo("top", anchor: .top)
                }
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
        .onChange(of: store.currentBookId) { _, _ in
            heatPick = nil
            missingDay = nil
            anchor = Date()
        }
        .sheet(item: $route) { r in
            switch r {
            case .add(let d):
                RecordEditor(record: nil, presetDate: d) { saved in
                    // 补记到过去某天时，把页面翻到那一天 —— 否则保存完视野没变，
                    // 看起来就像「点了保存什么都没发生」
                    anchor = Date(timeIntervalSince1970: saved.ts / 1000)
                    heatPick = Fmt.key(anchor)
                    missingDay = nil
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)

            case .edit(let rec):
                RecordEditor(record: rec) { saved in
                    anchor = Date(timeIntervalSince1970: saved.ts / 1000)
                    heatPick = Fmt.key(anchor)
                    missingDay = nil
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)

            case .books:
                BookSwitcherSheet()
            }
        }
    }

    // MARK: 页头

    private var header: some View {
        VStack(spacing: 9) {
            HStack(spacing: 8) {
                Button {
                    route = .books
                } label: {
                    HStack(spacing: 5) {
                        Text(store.currentBook?.emoji ?? "🏠")
                            .font(.system(size: 15))
                        Text(store.currentBook?.name ?? "家庭账本")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.ink3)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 6)

                HStack(spacing: 7) {
                    navButton("chevron.left") { step(-1) }
                    navButton("chevron.right") { step(1) }
                }
            }

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(1)
                    Text(subTitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ink3)
                }

                Spacer(minLength: 6)

                ScopeBar(titles: scopeTitles, index: $scopeIndex)
                    .frame(width: 148)
            }
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
        let cal = Fmt.cal
        let comp: Calendar.Component = scopeIndex == 0 ? .day : (scopeIndex == 1 ? .month : .year)
        if let d = cal.date(byAdding: comp, value: dir, to: anchor) {
            anchor = d
        }
    }

    // MARK: 删除 / 撤销

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

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        switch scopeIndex {
        case 0:
            dayContent
        case 1:
            monthContent
        default:
            yearList
        }
    }

    private var dayContent: some View {
        let groups = store.dayGroups(from: range.start, to: range.end)
        return Group {
            if groups.isEmpty {
                emptyState
            } else {
                ForEach(groups) { g in
                    groupCard(g, showHeader: false)
                        .padding(.horizontal, 16)
                }
            }
        }
    }

    private var monthContent: some View {
        let groups = store.dayGroups(from: range.start, to: range.end)
        return Group {
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
                route = .add(day)
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
    ///
    /// 刻意不用 GeometryReader 画占比条 —— 它没有固有尺寸，塞进 LazyVStack 的
    /// Button 里会把行高算错。固定 92pt 轨道 + 叠加填充，行为完全可预测。
    private var yearList: some View {
        let year = Fmt.cal.component(.year, from: anchor)
        let buckets = store.yearMonthBuckets(year: year)
        let maxV = max(buckets.map { $0.expense }.max() ?? 0, 1)
        return VStack(spacing: 0) {
            HStack {
                Text("12 个月")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.ink2)
                Spacer()
                Text("点一个月看明细")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink3)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 4)

            ForEach(buckets) { b in
                Button {
                    tapMonth(b.key, year: year)
                } label: {
                    yearRow(b, maxV: maxV)
                }
                .buttonStyle(.plain)

                if b.key != buckets.last?.key {
                    Rectangle().fill(Theme.line).frame(height: 0.7).padding(.leading, 14)
                }
            }
        }
        .cardStyle(padding: 0)
        .padding(.horizontal, 16)
    }

    private func yearRow(_ b: Bucket, maxV: Double) -> some View {
        let ratio = max(0, min(1, b.expense / maxV))
        return HStack(spacing: 10) {
            Text(b.label)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(b.expense > 0 ? Theme.ink : Theme.ink3)
                .frame(width: 38, alignment: .leading)

            Capsule()
                .fill(Theme.line.opacity(0.75))
                .frame(width: 92, height: 6)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(Theme.brand.opacity(0.8))
                        .frame(width: b.expense > 0 ? max(4, 92 * ratio) : 0, height: 6)
                }

            Spacer(minLength: 6)

            if b.income > 0 {
                Text("+" + Money.plain(b.income))
                    .font(.system(size: 10.5, design: .rounded))
                    .foregroundStyle(Theme.income)
            }

            Text(b.expense > 0 ? Money.currency(b.expense) : "—")
                .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(b.expense > 0 ? Theme.ink : Theme.ink3)
                .frame(width: 76, alignment: .trailing)

            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.ink3)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private func tapMonth(_ key: String, year: Int) {
        guard let m = Int(key.split(separator: "-").last.map(String.init) ?? "") else { return }
        var c = DateComponents()
        c.year = year
        c.month = m
        c.day = 1
        if let d = Fmt.cal.date(from: c) {
            anchor = d
            scopeIndex = 1
        }
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
                               onTap: { route = .edit(r) },
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
            Text("回到记账页说一句「午饭 32」，或者点下面加一笔")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.ink3)
                .multilineTextAlignment(.center)
            Button {
                route = .add(nil)
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

/// 全局只允许一行处于「滑开」状态。几行同时露出删除按钮会让整个列表看起来是坏的。
final class RowSwipeState: ObservableObject {
    static let shared = RowSwipeState()
    @Published var openId: String?
}

struct RecordLine: View {
    let record: LedgerRecord
    let memberName: String
    var onTap: (() -> Void)?
    var onDelete: (() -> Void)?

    @ObservedObject private var rowState = RowSwipeState.shared
    @State private var dx: CGFloat = 0
    @State private var dragging = false

    private let actionWidth: CGFloat = 72

    var body: some View {
        ZStack(alignment: .trailing) {
            if let del = onDelete {
                deleteButton(del)
            }
            rowContent
        }
        .clipped()
        .onChange(of: rowState.openId) { _, id in
            if id != record.id, dx != 0 {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { dx = 0 }
            }
        }
        .onDisappear {
            if rowState.openId == record.id { rowState.openId = nil }
        }
    }

    /// 行本身不再用 Button
    ///
    /// 之前是 `Button + .simultaneousGesture(DragGesture)`，结果是「左滑删除时顺手
    /// 打开编辑器」—— Button 的 tap 和拖动手势会同时被识别。换成 onTapGesture 后，
    /// 拖动一旦超过 minimumDistance，tap 就自动失败，两者不会再同时成立。
    private var rowContent: some View {
        let core = rowInner
            .background(Theme.card)
            .offset(x: dx)
            .contentShape(Rectangle())

        return Group {
            if onDelete == nil {
                core.onTapGesture(perform: handleTap)
            } else {
                core
                    .onTapGesture(perform: handleTap)
                    .simultaneousGesture(swipe)
            }
        }
    }

    private var rowInner: some View {
        HStack(spacing: 12) {
            EmojiBadge(emoji: record.emoji, tint: Tint.of(record.category))

            VStack(alignment: .leading, spacing: 2) {
                Text(record.title)
                    .font(.system(size: 14.5, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Text(record.category)
                    if !record.method.isEmpty {
                        Text("·")
                        Text(record.method)
                    }
                    Text("·")
                    Text(record.member.isEmpty ? "我" : memberName)
                    Text("·")
                    Text(Fmt.hm(record.ts))
                }
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.ink3)
                .lineLimit(1)

                if !record.note.isEmpty {
                    Text(record.note)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.ink3)
                        .lineLimit(1)
                }
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

    /// 悬浮的圆角红块，不再是从卡片边缘切出来的一条直角色带
    private func deleteButton(_ del: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { dx = 0 }
            rowState.openId = nil
            del()
        } label: {
            VStack(spacing: 2) {
                Image(systemName: "trash.fill")
                    .font(.system(size: 14, weight: .semibold))
                Text("删除")
                    .font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(.white)
            .frame(width: 60, height: 42)
            .background(
                LinearGradient(colors: [Theme.expense, Theme.expense.opacity(0.84)],
                               startPoint: .top,
                               endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.trailing, 10)
    }

    /// 只接管水平方向，竖直方向留给 ScrollView，否则列表就划不动了
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { g in
                guard onDelete != nil else { return }
                guard abs(g.translation.width) > abs(g.translation.height) * 1.2 else { return }
                dragging = true
                let base: CGFloat = (rowState.openId == record.id) ? -actionWidth : 0
                dx = min(0, max(-actionWidth, base + g.translation.width))
            }
            .onEnded { _ in
                guard onDelete != nil, dragging else {
                    dragging = false
                    return
                }
                let open = dx < -actionWidth * 0.5
                withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
                    dx = open ? -actionWidth : 0
                }
                rowState.openId = open ? record.id : nil
                // 手指离开后 0.15 秒内不再响应点击，避免收尾那一下被当成 tap
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    dragging = false
                }
            }
    }

    private func handleTap() {
        guard !dragging else { return }
        // 已经滑开时，点一下只是收起，不进编辑页
        if rowState.openId == record.id {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { dx = 0 }
            rowState.openId = nil
            return
        }
        onTap?()
    }
}

// MARK: - 编辑 / 新增

struct RecordEditor: View {
    let record: LedgerRecord?
    var presetDate: Date? = nil     // 从日历空格子补账时，把日期定在那天
    var onSaved: ((LedgerRecord) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = LedgerStore.shared

    @State private var amountText: String = ""
    @State private var isIncome: Bool = false
    @State private var category: String = "其他"
    @State private var emoji: String = "📦"
    @State private var note: String = ""
    @State private var method: String = ""
    @State private var bookId: String = ""
    @State private var date: Date = Date()
    @State private var showDeleteConfirm = false
    @State private var loaded = false
    @State private var hint: String?

    private let cols = [GridItem(.adaptive(minimum: 74), spacing: 8)]
    private let methods = ["支付宝", "微信", "银行卡", "现金", "其他"]

    private var categories: [BillCategory] {
        isIncome ? BillParser.incomeCategories : BillParser.expenseCategories
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    amountBox

                    ScopeBar(titles: ["支出", "收入"], index: Binding(
                        get: { isIncome ? 1 : 0 },
                        set: { isIncome = ($0 == 1) }
                    ), fill: isIncome ? Theme.income : Theme.expense)

                    if record != nil {
                        deleteButton
                    }

                    metaCard

                    Text("分类")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.ink2)

                    categoryGrid

                    noteField
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
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { saveBar }
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

    // MARK: 金额

    private var amountBox: some View {
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
                    .onChange(of: amountText) { _, v in
                        let c = Self.cleanAmount(v)
                        if c != v { amountText = c }
                        if !c.isEmpty { hint = nil }
                    }
            }

            if let hint {
                Text(hint)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.expense)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Theme.card2, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// 删除放在收支切换下面：之前贴在页面最底部，半屏高度时根本看不到，
    /// 用户会以为「没有删除功能」
    private var deleteButton: some View {
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

    // MARK: 时间 / 支付方式 / 账本

    private var metaCard: some View {
        VStack(spacing: 12) {
            HStack {
                Label("时间", systemImage: "clock")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.ink2)
                Spacer()
                DatePicker("", selection: $date, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .datePickerStyle(.compact)
            }

            Rectangle().fill(Theme.line).frame(height: 0.7)

            VStack(alignment: .leading, spacing: 8) {
                Label("支付方式", systemImage: "creditcard")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.ink2)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 62), spacing: 8)], spacing: 8) {
                    ForEach(methods, id: \.self) { m in
                        let on = m == method
                        Text(m)
                            .font(.system(size: 12.5, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? Theme.brand : Theme.ink2)
                            .frame(maxWidth: .infinity)
                            .frame(height: 30)
                            .background(on ? Theme.brandSoft : Theme.card2,
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(on ? Theme.brand.opacity(0.5) : Theme.line,
                                              lineWidth: on ? 1.2 : 0.7))
                            .contentShape(Rectangle())
                            .onTapGesture { method = on ? "" : m }
                    }
                }
            }

            if store.books.count > 1 {
                Rectangle().fill(Theme.line).frame(height: 0.7)

                Menu {
                    ForEach(store.books) { b in
                        Button {
                            bookId = b.id
                        } label: {
                            Text("\(b.emoji) \(b.name)")
                        }
                    }
                } label: {
                    HStack {
                        Label("所属账本", systemImage: "book.closed")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.ink2)
                        Spacer()
                        let b = store.books.first { $0.id == bookId }
                        Text(b == nil ? "未选择" : "\(b!.emoji) \(b!.name)")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.ink)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.ink3)
                    }
                    .contentShape(Rectangle())
                }
            }
        }
        .cardStyle(padding: 14)
    }

    private var categoryGrid: some View {
        LazyVGrid(columns: cols, spacing: 8) {
            ForEach(categories, id: \.name) { c in
                let on = c.name == category
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
                .contentShape(Rectangle())
                .onTapGesture {
                    category = c.name
                    emoji = c.emoji
                }
            }
        }
    }

    private var noteField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("备注")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.ink2)
            TextField("可选，比如「和爸妈吃饭」", text: $note, axis: .vertical)
                .lineLimit(2...4)
                .font(.system(size: 14))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Theme.card2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.line, lineWidth: 0.7))
        }
    }

    // MARK: 存取

    private var parsedAmount: Double? {
        guard let v = Double(amountText), v > 0, v.isFinite else { return nil }
        return v
    }

    /// 全角转半角、只留数字和一个小数点、小数最多两位
    ///
    /// 从微信 / 支付宝复制金额时常带「¥」「,」「元」，甚至全角数字。
    /// 以前直接 Double() 得到 nil 就把 `amountText` 当 0，保存按钮被 disabled 或
    /// 静默 return —— 用户看到的就是「点了保存没反应」。现在先清洗再判断。
    static func cleanAmount(_ s: String) -> String {
        let half = s.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? s
        var out = ""
        var dot = false
        for ch in half {
            if ch >= "0", ch <= "9" {
                out.append(ch)
            } else if ch == ".", !dot {
                dot = true
                out.append(ch)
            }
        }
        if let i = out.firstIndex(of: ".") {
            let frac = out[out.index(after: i)...]
            if frac.count > 2 {
                out = String(out[..<out.index(i, offsetBy: 3)])
            }
        }
        return out
    }

    /// 底部主按钮：不再是导航栏里那个「灰了就没提示」的保存
    private var saveBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.line).frame(height: 0.6)

            Button(action: save) {
                Text(record == nil ? "保存这笔账" : "保存修改")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(parsedAmount == nil ? Theme.ink3.opacity(0.38) : Theme.brand,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.top, 9)
            .padding(.bottom, 4)
        }
        .background(Theme.bg)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let r = record {
            amountText = Money.plain(r.amount)
            isIncome = r.isIncome
            category = r.category
            emoji = r.emoji
            note = r.note
            method = r.method
            bookId = store.bookId(of: r)
            date = Date(timeIntervalSince1970: r.ts / 1000)
        } else {
            bookId = store.currentBookId
            // 补账：日期用那天，时分秒沿用此刻
            if let d = presetDate {
                let cal = Fmt.cal
                let t = cal.dateComponents([.hour, .minute, .second], from: Date())
                var c = cal.dateComponents([.year, .month, .day], from: d)
                c.hour = t.hour
                c.minute = t.minute
                c.second = t.second
                date = cal.date(from: c) ?? Date()
            }
        }
    }

    private func save() {
        guard let v = parsedAmount else {
            // 绝不静默失败：告诉用户到底缺什么
            withAnimation(.easeOut(duration: 0.16)) {
                hint = amountText.isEmpty ? "先填一个金额" : "金额只认数字，比如 32.50"
            }
            return
        }
        let type = isIncome ? "income" : "expense"
        let ts = date.timeIntervalSince1970 * 1000
        var saved: LedgerRecord

        if let r = record {
            store.update(id: r.id, amount: v, category: category, emoji: emoji,
                         type: type, note: note, method: method, ts: ts, book: bookId)
            saved = store.db.records.first { $0.id == r.id } ?? r
        } else {
            var rec = LedgerRecord(ts: ts, type: type, amount: v,
                                   category: category, emoji: emoji,
                                   method: method, note: note)
            rec.member = store.selfMemberId
            rec.book = bookId.isEmpty ? store.currentBookId : bookId
            saved = store.add(rec)
        }
        onSaved?(saved)
        dismiss()
    }
}

// MARK: - 切换账本

struct BookSwitcherSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = LedgerStore.shared

    @State private var editing: LedgerBook?
    @State private var creating = false
    @State private var doomed: LedgerBook?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.books) { b in
                        Button {
                            store.switchBook(b.id)
                            dismiss()
                        } label: {
                            bookRow(b)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if store.books.count > 1 {
                                Button(role: .destructive) {
                                    doomed = b
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                            Button {
                                editing = b
                            } label: {
                                Label("改名", systemImage: "pencil")
                            }
                            .tint(Theme.brand)
                        }
                        .contextMenu {
                            Button { editing = b } label: { Label("改名 / 换图标", systemImage: "pencil") }
                            if store.books.count > 1 {
                                Button(role: .destructive) { doomed = b } label: {
                                    Label("删除账本", systemImage: "trash")
                                }
                            }
                        }
                    }
                } header: {
                    Text("点一下切换，左滑改名或删除")
                } footer: {
                    Text("每个账本的记录互不打扰，统计也只统计当前账本。两台手机通过家庭账本同步时，账本本身也会同步过去。")
                }

                Section {
                    Button {
                        creating = true
                    } label: {
                        Label("新建账本", systemImage: "plus.circle.fill")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.brand)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("我的账本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(item: $editing) { b in
                BookEditorSheet(book: b)
            }
            .sheet(isPresented: $creating) {
                BookEditorSheet(book: nil)
            }
            .confirmationDialog(
                doomed.map { "删除「\($0.name)」？" } ?? "",
                isPresented: Binding(get: { doomed != nil }, set: { if !$0 { doomed = nil } }),
                titleVisibility: .visible
            ) {
                Button("删除账本和里面的记录", role: .destructive) {
                    if let b = doomed { store.deleteBook(id: b.id) }
                    doomed = nil
                }
                Button("取消", role: .cancel) { doomed = nil }
            } message: {
                if let b = doomed {
                    Text("里面的 \(store.count(inBook: b.id)) 笔记录会一起删除，另一台手机同步后也会消失。")
                }
            }
        }
    }

    private func bookRow(_ b: LedgerBook) -> some View {
        let on = b.id == store.currentBookId
        let n = store.count(inBook: b.id)
        return HStack(spacing: 12) {
            Text(b.emoji)
                .font(.system(size: 20))
                .frame(width: 38, height: 38)
                .background(Theme.card2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(b.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.ink)
                Text(n == 0 ? "还没有记录" : "\(n) 笔")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.ink3)
            }

            Spacer()

            if on {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.brand)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

// MARK: - 新建 / 改名账本

struct BookEditorSheet: View {
    var book: LedgerBook?

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = LedgerStore.shared

    @State private var name = ""
    @State private var emoji = "🏠"
    @State private var loaded = false

    private let emojis = ["🏠", "✈️", "🍜", "🎁", "🏢", "🛒", "🎓", "🐾", "💊", "🚗", "🎉", "💰"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(spacing: 8) {
                        Text(emoji).font(.system(size: 40))
                        TextField("账本名，比如「装修」", text: $name)
                            .font(.system(size: 17, weight: .medium))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Theme.card2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Theme.line, lineWidth: 0.7))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)

                    Text("图标")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.ink2)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 8)], spacing: 8) {
                        ForEach(emojis, id: \.self) { e in
                            Text(e)
                                .font(.system(size: 22))
                                .frame(maxWidth: .infinity)
                                .frame(height: 46)
                                .background(e == emoji ? Theme.brandSoft : Theme.card2,
                                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(e == emoji ? Theme.brand.opacity(0.5) : Theme.line,
                                                  lineWidth: e == emoji ? 1.2 : 0.7))
                                .contentShape(Rectangle())
                                .onTapGesture { emoji = e }
                        }
                    }

                    if book == nil {
                        Text("常用模板")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.ink2)

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                            ForEach(Array(LedgerBook.presets.enumerated()), id: \.offset) { _, p in
                                HStack(spacing: 5) {
                                    Text(p.emoji).font(.system(size: 14))
                                    Text(p.name)
                                        .font(.system(size: 12.5))
                                        .foregroundStyle(Theme.ink2)
                                }
                                .frame(maxWidth: .infinity)
                                .frame(height: 34)
                                .background(Theme.card2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    emoji = p.emoji
                                    name = p.name
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(Theme.bg)
            .navigationTitle(book == nil ? "新建账本" : "修改账本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .fontWeight(.semibold)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                if let b = book {
                    name = b.name
                    emoji = b.emoji
                }
            }
        }
    }

    private func save() {
        if let b = book {
            store.renameBook(id: b.id, name: name, emoji: emoji)
        } else {
            store.addBook(name: name, emoji: emoji)
        }
        dismiss()
    }
}
