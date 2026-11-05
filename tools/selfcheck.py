#!/usr/bin/env python3
"""FreeRoute AI 本地静态自检（iSH 上没有 Xcode，这是编译前的最后一道防线）
检查项：
1. 括号/引号配平（跳过字符串与注释）
2. 每个 .swift 文件必须 import 它用到的框架
3. 视图类型重复定义检测
4. RootView 引用的视图是否都存在
5. 明显的编造 API 扫描（禁用清单）
"""
import os
import re
import sys
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
errors = []
warns = []


def strip_code(src):
    """去掉字符串与注释，返回 (纯代码, 掩码后的同长字符串)"""
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        # 行注释
        if c == '/' and i + 1 < n and src[i + 1] == '/':
            j = src.find('\n', i)
            j = n if j < 0 else j
            out.append(' ' * (j - i))
            i = j
            continue
        # 块注释（支持嵌套）
        if c == '/' and i + 1 < n and src[i + 1] == '*':
            depth, j = 1, i + 2
            while j < n and depth:
                if src.startswith('/*', j):
                    depth += 1
                    j += 2
                elif src.startswith('*/', j):
                    depth -= 1
                    j += 2
                else:
                    j += 1
            out.append(' ' * (j - i))
            i = j
            continue
        # 三引号字符串
        if src.startswith('"""', i):
            j = src.find('"""', i + 3)
            j = n if j < 0 else j + 3
            out.append(' ' * (j - i))
            i = j
            continue
        # 普通字符串（含 \\( ) 插值内部当代码处理）
        if c == '"':
            j = i + 1
            while j < n:
                if src[j] == '\\':
                    if src.startswith('\\(', j):
                        # 插值：把括号内当代码
                        depth, k = 1, j + 2
                        while k < n and depth:
                            if src[k] == '(':
                                depth += 1
                            elif src[k] == ')':
                                depth -= 1
                            k += 1
                        j = k
                        continue
                    j += 2
                    continue
                if src[j] == '"':
                    break
                j += 1
            j = min(j + 1, n)
            out.append(' ' * (i - i) + ' ' * (j - i))
            i = j
            continue
        out.append(c)
        i += 1
    return ''.join(out)


PAIRS = {')': '(', ']': '[', '}': '{'}


def check_balance(path, code):
    stack = []
    line = 1
    for ch in code:
        if ch == '\n':
            line += 1
        elif ch in '([{':
            stack.append((ch, line))
        elif ch in ')]}':
            if not stack:
                errors.append(f"{path}:{line} 多余的 '{ch}'")
                return
            op, ol = stack.pop()
            if op != PAIRS[ch]:
                errors.append(f"{path}:{line} '{ch}' 与 {ol} 行的 '{op}' 不匹配")
                return
    if stack:
        op, ol = stack[-1]
        errors.append(f"{path}:{ol} 未闭合的 '{op}'")


def collect():
    files = []
    for base, _, names in os.walk(ROOT):
        if '/.git' in base:
            continue
        for n in names:
            if n.endswith('.swift'):
                files.append(os.path.join(base, n))
    return sorted(files)


# 显式点名某框架的类型时，该文件必须 import 对应框架（SwiftUI 不会转发 UIKit/AVKit 等）
NEEDS_IMPORT = {
    "UIPasteboard": "UIKit", "UIApplication": "UIKit", "UIImage": "UIKit",
    "UIActivityViewController": "UIKit", "UIStackView": "UIKit", "UIScreen": "UIKit",
    "UIVisualEffectView": "UIKit", "UIHostingView": "UIKit",
    "AVPictureInPictureController": "AVKit", "AVPlayer": "AVFoundation",
    "AVAudioSession": "AVFoundation", "AVSampleBufferDisplayLayer": "AVFoundation",
    "CMSampleBuffer": "CoreMedia", "CMTime": "CoreMedia",
    "NWListener": "Network", "NWConnection": "Network", "NWParameters": "Network",
    "SecItem": "Security", "UTType": "UniformTypeIdentifiers",
    "ActivityAuthorizationInfo": "ActivityKit", "ActivityAttributes": "ActivityKit",
    "Chart": "Charts", "BarMark": "Charts", "LineMark": "Charts",
    "MKMapView": "MapKit", "CLLocationManager": "CoreLocation",
}

FORBIDDEN = [
    (r'\bTODO\b', '遗留 TODO'),
    (r'\bfatalError\s*\(', 'fatalError（运行时会崩）'),
    (r'\bpreconditionFailure\b', 'preconditionFailure'),
    (r'(?<!\.)\bprint\s*\(', 'print 调试输出'),
    (r'#warning\(\)|#error\(\)', '#error/#warning'),
    (r'placeholder|notImplemented|coming soon|敬请期待|待实现', '占位实现'),
    # try? 覆盖整个后缀链 → flatMap 落在 Data 上，$0 是 UInt8，String(data:) 编译不过
    (r'try\?\s*[^\n{]*\.flatMap\s*\{\s*String\(data:', 'try? 内对 Data 用 flatMap（$0 是字节）'),
    # Optional 没有 .value，必须 ?.value
    (r'\(try\?[^\n]*\)\.value\b', 'Optional 直接取 .value（应为 ?.value）'),
]

# 闭包参数存进属性必须显式 @escaping（CI 真实报过：
# "assigning non-escaping parameter 'title' to an '@escaping' closure"）
RE_SELF_ASSIGN = re.compile(r"self\.(\w+)\s*=\s*(\w+)(?![\w(])")  # 排除 self.x = x() 这种当场调用的
RE_ESC_PARAM = re.compile(r"(?:@escaping\b[^(){};]*?\b(\w+)\s*:)|\b(\w+)\s*:\s*@escaping\b")
RE_CLOS_PARAM = re.compile(r"\b(\w+)\s*:\s*(?:@[\w.]+\s+)*\([^()]*\)\s*->\s*[\w<>?,.\s]+[,)]")


def check_stored_closure(rel, raw):
    """闭包参数被存进属性却没有 @escaping —— CI 真实报过：
    assigning non-escaping parameter 'title' to an '@escaping' closure"""
    stored = {m.group(1) for m in RE_SELF_ASSIGN.finditer(raw)
              if m.group(1) == m.group(2)}
    if not stored:
        return
    escaped = {(m.group(1) or m.group(2)) for m in RE_ESC_PARAM.finditer(raw)}
    for m in RE_CLOS_PARAM.finditer(raw):
        name, start = m.group(1), m.start()
        if name not in stored or name in escaped:
            continue
        # 只在 init(...) 参数列表里报，避免把普通函数参数误判
        if "init(" not in raw[max(0, start - 400):start]:
            continue
        ln = raw[:start].count("\n") + 1
        errors.append(f"{rel}:{ln} 闭包参数 {name} 被存进属性，需要 @escaping")


# 同屏重复标签：Section 的行文案与区块标题同名时，读屏会连读两遍，
# XCUITest 也会报 Multiple matching elements（本项目真实踩过：设置页两行「安全」）
DUP_LABEL_WINDOW = 260


def check_duplicate_section_labels(rel, code):
    for m in re.finditer(r'header:\s*\{\s*Text\("([^"]+)"\)', code):
        title = m.group(1)
        lo = max(0, m.start() - DUP_LABEL_WINDOW)
        window = code[lo:m.end() + DUP_LABEL_WINDOW]
        for rm in re.finditer(r'label:\s*\{\s*Text\("([^"]+)"\)', window):
            if rm.group(1) == title:
                ln = code[:m.start()].count('\n') + 1
                errors.append(f"{rel}:{ln} 行文案与区块标题同为「{title}」（读屏连读、UI 测试无法唯一定位，请改其一）")


# ActivityViewContext 的可用成员（Xcode 26.6 SDK 实测：没有 activity，
# 想要固定属性请放进 ContentState，别写 context.activity.attributes.x）
ACTIVITY_CTX_ALLOWED = {'state', 'date', 'timing', 'inActivityContext'}


def main():
    files = collect()
    type_owner = {}
    for f in files:
        raw = open(f, encoding='utf-8').read()
        code = strip_code(raw)
        rel = os.path.relpath(f, ROOT)
        check_balance(rel, code)
        check_duplicate_section_labels(rel, raw)  # 必须用 raw：code 里字符串已被掩码
        check_stored_closure(rel, raw)

        # Live Activity 闭包里的 context 只有固定成员（CI 真实踩过：context.gatewayURL）
        if 'ActivityConfiguration' in code or 'DynamicIsland' in code:
            for cm_ in re.finditer(r'\bcontext\.([a-z]\w*)', code):
                if cm_.group(1) not in ACTIVITY_CTX_ALLOWED:
                    errors.append(f"{rel}: context.{cm_.group(1)} 不是 ActivityViewContext 的成员"
                                  f"（要显示的数据请放进 ContentState，用 context.state.{cm_.group(1)} 取）")

        # 显式点名某框架的类型却没 import 该框架（SwiftUI 不转发 UIKit/AVKit 等）
        for sym, mod in NEEDS_IMPORT.items():
            if not re.search(r'\b' + sym + r'\b', code):
                continue
            if f'import {mod}' in raw:
                continue
            if mod == 'Charts' and 'Charts.' in code:
                continue
            errors.append(f"{rel}: 用了 {sym} 但没 import {mod}")

        if 'import SwiftUI' in code:
            pass
        # SwiftUI 视图必须 import SwiftUI 或 SwiftUI 相关框架
        if re.search(r':\s*(some\s+)?View\b', code) and 'import SwiftUI' not in code:
            errors.append(f"{rel}: 定义了 View 但没有 import SwiftUI")
        if 'XCTest' in raw and 'import XCTest' not in raw:
            errors.append(f"{rel}: 使用 XCTest 但未 import")
        if 'Charts.' in code or re.search(r'\bChart\s*\{', code):
            if 'import Charts' not in raw:
                errors.append(f"{rel}: 使用 Swift Charts 但未 import Charts")

        for pat, why in FORBIDDEN:
            # UI 测试里 print 是标准日志通道：截图跳过等原因必须打出来，
            # 否则缺失会被"用例通过"掩盖（真实发生过），所以不算调试残留
            if why == 'print 调试输出' and rel.startswith('FreeRouteUITests/'):
                continue
            m = re.search(pat, code)
            if m:
                ln = code[:m.start()].count('\n') + 1
                (warns if 'print' in why else errors).append(f"{rel}:{ln} {why}")

        for m in re.finditer(r'^(?:@[\w()":"\. ,]+\s*)?(?:public |internal |private |fileprivate |open )*\b(?:struct|class|final class|actor|enum)\s+([A-Z]\w+)', code, re.M):
            name = m.group(1)
            if name in ('Content', 'Body'):
                continue
            type_owner.setdefault(name, []).append(rel)

    # 重复定义
    for name, owners in type_owner.items():
        uniq = sorted(set(owners))
        if len(uniq) > 1:
            errors.append(f"类型 {name} 在多个文件重复定义：{', '.join(uniq)}")

    # RootView 引用的视图必须存在
    SYSTEM_VIEWS = {"ProgressView", "AnyView", "EmptyView", "Text", "Image", "Color",
                    "NavigationView", "NavigationStack", "NavigationLink", "List", "Form"}
    app_file = os.path.join(ROOT, 'FreeRoute/App/FreeRouteApp.swift')
    if os.path.exists(app_file):
        src = strip_code(open(app_file, encoding='utf-8').read())
        for m in re.finditer(r'\b([A-Z]\w*View)\s*\(\s*\)', src):
            name = m.group(1)
            if name not in type_owner and name not in ('RootView',) and name not in SYSTEM_VIEWS:
                errors.append(f"FreeRouteApp.swift 引用了不存在的视图 {name}")

    print(f"扫描 {len(files)} 个 Swift 文件")
    for e in errors:
        print("  ✗", e)
    for w in warns:
        print("  !", w)
    print(f"结果：{len(errors)} 个错误，{len(warns)} 个提示")
    return 1 if errors else 0


if __name__ == '__main__':
    sys.exit(main())
