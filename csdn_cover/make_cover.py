# -*- coding: utf-8 -*-
"""生成 CSDN 博客封面：Skynet 游戏服务器实战（科技蓝渐变 + 代码元素）"""
import math
import random
from PIL import Image, ImageDraw, ImageFont, ImageFilter

# 最终尺寸 1200x512（约 2.34:1，贴近 CSDN 推荐封面比例），2 倍超采样抗锯齿
SS = 2
W, H = 1200, 512
w, h = W * SS, H * SS

FONT_BD = "C:/Windows/Fonts/msyhbd.ttc"
FONT_RG = "C:/Windows/Fonts/msyh.ttc"
FONT_MONO = "C:/Windows/Fonts/consola.ttf"

def f(path, size):
    return ImageFont.truetype(path, int(size * SS))

# ---------- 背景：对角渐变 + 双色光晕 ----------
try:
    import numpy as np
    yy, xx = np.mgrid[0:h, 0:w]
    nx = xx / w
    ny = yy / h
    r0, g0, b0 = 7, 16, 38
    r1, g1, b1 = 11, 58, 92
    t = np.clip(nx * 0.5 + ny * 0.62, 0, 1)
    R = r0 + (r1 - r0) * t
    G = g0 + (g1 - g0) * t
    B = b0 + (b1 - b0) * t
    for gx, gy, rad, cr, cg, cb in [
        (0.80, 0.16, 0.55, 6, 72, 88),
        (0.06, 0.94, 0.50, 4, 30, 56),
    ]:
        d = np.sqrt(((nx - gx) * 1.6) ** 2 + ((ny - gy) * 1.0) ** 2)
        glow = np.clip(1 - d / rad, 0, 1) ** 2
        R += glow * cr
        G += glow * cg
        B += glow * cb
    arr = np.stack([R, G, B], axis=-1).clip(0, 255).astype("uint8")
    img = Image.fromarray(arr, "RGB")
except Exception:
    img = Image.new("RGB", (w, h), (9, 30, 60))
    d0 = ImageDraw.Draw(img)
    for y in range(h):
        t = y / h
        d0.line([(0, y), (w, y)], fill=(int(7 + 6 * t), int(16 + 42 * t), int(38 + 54 * t)))

overlay = Image.new("RGBA", (w, h), (0, 0, 0, 0))
ov = ImageDraw.Draw(overlay)

# ---------- 右侧节点网络（分布式概念） ----------
random.seed(42)
nodes = []
for _ in range(22):
    x = random.uniform(w * 0.52, w * 0.97)
    y = random.uniform(h * 0.05, h * 0.95)
    nodes.append((x, y))
for i, (x1, y1) in enumerate(nodes):
    for x2, y2 in nodes[i + 1:]:
        dist = math.hypot(x2 - x1, y2 - y1)
        if dist < 210 * SS:
            alpha = int(70 * (1 - dist / (210 * SS)))
            ov.line([(x1, y1), (x2, y2)], fill=(90, 200, 235, alpha), width=1 * SS)
for (x, y) in nodes:
    r = random.uniform(2.5, 5.5) * SS
    ov.ellipse([x - r, y - r, x + r, y + r], fill=(120, 225, 255, 170))
    ov.ellipse([x - r * 2.6, y - r * 2.6, x + r * 2.6, y + r * 2.6],
               outline=(90, 200, 235, 45), width=1 * SS)

# ---------- 半透明代码水印 ----------
mono = f(FONT_MONO, 34)
codes = [
    ("skynet.call(", 0.60, 0.10), ("function()", 0.72, 0.30),
    ("{ }", 0.93, 0.42), ("cluster.send", 0.58, 0.62),
    ("</>", 0.88, 0.78), ("local uid =", 0.66, 0.90),
]
for s, px, py in codes:
    ov.text((w * px, h * py), s, font=mono, fill=(150, 215, 245, 38))

# ---------- 左侧竖向高亮条 + 角标装饰 ----------
ov.rounded_rectangle([118 * SS, 250 * SS, 130 * SS, 770 * SS],
                     radius=6 * SS, fill=(60, 220, 235, 230))
ov.rounded_rectangle([112 * SS, 244 * SS, 136 * SS, 776 * SS],
                     radius=8 * SS, fill=(60, 220, 235, 40))

img = Image.alpha_composite(img.convert("RGBA"), overlay).convert("RGB")
draw = ImageDraw.Draw(img)

# ---------- 文字（坐标均按最终 1200x512 设计，再乘 SS） ----------
X = 200 * SS
kicker = "技 术 实 战  ·  SERIES"
draw.text((X, 56 * SS), kicker, font=f(FONT_BD, 26), fill=(120, 225, 240))

title = "Skynet 游戏服务器实战"
draw.text((X, 126 * SS), title, font=f(FONT_BD, 80), fill=(245, 252, 255))

sub = "从登录网关到分布式架构"
draw.text((X + 4 * SS, 258 * SS), sub, font=f(FONT_RG, 34), fill=(135, 220, 245))

en = "GAME SERVER PRACTICE   /   LUA   /   DISTRIBUTED"
draw.text((X + 4 * SS, 318 * SS), en, font=f(FONT_MONO, 20), fill=(150, 190, 215))

draw.line([(X, 366 * SS), (X + 760 * SS, 366 * SS)], fill=(70, 150, 190), width=2 * SS)

# 标签 pills
pills = ["Lua", "Skynet", "分布式", "ECS 架构", "热更新", "一致性哈希"]
pf = f(FONT_RG, 20)
px = X
for p in pills:
    bb = draw.textbbox((0, 0), p, font=pf)
    tw = bb[2] - bb[0]
    pw = tw + 32 * SS
    ph = 46 * SS
    py = 386 * SS
    draw.rounded_rectangle([px, py, px + pw, py + ph], radius=ph / 2,
                           outline=(70, 175, 210), width=2 * SS,
                           fill=(20, 70, 100, 255))
    draw.text((px + 16 * SS, py + 8 * SS), p, font=pf, fill=(205, 240, 252))
    px += pw + 16 * SS

# 右下角装饰文字
draw.text((w - 250 * SS, h - 48 * SS), "@ robinicon", font=f(FONT_MONO, 18),
          fill=(120, 160, 190))

# ---------- 缩小输出 ----------
img = img.resize((W, H), Image.LANCZOS)
out_dir = "C:/workspaces/bookskynet/csdn_cover"
img.save(out_dir + "/csdn_cover_skynet.png")
img.save(out_dir + "/csdn_cover_skynet.jpg", quality=94)
print("saved:", out_dir + "/csdn_cover_skynet.png", img.size)
