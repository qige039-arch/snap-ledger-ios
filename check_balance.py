#!/usr/bin/env python3
# 粗略的 Swift 括号配平检查：跳过字符串字面量与注释，只数结构括号。
# 不是编译器，只用来提前发现明显的漏括号。
import glob
import io
import os

def scan(path):
    src = io.open(path, encoding='utf-8').read()
    i, n = 0, len(src)
    par = brace = brack = 0
    line = 1
    in_str = False
    in_line_comment = False
    in_block = 0
    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ''
        if c == '\n':
            line += 1
            in_line_comment = False
        if in_line_comment:
            i += 1
            continue
        if in_block:
            if c == '/' and nxt == '*':
                in_block += 1
                i += 2
                continue
            if c == '*' and nxt == '/':
                in_block -= 1
                i += 2
                continue
            i += 1
            continue
        if in_str:
            if c == '\\':
                i += 2
                continue
            if c == '"':
                in_str = False
            i += 1
            continue
        if c == '/' and nxt == '/':
            in_line_comment = True
            i += 2
            continue
        if c == '/' and nxt == '*':
            in_block = 1
            i += 2
            continue
        if c == '"':
            in_str = True
            i += 1
            continue
        if c == '(':
            par += 1
        elif c == ')':
            par -= 1
        elif c == '{':
            brace += 1
        elif c == '}':
            brace -= 1
        elif c == '[':
            brack += 1
        elif c == ']':
            brack -= 1
        i += 1
    return par, brace, brack

base = os.path.dirname(os.path.abspath(__file__))
files = sorted(glob.glob(os.path.join(base, '*.swift')))
bad = 0
for f in files:
    p, b, k = scan(f)
    n = len(io.open(f, encoding='utf-8').read().splitlines())
    flag = '' if (p == 0 and b == 0 and k == 0) else '   <== 不配平'
    if flag:
        bad += 1
    print('%-22s %5d 行   ( ) %+d   { } %+d   [ ] %+d%s' % (os.path.basename(f), n, p, b, k, flag))
print('\n不配平文件数:', bad)
