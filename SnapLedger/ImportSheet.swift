//
//  ImportSheet.swift
//  从 Excel / CSV / 任意表格导入旧账
//
//  为什么不做 .xlsx 二进制解析：
//    xlsx 本质是 zip 包里的 XML，要自己写 zip 解压 + 三张表关联，出错面很大，
//    而用户真正会用的路径是「在 Excel 里另存为 CSV」（一步），
//    或者直接从 Excel 复制一片单元格粘进来（零步）。这两条已经覆盖绝大多数场景。
//    真选了 .xlsx 会明确提示去另存，而不是模棱两可地失败。
//
//  列识别做成「表头关键词优先，其次按内容猜」：
//    各家 App 导出的表头五花八门（交易时间 / 记账日期 / 金额(元) / 收/支 …），
//    写死某一种格式必然漏，所以两套兜底都要有。
//

import SwiftUI
import UniformTypeIdentifiers
import CoreFoundation
import UIKit

// MARK: - 解析结果

struct ImportRow: Identifiable {
    let id = UUID()
    let ts: Double
    let amount: Double
    let isIncome: Bool
    let category: String
    let emoji: String
    let note: String
    let method: String
}

struct ImportOutcome {
    var rows: [ImportRow] = []
    var duplicate = 0
    var unreadable = 0
    var mapping = ""
    var error: String?
}

// MARK: - 列映射

private struct ColumnMap {
    var date = -1
    var amount = -1
    var type = -1
    var category = -1
    var note = -1
    var method = -1

    var valid: Bool { date >= 0 && amount >= 0 }

    var describe: String {
        var parts = ["日期=第\(date + 1)列", "金额=第\(amount + 1)列"]
        if category >= 0 { parts.append("分类=第\(category + 1)列") }
        if note >= 0 { parts.append("备注=第\(note + 1)列") }
        if type >= 0 { parts.append("收支=第\(type + 1)列") }
        if method >= 0 { parts.append("支付=第\(method + 1)列") }
        return parts.joined(separator: " · ")
    }

    static func from(header: [String]) -> ColumnMap {
        var m = ColumnMap()
        for (i, raw) in header.enumerated() {
            let k = raw.lowercased().trimmingCharacters(in: .whitespaces)
            if k.isEmpty { continue }
            if m.date < 0, hit(k, ["日期", "时间", "date", "time"]) { m.date = i; continue }
            if m.amount < 0, hit(k, ["金额", "amount", "money", "价格", "发生额"]) { m.amount = i; continue }
            if m.type < 0, hit(k, ["收/支", "收支", "类型", "方向", "type"]) { m.type = i; continue }
            if m.category < 0, hit(k, ["分类", "类别", "category", "科目", "项目"]) { m.category = i; continue }
            if m.note < 0, hit(k, ["备注", "说明", "描述", "摘要", "商家", "商品", "用途",
                                   "note", "remark", "memo"]) { m.note = i; continue }
            if m.method < 0, hit(k, ["支付", "方式", "账户", "渠道", "method", "account"]) { m.method = i; continue }
        }
        return m
    }

    private static func hit(_ k: String, _ words: [String]) -> Bool {
        words.contains { k.contains($0) }
    }

    /// 没有表头时按内容推断：哪一列「像日期」、哪一列「像金额」
    static func infer(_ table: [[String]]) -> ColumnMap {
        let cols = table.map { $0.count }.max() ?? 0
        guard cols > 0 else { return ColumnMap() }
        let sample = Array(table.prefix(30))

        var dateCol = (-1, 0.0)
        var amountCol = (-1, 0.0)

        for c in 0..<cols {
            var dateHits = 0
            var amountHits = 0
            var total = 0
            for row in sample where c < row.count {
                let v = row[c].trimmingCharacters(in: .whitespaces)
                if v.isEmpty { continue }
                total += 1
                if TableImporter.parseDate(v) != nil { dateHits += 1 }
                else if TableImporter.parseAmount(v) != nil { amountHits += 1 }
            }
            guard total > 0 else { continue }
            let dr = Double(dateHits) / Double(total)
            let ar = Double(amountHits) / Double(total)
            if dr >= 0.6, dr > dateCol.1 { dateCol = (c, dr) }
            if ar >= 0.7, ar > amountCol.1 { amountCol = (c, ar) }
        }

        var m = ColumnMap()
        m.date = dateCol.0
        m.amount = amountCol.0

        // 备注：第一个既不是日期也不是金额、且有中文的列
        for c in 0..<cols where c != m.date && c != m.amount {
            let texts = sample.compactMap { c < $0.count ? $0[c] : nil }
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard !texts.isEmpty else { continue }
            let chinese = texts.filter { $0.range(of: "\\p{Han}", options: .regularExpression) != nil }
            if chinese.count >= texts.count / 2 {
                m.note = c
                break
            }
        }
        return m
    }
}

// MARK: - 解析

enum TableImporter {

    static func decode(_ data: Data) -> String? {
        // xlsx / xls 本质是 zip 或 OLE 二进制，先按魔数挡掉，直接给明确提示，
        // 不要让它走到「解码出一堆乱码再报认不出列」那条路上
        if data.count > 4 {
            let b = [UInt8](data.prefix(4))
            if b == [0x50, 0x4B, 0x03, 0x04] { return nil }        // zip → xlsx
            if b == [0xD0, 0xCF, 0x11, 0xE0] { return nil }        // OLE → xls
        }
        // Windows 版 Excel 导出的 CSV 多数是 GBK/GB18030，UTF-8 优先，再兜底
        if let s = String(data: data, encoding: .utf8) { return s }
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        if let s = String(data: data, encoding: gb) { return s }
        if let s = String(data: data, encoding: .utf16) { return s }
        return nil
    }

    static func parse(_ raw: String, existing: Set<String>) -> ImportOutcome {
        var out = ImportOutcome()

        let text = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else {
            out.error = "没有读到任何内容"
            return out
        }

        let sep = detectSeparator(lines)
        var table = lines.map { split($0, sep: sep) }

        var map = ColumnMap()
        if isHeader(table[0]), table.count > 1 {
            map = ColumnMap.from(header: table[0])
            table.removeFirst()
        }
        if !map.valid {
            map = ColumnMap.infer(table)
        }
        guard map.valid else {
            out.error = "认不出哪一列是日期、哪一列是金额。请保留表头（含「日期」「金额」字样），或按「日期,金额,分类,备注」的顺序排列。"
            return out
        }
        out.mapping = map.describe

        var seen = existing
        for cells in table {
            guard let row = buildRow(cells, map) else {
                out.unreadable += 1
                continue
            }
            let key = "\(Int(row.ts))|\(row.amount)"
            if seen.contains(key) {
                out.duplicate += 1
                continue
            }
            seen.insert(key)
            out.rows.append(row)
        }

        if out.rows.isEmpty {
            if out.duplicate > 0 {
                out.error = "这批账已经在账本里了（重复 \(out.duplicate) 条）"
            } else {
                out.error = "没有一行能同时读出「日期」和「金额」"
            }
        }
        return out
    }

    // MARK: 单行

    private static func buildRow(_ cells: [String], _ m: ColumnMap) -> ImportRow? {
        func cell(_ i: Int) -> String {
            guard i >= 0, i < cells.count else { return "" }
            return cells[i].trimmingCharacters(in: .whitespaces)
        }

        guard let ts = parseDate(cell(m.date)) else { return nil }
        guard let signed = parseAmount(cell(m.amount)), abs(signed) > 0 else { return nil }

        var income = false
        let typeText = cell(m.type).lowercased()
        if typeText.contains("收") || typeText.contains("income") || typeText.contains("入账") {
            income = true
        }

        let rawCategory = cell(m.category)
        let note = cell(m.note)

        let cat = matchCategory(rawCategory, income: income)
            ?? guess(note + " " + rawCategory, income: income)
        let categoryName = cat?.name ?? "其他"
        let emoji = cat?.emoji ?? "📦"

        return ImportRow(ts: ts,
                         amount: abs(signed),
                         isIncome: income,
                         category: categoryName,
                         emoji: emoji,
                         note: note,
                         method: cell(m.method))
    }

    private static func matchCategory(_ s: String, income: Bool) -> BillCategory? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        let list = income ? BillParser.incomeCategories : BillParser.expenseCategories
        if let exact = list.first(where: { $0.name == t }) { return exact }
        return list.first { !$0.name.isEmpty && (t.contains($0.name) || $0.name.contains(t)) }
    }

    private static func guess(_ text: String, income: Bool) -> BillCategory? {
        let low = text.lowercased().trimmingCharacters(in: .whitespaces)
        guard low.count > 1 else { return nil }
        let list = income ? BillParser.incomeCategories : BillParser.expenseCategories
        var best: (cat: BillCategory, hits: Int)?
        for c in list {
            var hits = 0
            for k in c.keywords where low.contains(k.lowercased()) { hits += 1 }
            if hits > 0, hits > (best?.hits ?? 0) { best = (c, hits) }
        }
        return best?.cat
    }

    // MARK: 切分

    private static func detectSeparator(_ lines: [String]) -> Character {
        let sample = lines.prefix(6)
        var best: (ch: Character, n: Int) = (",", 0)
        for ch in [Character("\t"), ",", ";", "|"] {
            let n = sample.reduce(0) { $0 + $1.filter { $0 == ch }.count }
            if n > best.n { best = (ch, n) }
        }
        return best.ch
    }

    /// 支持双引号包裹（Excel 导出的备注里常带逗号）
    private static func split(_ line: String, sep: Character) -> [String] {
        var out: [String] = []
        var cur = ""
        var inQuote = false
        for ch in line {
            if ch == "\"" {
                inQuote.toggle()
            } else if ch == sep, !inQuote {
                out.append(cur)
                cur = ""
            } else {
                cur.append(ch)
            }
        }
        out.append(cur)
        return out
    }

    private static func isHeader(_ cells: [String]) -> Bool {
        let joined = cells.joined(separator: "|").lowercased()
        let words = ["日期", "时间", "金额", "收支", "分类", "备注", "说明",
                     "date", "amount", "note", "category", "money"]
        let hits = words.filter { joined.contains($0) }.count
        guard hits >= 1 else { return false }
        // 表头里不会有一格是纯金额，用它反向排除「备注里刚好写了『时间』」的数据行
        return !cells.contains { parseAmount($0) != nil && !$0.contains("年") }
    }

    // MARK: 日期 / 金额

    private static let dateFormats: [String] = [
        "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd",
        "yyyy/MM/dd HH:mm:ss", "yyyy/MM/dd HH:mm", "yyyy/MM/dd",
        "yyyy.MM.dd HH:mm", "yyyy.MM.dd",
        "yyyy年M月d日 HH:mm:ss", "yyyy年M月d日 HH:mm", "yyyy年M月d日",
        "MM/dd/yyyy", "M/d/yyyy",
        "yyyyMMdd"
    ]

    private static let formatters: [DateFormatter] = {
        dateFormats.map { pattern in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone.current
            f.dateFormat = pattern
            f.isLenient = false
            return f
        }
    }()

    static func parseDate(_ raw: String) -> Double? {
        let t = (raw.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? raw)
            .trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.count <= 24 else { return nil }

        // Excel 里日期若被存成数字，是「1900 起的天数」，不是文本
        if !t.contains("-"), !t.contains("/"), !t.contains("年"),
           let n = Double(t), n > 20000, n < 80000 {
            return excelSerial(n)
        }

        let hasTime = t.contains(":")
        for f in formatters {
            if let d = f.date(from: t) {
                // 只有日期时记到中午：记成 00:00 会让列表看起来像半夜花的钱
                let fixed = hasTime ? d : d.addingTimeInterval(12 * 3600)
                return fixed.timeIntervalSince1970 * 1000
            }
        }
        return nil
    }

    private static func excelSerial(_ v: Double) -> Double? {
        var c = DateComponents()
        c.year = 1899
        c.month = 12
        c.day = 30
        guard let base = Calendar.current.date(from: c) else { return nil }
        let d = base.addingTimeInterval(v * 86400)
        return d.timeIntervalSince1970 * 1000
    }

    static func parseAmount(_ raw: String) -> Double? {
        var t = (raw.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? raw)
            .trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }

        var negative = false
        if t.hasPrefix("("), t.hasSuffix(")") {
            negative = true
            t = String(t.dropFirst().dropLast())
        }
        for junk in ["¥", "￥", "元", "人民币", "CNY", "cny", " ", ",", "＋", "+"] {
            t = t.replacingOccurrences(of: junk, with: "")
        }
        if t.hasPrefix("-") {
            negative = true
            t = String(t.dropFirst())
        }
        // 「收入 300」这种带前缀文字的，取最后一段数字
        if Double(t) == nil {
            let digits = t.filter { ($0 >= "0" && $0 <= "9") || $0 == "." }
            t = String(digits)
        }
        guard let v = Double(t), v.isFinite else { return nil }
        return negative ? -v : v
    }
}

// MARK: - 界面

struct ImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = LedgerStore.shared

    @State private var text = ""
    @State private var fileName = ""
    @State private var outcome: ImportOutcome?
    @State private var showPicker = false
    @State private var importedCount: Int?
    @State private var trouble: String?
    @State private var analyzedText = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if let n = importedCount {
                        doneCard(n)
                    } else {
                        introCard
                        actionRow
                        if let trouble { troubleCard(trouble) }
                        editorCard
                        if let o = outcome { previewCard(o) }
                    }
                }
                .padding(16)
                .padding(.bottom, 8)
            }
            .background(Theme.bg)
            .navigationTitle("导入账单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(importedCount == nil ? "取消" : "完成") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if importedCount == nil { importBar }
            }
            .fileImporter(isPresented: $showPicker,
                          allowedContentTypes: [.commaSeparatedText, .tabSeparatedText,
                                                .plainText, .spreadsheet],
                          allowsMultipleSelection: false) { result in
                handlePick(result)
            }
        }
    }

    // MARK: 说明

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("支持哪些格式", systemImage: "tablecells")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(Theme.ink)

            bullet("CSV 文件（Excel 里「另存为 CSV」，推荐）")
            bullet("从 Excel / 网页表格直接复制，粘贴到下面")
            bullet("表头有「日期」「金额」字样最好；没有也能按内容猜")

            Text("xlsx 请先另存为 CSV —— 二进制表格格式不在支持范围内。")
                .font(.system(size: 11))
                .foregroundStyle(Theme.ink3)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func bullet(_ s: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("·")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.brand)
            Text(s)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button {
                showPicker = true
            } label: {
                Label("选择文件", systemImage: "folder")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Theme.brand)
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(Theme.brandSoft,
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)

            Button {
                if let s = UIPasteboard.general.string, !s.isEmpty {
                    text = s
                    fileName = "剪贴板"
                    analyze()
                } else {
                    trouble = "剪贴板里没有文字。先在 Excel 里选中区域复制。"
                }
            } label: {
                Label("粘贴表格", systemImage: "doc.on.clipboard")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Theme.ink2)
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(Theme.card2,
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Theme.line, lineWidth: 0.7))
            }
            .buttonStyle(.plain)
        }
    }

    private func troubleCard(_ s: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.expense)
            Text(s)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Theme.expense.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var editorCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(fileName.isEmpty ? "粘贴区" : fileName)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
                Spacer()
                if !text.isEmpty {
                    Button("清空") {
                        text = ""
                        fileName = ""
                        outcome = nil
                        trouble = nil
                        analyzedText = ""
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink3)
                }
            }

            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.ink)
                .scrollContentBackground(.hidden)
                .frame(height: 140)
                .padding(8)
                .background(Theme.card2,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.line, lineWidth: 0.7))
                .onChange(of: text) { _, v in
                    // 程序里 set text 之后马上 analyze()，onChange 会晚一拍才来；
                    // 只认「和上次分析的内容不一样」，别把刚算好的结果清掉
                    guard v != analyzedText else { return }
                    if outcome != nil { outcome = nil }
                    if trouble != nil { trouble = nil }
                }

            Text("例如：\n日期,金额,分类,备注\n2026-10-01,32.5,餐饮,午饭")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Theme.ink3)
        }
        .cardStyle()
    }

    // MARK: 预览

    private func previewCard(_ o: ImportOutcome) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("识别结果")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text("可导入 \(o.rows.count) 笔")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(o.rows.isEmpty ? Theme.ink3 : Theme.brand)
            }

            if !o.mapping.isEmpty {
                Text(o.mapping)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.ink3)
                    .lineLimit(2)
            }

            if o.duplicate > 0 || o.unreadable > 0 {
                HStack(spacing: 10) {
                    if o.duplicate > 0 {
                        TagView(text: "重复 \(o.duplicate) 条已跳过", color: Theme.ink3)
                    }
                    if o.unreadable > 0 {
                        TagView(text: "读不出 \(o.unreadable) 行", color: Theme.expense)
                    }
                    Spacer(minLength: 0)
                }
            }

            if !o.rows.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(o.rows.prefix(8))) { r in
                        previewRow(r)
                        Rectangle().fill(Theme.line).frame(height: 0.6)
                    }
                }

                if o.rows.count > 8 {
                    Text("下面还有 \(o.rows.count - 8) 笔，导入后都能看到")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.ink3)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func previewRow(_ r: ImportRow) -> some View {
        HStack(spacing: 9) {
            Text(r.emoji)
                .font(.system(size: 14))
                .frame(width: 26, height: 26)
                .background(Tint.of(r.category).opacity(0.13), in: Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(r.note.isEmpty ? r.category : r.note)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text(Fmt.mdhm(r.ts) + " · " + r.category)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.ink3)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Text((r.isIncome ? "+" : "-") + Money.currency(r.amount))
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(r.isIncome ? Theme.income : Theme.ink)
        }
        .padding(.vertical, 6)
    }

    // MARK: 底部按钮

    private var importBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.line).frame(height: 0.6)

            Button(action: runImport) {
                Text(buttonTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(canImport ? Theme.brand : Theme.ink3.opacity(0.38),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.top, 9)
            .padding(.bottom, 4)
        }
        .background(Theme.bg)
    }

    private var canImport: Bool {
        (outcome?.rows.isEmpty == false)
    }

    private var buttonTitle: String {
        if let o = outcome, !o.rows.isEmpty { return "导入 \(o.rows.count) 笔" }
        return text.isEmpty ? "先粘贴或选择文件" : "分析一下"
    }

    // MARK: 动作

    private func handlePick(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let e):
            trouble = "打不开文件：\(e.localizedDescription)"
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                guard let s = TableImporter.decode(data) else {
                    trouble = "这不是文本表格。xlsx 请在 Excel 里「另存为 CSV」再导入。"
                    return
                }
                fileName = url.lastPathComponent
                text = s
                analyze()
            } catch {
                trouble = "读取失败：\(error.localizedDescription)"
            }
        }
    }

    private func analyze() {
        trouble = nil
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            trouble = "还没有内容"
            return
        }
        analyzedText = text
        let existing = Set(store.db.records.map { "\(Int($0.ts))|\($0.amount)" })
        let o = TableImporter.parse(text, existing: existing)
        outcome = o
        if let e = o.error { trouble = e }
    }

    private func runImport() {
        guard let o = outcome, !o.rows.isEmpty else {
            analyze()
            return
        }
        let records = o.rows.map { r in
            LedgerRecord(ts: r.ts,
                         type: r.isIncome ? "income" : "expense",
                         amount: r.amount,
                         category: r.category,
                         emoji: r.emoji,
                         method: r.method,
                         note: r.note,
                         source: "import")
        }
        let n = store.addBatch(records)
        withAnimation(.easeOut(duration: 0.2)) { importedCount = n }
    }

    private func doneCard(_ n: Int) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 42))
                .foregroundStyle(Theme.brand)

            Text("已导入 \(n) 笔")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.ink)

            Text("回到「账本」就能看到。如果开了同步，另一台手机拉取后也会出现。")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.ink3)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .cardStyle()
    }
}
