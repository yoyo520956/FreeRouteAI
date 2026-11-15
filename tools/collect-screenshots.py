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
# 测试跑完模拟器已关机，`booted` 不再解析；CI 通过 SIM_UDID 显式传入
UDID = os.environ.get("SIM_UDID") or "booted"
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
    if isinstance(items, dict):
        items = items.get("documents") or items.get("attachments") or []
    if not items:
        print("· manifest 为空（UI 测试没有产出附件？）")
    elif not any((it.get("exportedFileName") or it.get("filename")
                  or it.get("suggestedFileName")) for it in items):
        # 字段名跨 Xcode 版本不同；一条都不匹配时把真实结构打出来，别让人去猜
        print("· manifest 条目存在但没有可识别的文件名字段，样例：")
        print(json.dumps(items[0], ensure_ascii=False)[:400])
    got = 0
    for item in items:
        title = item.get("title") or item.get("name") or ""
        # manifest 里的 suggestedHumanReadableName 是 "Synthesized Event <时间>"，
        # 只有形如 01-dashboard 的名字才可信，否则交给 blob 兜底按序号命名
        if title and not re.match(r"^[0-9]{2}-[a-z-]+$", title):
            title = ""
        # xcresulttool 的 manifest 字段跨版本不一致，逐个兼容
        # Xcode 26.6 实测字段是 exportedFileName；attachment.name 不会进 manifest
        filename = (item.get("exportedFileName")
                    or item.get("filename")
                    or item.get("suggestedFileName")
                    or "")
        if not filename:
            continue
        src = os.path.join(raw, filename)
        if not os.path.exists(src):
            # exportedFileName 是不带后缀的哈希，真实落盘名可能带扩展名
            guess = [f for f in os.listdir(raw) if f.startswith(filename)]
            if not guess:
                continue
            src = os.path.join(raw, guess[0])
        name = title if title else os.path.splitext(filename)[0]
        if not name:
            continue
        dest = os.path.join(OUT, name if name.endswith(".png") else name + ".png")
        shutil.copy(src, dest)
        got += 1
    print(f"· 从 xcresult 收集 {got} 张")
    return got


def from_simulator():
    """UI 测试把 PNG 按屏名写进自己的沙盒；用 simctl 找到容器直接取出来。
    附件通道会丢掉 attachment.name，所以这条是主路径而不是兜底。"""
    candidates = [
        "com.freeroute.ai.uitests.xctrunner",  # Xcode 生成的 UI 测试 runner 真实后缀
        "com.freeroute.ai.uitests.runner",
        "com.freeroute.ai.uitests",
        "com.freeroute.ai",
    ]
    subdirs = ["Documents/ci-screenshots", "ci-screenshots",
               "tmp/screenshots", "Library/Caches/screenshots"]
    for bundle in candidates:
        container, rc = sh(f"xcrun simctl get_app_container {UDID} {bundle} data")
        if rc != 0 or not container:
            continue
        for sub in subdirs:
            src = os.path.join(container, sub.replace("/", os.sep))
            if not os.path.isdir(src):
                continue
            files = [f for f in os.listdir(src) if f.endswith(".png")]
            if not files:
                continue
            os.makedirs(OUT, exist_ok=True)
            got = 0
            for f in files:
                shutil.copy(os.path.join(src, f), os.path.join(OUT, f))
                got += 1
            print(f"· 从 {bundle}/{sub} 取到 {got} 张（按屏名）")
            return got
    # 按 bundle id 猜容器不可靠，直接在宿主侧按目录名搜一次（确定性最高）
    home = os.path.expanduser("~")
    dev = os.path.join(home, "Library/Developer/CoreSimulator/Devices")
    out, rc = sh(f"find {dev} -maxdepth 8 -type d -name ci-screenshots -print -quit")
    if rc == 0 and out and os.path.isdir(out):
        files = [f for f in os.listdir(out) if f.endswith(".png")]
        if files:
            os.makedirs(OUT, exist_ok=True)
            for f in files:
                shutil.copy(os.path.join(out, f), os.path.join(OUT, f))
            print(f"· 按目录名搜到 {out}，取到 {len(files)} 张（按屏名）")
            return len(files)
    print("· 模拟器沙盒里没找到 ci-screenshots；已试过的 bundle：" + ", ".join(candidates))
    return 0


def from_blobs(path="UITests.xcresult", limit=16):
    """兜底：manifest 字段名跨版本不一致时，直接从 xcresult 的 Data 目录里捞 PNG。
    附件是未压缩 PNG blob（本地实测），能拿到图，但名字只能按序号，无法对应屏名。"""
    data_dir = os.path.join(path, "Data")
    if not os.path.isdir(data_dir):
        return 0
    os.makedirs(OUT, exist_ok=True)
    got = 0
    for name in sorted(os.listdir(data_dir)):
        if not name.startswith("data.") or got >= limit:
            continue
        f = os.path.join(data_dir, name)
        try:
            with open(f, "rb") as fh:
                if fh.read(8) != b"\x89PNG\r\n\x1a\n":
                    continue
                fh.seek(0)          # 上面那 8 字节是签名，必须回卷，否则写出的 PNG 缺头
                blob = fh.read()
        except OSError:
            continue
        if len(blob) < 2000:      # 太小的多半是图标，不是截图
            continue
        got += 1
        dest = os.path.join(OUT, f"raw-shot-{got:02d}.png")
        with open(dest, "wb") as out:
            out.write(blob)
    if got:
        print(f"· 兜底：从 xcresult Data 里捞到 {got} 张 PNG（按序号命名，未对应屏名）")
    return got


def main():
    os.makedirs(OUT, exist_ok=True)
    total = from_xcresult()
    total += from_simulator()
    if total == 0:
        total = from_blobs()
    print("\n截图清单：")
    have = sorted(f for f in os.listdir(OUT) if f.endswith(".png")) if os.path.isdir(OUT) else []
    for name in WANTED:
        mark = "✓" if f"{name}.png" in have else "✗ 缺失"
        print(f"  {mark} {name}.png")
    print(f"\n合计 {len(have)} 张（UI 测试截图来自 iOS 模拟器，不等同于真机截图）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
