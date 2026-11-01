# -*- coding: utf-8 -*-
"""把 Parser.swift 里商户/备注/分类/付款方式/认人这几步复刻成 Python，
拿真实截图文字跑一遍，确认改动的输出符合预期。
金额逻辑没动，这里不重复实现。
"""
import re

brandTable = [
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
    ("大悦城", ["大悦城"]),
]

corpSuffix = ["股份有限公司", "有限责任公司", "有限公司", "分公司", "公司",
              "连锁", "商贸", "实业", "企业管理", "商业管理", "零售"]

regionPrefix = ["中国", "内蒙古", "黑龙江", "江苏", "浙江", "广东", "山东", "河南",
                "河北", "湖北", "湖南", "四川", "福建", "安徽", "江西", "陕西",
                "山西", "辽宁", "吉林", "云南", "贵州", "广西", "甘肃", "海南",
                "上海", "北京", "天津", "重庆", "深圳", "广州", "杭州", "南京",
                "苏州", "无锡", "常州", "宁波", "成都", "武汉", "西安", "长沙",
                "郑州", "青岛", "济南", "合肥", "福州", "厦门", "南昌", "昆明",
                "沈阳", "大连", "哈尔滨", "长春", "石家庄", "太原", "南宁", "贵阳"]

skipLine = ("(微信支付|支付宝|云闪付|账单|详情|订单号|交易号|支付时间|付款方式|支付方式|到账时间|服务|"
            "客服|协议|隐私|查看更多|当前状态|支付成功|付款成功|已付款|退款|账户|尾号|余额|商品|完成|"
            "返回|确定|取消|添加|请选择|未选择)")

merchantHint = "(店|超市|商城|餐厅|饭店|咖啡|茶|便利|药房|药店|医院|诊所|公司|科技|有限|集团|中心|广场|酒店|宾馆|馆|行|社|部|局|站|场|院|城|汇|轩|苑|坊|铺|屋|吧|会所|俱乐部|work|store|shop|coffee|cafe)"

sceneRules = [
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
    ("网购", ["淘宝", "天猫", "京东商城", "拼多多", "抖音电商"]),
]

declaredCategoryMap = [
    ("日用百货", "日用"), ("食品酒饮", "餐饮"), ("餐饮美食", "餐饮"), ("酒店旅游", "娱乐"),
    ("交通出行", "交通"), ("服饰装扮", "购物"), ("数码电器", "购物"), ("美容美发", "购物"),
    ("母婴亲子", "购物"), ("文化休闲", "娱乐"), ("运动户外", "娱乐"), ("医疗健康", "医疗"),
    ("住房物业", "居住"), ("生活服务", "居住"), ("家居家装", "居住"), ("通讯缴费", "通讯"),
    ("教育培训", "学习"), ("转账红包", "人情"), ("宠物", "宠物"), ("汽车相关", "交通"),
]

expenseCatNames = ["餐饮", "交通", "购物", "日用", "娱乐", "医疗", "居住", "通讯", "学习", "人情", "宠物", "其他"]


def has(pattern, text):
    return re.search(pattern, text) is not None


def tidy(s):
    t = re.sub(r"^[：:\s\-−]+", "", s)
    t = re.sub(r"[：:\s\-−,，。]+$", "", t)
    return t[:24]


def matchBrand(raw):
    t = re.sub(r"[\s（）()·•,，。、\-—_]", "", raw.lower())
    if len(t) < 2:
        return None
    for name, aliases in brandTable:
        for a in sorted(aliases, key=len, reverse=True):
            if a.lower() in t:
                return name
    return None


def refineMerchant(raw):
    base = tidy(raw)
    if not base:
        return ""
    looksCorp = len(base) >= 6 or any(base.endswith(s) for s in corpSuffix)
    if not looksCorp:
        return base
    b = matchBrand(base)
    if b:
        return b
    s = base
    for suf in corpSuffix:
        if len(s) - len(suf) >= 2 and s.endswith(suf):
            s = s[:-len(suf)]
    b = matchBrand(s)
    if b:
        return b
    if len(s) > 6:
        for p in sorted(regionPrefix, key=len, reverse=True):
            if s.startswith(p):
                rest = s[len(p):]
                if len(rest) >= 2:
                    s = rest
                    break
        for suf in corpSuffix:
            if len(s) - len(suf) >= 2 and s.endswith(suf):
                s = s[:-len(suf)]
    b = matchBrand(s)
    if b:
        return b
    return s if s else base


def looksLikeName(raw):
    L = re.sub(r"^[！!。，,．.·•|:：\-—_\s]+", "", raw.strip())
    L = re.sub(r"[！!。，,．.·•|:：\-—_\s]+$", "", L)
    if len(L) < 2:
        return False
    if re.search(r"[\u4e00-\u9fa5]", L):
        return True
    return sum(1 for c in L if c.isalpha()) >= 5


def extractMerchant(text, lines):
    flat = re.sub(r"\s+", " ", text)
    strong = [
        r"付款给[：:\s]*([^\s，,。；;]{2,24})",
        r"收款方[：:\s]*([^\s，,。；;]{2,24})",
        r"对方[：:\s]*([^\s，,。；;]{2,24})",
        r"向\s*([^\s，,。；;]{2,20})\s*(?:付款|转账)",
        r"给\s*([^\s，,。；;]{2,20})\s*(?:付款|转账)",
        r"【([^】]{2,20})】",
    ]
    for p in strong:
        for m in re.finditer(p, flat):
            v = m.group(1)
            if not v:
                continue
            if v in ["微信", "支付宝", "零钱", "余额", "银行卡", "支付", "收款"]:
                continue
            return refineMerchant(v)

    for i in range(min(len(lines), 3)):
        L = lines[i].strip()
        if 2 <= len(L) <= 20 and looksLikeName(L) \
                and not has(r"^[\d\s.,:：¥￥\-−+/]+$", L) and not has(skipLine, L):
            return refineMerchant(L)

    for p in [r"商户全称[：:\s]*([^\s，,。；;]{2,30})",
              r"商户名称[：:\s]*([^\s，,。；;]{2,30})",
              r"商户[：:\s]*([^\s，,。；;]{2,24})"]:
        for m in re.finditer(p, flat):
            v = m.group(1)
            if v:
                return refineMerchant(v)

    best = ""
    for raw in lines:
        L = raw.strip()
        if len(L) < 2 or len(L) > 26:
            continue
        if has(r"^[\d\s.,:：¥￥\-−+/]+$", L):
            continue
        if has(skipLine, L):
            continue
        if not looksLikeName(L):
            continue
        if has(merchantHint, L) and len(L) > len(best):
            best = L
    return refineMerchant(best) if best else ""


def detectNote(lines, merchant):
    keys = ["商品说明", "订单信息", "商品", "备注", "说明"]
    for L in lines:
        for k in keys:
            if not L.startswith(k):
                continue
            rest = L[len(k):]
            if not rest or rest[0] not in "：: ":
                break
            s = rest.strip("：: ")
            if len(s) < 2 or len(s) > 40 or has(skipLine, s):
                break
            b = matchBrand(s)
            if merchant and b == merchant:
                break
            return s
    return ""


def detectScene(text):
    t = " " + text.lower() + " "
    for label, keys in sceneRules:
        if any(k.lower() in t for k in keys):
            return label
    return ""


def detectDeclaredCategory(lines):
    for L in lines:
        for k in ["账单分类", "交易分类", "消费分类", "账单类别"]:
            if not L.startswith(k):
                continue
            rest = L[len(k):].strip("：: ")
            if not rest:
                continue
            for key, name in declaredCategoryMap:
                if key in rest:
                    return name
    return None


def detectMethod(text):
    for m in re.finditer(r"(?:付款方式|支付方式|扣款方式)[：:\s]*([^\n]{0,28})", text):
        v = m.group(1).lower()
        if not v:
            continue
        if "亲情卡" in v or "亲属卡" in v:
            return "亲情卡"
        if "花呗" in v:
            return "花呗"
        if "白条" in v:
            return "白条"
        if "零钱" in v:
            return "微信"
        if "信用卡" in v:
            return "信用卡"
        if "余额宝" in v:
            return "支付宝"
        if "储蓄卡" in v or "银行卡" in v or "银行" in v:
            return "银行卡"
        if "云闪付" in v:
            return "云闪付"
        if "余额" in v:
            return "余额"
        if "现金" in v:
            return "现金"
    if "云闪付" in text:
        return "云闪付"
    if "花呗" in text:
        return "花呗"
    if has("(微信支付|零钱|微信)", text):
        return "微信"
    if has("(支付宝|余额宝)", text):
        return "支付宝"
    if has("(信用卡|银行卡|储蓄卡|工商银行|建设银行|招商银行|农业银行|中国银行)", text):
        return "银行卡"
    if "现金" in text:
        return "现金"
    return ""


def detectMember(text, members):
    pool = sorted([m for m in members if m], key=len, reverse=True)
    if not pool:
        return ""
    payLine = "".join(m.group(1) for m in re.finditer(r"(?:付款方式|支付方式|扣款方式|持卡人)[：:\s]*([^\n]{0,30})", text))
    for nm in pool:
        if len(nm) >= 2:
            if nm in text:
                return nm
        elif nm in payLine:
            return nm
    return ""


def keywordCategory(text):
    pool = [
        ("餐饮", ["餐", "饭", "食", "咖啡", "奶茶", "星巴克", "瑞幸", "麦当劳", "肯德基", "外卖", "火锅", "烧烤", "小吃", "食堂", "米线", "面馆", "甜品", "面包"]),
        ("交通", ["地铁", "公交", "滴滴", "打车", "加油", "停车", "etc", "高速", "火车", "高铁", "机票", "单车", "充电桩"]),
        ("购物", ["淘宝", "天猫", "京东", "拼多多", "商城", "百货", "优衣库", "小米", "华为", "苹果", "服饰", "衣服", "数码", "家电"]),
        ("日用", ["超市", "沃尔玛", "永辉", "盒马", "大润发", "家乐福", "便利店", "全家", "罗森", "生鲜", "菜市场", "买菜", "蔬菜", "水果", "日用", "洗护", "纸巾", "清洁", "菜"]),
        ("娱乐", ["电影", "影院", "ktv", "游戏", "演出", "门票", "旅游", "酒店", "民宿", "会员", "订阅", "健身"]),
        ("医疗", ["医院", "诊所", "药", "药店", "体检", "挂号", "门诊", "医疗"]),
        ("居住", ["房租", "物业", "水费", "电费", "燃气", "宽带", "家政", "维修"]),
        ("通讯", ["话费", "流量", "中国移动", "中国联通", "中国电信", "营业厅", "充话费"]),
        ("学习", ["书店", "图书", "课程", "培训", "学费", "文具"]),
        ("人情", ["红包", "礼金", "礼物", "请客", "转账给", "捐赠"]),
        ("宠物", ["宠物", "猫粮", "狗粮", "猫砂", "疫苗"]),
    ]
    t = " " + text.lower() + " "
    best, bestScore = "其他", 0
    for name, kws in pool:
        score = sum(min(4, len(k)) for k in kws if k.lower() in t)
        if score > bestScore:
            bestScore, best = score, name
    return best


def analyze(raw, members):
    text = raw.replace("\r", "")
    lines = [x.strip() for x in text.split("\n") if x.strip()]
    merchant = extractMerchant(text, lines)
    cat = keywordCategory(text + " " + merchant)
    declared = detectDeclaredCategory(lines)
    if declared and declared in expenseCatNames:
        cat = declared
    scene = detectScene(text + " " + merchant)
    goods = detectNote(lines, merchant)
    note = " · ".join([x for x in [scene, goods] if x])
    return {
        "merchant": merchant,
        "category": cat,
        "method": detectMethod(text),
        "member": detectMember(text, members),
        "note": note,
    }


SHOT = """账单详情
无锡惠山山姆零售有限公司
445.20
交易成功
支付时间 2026-11-01 17:08:21
付款方式 亲情卡(头发乱了honey(杨慧丽))
商品说明 无锡北山姆
支付奖励 立即领取54积分
收单机构 支付宝支付科技有限公司
更多
账单管理
账单分类 日用百货
标签 请选择
计入收支
备注 添加"""

CASES = [
    ("山姆这张（支付宝账单详情）", SHOT, ["杨慧丽", "我"],
     {"merchant": "山姆", "category": "日用", "method": "亲情卡", "member": "杨慧丽", "note": "超市"}),
    ("美团外卖不能被归并", "美团外卖\n-32.50\n支付成功", [], {"merchant": "美团外卖"}),
    ("肯德基不能被归并", "肯德基\n-45.00\n交易成功", [], {"merchant": "肯德基"}),
    ("备注按钮文案不能当备注", "肯德基\n-45.00\n备注 添加", [], {"note": ""}),
    ("星巴克上海公司", "星巴克咖啡（上海）有限公司\n-38.00\n交易成功", [], {"merchant": "星巴克"}),
    ("盒马鲜生门店", "上海盒马网络科技有限公司\n-156.80\n交易成功", [], {"merchant": "盒马"}),
    ("永辉超市", "永辉超市股份有限公司\n-88.00\n支付成功", [], {"merchant": "永辉", "note": "超市"}),
    ("南京大排档不能被剥成三个字", "南京大排档\n-66.00\n交易成功", [], {"merchant": "南京大排档"}),
]

fails = 0
for name, shot, members, expect in CASES:
    got = analyze(shot, members)
    for k, v in expect.items():
        ok = got[k] == v
        if not ok:
            fails += 1
        print(("PASS " if ok else "FAIL ") + name + " · " + k +
              ("  → " + repr(got[k]) + (" (期望 " + repr(v) + ")" if not ok else "")))
    if name.startswith("山姆"):
        print("      实得:", got)

print("\n失败", fails, "项")
