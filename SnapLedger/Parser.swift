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
    var note: String = ""
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
                     note: note,
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
        BillCategory(name: "通讯", emoji: "📱", keywords: ["话费", "流量", "中国移动", "中国联通", "中国电信", "移动营业厅", "联通", "电信", "营业厅", "宽带费", "手机费", "话费充值", "充话费", "通信"]),
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

    // MARK: - 金额

    /// 两档金额关键词，extractAmount 内部和 analyze 的优惠校正共用一份，避免走偏
    static let finalKwInline = "(实付|实际支付|实际付款|付款金额|支付金额|交易金额|本次消费|支出金额|消费金额|应付金额)"
    static let grossKwInline = "(订单金额|商品金额|商品总额|原价|总价)"

    static func extractAmount(_ text: String) -> (amount: Double, weight: Double, candidates: [Double], kind: String) {
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
        //
        // 分三档。账单里常常同时出现好几个数，混在一档就会选错：
        //   · 实付 / 付款金额 / 支付金额 = 真正花出去的钱（最高档）
        //   · 订单金额 / 原价 / 合计      = 优惠前的数，当成主金额会多记（84.00 对 实付 82.55）
        //   · 收款 / 到账 / 入账          = 银行短信的方向词
        let finalKw = "(实付|实际支付|实际付款|付款金额|支付金额|交易金额|本次消费|支出金额|消费金额|应付金额|支付成功|成功付款)"
        let grossKw = "(订单金额|商品金额|商品总额|原价|总价|合计|总计|总额|应付|应收)"
        for m in all("\(finalKw)[^\\d\\-−¥￥\\n]{0,10}[-−]?[ \\t]*[¥￥]?[ \\t]*([\\d,]+(?:\\.\\d{1,2})?)", s) {
            push(m, 2, 120, sub(m, 1, s))
        }
        for m in all("\(grossKw)[^\\d\\-−¥￥\\n]{0,10}[-−]?[ \\t]*[¥￥]?[ \\t]*([\\d,]+(?:\\.\\d{1,2})?)", s) {
            push(m, 2, 45, sub(m, 1, s))
        }
        for m in all("(收款|到账|入账)[^\\d\\-−¥￥\\n]{0,10}[-−]?[ \\t]*[¥￥]?[ \\t]*([\\d,]+(?:\\.\\d{1,2})?)", s) {
            push(m, 2, 105, sub(m, 1, s))
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

        if cands.isEmpty { return (0, 0, [], "") }

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
        // kind 带出去：调用方靠它判断「这个数是不是优惠前的原价」
        return (top.v, top.w, others, top.note)
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

    private static let skipLine = "(微信支付|支付宝|云闪付|账单|详情|订单号|交易号|支付时间|付款方式|支付方式|到账时间|服务|客服|协议|隐私|查看更多|当前状态|支付成功|付款成功|已付款|退款|账户|尾号|余额|商品|完成|返回|确定|取消|添加|请选择|未选择)"

    // MARK: 商户全称 → 用户认识的那个牌子
    //
    // 账单里的商户字段几乎永远是工商全称：「无锡惠山山姆零售有限公司」「星巴克咖啡（上海）有限公司」。
    // 原样放进账本，列表里就是一行看不懂的公文 —— 用户要的是「山姆」两个字。
    //
    // 左边是规范名，右边是能在全称里认出来的写法。长别名要先试，否则
    // 「沃尔玛山姆会员店」会被「沃尔玛」抢走。品牌顺序也有讲究：越容易误伤的放越后。
    private static let brandTable: [(name: String, aliases: [String])] = [
        ("山姆", ["沃尔玛山姆", "山姆会员", "山姆", "samsclub", "sam's club", "sams club"]),
        ("开市客", ["开市客", "costco"]),
        ("盒马", ["盒马鲜生", "盒马"]),
        ("沃尔玛", ["沃尔玛", "walmart"]),
        ("华润万家", ["华润万家"]),
        ("大润发", ["大润发", "rt-mart"]),
        ("家乐福", ["家乐福", "carrefour"]),
        ("永辉", ["永辉超市", "永辉"]),
        ("物美", ["物美"]),
        ("胖东来", ["胖东来"]),
        ("罗森", ["罗森", "lawson"]),
        ("全家", ["全家便利", "全家"]),
        ("7-11", ["7-11", "711", "7-eleven"]),
        ("美宜佳", ["美宜佳"]),
        ("星巴克", ["星巴克", "starbucks"]),
        ("瑞幸", ["瑞幸", "luckin"]),
        ("库迪", ["库迪"]),
        ("蜜雪冰城", ["蜜雪冰城", "蜜雪"]),
        ("喜茶", ["喜茶"]),
        ("奈雪", ["奈雪的茶", "奈雪"]),
        ("茶百道", ["茶百道"]),
        ("古茗", ["古茗"]),
        ("麦当劳", ["麦当劳", "mcdonald"]),
        ("肯德基", ["肯德基", "kfc"]),
        ("汉堡王", ["汉堡王", "burger king"]),
        ("必胜客", ["必胜客", "pizza hut"]),
        ("海底捞", ["海底捞"]),
        ("优衣库", ["优衣库", "uniqlo"]),
        ("无印良品", ["无印良品", "muji"]),
        ("名创优品", ["名创优品", "miniso"]),
        ("宜家", ["宜家家居", "宜家", "ikea"]),
        ("迪卡侬", ["迪卡侬", "decathlon"]),
        ("屈臣氏", ["屈臣氏", "watsons"]),
        ("小米", ["小米之家", "小米"]),
        ("华为", ["华为"]),
        ("苹果", ["apple store", "苹果零售", "苹果贸易"]),
        ("苏宁", ["苏宁"]),
        ("国美", ["国美"]),
        ("京东", ["京东"]),
        ("天猫", ["天猫"]),
        ("淘宝", ["淘宝"]),
        ("拼多多", ["拼多多"]),
        ("美团", ["美团"]),
        ("饿了么", ["饿了么"]),
        ("滴滴", ["滴滴"]),
        ("顺丰", ["顺丰"]),
        ("中国移动", ["中国移动", "移动通信"]),
        ("中国联通", ["中国联通", "联通"]),
        ("中国电信", ["中国电信"]),
        ("中石化", ["中国石化", "中石化", "sinopec"]),
        ("中石油", ["中国石油", "中石油"]),
        ("万达", ["万达"]),
        ("万象城", ["万象城"]),
        ("大悦城", ["大悦城"])
    ]

    /// 工商后缀，从长到短剥。不剥的话账本里全是「XX有限公司」。
    private static let corpSuffix = ["股份有限公司", "有限责任公司", "有限公司", "分公司", "公司",
                                     "连锁", "商贸", "实业", "企业管理", "商业管理", "零售"]

    /// 常见省市前缀。只在名字还很长时才剥，剥完不足 2 字就作罢 ——
    /// 「南京大排档」不能被剥成「大排档」，那反而更难认。
    private static let regionPrefix = ["中国", "内蒙古", "黑龙江", "江苏", "浙江", "广东", "山东", "河南",
                                       "河北", "湖北", "湖南", "四川", "福建", "安徽", "江西", "陕西",
                                       "山西", "辽宁", "吉林", "云南", "贵州", "广西", "甘肃", "海南",
                                       "上海", "北京", "天津", "重庆", "深圳", "广州", "杭州", "南京",
                                       "苏州", "无锡", "常州", "宁波", "成都", "武汉", "西安", "长沙",
                                       "郑州", "青岛", "济南", "合肥", "福州", "厦门", "南昌", "昆明",
                                       "沈阳", "大连", "哈尔滨", "长春", "石家庄", "太原", "南宁", "贵阳"]

    /// 在全称里找品牌。命中返回规范短名，没有返回 nil。
    private static func matchBrand(_ raw: String) -> String? {
        let t = raw.lowercased()
            .replacingOccurrences(of: "[\\s（）()·•,，。、\\-—_]", with: "", options: .regularExpression)
        guard t.count >= 2 else { return nil }
        for (name, aliases) in brandTable {
            for a in aliases.sorted(by: { $0.count > $1.count }) where t.contains(a.lowercased()) {
                return name
            }
        }
        return nil
    }

    /// 商户名归一。已经是个短名字（「美团外卖」「肯德基」）就原样放过 ——
    /// 归并只会丢信息；只有像公文的全称才值得提炼。
    private static func refineMerchant(_ raw: String) -> String {
        let base = tidy(raw)
        if base.isEmpty { return "" }
        let looksCorporate = base.count >= 6 || corpSuffix.contains { base.hasSuffix($0) }
        guard looksCorporate else { return base }

        if let b = matchBrand(base) { return b }

        var s = base
        for suf in corpSuffix where s.count - suf.count >= 2 && s.hasSuffix(suf) {
            s = String(s.dropLast(suf.count))
        }
        if let b = matchBrand(s) { return b }

        // 剥完还很长，才去猜前面的城市
        if s.count > 6 {
            for p in regionPrefix.sorted(by: { $0.count > $1.count }) where s.hasPrefix(p) {
                let rest = String(s.dropFirst(p.count))
                if rest.count >= 2 { s = rest; break }
            }
            for suf in corpSuffix where s.count - suf.count >= 2 && s.hasSuffix(suf) {
                s = String(s.dropLast(suf.count))
            }
        }
        if let b = matchBrand(s) { return b }
        return s.isEmpty ? base : String(s.prefix(16))
    }

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
                return refineMerchant(v)
            }
        }

        // 2) 前 3 行里第一个像名字的短行（支付截图的标题位置）。
        //    截图 OCR 的头几行经常是状态栏碎片（时间、信号、「！.4G0」这种），
        //    只挡纯数字符号挡不住它 —— 必须要求「像名字」。
        for i in 0..<min(lines.count, 3) {
            let L = lines[i].trimmingCharacters(in: .whitespaces)
            if L.count >= 2, L.count <= 20,
               looksLikeName(L),
               !has("^[\\d\\s.,:：¥￥\\-−+/]+$", L),
               !has(skipLine, L) {
                return refineMerchant(L)
            }
        }

        // 3) 商户字段
        for p in ["商户全称[：:\\s]*([^\\s，,。；;]{2,30})",
                  "商户名称[：:\\s]*([^\\s，,。；;]{2,30})",
                  "商户[：:\\s]*([^\\s，,。；;]{2,24})"] {
            for m in all(p, s) {
                let v = sub(m, 1, s)
                if !v.isEmpty { return refineMerchant(v) }
            }
        }

        // 4) 全文里带行业词、且最像名字的一行
        var bestLine = ""
        for raw in lines {
            let L = raw.trimmingCharacters(in: .whitespaces)
            if L.count < 2 || L.count > 26 { continue }
            if has("^[\\d\\s.,:：¥￥\\-−+/]+$", L) { continue }
            if has(skipLine, L) { continue }
            if !looksLikeName(L) { continue }
            if has(merchantHint, L), L.count > bestLine.count { bestLine = L }
        }
        return bestLine.isEmpty ? "" : refineMerchant(bestLine)
    }

    /// OCR 行是否「像商户名」。状态栏垃圾（！.4G0、11:16、HD、5G）和纯符号行必须挡掉：
    /// 含中文的行基本可信；纯拉丁/数字的短行（<5 个字母）一律当碎片，
    /// 长的才可能是商户（Starbucks、IKEA 这类）。
    static func looksLikeName(_ raw: String) -> Bool {
        var L = raw.trimmingCharacters(in: .whitespaces)
        L = L.replacingOccurrences(of: "^[！!。，,．.·•|:：\\-—_\\s]+", with: "", options: .regularExpression)
        L = L.replacingOccurrences(of: "[！!。，,．.·•|:：\\-—_\\s]+$", with: "", options: .regularExpression)
        if L.count < 2 { return false }
        if L.range(of: "[\\x{4e00}-\\x{9fa5}]", options: .regularExpression) != nil { return true }
        let letters = L.filter { $0.isLetter }.count
        return letters >= 5
    }

    /// 「商品 / 订单信息 / 备注」这类字段抓出来做备忘 —— 账单截图里现成写着，
    /// 不抓白不抓。没有就返回空串。
    ///
    /// merchant 传进来是为了去重：支付宝的「商品说明」经常就是门店名
    /// （山姆这张写的是「无锡北山姆」），提炼后跟商户一样，写进备注纯属噪音。
    static func detectNote(_ lines: [String], merchant: String = "") -> String {
        let keys = ["商品说明", "订单信息", "商品", "备注", "说明"]
        lineLoop: for L in lines {
            for k in keys where L.hasPrefix(k) {
                let rest = L.dropFirst(k.count)
                guard let first = rest.first, first == "：" || first == ":" || first == " " else { continue lineLoop }
                let s = String(rest).trimmingCharacters(in: CharacterSet(charactersIn: "：: "))
                if s.count < 2 || s.count > 40 || has(skipLine, s) { continue lineLoop }
                if !merchant.isEmpty, let b = matchBrand(s), b == merchant { continue lineLoop }
                return s
            }
        }
        return ""
    }

    /// 账单里能看出来的「场景」：买菜、停车、加油、吃饭……
    ///
    /// 用户要的不是一屏 OCR 原文，而是一眼能认出的那句话；所以只做「命中才写」，
    /// 猜不出来就留空，别硬编一个。商户名已经单独成字段（列表里当标题），
    /// 这里补的是「在干嘛」。
    private static let sceneRules: [(String, [String])] = [
        ("停车", ["停车", "泊车", "车位", "停车费"]),
        ("加油", ["加油", "汽油", "柴油", "中石化", "中石油", "壳牌", "充电桩"]),
        ("超市", ["超市", "日用百货", "会员店", "仓储", "卖场", "山姆", "开市客", "costco"]),
        ("买菜", ["生鲜", "菜市场", "菜场", "果蔬", "蔬果", "农贸", "粮油"]),
        ("吃饭", ["餐厅", "饭店", "餐饮", "外卖", "食堂", "小吃", "火锅", "烧烤", "快餐", "咖啡", "奶茶"]),
        ("买药", ["药房", "药店", "医药", "诊所", "医院", "门诊"]),
        ("看电影", ["电影", "影院", "影城"]),
        ("话费", ["话费", "流量", "营业厅", "移动通信", "宽带费"]),
        ("缴费", ["水费", "电费", "燃气费", "物业费", "供暖费", "取暖费"]),
        ("打车", ["滴滴", "打车", "出租车", "网约车", "曹操", "t3出行"]),
        ("出行", ["地铁", "公交", "高铁", "火车", "12306", "机票"]),
        ("快递", ["快递", "顺丰", "菜鸟驿站", "京东物流"]),
        ("房租", ["房租", "租金"]),
        ("学费", ["学费", "培训", "课程", "辅导班"]),
        ("宠物", ["宠物", "猫粮", "狗粮", "猫砂", "宠物医院"]),
        ("网购", ["淘宝", "天猫", "京东商城", "拼多多", "抖音电商"])
    ]

    static func detectScene(_ text: String) -> String {
        let t = " " + text.lowercased() + " "
        for (label, keys) in sceneRules where keys.contains(where: { t.contains($0.lowercased()) }) {
            return label
        }
        return ""
    }

    /// 优惠 / 立减 / 满减 / 红包抵扣 / 折扣 的金额合计。
    ///
    /// 账单里这几个数本来不是为了记账，但差额全在这儿：
    /// 「订单金额 84.00、优惠 1.45、实付 82.55」—— 只抄到 84.00 就多记了 1.45。
    /// 两个用途：① 实付没读到时从原价里减掉；② 写进备注，对账时能解释差额。
    static func detectDiscount(_ text: String) -> Double {
        let flat = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        let s = flat as NSString
        var sum = 0.0
        for m in all("(?:优惠|立减|满减|折扣|红包抵扣|抵扣|减免|随机减|券)[^\\d\\-−¥￥\\n]{0,10}[-−]?[ \\t]*[¥￥]?[ \\t]*([\\d,]+(?:\\.\\d{1,2})?)", s) {
            let raw = sub(m, 1, s).replacingOccurrences(of: ",", with: "")
            if let v = Double(raw), v > 0, v < 10_000 { sum += v }
        }
        return min(sum, 9_999)
    }

    private static func tidy(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "^[：:\\s\\-−]+", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "[：:\\s\\-−,，。]+$", with: "", options: .regularExpression)
        return String(t.prefix(24))
    }

    // MARK: - 类别

    /// 账单页自己标的分类（支付宝「账单分类 日用百货」、微信「交易分类」）。
    /// 这是收单侧标的，比我们按关键词猜准 —— 猜出来是「购物」，人家标的是「日用百货」。
    private static let declaredCategoryMap: [(key: String, name: String)] = [
        ("日用百货", "日用"), ("食品酒饮", "餐饮"), ("餐饮美食", "餐饮"), ("酒店旅游", "娱乐"),
        ("交通出行", "交通"), ("服饰装扮", "购物"), ("数码电器", "购物"), ("美容美发", "购物"),
        ("母婴亲子", "购物"), ("文化休闲", "娱乐"), ("运动户外", "娱乐"), ("医疗健康", "医疗"),
        ("住房物业", "居住"), ("生活服务", "居住"), ("家居家装", "居住"), ("通讯缴费", "通讯"),
        ("教育培训", "学习"), ("转账红包", "人情"), ("宠物", "宠物"), ("汽车相关", "交通")
    ]

    static func detectDeclaredCategory(_ lines: [String]) -> String? {
        for L in lines {
            for k in ["账单分类", "交易分类", "消费分类", "账单类别"] where L.hasPrefix(k) {
                let rest = String(L.dropFirst(k.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "：: "))
                guard !rest.isEmpty else { continue }
                for (key, name) in declaredCategoryMap where rest.contains(key) { return name }
            }
        }
        return nil
    }

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
        // 先看「付款方式」那一行。支付宝账单里「收单机构 支付宝支付科技有限公司」也带
        // 「支付宝」三个字，按老顺序会先命中它 —— 于是亲情卡付的钱被记成「支付宝」。
        // 付款方式这行才是钱的出处，优先级必须最高。
        let s = text as NSString
        for m in all("(?:付款方式|支付方式|扣款方式)[：:\\s]*([^\\n]{0,28})", s) {
            let v = sub(m, 1, s).lowercased()
            if v.isEmpty { continue }
            if v.contains("亲情卡") || v.contains("亲属卡") { return "亲情卡" }
            if v.contains("花呗") { return "花呗" }
            if v.contains("白条") { return "白条" }
            if v.contains("零钱") { return "微信" }
            if v.contains("信用卡") { return "信用卡" }
            if v.contains("余额宝") { return "支付宝" }
            if v.contains("储蓄卡") || v.contains("银行卡") || v.contains("银行") { return "银行卡" }
            if v.contains("云闪付") { return "云闪付" }
            if v.contains("余额") { return "余额" }
            if v.contains("现金") { return "现金" }
        }

        if text.contains("云闪付") { return "云闪付" }
        if text.contains("花呗") { return "花呗" }
        if has("(微信支付|零钱|微信)", text) { return "微信" }
        if has("(支付宝|余额宝)", text) { return "支付宝" }
        if has("(信用卡|银行卡|储蓄卡|工商银行|建设银行|招商银行|农业银行|中国银行)", text) { return "银行卡" }
        if text.contains("现金") { return "现金" }
        return ""
    }

    /// 从账单里认人。付款方式那行常带着持卡人 —— 支付宝亲情卡写成
    /// 「亲情卡(头发乱了honey(杨慧丽))」，名字正好是家里某个成员就归给他，
    /// 比一律记成「我」准确得多。
    static func detectMember(_ text: String, members: [String]) -> String {
        let pool = members.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        guard !pool.isEmpty else { return "" }

        // 单字名（「我」「妈」）全文匹配等于瞎猜 —— 任何一句话都可能撞上，只在付款方式行里认。
        let s = text as NSString
        let payLine = all("(?:付款方式|支付方式|扣款方式|持卡人)[：:\\s]*([^\\n]{0,30})", s)
            .map { sub($0, 1, s) }.joined()

        for nm in pool {
            if nm.count >= 2 {
                if text.contains(nm) { return nm }
            } else if payLine.contains(nm) {
                return nm
            }
        }
        return ""
    }

    // MARK: - 主入口：整段账单文字

    static func analyze(_ rawText: String, members: [String] = []) -> ParsedBill {
        let text = rawText.replacingOccurrences(of: "\r", with: "")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var amt = extractAmount(text)
        let merchant = extractMerchant(text, lines: lines)
        let type = detectType(text, merchant)
        var cat = detectCategory(text + " " + merchant, type: type)
        // 账单页自己标了分类就信它。「日用百货」按关键词会被算成「购物」（都命中 2 个字），
        // 但收单侧标的那个才是用户心里的账。
        if type == "expense", let declared = detectDeclaredCategory(lines),
           let hit = expenseCategories.first(where: { $0.name == declared }) {
            cat = hit
        }
        let ts = detectDate(text)
        let method = detectMethod(text)
        let member = detectMember(text, members: members)

        // 优惠：实付金额没读到、只读到「订单金额/原价」时，减去优惠才是真花出去的钱。
        // 读到实付就信实付（实付已经是优惠后的数，不能再减一次）。
        let discount = detectDiscount(text)
        var adjustedFromGross = false
        if discount > 0, amt.amount > discount,
           !has(finalKwInline, text),
           has(grossKwInline, amt.kind) {
            amt.amount = ((amt.amount - discount) * 100).rounded() / 100
            adjustedFromGross = true
        }

        // 备注 = 场景 · 商品/订单信息 · 优惠。
        // 顺序按「用户最想知道」排：先是在干嘛，再是买了啥，最后才是优惠了多少钱。
        var parts: [String] = []
        let scene = detectScene(text + " " + merchant)
        if !scene.isEmpty { parts.append(scene) }
        let goods = detectNote(lines, merchant: merchant)
        if !goods.isEmpty { parts.append(goods) }
        if discount > 0 {
            parts.append("优惠 ¥" + String(format: "%.2f", discount) + (adjustedFromGross ? "（已扣）" : ""))
        }
        var note = parts.joined(separator: " · ")
        if note.count > 60 { note = String(note.prefix(60)) }

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
                          note: note,
                          member: member,
                          confidence: conf,
                          lines: lines)
    }

    // MARK: - 一屏多条：交易列表

    /// 列表里的一笔（切块中间产物）
    private struct ListBlock {
        var lines: [String]
        var month: Int?
    }

    /// 单笔详情页的强特征。命中 2 个以上就绝不当成列表。
    ///
    /// 详情页也会同时出现「实付 82.55 / 订单金额 84.00 / 优惠 1.45」三个数，
    /// 不挡的话会被切成三笔假账 —— 这比漏记更难收拾。
    private static let detailMarkers = ["交易单号", "订单号", "商户单号", "支付时间", "付款时间",
                                        "付款方式", "支付方式", "商品说明", "账单详情", "收款方",
                                        "收单机构", "交易成功", "创建时间", "交易分类"]

    /// 一屏多条的入口。
    ///
    /// 支付宝/微信的「搜索交易记录」是一屏十几条，每条一行「商户 … 金额」。
    /// 老逻辑把整屏当一张账单交给 extractAmount，它只取权重最高的那个数 ——
    /// 结果十几笔只入一笔，而且往往是金额最大的那笔，其余全丢。
    ///
    /// 切不出 2 笔以上时退回单笔逻辑，行为与以前完全一致。
    static func analyzeAll(_ rawText: String, members: [String] = []) -> [ParsedBill] {
        let text = rawText.replacingOccurrences(of: "\r", with: "")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let markers = detailMarkers.filter { text.contains($0) }.count
        guard markers < 2 else { return [analyze(text, members: members)] }

        let blocks = splitList(lines)
        // 商户名全一样说明只是同一笔被切碎了（比如「商户 / 金额 / 优惠」三行），
        // 不是列表 —— 退回单笔。
        let names = Set(blocks.compactMap { $0.lines.first })
        guard blocks.count >= 2, names.count >= 2 else {
            return [analyze(text, members: members)]
        }

        var out: [ParsedBill] = []
        var seen = Set<String>()
        let cal = Calendar.current
        let curMonth = cal.component(.month, from: Date())

        for b in blocks {
            var bill = analyze(b.lines.joined(separator: "\n"), members: members)
            guard bill.amount > 0 else { continue }

            // 列表里每条只有「商户 + 金额」，没有日期。月份分组标题是唯一线索：
            // 「10月」分组里的那几笔不能全记到今天，否则账本里翻不到。
            if !hasDateMark(b.lines), let mo = b.month, mo != curMonth,
               let ts = monthFallback(mo) {
                bill.ts = ts
            }

            // 同一屏里完全相同的「类型 + 商户 + 金额」只留一笔：
            // OCR 偶尔会把一行读两遍。真有两笔一模一样的情况极少，用户手动补更快。
            let k = "\(bill.type)|\(bill.merchant)|" + String(format: "%.2f", bill.amount)
            if seen.contains(k) { continue }
            seen.insert(k)
            out.append(bill)
        }

        // 切出来的笔数不合理就退回单笔，让用户用一句话记 ——
        // 宁可少记一笔，也不能往账本里灌一堆碎账。
        guard out.count >= 2, out.count <= 30 else {
            return [analyze(text, members: members)]
        }
        return out
    }

    /// 以「金额」为锚往回攒商户名。
    ///
    /// 支持两种版式：金额和商户同一行（`林氏家居 13.80`），以及金额单独一行
    /// （OCR 常把右对齐的数字拆出来）。汇总行和月份分组只当上下文，不入账。
    private static func splitList(_ lines: [String]) -> [ListBlock] {
        var out: [ListBlock] = []
        var buf: [String] = []
        var month: Int?

        for raw in lines {
            let t = raw.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }

            // 「11月」「11月 支出 ¥0.00 收入 ¥0.00」整行都是分组头，后面那半是汇总，一起丢
            if let mo = monthHeader(t) { month = mo; buf.removeAll(); continue }
            if isSummaryRow(t) { buf.removeAll(); continue }

            if let tail = trailingAmount(t) {
                if tail.name.count >= 2 { buf.append(tail.name) }
                if !buf.isEmpty {
                    out.append(ListBlock(lines: buf + [String(format: "%.2f", tail.value)],
                                         month: month))
                    buf = []
                }
                continue
            }

            if let solo = soloAmount(t) {
                if !buf.isEmpty {
                    out.append(ListBlock(lines: buf + [String(format: "%.2f", solo)],
                                         month: month))
                    buf = []
                }
                continue
            }

            // 攒不住的东西（页头、说明）不能无限堆：留最近 3 行就够定位商户
            buf.append(t)
            if buf.count > 3 { buf.removeFirst() }
        }
        return out
    }

    /// 「11月」/「2026年11月」；后面允许跟空白（跟了汇总字段的那行也算分组头）
    private static func monthHeader(_ t: String) -> Int? {
        let s = t as NSString
        guard let m = all("^(?:20\\d{2}\\s*年\\s*)?(\\d{1,2})\\s*月(?:\\s|$)", s).first else { return nil }
        let mo = Int(sub(m, 1, s)) ?? 0
        return (1...12).contains(mo) ? mo : nil
    }

    /// 汇总行：支出 / 收入 / 结余 / 本月已省 / 笔数 …（这些数不是任何一笔账）
    private static let summaryWords = ["支出", "收入", "结余", "本月已省", "已省", "笔数",
                                       "合计", "总计", "预算", "余额", "全部"]
    private static func isSummaryRow(_ t: String) -> Bool {
        if summaryWords.contains(where: { t.hasPrefix($0) }) { return true }
        // 「全部 支出 收入」这类筛选 tab 栏：整行拆开全是汇总词，也该丢
        let toks = t.split(whereSeparator: { " \t·|｜/".contains($0) }).map(String.init)
        if !toks.isEmpty, toks.allSatisfy({ summaryWords.contains($0) }) { return true }
        return false
    }

    /// 行尾是金额：`林氏家居旗舰店 13.80` / `无锡山姆 ¥445.20`
    ///
    /// 前缀里带两位以上数字的（日期、单号）不算 —— 那不是商户名。
    private static func trailingAmount(_ t: String) -> (name: String, value: Double)? {
        let s = t as NSString
        guard let m = all("^(.*?)[\\s¥￥:：]*[¥￥]?\\s*([\\d,]{1,7}\\.\\d{1,2})\\s*元?$", s).first
        else { return nil }
        var name = sub(m, 1, s).trimmingCharacters(in: .whitespaces)
        guard let v = Double(sub(m, 2, s).replacingOccurrences(of: ",", with: "")), v > 0
        else { return nil }
        if has("\\d{2,}", name) { return nil }
        // 去掉行尾的省略号、箭头、括号这类装饰
        while let l = name.last, "…·．.>）》」』-—–:：*".contains(l) { name.removeLast() }
        return (name.trimmingCharacters(in: .whitespaces), v)
    }

    /// 整行只有一个金额：`13.80` / `¥445.20` / `-30.00`
    private static func soloAmount(_ t: String) -> Double? {
        let s = t as NSString
        guard let m = all("^[+\\-−]?\\s*[¥￥]?\\s*([\\d,]{1,7}\\.\\d{1,2})$", s).first else { return nil }
        let v = Double(sub(m, 1, s).replacingOccurrences(of: ",", with: "")) ?? 0
        return v > 0 ? v : nil
    }

    /// 这一块里有没有自带日期（有就信它，别再拿月份分组兜底）
    private static func hasDateMark(_ lines: [String]) -> Bool {
        let p = "(\\d{1,2}\\s*月\\s*\\d{1,2}\\s*日|\\d{1,2}[-/]\\d{1,2}\\s+\\d{1,2}[:：]\\d{2}|昨天|前天|今天|\\d{1,2}[:：]\\d{2})"
        return lines.contains { has(p, $0) }
    }

    /// 只有月份、没有日：落到那个月的最后一天中午。
    /// 比起「记到今天」，这样至少能在账本里翻到正确的月份。
    private static func monthFallback(_ mo: Int) -> Double? {
        let cal = Calendar.current
        let now = Date()
        var y = cal.component(.year, from: now)
        // 1 月里看到「12月」的分组，那是去年
        if mo > cal.component(.month, from: now) { y -= 1 }
        guard let first = cal.date(from: DateComponents(year: y, month: mo, day: 1)),
              let next = cal.date(byAdding: .month, value: 1, to: first),
              let last = cal.date(byAdding: .day, value: -1, to: next) else { return nil }
        var c = cal.dateComponents([.year, .month, .day], from: last)
        c.hour = 12
        // 注意：不能写成 `cal.date(from: c)?.timeIntervalSince1970 * 1000` ——
        // 可选链出来的是 TimeInterval?，乘号用不了，编译直接报「must be unwrapped」。
        guard let day = cal.date(from: c) else { return nil }
        return day.timeIntervalSince1970 * 1000
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
