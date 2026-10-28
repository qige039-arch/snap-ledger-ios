//
//  Parser.swift
//  账单语义解析 —— 从 ocr.js 1:1 移植
//
//  核心思路（和网页版一致，不要「优化」掉这些看起来奇怪的地方）：
//  1. 金额不用一条正则取，而是六种模式各自出候选 + 加权打分，最后取最高分。
//     原因：支付截图、银行短信、小票的版式完全不一样，单条正则必然在某一类上失败。
//  2. 打分之后还要看上下文：金额前面紧邻「余额/原价/额度」的重罚，
//     紧跟「年/月/日/时/分」的重罚 —— 这是「2026 被当成金额」的根治办法。
//  3. 「支付成功」这类关键词后面最多跟 10 个非数字字符，且不允许跨行。
//     用 \s* 会吃掉换行，把下一行的时间当金额。
//

import Foundation

// MARK: - 输出结构

struct BillCategory {
    let name: String
    let emoji: String
    let keywords: [String]
}

struct ParsedBill {
    var type: String              // "expense" / "income"
    var amount: Double
    var amountCandidates: [Double]
    var merchant: String
    var category: String
    var emoji: String
    var ts: Double                // 毫秒
    var method: String
    var member: String
    var confidence: Int
    var lines: [String]

    var isIncome: Bool { type == "income" }

    func toRecord(source: String) -> LedgerRecord {
        LedgerRecord(ts: ts,
                     type: type,
                     amount: amount,
                     category: category,
                     emoji: emoji,
                     merchant: merchant,
                     method: method,
                     member: member,
                     source: source)
    }
}

// MARK: - 解析器

enum BillParser {

    // MARK: 词表

    static let expenseCategories: [BillCategory] = [
        BillCategory(name: "餐饮", emoji: "🍜", keywords: ["餐", "饭", "食", "咖啡", "奶茶", "茶饮", "星巴克", "瑞幸", "库迪", "麦当劳", "肯德基", "kfc", "mcdonald", "汉堡", "海底捞", "火锅", "烧烤", "面馆", "米线", "米粉", "小吃", "食堂", "外卖", "饿了么", "美团外卖", "美团", "大众点评", "甜品", "烘焙", "面包", "早点", "早餐", "午餐", "晚餐", "饮料", "果汁", "喜茶", "蜜雪", "奈雪", "粉", "粥", "饺子", "披萨", "寿司", "料理", "聚餐", "酒店餐饮"]),
        BillCategory(name: "交通", emoji: "🚇", keywords: ["地铁", "公交", "巴士", "滴滴", "打车", "出租", "高德", "曹操", "t3出行", "加油", "中石化", "中石油", "壳牌", "停车", "etc", "高速", "通行费", "铁路", "12306", "火车", "高铁", "机票", "航空", "航班", "单车", "哈啰", "青桔", "摩拜", "充电桩", "特斯拉超充", "车费", "泊车"]),
        BillCategory(name: "购物", emoji: "🛍", keywords: ["淘宝", "天猫", "京东", "拼多多", "唯品会", "苏宁", "商城", "百货", "优衣库", "zara", "耐克", "nike", "阿迪", "adidas", "小米", "华为", "apple", "苹果", "三星", "服饰", "衣服", "鞋", "包", "化妆品", "护肤", "口红", "数码", "耳机", "家电", "京东自营", "天猫超市"]),
        BillCategory(name: "日用", emoji: "🧴", keywords: ["超市", "沃尔玛", "永辉", "盒马", "华润万家", "大润发", "家乐福", "便利店", "全家", "罗森", "7-11", "711", "美宜佳", "生鲜", "菜市场", "买菜", "蔬菜", "水果", "日用", "洗护", "纸巾", "清洁", "五金", "药妆", "屈臣氏", "菜"]),
        BillCategory(name: "娱乐", emoji: "🎬", keywords: ["电影", "影院", "影城", "ktv", "游戏", "steam", "演出", "演唱会", "门票", "景区", "旅游", "酒店", "民宿", "会员", "订阅", "音乐", "网易云", "qq音乐", "爱奇艺", "腾讯视频", "优酷", "b站", "哔哩哔哩", "健身", "球", "游泳", "剧本杀", "密室", "桌游"]),
        BillCategory(name: "医疗", emoji: "💊", keywords: ["医院", "诊所", "药", "药店", "大药房", "体检", "牙科", "口腔", "挂号", "门诊", "急诊", "医疗", "医保", "眼科", "中医", "保健"]),
        BillCategory(name: "居住", emoji: "🏠", keywords: ["房租", "租金", "物业", "水费", "电费", "燃气", "暖气", "宽带", "家政", "保洁", "维修", "装修", "家具", "房贷"]),
        BillCategory(name: "通讯", emoji: "📱", keywords: ["话费", "流量", "中国移动", "中国联通", "中国电信", "充值话费", "宽带费", "手机费"]),
        BillCategory(name: "学习", emoji: "📚", keywords: ["书店", "图书", "当当", "课程", "培训", "学费", "教育", "得到", "知识星球", "网课", "考试", "报名费", "文具", "打印"]),
        BillCategory(name: "人情", emoji: "🎁", keywords: ["红包", "礼金", "礼物", "请客", "转账给", "捐赠", "公益", "份子"]),
        BillCategory(name: "宠物", emoji: "🐾", keywords: ["宠物", "猫粮", "狗粮", "猫砂", "宠物医院", "洗澡", "驱虫", "疫苗"]),
        BillCategory(name: "其他", emoji: "📦", keywords: [])
    ]

    static let incomeCategories: [BillCategory] = [
        BillCategory(name: "工资", emoji: "💰", keywords: ["工资", "薪资", "月薪", "薪水", "代发"]),
        BillCategory(name: "奖金", emoji: "🏆", keywords: ["奖金", "绩效", "提成", "年终"]),
        BillCategory(name: "红包", emoji: "🧧", keywords: ["红包", "压岁", "礼金"]),
        BillCategory(name: "退款", emoji: "↩️", keywords: ["退款", "退货", "退回", "撤销"]),
        BillCategory(name: "理财", emoji: "📈", keywords: ["收益", "利息", "基金", "股票", "理财", "分红"]),
        BillCategory(name: "报销", emoji: "🧾", keywords: ["报销", "补贴", "补助"]),
        BillCategory(name: "其他", emoji: "📦", keywords: [])
    ]

    // MARK: 小工具

    private static func all(_ pattern: String,
                            _ s: NSString,
                            _ options: NSRegularExpression.Options = []) -> [NSTextCheckingResult] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else {
            assertionFailure("正则编译失败: \(pattern)")
            return []
        }
        return re.matches(in: s as String, options: [], range: NSRange(location: 0, length: s.length))
    }

    private static func sub(_ m: NSTextCheckingResult, _ i: Int, _ s: NSString) -> String {
        guard i < m.numberOfRanges else { return "" }
        let r = m.range(at: i)
        guard r.location != NSNotFound else { return "" }
        return s.substring(with: r)
    }

    /// 取 at 之前的 len 个字符（不足就从 0 开始），别直接把负数喂给 substring
    private static func before(_ s: NSString, _ at: Int, _ len: Int) -> String {
        let end = max(0, min(at, s.length))
        let start = max(0, end - len)
        return s.substring(with: NSRange(location: start, length: end - start))
    }

    /// 取 at 之后的 len 个字符
    private static func after(_ s: NSString, _ at: Int, _ len: Int) -> String {
        let start = max(0, min(at, s.length))
        let end = max(start, min(start + len, s.length))
        return s.substring(with: NSRange(location: start, length: end - start))
    }

    private static func has(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func cleanNum(_ raw: String) -> Double {
        let digits = raw.replacingOccurrences(of: "[^0-9.]", with: "", options: .regularExpression)
        return Double(digits) ?? .nan
    }

    // MARK: - 金额

    /// 这些词出现在金额附近，说明它不是本次实付
    private static let negWords = ["余额", "优惠", "折扣", "立减", "红包抵扣", "积分", "抹零",
                                   "原价", "小计金", "卡内", "可用", "额度", "运费险", "返现",
                                   "预计", "最高", "最低", "起"]

    private struct AmountHit {
        var v: Double
        var w: Double
        var note: String
        var at: Int
        var rawLen: Int
    }

    static func extractAmount(_ text: String) -> (amount: Double, weight: Double, candidates: [Double]) {
        let flat = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        let s = flat as NSString
        var cands: [AmountHit] = []

        func push(_ m: NSTextCheckingResult, _ group: Int, _ weight: Double, _ note: String) {
            let r = m.range(at: group)
            guard r.location != NSNotFound else { return }
            let raw = s.substring(with: r)
            let v = cleanNum(raw)
            guard v.isFinite, v > 0, v <= 50_000_000 else { return }
            cands.append(AmountHit(v: v, w: weight, note: note, at: r.location, rawLen: r.length))
        }

        // 1) 强句式。禁止跨行 —— 否则「支付成功\n支付时间 2026年」会把年份当金额
        let kwPattern = "(实付|实际支付|实际付款|付款金额|支付金额|交易金额|订单金额|消费金额|合计|总计|总额|应付|应收|支付成功|成功付款|本次消费|支出金额|收款|到账|入账)[^\\d\\-−¥￥\\n]{0,10}[-−]?[ \\t]*[¥￥]?[ \\t]*([\\d,]+(?:\\.\\d{1,2})?)"
        for m in all(kwPattern, s) {
            let kw = sub(m, 1, s)
            let w: Double = (kw.contains("收款") || kw.contains("到账") || kw.contains("入账")) ? 95 : 100
            push(m, 2, w, kw)
        }

        // 2) 银行短信：人民币 XXX / 支出 XXX 元
        for m in all("(?:人民币|RMB|CNY)\\s*([\\d,]+(?:\\.\\d{1,2})?)", s, .caseInsensitive) {
            push(m, 1, 86, "人民币")
        }
        for m in all("(支出|消费|扣款|支付|转入|收入)[^\\d\\n]{0,8}([\\d,]+\\.\\d{1,2})\\s*元", s) {
            push(m, 2, 90, "元")
        }

        // 3) ¥ / ￥ 前缀
        for m in all("[¥￥]\\s*([\\d,]+(?:\\.\\d{1,2})?)", s) {
            push(m, 1, 62, "¥")
        }

        // 4) 负号金额（-38.50）：支付截图里最常见的主金额形式
        for m in all("[-−]\\s*[¥￥]?\\s*([\\d,]+\\.\\d{1,2})", s) {
            push(m, 1, 78, "-")
        }

        // 5) 带两位小数的数字
        for m in all("(?:^|[^\\d.,])([\\d,]{1,7}\\.\\d{2})(?![\\d])", s) {
            push(m, 1, 24, "dec")
        }

        // 6) 独立成行的大字金额。¥ 常被 OCR 认成 x / * / Y，所以前缀字符放宽
        for m in all("(?:^|\\n)[ \\t]*[¥￥YyxX*×＊·.\\-−]{0,3}[ \\t]*([\\d,]{1,7}\\.\\d{2})[ \\t]*(?=\\n|$)", s) {
            push(m, 1, 58, "line")
        }

        if cands.isEmpty { return (0, 0, []) }

        // 上下文校正
        for i in cands.indices {
            let c = cands[i]
            let pre = before(s, c.at, 8)
            let post = after(s, c.at + c.rawLen, 14)
            let preTrim = pre.trimmingCharacters(in: .whitespaces)
            let postTrim = post.trimmingCharacters(in: .whitespaces)

            var w = c.w
            for neg in negWords {
                if pre.contains(neg) { w -= 62; break }
                if post.contains(neg) { w -= 34; break }
            }
            if postTrim.hasPrefix("元") { w += 18 }
            if preTrim.hasSuffix(":") || preTrim.hasSuffix("：") { w -= 50 }
            if postTrim.hasPrefix(":") || postTrim.hasPrefix("：") { w -= 50 }
            if let f = postTrim.first, "年月日号时分秒点".contains(f) { w -= 95 }
            if let l = preTrim.last, "年月日号".contains(l) { w -= 95 }
            if let l = pre.last, l.isNumber { w -= 40 }
            cands[i].w = w
        }

        // 同一金额保留最高权重
        var best: [String: AmountHit] = [:]
        for c in cands {
            let k = String(format: "%.2f", c.v)
            if let cur = best[k] {
                if cur.w < c.w { best[k] = c }
            } else {
                best[k] = c
            }
        }
        var list = Array(best.values)
        list.sort { a, b in
            if a.w != b.w { return a.w > b.w }
            return a.v > b.v
        }

        let top = list[0]
        let others = list.dropFirst().prefix(5).filter { $0.w >= 15 }.map { $0.v }.filter { $0 != top.v }
        return (top.v, top.w, others)
    }

    // MARK: - 收 / 支

    static func detectType(_ text: String, _ merchant: String) -> String {
        // 「收款方 X」「付款方 X」只是角色标签，不代表方向。
        // 不剥掉的话，「收款方 美团外卖」会把付款认成收入。
        let t = (text + " " + merchant)
            .replacingOccurrences(of: "(收款方|付款方|收款账户|付款账户|收款人|付款人)", with: " ", options: .regularExpression)

        if t.contains("退款") || t.contains("已退款") || t.contains("退回") || t.contains("退货") {
            return "income"
        }
        // 金额前的负号是最硬的方向信号；先把日期时间剥掉，免得 2026-10-28 的 - 被当成符号
        var bare = t.replacingOccurrences(of: "\\d{4}\\s*[-/年.]\\s*\\d{1,2}\\s*[-/月.]\\s*\\d{1,2}\\s*日?",
                                          with: " ", options: .regularExpression)
        bare = bare.replacingOccurrences(of: "\\d{1,2}\\s*[-:：]\\s*\\d{2}(?:\\s*[-:：]\\s*\\d{2})?",
                                         with: " ", options: .regularExpression)
        if has("[-−]\\s*[¥￥]?\\s*\\d", bare) { return "expense" }

        if has("(收款|到账|收入|入账|红包已领取|工资|薪资|报销|转入)", t) { return "income" }
        if has("(付款成功|支付成功|已付款|支出|消费|扣款|结算|订单)", t) { return "expense" }
        return "expense"
    }

    // MARK: - 商户

    private static let merchantHint = "(店|超市|商城|餐厅|饭店|咖啡|茶|便利|药房|药店|医院|诊所|公司|科技|有限|集团|中心|广场|酒店|宾馆|馆|行|社|部|局|站|场|院|城|汇|轩|苑|坊|铺|屋|吧|会所|俱乐部|work|store|shop|coffee|cafe)"

    private static let skipLine = "(微信支付|支付宝|云闪付|账单|详情|订单号|交易号|支付时间|付款方式|支付方式|到账时间|服务|客服|协议|隐私|查看更多|当前状态|支付成功|付款成功|已付款|退款|账户|尾号|余额|商品|完成|返回|确定|取消)"

    static func extractMerchant(_ text: String, lines: [String]) -> String {
        let flat = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let s = flat as NSString

        // 1) 最强的明确句式
        let strong = [
            "付款给[：:\\s]*([^\\s，,。；;]{2,24})",
            "收款方[：:\\s]*([^\\s，,。；;]{2,24})",
            "对方[：:\\s]*([^\\s，,。；;]{2,24})",
            "向\\s*([^\\s，,。；;]{2,20})\\s*(?:付款|转账)",
            "给\\s*([^\\s，,。；;]{2,20})\\s*(?:付款|转账)",
            "【([^】]{2,20})】"
        ]
        for p in strong {
            for m in all(p, s) {
                let v = sub(m, 1, s)
                if v.isEmpty { continue }
                if ["微信", "支付宝", "零钱", "余额", "银行卡", "支付", "收款"].contains(v) { continue }
                return tidy(v)
            }
        }

        // 2) 前 3 行里第一个像名字的短行（支付截图的标题位置）
        for i in 0..<min(lines.count, 3) {
            let L = lines[i].trimmingCharacters(in: .whitespaces)
            if L.count >= 2, L.count <= 20,
               !has("^[\\d\\s.,:：¥￥\\-−+/]+$", L),
               !has(skipLine, L) {
                return tidy(L)
            }
        }

        // 3) 商户字段
        for p in ["商户全称[：:\\s]*([^\\s，,。；;]{2,30})",
                  "商户名称[：:\\s]*([^\\s，,。；;]{2,30})",
                  "商户[：:\\s]*([^\\s，,。；;]{2,24})"] {
            for m in all(p, s) {
                let v = sub(m, 1, s)
                if !v.isEmpty { return tidy(v) }
            }
        }

        // 4) 全文里带行业词、且最像名字的一行
        var bestLine = ""
        for raw in lines {
            let L = raw.trimmingCharacters(in: .whitespaces)
            if L.count < 2 || L.count > 26 { continue }
            if has("^[\\d\\s.,:：¥￥\\-−+/]+$", L) { continue }
            if has(skipLine, L) { continue }
            if has(merchantHint, L), L.count > bestLine.count { bestLine = L }
        }
        return bestLine.isEmpty ? "" : tidy(bestLine)
    }

    private static func tidy(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "^[：:\\s\\-−]+", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "[：:\\s\\-−,，。]+$", with: "", options: .regularExpression)
        return String(t.prefix(24))
    }

    // MARK: - 类别

    static func detectCategory(_ text: String, type: String) -> BillCategory {
        let pool = type == "income" ? incomeCategories : expenseCategories
        let t = " " + text.lowercased() + " "
        var best = pool[pool.count - 1]
        var bestScore = 0
        for cat in pool {
            var score = 0
            for k in cat.keywords where t.contains(k.lowercased()) {
                score += min(4, k.count)
            }
            if score > bestScore {
                bestScore = score
                best = cat
            }
        }
        return best
    }

    // MARK: - 时间

    static func detectDate(_ text: String) -> Double {
        let now = Date()
        let cal = Calendar.current
        let t = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let s = t as NSString
        let hourNow = cal.component(.hour, from: now)
        let minNow = cal.component(.minute, from: now)

        func stamp(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Double? {
            var c = DateComponents()
            c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi
            return cal.date(from: c)?.timeIntervalSince1970
        }

        // 2026-10-28 / 2026年10月28日 / 2026.10.28
        if let m = all("(20\\d{2})\\s*[年\\-/.]\\s*(\\d{1,2})\\s*[月\\-/.]\\s*(\\d{1,2})", s).first {
            var h = hourNow, mi = minNow
            if let hm = all("(\\d{1,2})[：:](\\d{2})", s).first {
                h = Int(sub(hm, 1, s)) ?? h
                mi = Int(sub(hm, 2, s)) ?? mi
            }
            if let sec = stamp(Int(sub(m, 1, s)) ?? 0,
                               Int(sub(m, 2, s)) ?? 1,
                               Int(sub(m, 3, s)) ?? 1, h, mi),
               sec * 1000 - now.timeIntervalSince1970 * 1000 <= 86400000 {
                return sec * 1000
            }
        }

        // 10月28日（年份缺省；比现在晚一天以上就认为是去年）
        if let m = all("(\\d{1,2})\\s*月\\s*(\\d{1,2})\\s*日", s).first {
            let y = cal.component(.year, from: now)
            let mo = Int(sub(m, 1, s)) ?? 1
            let d = Int(sub(m, 2, s)) ?? 1
            if var sec = stamp(y, mo, d, hourNow, minNow) {
                if sec * 1000 - now.timeIntervalSince1970 * 1000 > 86400000 {
                    sec = stamp(y - 1, mo, d, hourNow, minNow) ?? sec
                }
                return sec * 1000
            }
        }

        if t.contains("昨天") { return now.addingTimeInterval(-86400).timeIntervalSince1970 * 1000 }
        if t.contains("前天") { return now.addingTimeInterval(-172800).timeIntervalSince1970 * 1000 }

        // 10-28 20:16
        if let m = all("(\\d{1,2})[-/](\\d{1,2})\\s+(\\d{1,2})[：:](\\d{2})", s).first {
            let y = cal.component(.year, from: now)
            let mo = Int(sub(m, 1, s)) ?? 1
            let d = Int(sub(m, 2, s)) ?? 1
            let h = Int(sub(m, 3, s)) ?? hourNow
            let mi = Int(sub(m, 4, s)) ?? minNow
            if var sec = stamp(y, mo, d, h, mi) {
                if sec * 1000 - now.timeIntervalSince1970 * 1000 > 86400000 {
                    sec = stamp(y - 1, mo, d, h, mi) ?? sec
                }
                return sec * 1000
            }
        }

        return now.timeIntervalSince1970 * 1000
    }

    // MARK: - 支付方式

    static func detectMethod(_ text: String) -> String {
        if text.contains("云闪付") { return "云闪付" }
        if text.contains("花呗") { return "花呗" }
        if has("(微信支付|零钱|微信)", text) { return "微信" }
        if has("(支付宝|余额宝)", text) { return "支付宝" }
        if has("(信用卡|银行卡|储蓄卡|工商银行|建设银行|招商银行|农业银行|中国银行)", text) { return "银行卡" }
        if text.contains("现金") { return "现金" }
        return ""
    }

    // MARK: - 主入口：整段账单文字

    static func analyze(_ rawText: String) -> ParsedBill {
        let text = rawText.replacingOccurrences(of: "\r", with: "")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let amt = extractAmount(text)
        let merchant = extractMerchant(text, lines: lines)
        let type = detectType(text, merchant)
        let cat = detectCategory(text + " " + merchant, type: type)
        let ts = detectDate(text)
        let method = detectMethod(text)

        var conf = 0
        if amt.amount > 0 {
            conf += amt.weight >= 90 ? 55 : (amt.weight >= 50 ? 38 : 22)
        }
        if !merchant.isEmpty { conf += 22 }
        if let k = cat.keywords.first, text.lowercased().contains(k.lowercased()) { conf += 8 }
        conf = min(96, conf)

        return ParsedBill(type: type,
                          amount: amt.amount,
                          amountCandidates: amt.candidates,
                          merchant: merchant,
                          category: cat.name,
                          emoji: cat.emoji,
                          ts: ts,
                          method: method,
                          member: "",
                          confidence: conf,
                          lines: lines)
    }

    // MARK: - 口语短句

    private static let incomeHint = "(工资|薪资|发薪|奖金|提成|年终|报销|退款|退回|收到|进账|入账|到账|利息|分红|收益|中奖|卖了个|转我)"
    private static let noiseVerb = "(花了|花掉|花费|买了|买|付了|付款|支付|消费|共计|一共|总共|合计|大概|大约|左右|记一笔|记账|支出|收入|收到|领到|又|了|的)"

    private struct QuickHit {
        var v: Double
        var w: Double
        var at: Int
    }

    static func quickAmount(_ text: String) -> (amount: Double, weight: Double, candidates: [Double]) {
        let s = text as NSString
        var list: [QuickHit] = []

        for m in all("[¥￥]?[ \\t]*(\\d+(?:\\.\\d{1,2})?)[ \\t]*(元|块钱|块|圆)?", s) {
            let numStr = sub(m, 1, s)
            guard let v = Double(numStr), v > 0, v <= 50_000_000 else { continue }
            let unit = sub(m, 2, s)
            let full = sub(m, 0, s)
            let at = m.range.location
            let pre = before(s, at, 3).trimmingCharacters(in: .whitespaces)
            let post = after(s, at + m.range.length, 2).trimmingCharacters(in: .whitespaces)

            var w = 0.0
            if !unit.isEmpty { w += 34 }
            // 原版这里检查的是 m[0] 之前的 3 个字符，¥ 在 m[0] 里所以永远查不到；
            // 改成检查 m[0] 本身，语义才是「金额前面有 ¥」
            if full.hasPrefix("¥") || full.hasPrefix("￥") { w += 26 }
            if let f = post.first, "月日号点时年:：".contains(f) { w -= 48 }
            if pre.hasSuffix(":") || pre.hasSuffix("：") { w -= 48 }
            if let l = pre.last, "月日号点时年".contains(l) { w -= 48 }
            if numStr.contains(".") { w += 12 }
            list.append(QuickHit(v: v, w: w, at: at))
        }

        if list.isEmpty { return (0, 0, []) }
        // 中文习惯把金额放在句尾
        if !list.isEmpty { list[list.count - 1].w += 16 }

        var best: [String: QuickHit] = [:]
        for c in list {
            let k = String(format: "%.2f", c.v)
            if let cur = best[k] {
                if cur.w < c.w { best[k] = c }
            } else {
                best[k] = c
            }
        }
        let arr = Array(best.values).sorted { a, b in
            if a.w != b.w { return a.w > b.w }
            return a.at > b.at
        }
        return ((arr[0].v * 100).rounded() / 100, arr[0].w, arr.dropFirst().prefix(3).map { $0.v })
    }

    static func quickMerchant(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: "\\d{1,2}\\s*[月日号]", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "[¥￥]?\\s*\\d+(?:\\.\\d{1,2})?\\s*(元|块钱|块|圆)?", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "(昨天|前天|今天|今日|昨日|大前天|上午|下午|中午|晚上|早上|凌晨|上周|这周|周末)", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: noiseVerb, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "[，,。.!！?？、;；:：~\\-—_]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        s = s.replacingOccurrences(of: "^(一|二|两|三|四|五|六|七|八|九|十|几|些|个|次|杯|份|顿|件|瓶|袋|张|台|斤)\\s*",
                                   with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s*(块钱|元|块)$", with: "", options: .regularExpression)
        return String(s.trimmingCharacters(in: .whitespaces).prefix(16))
    }

    /// 解析聊天框里的一句话：「昨天午饭 32」「老婆买菜 86」
    static func parseQuick(_ raw: String, members: [String] = []) -> ParsedBill? {
        let collapsed = raw.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.isEmpty { return nil }

        var text = collapsed
        var member = ""
        for nm in members where !nm.isEmpty && text.contains(nm) {
            member = nm
            text = text.replacingOccurrences(of: nm, with: " ", options: .literal)
            break
        }

        let amt = quickAmount(text)
        var amount = amt.amount
        if amount == 0 {
            // 兜底：整句只有一个数字
            let s = text as NSString
            if let m = all("^\\D*?(\\d+(?:\\.\\d{1,2})?)\\D*$", s).first {
                amount = Double(sub(m, 1, s)) ?? 0
            }
            if amount <= 0 { return nil }
        }

        var type = detectType(text, "")
        // 口语里「收到 / 报销 / 退款」比「订单」更可靠
        if has(incomeHint, text) { type = "income" }
        if has("(付|买|花|消费|支出|扣)", text) && !has("(收到|退款|报销)", text) { type = "expense" }

        let merchant = quickMerchant(text)
        let cat = detectCategory(text + " " + merchant, type: type)

        var conf = 40
        if amt.weight >= 30 { conf += 25 }
        else if amt.weight >= 10 { conf += 15 }
        if merchant.count >= 2 { conf += 18 }
        if !cat.keywords.isEmpty { conf += 8 }
        conf = min(94, conf)

        return ParsedBill(type: type,
                          amount: amount,
                          amountCandidates: amt.candidates,
                          merchant: merchant,
                          category: cat.name,
                          emoji: cat.emoji,
                          ts: detectDate(text),
                          method: detectMethod(text),
                          member: member,
                          confidence: conf,
                          lines: [collapsed])
    }
}
