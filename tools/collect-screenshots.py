#!/usr/bin/env python3
"""从 .xcresult 与模拟器沙盒收集 UI 截图到 ./screenshots/
命名保持需求文件要求的 01-dashboard.png … 10-settings.png
"""
import json
import os
import re
import shutil
import subprocess
import sys

OUT = "screenshots"
WANTED = [
    "01-dashboard", "02-models", "03-providers", "04-smart-router", "05-gateway",
    "06-pip-monitor", "07-logs", "08-statistics", "09-security", "10-settings",
    "11-provider-editor", "12-provider-saved",
]


def sh(cmd):
    try:
        p = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=300)
        return p.stdout.strip(), p.returncode
    except Exception:
        return "", 1


def from_xcresult(path="UITests.xcresult"):
    if not os.path.isdir(path):
        print(f"· 无 {path}，跳过")
        return 0
    raw = "raw-attachments"
    shutil.rmtree(raw, ignore_errors=True)
    os.makedirs(raw, exist_ok=True)
    out, rc = sh(f"xcrun xcresulttool export attachments --path {path} --output-path {raw}")
    if rc != 0:
        print("· xcresulttool 导出失败：", out[:300])
        return 0
    manifest = os.path.join(raw, "manifest.json")
    if not os.path.exists(manifest):
        print("· manifest 缺失")
        return 0
    os.makedirs(OUT, exist_ok=True)
    items = json.load(open(manifest, encoding="utf-8"))
    got = 0
    for item in items:
        title = item.get("title") or item.get("name") or ""
        filename = item.get("suggestedFileName") or (item.get("payload") or {}).get("suggestedFileName") or ""
        if not filename:
            continue
        src = os.path.join(raw, filename)
        if not os.path.exists(src):
            continue
        name = title if title else os.path.splitext(filename)[0]
        if not name:
            continue
        dest = os.path.join(OUT, name if name.endswith(".png") else name + ".png")
        shutil.copy(src, dest)
        got += 1
    print(f"· 从 xcresult 收集 {got} 张")
    return got


def from_simulator(bundle="com.freeroute.ai"):
    container, rc = sh(f"xcrun simctl get_app_container booted {bundle} data")
    if rc != 0 or not container:
        print("· 取不到模拟器沙盒（App 未安装或测试未跑）")
        return 0
    src = os.path.join(container, "tmp", "screenshots")
    if not os.path.isdir(src):
        src = os.path.join(container, "Library", "Caches", "screenshots")
    if not os.path.isdir(src):
        print("· 沙盒里没有 screenshots 目录")
        return 0
    os.makedirs(OUT, exist_ok=True)
    n = 0
    for f in sorted(os.listdir(src)):
        if f.endswith(".png"):
            shutil.copy(os.path.join(src, f), os.path.join(OUT, f))
            n += 1
    print(f"· 从模拟器沙盒收集 {n} 张")
    return n


def main():
    os.makedirs(OUT, exist_ok=True)
    total = from_xcresult()
    total += from_simulator()
    print("\n截图清单：")
    have = sorted(f for f in os.listdir(OUT) if f.endswith(".png")) if os.path.isdir(OUT) else []
    for name in WANTED:
        mark = "✓" if f"{name}.png" in have else "✗ 缺失"
        print(f"  {mark} {name}.png")
    print(f"\n合计 {len(have)} 张（UI 测试截图来自 iOS 模拟器，不等同于真机截图）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
