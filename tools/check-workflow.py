#!/usr/bin/env python3
"""工作流结构校验（actionlint 在 iSH 下会段错误，这个是稳定兜底）。

抓的是真会让整个 workflow 解析失败/静默跳过的问题：
- steps 上下文用步骤名引用（Actions 只认 id）
- if 里引用未声明的 id（静默永不执行）
- 步骤既无 run 也无 uses
- 表达式括号不配平
"""
import glob
import re
import sys

import yaml


def check(path):
    problems = []
    doc = yaml.safe_load(open(path, encoding='utf-8'))
    jobs = doc.get('jobs') or {}
    if not jobs:
        problems.append(f"{path}: 没有 jobs")
    for jn, job in jobs.items():
        if not job.get('runs-on'):
            problems.append(f"{path}:{jn} 缺 runs-on")
        ids = {st['id'] for st in job.get('steps', []) if isinstance(st, dict) and 'id' in st}
        for i, st in enumerate(job.get('steps', []), 1):
            if not isinstance(st, dict):
                problems.append(f"{path}:{jn}#{i} 步骤不是映射")
                continue
            if not (st.get('run') or st.get('uses')):
                problems.append(f"{path}:{jn}#{i} 既无 run 也无 uses")
            expr = st.get('if', '')
            if isinstance(expr, str) and expr:
                if expr.count('(') != expr.count(')'):
                    problems.append(f"{path}:{jn}#{i} if 括号不配平：{expr}")
                for m in re.finditer(r"steps\.(?:'([^']+)'|\"([^\"]+)\"|(\w+))", expr):
                    ref = m.group(1) or m.group(2) or m.group(3)
                    if m.group(3) is None:
                        problems.append(f"{path}:{jn}#{i} if 用步骤名引用 steps（只能用 id）：{ref}")
                    elif ref not in ids:
                        problems.append(f"{path}:{jn}#{i} if 引用未声明的 id：{ref}")
    return problems


def main():
    all_problems = []
    files = sorted(glob.glob('.github/workflows/*.yml') + glob.glob('.github/workflows/*.yaml'))
    for f in files:
        all_problems += check(f)
    print(f"校验工作流 {len(files)} 个")
    for p in all_problems:
        print("  ✗", p)
    print(f"结果：{len(all_problems)} 个问题")
    return 1 if all_problems else 0


if __name__ == '__main__':
    sys.exit(main())
