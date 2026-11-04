#!/usr/bin/env python3
"""校验 project.yml 里每个 target 的 sources 在磁盘上真的有文件。

背景（CI 真实事故）：App target 的 sources 写了 excludes: ["**/.*"]，
XcodeGen 因此给它收录了 0 个源文件 —— 结果 xcodebuild 一路
BUILD SUCCEEDED / ARCHIVE SUCCEEDED，导出的 IPA 里却没有主程序。
这个检查让它在推送前就暴露。
"""
import os
import re
import sys
import glob

try:
    import yaml
except ModuleNotFoundError:
    print('跳过：本机/Runner 没有 PyYAML（此检查降级为不执行，' 
          'Archive 阶段的主程序硬校验仍是真正的门）')
    raise SystemExit(0)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main():
    spec = yaml.safe_load(open(os.path.join(ROOT, 'project.yml'), encoding='utf-8'))
    problems = []
    for name, target in (spec.get('targets') or {}).items():
        ttype = target.get('type', '')
        total = 0
        for src in target.get('sources') or []:
            path = src['path'] if isinstance(src, dict) else src
            full = os.path.join(ROOT, path)
            if not os.path.exists(full):
                problems.append(f"{name}: sources 路径不存在 → {path}")
                continue
            if os.path.isfile(full):
                total += 1
                continue
            swift = len(glob.glob(os.path.join(full, '**', '*.swift'), recursive=True))
            other = len([p for p in glob.glob(os.path.join(full, '**', '*'), recursive=True)
                         if os.path.isfile(p) and not p.endswith('.swift')])
            print(f"  {name:<18} {path:<24} swift={swift:<3} 其他={other}")
            total += swift + other
            if isinstance(src, dict) and src.get('excludes'):
                problems.append(f"{name}: {path} 带 excludes={src['excludes']} —— XcodeGen 的 "
                                f"glob 可能因此收录 0 个文件，禁止使用（已在 CI 踩过）")
        if total == 0:
            problems.append(f"{name}: 该 target 一个源文件都没有（type={ttype}）")

    # 项目级 settings 必须是顶层键；写在 options 下会被 XcodeGen 静默忽略，
    # 于是 CURRENT_PROJECT_VERSION 等未定义，Info.plist 的 $(…) 解析为空
    opts = spec.get('options') or {}
    if 'settings' in opts:
        problems.append("options.settings 无效：项目级设置必须是顶层 settings（XcodeGen 会静默忽略，已踩过）")
    base = ((spec.get('settings') or {}).get('base') or {})
    used = set()
    for rel in ['FreeRoute/Info.plist', 'FreeRouteWidget/Info.plist']:
        if os.path.exists(rel):
            used |= set(re.findall(r'\$\((CURRENT_PROJECT_VERSION|MARKETING_VERSION)\)',
                                   open(rel, encoding='utf-8').read()))
    for key in sorted(used - set(base)):
        problems.append(f"Info.plist 引用了 $({key})，但项目级 settings.base 未定义 → 产物会缺对应键")
    # 手写 Info.plist（INFOPLIST_FILE）必须自带 installd 要求的键。
    # 这些错只在安装阶段暴露（CI 踩过：widget 缺 CFBundleExecutable → 装不上）
    REQUIRED = ['CFBundleExecutable', 'CFBundleIdentifier', 'CFBundleName',
                'CFBundleShortVersionString', 'CFBundleVersion']
    for name, t in (spec.get('targets') or {}).items():
        rel = ((t.get('settings') or {}).get('base') or {}).get('INFOPLIST_FILE')
        if not rel or not os.path.exists(rel):
            if rel:
                problems.append(f"{name}: INFOPLIST_FILE 指向不存在的 {rel}")
            continue
        txt = open(rel, encoding='utf-8').read()
        for key in REQUIRED:
            if f'<key>{key}</key>' not in txt:
                problems.append(f"{name}: {rel} 缺 <key>{key}</key>（安装阶段会失败）")
    print()
    for p in problems:
        print("  ✗", p)
    print(f"结果：{len(problems)} 个问题")
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main())
