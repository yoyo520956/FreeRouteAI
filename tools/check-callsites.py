#!/usr/bin/env python3
"""跨文件调用点校验：抓「视图/构造器参数标签与实际声明不符」这类编译错误。

iSH 没有 Xcode，这类错误只能靠静态比对提前抓出来，避免浪费 macOS 排队机会。
做法：
1. 解析每个 struct/class 的存储属性（= 成员逐一初始化器的参数标签）与显式 init 的参数标签；
2. 扫描所有 `Name(label: ..., label2: ...)` 调用点；
3. 标签不在声明集合里 → 报错。
不做类型推断（能力有限），但能抓住拼错/多写/漏写必填标签。
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

DECL_RE = re.compile(r'^\s*(?:public |internal |private |fileprivate )?(?:static )?'
                     r'(?:@[\w.]+(?:\([^)]*\))? )*'
                     r'(?:struct|final class|class|actor)\s+([A-Z]\w*)')
PROP_RE = re.compile(r'^\s*(?:@[\w.]+(?:\([^)]*\))? )*'
                     r'(?:public |internal |private |fileprivate )?'
                     r'(?:@State |@Binding |@Environment\(.*?\) |@Bindable |@Query )*'
                     r'(?:let|var)\s+(\w+)\s*:\s*([^={\n]+?)\s*(?:=\s*(.+))?$', re.M)
INIT_RE = re.compile(r'(?:public |internal |private )?init\s*\(([^)]*)\)\s*(?:async )?(?:throws )?\{', re.M)
CALL_RE = re.compile(r'(?<![.\w])([A-Z]\w*(?:View|Card|Badge|Metric|State|Dot|Glyph|Pulse|Editor|Row|Sheet|Panel))\s*\(([^()]*(?:\([^()]*\)[^()]*)*)\)')

SWIFT_BUILTINS = {"Text", "Image", "Color", "Button", "Label", "HStack", "VStack", "ZStack",
                  "List", "Form", "Section", "NavigationStack", "NavigationLink", "Spacer",
                  "ProgressView", "Toggle", "TextField", "SecureField", "Picker", "Slider",
                  "Stepper", "Menu", "Divider", "ScrollView", "LazyVGrid", "GridItem",
                  "RoundedRectangle", "Capsule", "Circle", "Ellipse", "LinearGradient",
                  "GeometryReader", "ForEach", "EmptyView", "AnyView", "Group", "Content",
                  "UINavigationController", "UIHostingController", "Chart", "BarMark"}


def strip(src):
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if c == '/' and i + 1 < n and src[i+1] == '/':
            j = src.find('\n', i); j = n if j < 0 else j
            out.append(' ' * (j - i)); i = j; continue
        if c == '/' and i + 1 < n and src[i+1] == '*':
            d, j = 1, i + 2
            while j < n and d:
                if src.startswith('/*', j): d += 1; j += 2
                elif src.startswith('*/', j): d -= 1; j += 2
                else: j += 1
            out.append(' ' * (j - i)); i = j; continue
        if src.startswith('"""', i):
            j = src.find('"""', i + 3); j = n if j < 0 else j + 3
            out.append(' ' * (j - i)); i = j; continue
        if c == '"':
            j = i + 1
            while j < n:
                if src[j] == '\\':
                    if src.startswith('\\(', j):
                        d, k = 1, j + 2
                        while k < n and d:
                            if src[k] == '(': d += 1
                            elif src[k] == ')': d -= 1
                            k += 1
                        j = k; continue
                    j += 2; continue
                if src[j] == '"': break
                j += 1
            j = min(j + 1, n)
            out.append(' ' * (j - i)); i = j; continue
        out.append(c); i += 1
    return ''.join(out)


def split_params(inner):
    """按顶层逗号切分参数列表"""
    parts, depth, cur = [], 0, ''
    for ch in inner:
        if ch in '(<[{':
            depth += 1
        elif ch in ')>]}':
            depth -= 1
        if ch == ',' and depth == 0:
            parts.append(cur); cur = ''
        else:
            cur += ch
    if cur.strip():
        parts.append(cur)
    return [p.strip() for p in parts if p.strip()]


def labels_of_params(inner):
    """从参数列表提取「调用侧标签」：`a: T` → a；`_ a: T` → 位置参数(记作 '')"""
    out = []
    for p in split_params(inner):
        p = re.sub(r'@escaping\s+', '', p).strip()
        m = re.match(r'^(\w+)\s+([\w<>?\.\[\] ]+?):\s*\S', p)
        if m:                      # 外部标签 + 内部名
            out.append(m.group(1))
            continue
        m = re.match(r'^_(?:\s+\w+)?\s*:', p)
        if m:                      # 位置参数
            out.append('')
            continue
        m = re.match(r'^(\w+)\s*:', p)
        if m:
            out.append(m.group(1))
    return out


def collect():
    """用花括号深度栈把属性/init 归属到正确的类型（嵌套类型不会串味）。"""
    decls = {}
    files = []
    for base, _, names in os.walk(ROOT):
        if '/.git' in base:
            continue
        for n in names:
            if n.endswith('.swift'):
                files.append(os.path.join(base, n))
    for path in sorted(files):
        code = strip(open(path, encoding='utf-8').read())
        stack = []      # [(type_name, depth_at_declaration)]
        depth = 0
        for ln in code.split('\n'):
            if not ln.strip():
                continue
            opens, closes = ln.count('{'), ln.count('}')
            m = DECL_RE.match(ln)
            if m:
                while stack and stack[-1][1] >= depth:
                    stack.pop()
                stack.append((m.group(1), depth))
                depth += opens - closes
                continue
            if stack:
                owner = stack[-1][0]
                pm = PROP_RE.match(ln)
                if pm and 'static' not in ln and pm.group(1) != 'body':
                    decls.setdefault(owner, set()).add(pm.group(1))
                im = INIT_RE.search(ln)
                if im:
                    for lb in labels_of_params(im.group(1)):
                        if lb:
                            decls.setdefault(owner, set()).add(lb)
            depth += opens - closes
            while stack and depth <= stack[-1][1]:
                stack.pop()
    return decls, files


def main():
    decls, files = collect()
    errors, checked = [], 0
    for path in files:
        code = strip(open(path, encoding='utf-8').read())
        rel = os.path.relpath(path, ROOT)
        for m in CALL_RE.finditer(code):
            name, args = m.group(1), m.group(2)
            if name in SWIFT_BUILTINS or name not in decls:
                continue
            known = decls[name]
            if not known:
                continue
            outer = 0
            labels = []
            cur = ''
            for ch in args:
                if ch in '(<[{':
                    outer += 1
                elif ch in ')>]}':
                    outer -= 1
                if ch == ',' and outer == 0:
                    labels.append(cur); cur = ''
                else:
                    cur += ch
            labels.append(cur)
            got = set()
            for p in labels:
                p = p.strip()
                if not p:
                    continue
                mm = re.match(r'^(\w+)\s*:', p)
                if mm:
                    got.add(mm.group(1))
            checked += 1
            bad = {g for g in got if g not in known}
            if bad:
                ln = code[:m.start()].count('\n') + 1
                errors.append(f"{rel}:{ln} 调用 {name}(...) 用了未声明的参数标签 {sorted(bad)}；"
                              f"该类型可用标签：{sorted(known)[:14]}")
    print(f"校验调用点 {checked} 处，涉及 {len([k for k in decls if decls[k]])} 个已声明类型")
    for e in errors:
        print("  ✗", e)
    print(f"结果：{len(errors)} 个不匹配")
    return 1 if errors else 0


if __name__ == '__main__':
    sys.exit(main())
