#!/usr/bin/env python3
"""FreeRoute AI 应用图标生成器（纯代码绘制，不依赖任何第三方素材）
主题：AI 智能路由核心 —— 深蓝黑背景 + 中心发光核心 + 蓝青数据线路汇聚
输出：AppIcon.appiconset 所需的 1024x1024 全出血方图（iOS 自行裁圆角）
"""
import math
import os
from PIL import Image, ImageDraw, ImageFilter

S = 1024
CX = CY = S / 2


def lerp(a, b, t):
    return a + (b - a) * t


def vertical_gradient(size, top, bottom):
    img = Image.new("RGB", size)
    px = img.load()
    w, h = size
    for y in range(h):
        t = y / max(1, h - 1)
        r = int(lerp(top[0], bottom[0], t))
        g = int(lerp(top[1], bottom[1], t))
        b = int(lerp(top[2], bottom[2], t))
        for x in range(w):
            px[x, y] = (r, g, b)
    return img


def radial_glow(size, center, radius, color, peak=1.0, gamma=2.2):
    """生成单通道径向发光（返回 RGBA 图层）"""
    w, h = size
    layer = Image.new("RGBA", size, (0, 0, 0, 0))
    px = layer.load()
    cx, cy = center
    step = 2  # 加速：2px 采样
    for y in range(0, h, step):
        dy2 = (y - cy) ** 2
        for x in range(0, w, step):
            dx2 = (x - cx) ** 2
            d = math.sqrt(dx2 + dy2)
            if d > radius:
                continue
            t = 1.0 - d / radius
            a = int(255 * peak * (t ** gamma))
            if a <= 0:
                continue
            for j in range(step):
                if y + j >= h:
                    break
                for i in range(step):
                    if x + i >= w:
                        break
                    px[x + i, y + j] = (color[0], color[1], color[2], a)
    return layer


def rounded_square_mask(size, radius):
    m = Image.new("L", size, 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle([0, 0, size[0] - 1, size[1] - 1], radius=radius, fill=255)
    return m


def draw_line_gradient(img, p0, p1, c0, c1, width, alpha=255, samples=48):
    """在 RGBA 图上画渐变线"""
    d = ImageDraw.Draw(img)
    for i in range(samples):
        t0 = i / samples
        t1 = (i + 1.2) / samples
        if t1 > 1:
            t1 = 1.0
        x0 = lerp(p0[0], p1[0], t0)
        y0 = lerp(p0[1], p1[1], t0)
        x1 = lerp(p0[0], p1[0], t1)
        y1 = lerp(p0[1], p1[1], t1)
        col = (int(lerp(c0[0], c1[0], t0)),
               int(lerp(c0[1], c1[1], t0)),
               int(lerp(c0[2], c1[2], t0)), alpha)
        d.line([(x0, y0), (x1, y1)], fill=col, width=int(width))


def main():
    out_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                           "FreeRoute", "Resources", "Assets.xcassets", "AppIcon.appiconset")
    os.makedirs(out_dir, exist_ok=True)

    # ---------- 1. 背景：深蓝黑对角渐变 ----------
    base = vertical_gradient((S, S), (12, 18, 34), (4, 6, 12)).convert("RGBA")

    # 左上暗角 + 右侧微光，制造深度
    depth = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    depth = Image.alpha_composite(depth, radial_glow((S, S), (S * 0.18, S * 0.16), S * 0.75, (26, 44, 92), 0.55, 2.6))
    depth = Image.alpha_composite(depth, radial_glow((S, S), (S * 0.86, S * 0.9), S * 0.6, (10, 40, 58), 0.42, 2.6))
    base = Image.alpha_composite(base, depth)

    # ---------- 2. 汇聚线 glow 层 ----------
    nodes = []
    R = S * 0.335
    # 8 个外围节点：非均匀角度，避免过于机械
    angles = [90, 135, 180, 225, 270, 315, 0, 45]
    radii = [1.0, 0.82, 1.06, 0.88, 1.0, 0.84, 1.04, 0.9]
    for a, rr in zip(angles, radii):
        rad = math.radians(a)
        nodes.append((CX + math.cos(rad) * R * rr, CY - math.sin(rad) * R * rr, a))

    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    for (nx, ny, _) in nodes:
        draw_line_gradient(glow, (nx, ny), (CX, CY), (60, 200, 235), (36, 92, 235), 26, 70, samples=34)
    glow = glow.filter(ImageFilter.GaussianBlur(18))

    core_glow = radial_glow((S, S), (CX, CY), S * 0.30, (58, 150, 255), 0.85, 1.7)
    cyan_glow = radial_glow((S, S), (CX, CY), S * 0.155, (150, 240, 255), 0.75, 1.4)
    glow = Image.alpha_composite(glow, core_glow)
    glow = Image.alpha_composite(glow, cyan_glow)
    base = Image.alpha_composite(base, glow)

    # ---------- 3. 清晰线路 + 轨道环 ----------
    lines = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(lines)
    # 外轨道环（细）
    d.ellipse([CX - R * 1.02, CY - R * 1.02, CX + R * 1.02, CY + R * 1.02],
              outline=(120, 190, 255, 34), width=3)
    d.ellipse([CX - R * 0.62, CY - R * 0.62, CX + R * 0.62, CY + R * 0.62],
              outline=(120, 220, 255, 22), width=2)
    for (nx, ny, _) in nodes:
        draw_line_gradient(lines, (nx, ny), (CX, CY), (120, 235, 255), (48, 110, 245), 6, 210, samples=56)
    base = Image.alpha_composite(base, lines)

    # ---------- 4. 外围节点（小发光球） ----------
    for idx, (nx, ny, _) in enumerate(nodes):
        node_glow = radial_glow((S, S), (nx, ny), S * 0.055, (110, 225, 255), 0.85, 1.5)
        base = Image.alpha_composite(base, node_glow)
        d2 = ImageDraw.Draw(base)
        r = S * 0.0195 if idx % 2 == 0 else S * 0.0155
        d2.ellipse([nx - r, ny - r, nx + r, ny + r], fill=(225, 250, 255, 255))
        d2.ellipse([nx - r * 0.5, ny - r * 0.5, nx + r * 0.5, ny + r * 0.5], fill=(255, 255, 255, 255))

    # ---------- 5. 中心核心（玻璃球） ----------
    core_r = S * 0.108
    core = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    dc = ImageDraw.Draw(core)
    # 同心圆近似径向渐变：t=1 为边缘（深蓝），t=0 为中心（白青）
    steps = 90
    for i in range(steps, 0, -1):
        t = i / steps
        r = core_r * t
        cr = int(lerp(240, 20, t))
        cg = int(lerp(252, 92, t))
        cb = int(lerp(255, 232, t))
        dc.ellipse([CX - r, CY - r, CX + r, CY + r], fill=(cr, cg, cb, 255))
    # 左上柔和高光（小而克制，避免形成"表情"）
    hl = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    dh = ImageDraw.Draw(hl)
    dh.ellipse([CX - core_r * 0.66, CY - core_r * 0.80,
                CX - core_r * 0.16, CY - core_r * 0.40], fill=(255, 255, 255, 105))
    hl = hl.filter(ImageFilter.GaussianBlur(13))
    core = Image.alpha_composite(core, hl)
    # 右上冷边光（rim light，弱化处理，不再形成弧线笑脸）
    rim = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    dr0 = ImageDraw.Draw(rim)
    dr0.arc([CX - core_r, CY - core_r, CX + core_r, CY + core_r],
            start=300, end=400, fill=(170, 235, 255, 90), width=int(core_r * 0.10))
    rim = rim.filter(ImageFilter.GaussianBlur(8))
    core = Image.alpha_composite(core, rim)
    # 外环（智能路由接口）
    dr = ImageDraw.Draw(core)
    dr.ellipse([CX - core_r * 1.46, CY - core_r * 1.46, CX + core_r * 1.46, CY + core_r * 1.46],
               outline=(150, 225, 255, 165), width=5)
    dr.ellipse([CX - core_r * 1.74, CY - core_r * 1.74, CX + core_r * 1.74, CY + core_r * 1.74],
               outline=(90, 170, 255, 70), width=3)
    base = Image.alpha_composite(base, core)

    # ---------- 6. 整体玻璃质感高光 ----------
    sheen = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ds = ImageDraw.Draw(sheen)
    ds.ellipse([-S * 0.35, -S * 0.72, S * 1.05, S * 0.30], fill=(255, 255, 255, 26))
    sheen = sheen.filter(ImageFilter.GaussianBlur(60))
    base = Image.alpha_composite(base, sheen)

    # ---------- 7. 轻微暗角 + 输出 ----------
    vig = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    vig_px = vig.load()
    for y in range(0, S, 4):
        for x in range(0, S, 4):
            dx = (x - CX) / (S * 0.72)
            dy = (y - CY) / (S * 0.72)
            d0 = math.sqrt(dx * dx + dy * dy)
            a = int(min(120, max(0, (d0 - 0.55) * 240)))
            if a > 0:
                for j in range(4):
                    for i in range(4):
                        if x + i < S and y + j < S:
                            vig_px[x + i, y + j] = (0, 0, 0, a)
    base = Image.alpha_composite(base, vig)

    final = base.convert("RGB")  # App Store 图标不允许 alpha
    final.save(os.path.join(out_dir, "AppIcon-1024.png"), optimize=True)
    print("图标已生成:", os.path.join(out_dir, "AppIcon-1024.png"), final.size)

    # 预览缩略图
    prev = final.copy()
    prev.thumbnail((512, 512))
    mask = rounded_square_mask(prev.size, int(prev.size[0] * 0.225))
    canvas = Image.new("RGB", prev.size, (12, 16, 28))
    canvas.paste(prev, (0, 0), mask)
    canvas.save(os.path.join(os.path.dirname(out_dir), "..", "..", "..", "tools", "icon-preview.png"))


if __name__ == "__main__":
    main()
