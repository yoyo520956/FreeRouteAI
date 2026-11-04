#!/usr/bin/env python3
"""服务链式调用校验：抓 `app.xxx.member` 里不存在的成员名。

只做「成员名是否存在」这一件事，不看类型（那是 Xcode 的活）。
用途：跨文件重构后漏改的调用点，这类错误本来只能等云端编译暴露。
"""
import os
import re
import sys


def scrub(src: str) -> str:
    """去掉注释与字符串字面量内容（保留行结构），避免把 "pip.enter" 之类当代码。"""
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if c == '"' and src.startswith('"""', i):
            j = src.find('"""', i + 3)
            j = n if j < 0 else j + 3
            out.append(' ' * (j - i)); i = j
        elif c == '"':
            j = i + 1
            while j < n and src[j] != '"':
                j += 2 if src[j] == '\\' else 1
            out.append('"' + ' ' * max(0, min(j, n - 1) - i) + ('"' if j < n else ''))
            i = j + 1
        elif c == '/' and src.startswith('//', i):
            j = src.find('\n', i)
            j = n if j < 0 else j
            out.append(' ' * (j - i)); i = j
        elif c == '/' and src.startswith('/*', i):
            j = src.find('*/', i + 2)
            j = n if j < 0 else j + 2
            # 保留换行，行号才不会错位
            out.append(''.join('\n' if ch == '\n' else ' ' for ch in src[i:j])); i = j
        else:
            out.append(c); i += 1
    return ''.join(out)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

MOD = r'(?:public |internal |private |fileprivate |open )?'
# 注意 (private|fileprivate)(set) 后面那个空格必须在组内，否则 "public private(set) var" 匹配不上
SETTER = r'(?:(?:private|fileprivate)\(set\) )?'
PRE = rf'(?:@[\w.]+(?:\([^)]*\))?\s+)*{MOD}{SETTER}(?:static |final |class |override |weak |unowned |convenience |mutating |async |throws |rethrows )*'

DECL_RE = re.compile(rf'^\s*{MOD}?(?:final |indirect |open )*(?:struct|class|enum|protocol|actor)\s+([A-Z]\w*)')
MEMBER_RE = re.compile(rf'^\s*{PRE}(?:var|let|func|subscript)\s+([a-z_]\w*)')
INIT_RE = re.compile(r'\binit\s*\(')
CASE_RE = re.compile(r'^\s*case\s+([\w, \"`]+)')

# 变量前缀 -> 类型名（按项目实际持有的服务对象）
CHAIN = {
    'app.': 'AppState',
    'app.gateway.': 'GatewayController',
    'app.gateway.server.': 'GatewayServer',
    'app.router.': 'RouterEngine',
    'app.monitor.': 'MonitorFeed',
    'app.statistics.': 'StatisticsEngine',
    'app.keychain.': 'KeychainStore',
    'app.store.': 'ModelStore',
    'app.settings.': 'AppSettings',
    'app.pip.': 'PiPController',
    'pip.': 'PiPController',
    'coordinator.': 'AppCoordinator',
    'FRFormat.': 'FRFormat',
    'FRDesign.': 'FRDesign',
    'RouterMode.': 'RouterMode',
}

# Swift 自带 / 系统成员，别报成缺失
BUILTIN = {
    'id', 'hashValue', 'description', 'debugDescription', 'init', 'self', 'dynamicType',
    'count', 'isEmpty', 'first', 'last', 'map', 'flatMap', 'compactMap', 'filter', 'sorted',
    'contains', 'reduce', 'append', 'removeAll', 'insert', 'keys', 'values', 'utf8',
    'rawValue', 'allCases', 'label', 'name', 'value', 'type', 'kind', 'shared',
}


def members_by_type():
    out = {}
    for base, _, names in os.walk(ROOT):
        if '/.git' in base:
            continue
        for n in names:
            if not n.endswith('.swift'):
                continue
            path = os.path.join(base, n)
            stack = []      # [(type, depth)]
            depth = 0
            for ln in scrub(open(path, encoding='utf-8').read()).split('\n'):
                ln = ln.rstrip('\n')
                if not ln.strip():
                    continue
                opens, closes = ln.count('{'), ln.count('}')
                d = DECL_RE.match(ln)
                if d:
                    while stack and depth <= stack[-1][1]:
                        stack.pop()
                    stack.append((d.group(1), depth))
                    out.setdefault(d.group(1), set())
                    depth += opens - closes
                    continue
                if stack:
                    m = MEMBER_RE.match(ln)
                    if m:
                        out.setdefault(stack[-1][0], set()).add(m.group(1))
                    elif CASE_RE.match(ln):
                        for cn in CASE_RE.match(ln).group(1).split(','):
                            nm = re.match(r'([a-z_]\w*)', cn.strip())
                            if nm:
                                out.setdefault(stack[-1][0], set()).add(nm.group(1))
                    elif INIT_RE.search(ln):
                        out.setdefault(stack[-1][0], set()).add('init')
                depth += opens - closes
                while stack and depth <= stack[-1][1]:
                    stack.pop()
    return out


def main():
    members = members_by_type()
    problems = []
    checked = 0
    for base, _, names in os.walk(ROOT):
        if '/.git' in base or '/tools' in base:
            continue
        test_target = ('FreeRouteTests' in base) or ('FreeRouteUITests' in base)
        for n in names:
            if not n.endswith('.swift'):
                continue
            path = os.path.join(base, n)
            rel = os.path.relpath(path, ROOT)
            for no, raw in enumerate(open(path, encoding='utf-8'), 1):
                if raw.lstrip().startswith('//'):
                    continue
                ln = scrub(raw)          # 只看代码，不看字符串/注释
                for prefix, typ in sorted(CHAIN.items(), key=lambda kv: -len(kv[0])):
                    if test_target and prefix in ('app.', 'coordinator.'):
                        continue          # 测试里的 app 是 XCUIApplication
                    for m in re.finditer(re.escape(prefix) + r'([a-z]\w*)', ln):
                        member = m.group(1)
                        if member in BUILTIN:
                            continue
                        declared = members.get(typ)
                        if not declared or len(declared) < 3:
                            continue          # 该类型没解析出来，跳过而不是乱报
                        checked += 1
                        if member not in declared:
                            problems.append(f"{rel}:{no} {prefix}{member} 不在 {typ} 的成员里")
    # 同名前缀嵌套去重（app. 与 app.gateway. 会重复命中）
    uniq = sorted(set(problems))
    print(f"校验链式引用 {checked} 处，索引类型 {len(members)} 个")
    for p in uniq[:30]:
        print("  ✗", p)
    print(f"结果：{len(uniq)} 处可疑")
    return 1 if uniq else 0


if __name__ == '__main__':
    sys.exit(main())
