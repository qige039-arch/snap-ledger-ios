import SwiftUI

// MARK: - 自定义分类
//
// 内置分类是写死在 Parser 里的词表（靠关键词自动判定），用户想加「宠物美容」
// 「孩子学费」这类，词表里既没有也没关键词可判 —— 所以单独存一份。
// 它只参与「手动选分类」，不参与 OCR 自动判定：自动判定仍然走内置词表，
// 猜错了用户点一下改掉就行，但别让一套自己的词表把自动判定搅浑。
//
// 存 UserDefaults 而不是 db：分类是「本机偏好」，不参与同步，
// 也就不必动 server.js 的字段白名单（那边是白名单，加字段会被静默丢弃）。

struct CustomCategory: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var emoji: String
    var type: String      // "expense" / "income"

    init(id: String = String(UUID().uuidString.prefix(8)),
         name: String,
         emoji: String,
         type: String) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.type = type
    }
}

enum CategoryStore {
    private static let key = "snap.custom.cats"

    static func all() -> [CustomCategory] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([CustomCategory].self, from: data) else { return [] }
        return list
    }

    static func all(type: String) -> [CustomCategory] {
        all().filter { $0.type == type }
    }

    @discardableResult
    static func add(name: String, emoji: String, type: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n.count <= 6 else { return false }
        var list = all()
        // 内置分类里已经有的名字不再加一份，否则选择器里会出现两个同名项
        let builtin = (type == "income" ? BillParser.incomeCategories : BillParser.expenseCategories)
        guard !builtin.contains(where: { $0.name == n }) else { return false }
        guard !list.contains(where: { $0.name == n && $0.type == type }) else { return false }
        list.append(CustomCategory(name: n, emoji: emoji, type: type))
        save(list)
        return true
    }

    static func remove(id: String) {
        save(all().filter { $0.id != id })
    }

    static func isCustom(name: String) -> Bool {
        all().contains { $0.name == name }
    }

    private static func save(_ list: [CustomCategory]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

// MARK: - 新增分类

struct AddCategorySheet: View {
    /// "expense" / "income"
    let type: String
    var onSave: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var emoji = "🏷️"

    /// 挑的都是「一眼能认出是什么」的图，不塞生僻符号 ——
    /// 自定义分类的图标最终要在一堆 12pt 小方块里认出来。
    private let palette = [
        "🏷️", "🍜", "🥬", "🍎", "🧋", "🍰", "🥩", "🍚",
        "🚗", "🚌", "🚇", "⛽", "🅿️", "🚲", "✈️", "🚕",
        "🛒", "🛍️", "👕", "👟", "💄", "💍", "🎁", "🧸",
        "🏠", "💡", "💧", "🔥", "🧹", "🛠️", "🪑", "🧺",
        "💊", "🏥", "🦷", "👓", "📚", "✏️", "🎓", "🎒",
        "🎬", "🎮", "🎤", "🏀", "🎣", "🏕️", "🐱", "🐶",
        "📱", "💻", "🎧", "⌚", "💰", "🧧", "💳", "📈"
    ]

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 8), count: 8)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("分类名称")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.ink2)
                        TextField(type == "income" ? "比如「房租收入」" : "比如「宠物美容」", text: $name)
                            .font(.system(size: 15))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 11)
                            .background(Theme.card2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Theme.line, lineWidth: 0.7))
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        Text("选个小图标")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.ink2)
                        LazyVGrid(columns: cols, spacing: 8) {
                            ForEach(palette, id: \.self) { e in
                                let on = e == emoji
                                Text(e)
                                    .font(.system(size: 20))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 40)
                                    .background(on ? Theme.brandSoft : Theme.card2,
                                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(on ? Theme.brand.opacity(0.6) : Color.clear, lineWidth: 1.2))
                                    .contentShape(Rectangle())
                                    .onTapGesture { emoji = e }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(Theme.bg)
            .navigationTitle("新增分类")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(name.trimmingCharacters(in: .whitespacesAndNewlines), emoji)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
