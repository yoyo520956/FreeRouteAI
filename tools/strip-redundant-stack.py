#!/usr/bin/env python3
"""去掉「被 push 的页面」里多余的 NavigationStack（否则出现双层导航栏、返回键异常）。
被 sheet / tab 根打开的页面保留：HomeView / ModelsHubView / SmartRouterView /
GatewayView / SettingsView（tab 根），FreeCatalogView / ProviderEditorView（sheet）。
"""
import sys

TARGETS = [
    "FreeRoute/Features/LogsView.swift",
    "FreeRoute/Features/StatisticsView.swift",
    "FreeRoute/Features/ModelDetailView.swift",
    "FreeRoute/Features/MonitorView.swift",
]


def strip_code_keep_len(src):
    """把字符串/注释替换成空格，返回同长度掩码（用于配平计数）"""
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == '/' and i + 1 < n and src[i + 1] == '/':
            j = src.find('\n', i)
            j = n if j < 0 else j
            out.append(' ' * (j - i)); i = j; continue
        if c == '/' and i + 1 < n and src[i + 1] == '*':
            depth, j = 1, i + 2
            while j < n and depth:
                if src.startswith('/*', j): depth += 1; j += 2
                elif src.startswith('*/', j): depth -= 1; j += 2
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
                        depth, k = 1, j + 2
                        while k < n and depth:
                            if src[k] == '(': depth += 1
                            elif src[k] == ')': depth -= 1
                            k += 1
                        j = k
                        continue
                    j += 2; continue
                if src[j] == '"': break
                j += 1
            j = min(j + 1, n)
            out.append(' ' * (j - i)); i = j; continue
        out.append(c); i += 1
    return ''.join(out)


def find_wrapper(src, mask, start_idx):
    """从 'NavigationStack {' 的 '{' 开始，返回其匹配 '}' 的下标"""
    depth = 0
    i = start_idx
    while i < len(mask):
        ch = mask[i]
        if ch == '{':
            depth += 1
        elif ch == '}':
            depth -= 1
            if depth == 0:
                return i
        i += 1
    raise RuntimeError("找不到匹配的右花括号")


def patch(path):
    src = open(path, encoding='utf-8').read()
    mask = strip_code_keep_len(src)
    needle = "NavigationStack {"
    pos = src.find(needle)
    if pos < 0:
        print(f"· {path} 无 NavigationStack，跳过")
        return False
    brace_at = pos + len(needle) - 1
    close_at = find_wrapper(src, mask, brace_at)

    # 1) 删掉 "NavigationStack {"（连同其所在行的前导空白与行尾换行）
    line_start = src.rfind('\n', 0, pos) + 1
    line_end = src.find('\n', brace_at)
    line_end = len(src) if line_end < 0 else line_end
    new = src[:line_start] + src[line_end + 1:]

    # 2) 删掉与之匹配的 '}'（它在原 new 串里位置左移了 delta）
    delta = (line_end + 1) - line_start
    close_new = close_at - delta
    if new[close_new] != '}':
        # 允许该 '}' 前后有空白
        k = close_new
        while k > 0 and new[k] not in '}':
            k -= 1
        close_new = k
    assert new[close_new] == '}', f"{path}: 定位右括号失败"
    ls = new.rfind('\n', 0, close_new) + 1
    le = new.find('\n', close_new)
    le = len(new) if le < 0 else le
    new = new[:ls] + new[le + 1:]

    # 3) 校验配平
    m2 = strip_code_keep_len(new)
    if m2.count('{') != m2.count('}') or m2.count('(') != m2.count(')'):
        raise RuntimeError(f"{path}: 删除后括号不平衡，已放弃写入")
    open(path, 'w', encoding='utf-8').write(new)
    print(f"✓ {path} 已去掉多余 NavigationStack")
    return True


if __name__ == "__main__":
    changed = 0
    for t in TARGETS:
        try:
            if patch(t):
                changed += 1
        except Exception as e:
            print(f"✗ {t}: {e}")
            sys.exit(1)
    print(f"共修改 {changed} 个文件")
