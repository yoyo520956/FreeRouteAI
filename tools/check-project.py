#!/usr/bin/env python3
"""校验 project.yml 里每个 target 的 sources 在磁盘上真的有文件。

背景（CI 真实事故）：App target 的 sources 写了 excludes: ["**/.*"]，
XcodeGen 因此给它收录了 0 个源文件 —— 结果 xcodebuild 一路
BUILD SUCCEEDED / ARCHIVE SUCCEEDED，导出的 IPA 里却没有主程序。
这个检查让它在推送前就暴露。
"""
import os
import sys
import glob

import yaml

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
        expect_sources = not ttype.startswith('bundle.') or True
        if total == 0 and expect_sources:
            problems.append(f"{name}: 该 target 一个源文件都没有（type={ttype}）")
    print()
    for p in problems:
        print("  ✗", p)
    print(f"结果：{len(problems)} 个问题")
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main())
