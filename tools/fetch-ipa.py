#!/usr/bin/env python3
"""只从 Actions 产物 zip 里取指定文件，不下载整包。

背景：build-output 产物里 78MB 几乎全是 UITests.xcresult，而 iSH 拉整包会超时。
做法：用 HTTP Range 只取 zip 的尾部和目标条目的字节，本地重组成合法 zip。
依赖：仅标准库 + gh（拿签名下载地址）。
"""
import io
import json
import struct
import subprocess
import sys
import urllib.request

OWNER_REPO = "yoyo520956/FreeRouteAI"


def sh(args):
    r = subprocess.run(args, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"命令失败 {args[:3]}: {r.stderr.strip()[:300]}")
    return r.stdout


def artifact_zip_url(run_id, artifact_name):
    arts = json.loads(sh([
        "gh", "api", f"repos/{OWNER_REPO}/actions/runs/{run_id}/artifacts",
        "--jq", ".artifacts"
    ]))
    hit = [a for a in arts if a["name"] == artifact_name]
    if not hit:
        sys.exit(f"没找到产物 {artifact_name}；现有：{[a['name'] for a in arts]}")
    aid = hit[0]["id"]
    print(f"artifact id={aid} size={hit[0]['size_in_bytes']/1e6:.1f}MB")
    # 取 302 的 Location（gh api 会自动跟随重定向，所以用 -i 看头）
    out = sh(["gh", "api", "-i",
              f"repos/{OWNER_REPO}/actions/artifacts/{aid}/zip"])
    for line in out.splitlines():
        if line.lower().startswith("location:"):
            return line.split(":", 1)[1].strip(), aid
    sys.exit("拿不到签名下载地址")


def fetch_range(url, start, end):
    req = urllib.request.Request(url, headers={"Range": f"bytes={start}-{end}"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.read()


def total_size(url):
    req = urllib.request.Request(url, method="HEAD")
    with urllib.request.urlopen(req, timeout=60) as r:
        return int(r.headers["Content-Length"])


def central_entries(url, size):
    """从尾部解析 EOCD，再取中央目录。"""
    tail = fetch_range(url, max(0, size - 65557), size - 1)
    i = tail.rfind(b"PK\x05\x06")
    if i < 0:
        sys.exit("找不到 EOCD 签名")
    _, _, _, _, cd_count, cd_size, cd_off, _ = struct.unpack("<IHHHHIIH", tail[i:i + 22])
    cd = fetch_range(url, cd_off, cd_off + cd_size - 1)
    out, p = [], 0
    for _ in range(cd_count):
        if cd[p:p + 4] != b"PK\x01\x02":
            break
        (method, _, _, _, _, _, csize, usize, nlen, elen, clen,
         _, _, ext, lho) = struct.unpack("<HHHHHHIIIHHHHHII", cd[p + 10:p + 46])
        name = cd[p + 46:p + 46 + nlen].decode("utf-8", "replace")
        out.append((name, method, csize, usize, lho, cd[p:p + 46 + nlen + elen + clen]))
        p += 46 + nlen + elen + clen
    return out


def build_zip(url, picked, path):
    """picked: [(name, method, csize, usize, lho, cd_record)]，重新打包成一个 zip。"""
    buf = io.BytesIO()
    new_cd = b""
    for name, method, csize, usize, lho, cd_rec in picked:
        local = fetch_range(url, lho, lho + 29)
        nlen, elen = struct.unpack("<HH", local[26:30])
        head = fetch_range(url, lho, lho + 30 + nlen + elen - 1)
        data = fetch_range(url, lho + 30 + nlen + elen,
                           lho + 30 + nlen + elen + csize - 1) if csize else b""
        offset = buf.tell()
        buf.write(head)
        buf.write(data)
        # 修正中央目录里的本地头偏移
        fixed = bytearray(cd_rec)
        struct.pack_into("<I", fixed, 42, offset)
        new_cd += bytes(fixed)
    cd_start = buf.tell()
    buf.write(new_cd)
    buf.write(struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, len(picked), len(picked),
                          len(new_cd), cd_start, 0))
    open(path, "wb").write(buf.getvalue())
    return buf.tell()


def main():
    run_id, out_path = sys.argv[1], sys.argv[2]
    want = sys.argv[3] if len(sys.argv) > 3 else ".ipa"
    artifact = sys.argv[4] if len(sys.argv) > 4 else "build-output"
    url, _ = artifact_zip_url(run_id, artifact)
    size = total_size(url)
    entries = central_entries(url, size)
    names = [e[0] for e in entries]
    picked = [e for e in entries if e[0].endswith(want) and not e[0].endswith("/")]
    if not picked:
        sys.exit(f"产物里没有以 {want} 结尾的文件；清单：\n" + "\n".join(names[:40]))
    n = build_zip(url, picked, out_path)
    print(f"下载字节数（只取目标条目）：约 "
          f"{sum(p[2] for p in picked)/1e6:.2f}MB，写出 {out_path} {n/1e6:.2f}MB")
    for p in picked:
        print(f"  · {p[0]}  原始 {p[3]/1e6:.2f}MB")


if __name__ == "__main__":
    main()
