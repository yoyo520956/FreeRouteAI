#!/usr/bin/env python3
"""从 simctl 挑一个真实可用的模拟器，输出 name / os / udid。

为什么必须用 udid：`-destination "platform=iOS Simulator,name=X"` 会隐式加
`OS:latest`，而 Runner 上某些机型只装了旧系统（iPhone 16e 只有 26.2，
latest 是 26.5），于是报 "no available devices matched the request"。
CI run 41885104247 的步骤 6 就是这么失败的。
"""
import json
import os
import subprocess
import sys

PREFERENCE = ["iPhone SE (3rd generation)", "iPhone SE (2nd generation)",
              "iPhone 16e", "iPhone 17e", "iPhone Air", "iPhone 17",
              "iPhone 17 Pro", "iPhone 15", "iPhone 14"]


def ver(s):
    return tuple(int(p) for p in str(s).replace('_', '.').split('.') if p.isdigit()) or (0,)


def main():
    res = subprocess.run(['xcrun', 'simctl', 'list', 'devices', 'available', '-j'],
                         capture_output=True, text=True)
    if res.returncode != 0:
        print("::error::simctl 调用失败：" + res.stderr.strip(), file=sys.stderr)
        return 1
    data = json.loads(res.stdout)['devices']
    cands = []
    for runtime, devs in data.items():
        if 'iOS' not in runtime:
            continue
        rt_os = runtime.split('runtime.com.apple.CoreSimulator.SimRuntime.iOS-')[-1]
        for d in devs:
            if not d.get('name', '').startswith('iPhone'):
                continue
            cands.append((d['name'], d.get('version') or rt_os.replace('-', '.'), d['udid']))
    if not cands:
        print("::error::没有可用的 iPhone 模拟器", file=sys.stderr)
        return 1

    def rank(c):
        name, v, _ = c
        pref = next((i for i, p in enumerate(PREFERENCE) if p == name), len(PREFERENCE))
        return (pref, tuple(-x for x in ver(v)))

    cands.sort(key=rank)
    name, v, udid = cands[0]
    print(f"选中：{name} · iOS {v} · {udid}")
    if "SE" not in name:
        print("提示：Runner 未提供 iPhone SE (3rd generation) 模拟器，"
              "CI 截图不是 SE 3 的 4.7 寸尺寸，小屏适配需真机验证。")
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a', encoding='utf-8') as f:
            f.write(f"name={name}\nos={v}\nud={udid}\n")
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a', encoding='utf-8') as f:
            f.write(f"- 测试机型：{name}（iOS {v}，按 UDID 精确指定）\n")
            if "SE" not in name:
                f.write("- ⚠️ 截图**不是 iPhone SE 3 尺寸**，SE3 小屏适配需真机验证\n")
    return 0


if __name__ == '__main__':
    sys.exit(main())
