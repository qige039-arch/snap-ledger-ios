# -*- coding: utf-8 -*-
"""把 Parser.swift 里「一屏多条」的切块逻辑复刻成 Python，拿模拟 OCR 文本验一遍。

为什么要有这个脚本：这台机器编不了 Swift，一轮 CI 五分钟。切块规则全是正则，
先在 Python 里跑通再发版，能省掉「编译过了但逻辑错」的那种往返。

注意：这里只验切块（块数、每块的商户和金额、月份上下文），不验 analyze 的
分类/支付方式/备注那部分 —— 那些已经有 ParserTests 的回归用例。
"""
import re

DETAIL_MARKERS = ["交易单号", "订单号", "商户单号", "支付时间", "付款时间",
                  "付款方式", "支付方式", "商品说明", "账单详情", "收款方",
                  "收单机构", "交易成功", "创建时间", "交易分类"]

SUMMARY_WORDS = ["支出", "收入", "结余", "本月已省", "已省", "笔数",
                 "合计", "总计", "预算", "余额", "全部"]

MONTH_RE = re.compile(r"^(?:20\d{2}\s*年\s*)?(\d{1,2})\s*月(?:\s|$)")
TRAIL_RE = re.compile(r"^(.*?)[\s¥￥:：]*[¥￥]?\s*([\d,]{1,7}\.\d{1,2})\s*元?$")
SOLO_RE = re.compile(r"^[+\-−]?\s*[¥￥]?\s*([\d,]{1,7}\.\d{1,2})$")
DATE_RE = re.compile(r"(\d{1,2}\s*月\s*\d{1,2}\s*日|\d{1,2}[-/]\d{1,2}\s+\d{1,2}[:：]\d{2}"
                     r"|昨天|前天|今天|\d{1,2}[:：]\d{2})")

# 商户名里出现连续两位数字（日期、单号）就不是商户
SKIP_NAME_RE = re.compile(r"\d{2,}")
TAIL_JUNK = "…·．.>）》」』-—–:：*"


def month_header(t):
    m = MONTH_RE.match(t)
    if not m:
        return None
    mo = int(m.group(1))
    return mo if 1 <= mo <= 12 else None


def is_summary_row(t):
    if any(t.startswith(w) for w in SUMMARY_WORDS):
        return True
    toks = [x for x in re.split(r"[ \t·|｜/]", t) if x]
    return bool(toks) and all(x in SUMMARY_WORDS for x in toks)


def trailing_amount(t):
    m = TRAIL_RE.match(t)
    if not m:
        return None
    name = m.group(1).strip()
    try:
        v = float(m.group(2).replace(",", ""))
    except ValueError:
        return None
    if v <= 0:
        return None
    if SKIP_NAME_RE.search(name):
        return None
    while name and name[-1] in TAIL_JUNK:
        name = name[:-1]
    return name.strip(), v


def solo_amount(t):
    m = SOLO_RE.match(t)
    if not m:
        return None
    v = float(m.group(1).replace(",", ""))
    return v if v > 0 else None


def split_list(lines):
    out, buf, month = [], [], None
    for raw in lines:
        t = raw.strip()
        if not t:
            continue
        mo = month_header(t)
        if mo is not None:
            month, buf = mo, []
            continue
        if is_summary_row(t):
            buf = []
            continue
        tail = trailing_amount(t)
        if tail is not None:
            name, v = tail
            if len(name) >= 2:
                buf.append(name)
            if buf:
                out.append({"lines": buf + ["%.2f" % v], "month": month})
                buf = []
            continue
        solo = solo_amount(t)
        if solo is not None:
            if buf:
                out.append({"lines": buf + ["%.2f" % solo], "month": month})
                buf = []
            continue
        buf.append(t)
        if len(buf) > 3:
            buf.pop(0)
    return out


def has_date_mark(lines):
    return any(DATE_RE.search(x) for x in lines)


def analyze_all(text):
    """返回 (是否走了多笔, 块列表)"""
    lines = [x.strip() for x in text.replace("\r", "").split("\n") if x.strip()]
    if sum(1 for m in DETAIL_MARKERS if m in text) >= 2:
        return False, []
    blocks = split_list(lines)
    names = {b["lines"][0] for b in blocks if b["lines"]}
    if len(blocks) < 2 or len(names) < 2:
        return False, []
    # 金额必须 > 0，且去重
    out, seen = [], set()
    for b in blocks:
        try:
            v = float(b["lines"][-1])
        except ValueError:
            continue
        if v <= 0:
            continue
        key = (b["lines"][0], "%.2f" % v)
        if key in seen:
            continue
        seen.add(key)
        out.append(b)
    if not (2 <= len(out) <= 30):
        return False, []
    return True, out


CASES = []


def case(name, text, expect):
    CASES.append((name, text, expect))


case("A 商户与金额同行（支付宝列表）", """
搜索交易记录
全部 支出 收入
11月
支出 ¥0.00
收入 ¥0.00
本月已省 ¥42.3
林氏家居旗舰店 13.80
林氏家居华南旗舰店 14.90
无锡山姆会员商店 445.20
诺斯清(北京)医疗器械 7.01
10月
支出 ¥2.18
收入 ¥0.00
""", [("林氏家居旗舰店", 13.80), ("林氏家居华南旗舰店", 14.90),
      ("无锡山姆会员商店", 445.20), ("诺斯清(北京)医疗器械", 7.01)])

case("B 金额单独一行", """
11月
林氏家居旗舰店
今天 12:03
13.80
无锡山姆会员商店
昨天 18:20
445.20
""", [("林氏家居旗舰店", 13.80), ("无锡山姆会员商店", 445.20)])

case("C 千分位与 ¥ 前缀", """
11月
京东自营 1,299.00
美团外卖 ¥32.50
""", [("京东自营", 1299.00), ("美团外卖", 32.50)])

case("D 单笔详情不应被切", """
支付成功
实付 82.55
订单金额 84.00
优惠 1.45
付款方式 亲情卡
交易单号 2026110122001
商户名称 无锡惠山山姆零售有限公司
""", None)

case("E 只有一笔的列表", """
11月
无锡山姆会员商店 445.20
""", None)

case("F 退款条目", """
11月
退款-林氏家居旗舰店 13.80
无锡山姆会员商店 445.20
""", [("退款-林氏家居旗舰店", 13.80), ("无锡山姆会员商店", 445.20)])


def main():
    ok = True
    for name, text, expect in CASES:
        multi, blocks = analyze_all(text)
        got = [(b["lines"][0], float(b["lines"][-1])) for b in blocks]
        if expect is None:
            good = not multi
            detail = "单笔（正确）" if good else "被误切成 %d 笔" % len(got)
        else:
            good = multi and len(got) == len(expect) and all(
                g[0] == e[0] and abs(g[1] - e[1]) < 0.005 for g, e in zip(got, expect))
            detail = "%s" % (got,)
        print(("PASS " if good else "FAIL ") + name + "  " + detail)
        if not good:
            ok = False
            if expect is not None:
                print("      期望:", expect)
    print()
    print("全部通过" if ok else "有失败用例")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
