# -*- coding: utf-8 -*-
"""第 02 篇 CSDN 插图：对象池收益边界（信息图；科技蓝渐变 + 代码元素，本地 PIL 绘图保证中文清晰）"""
import math
import random
import numpy as np
from PIL import Image, ImageDraw, ImageFont

# 最终尺寸 1200x675（16:9 稍高，适合信息图），2 倍超采样抗锯齿
SS = 2
W, H = 1200, 675
w, h = W * SS, H * SS

FONT_BD = "C:/Windows/Fonts/msyhbd.ttc"
FONT_RG = "C:/Windows/Fonts/msyh.ttc"
FONT_MONO = "C:/Windows/Fonts/consola.ttf"


def f(path, size):
    return ImageFont.truetype(path, int(size * SS))


# ---------- 背景：对角渐变 + 双色光晕（沿用封面配色） ----------
yy, xx = np.mgrid[0:h, 0:w]
nx, ny = xx / w, yy / h
r0, g0, b0 = 7, 16, 38
r1, g1, b1 = 11, 58, 92
t = np.clip(nx * 0.42 + ny * 0.58, 0, 1)
R = r0 + (r1 - r0) * t
G = g0 + (g1 - g0) * t
B = b0 + (b1 - b0) * t
for gx, gy, rad, cr, cg, cb in [
    (0.86, 0.10, 0.55, 6, 72, 88),
    (0.05, 0.95, 0.50, 4, 30, 56),
]:
    d0 = np.sqrt(((nx - gx) * 1.5) ** 2 + ((ny - gy) * 1.0) ** 2)
    glow = np.clip(1 - d0 / rad, 0, 1) ** 2
    R += glow * cr
    G += glow * cg
    B += glow * cb
arr = np.stack([R, G, B], axis=-1).clip(0, 255).astype("uint8")
img = Image.fromarray(arr, "RGB")

# ---------- 装饰层：节点网络 + 代码水印（低透明度，不干扰图表） ----------
overlay = Image.new("RGBA", (w, h), (0, 0, 0, 0))
ov = ImageDraw.Draw(overlay)
random.seed(5)
nodes = [(random.uniform(w * 0.55, w * 0.98), random.uniform(h * 0.05, h * 0.95))
         for _ in range(18)]
for i, (x1, y1) in enumerate(nodes):
    for x2, y2 in nodes[i + 1:]:
        dist = math.hypot(x2 - x1, y2 - y1)
        if dist < 190 * SS:
            ov.line([(x1, y1), (x2, y2)],
                    fill=(90, 200, 235, int(38 * (1 - dist / (190 * SS)))),
                    width=1 * SS)
for x, y in nodes:
    r = random.uniform(2, 4) * SS
    ov.ellipse([x - r, y - r, x + r, y + r], fill=(120, 225, 255, 110))
mono = f(FONT_MONO, 26)
for s, px, py in [("pool.get()", 0.62, 0.08), ("obj:put(o)", 0.80, 0.22),
                  ("reset(o)", 0.66, 0.88), ("debug.sethook", 0.88, 0.74)]:
    ov.text((w * px, h * py), s, font=mono, fill=(150, 215, 245, 30))

img = Image.alpha_composite(img.convert("RGBA"), overlay).convert("RGB")
d = ImageDraw.Draw(img)

# ---------- 标题区（坐标按最终尺寸设计，再乘 SS） ----------
X = 150 * SS
d.text((X, 44 * SS), "技 术 实 战  ·  第 5 章  PERFORMANCE",
       font=f(FONT_BD, 22), fill=(120, 225, 240))
d.text((X, 86 * SS), "对象池是负优化？", font=f(FONT_BD, 60), fill=(245, 252, 255))
d.text((X + 3 * SS, 166 * SS), "10 万次分配测出的收益边界",
       font=f(FONT_RG, 32), fill=(135, 220, 245))
d.line([(X, 222 * SS), (X + 900 * SS, 222 * SS)], fill=(70, 150, 190), width=2 * SS)
d.text((X, 242 * SS), "四场景池化 speedup（strict 模式，no-pool = 1.0x 为基准）",
       font=f(FONT_RG, 21), fill=(190, 220, 238))

# ---------- speedup 条形图（真实数据，来自 02 篇场景 A–D） ----------
rows = [
    ("A  packet（5 标量）", 0.81),
    ("B  aoi_entity（嵌套表）", 1.31),
    ("C  heavy（变长 reset）", 0.93),
    ("D  damage_event（嵌套表）", 1.15),
]
x0 = 430 * SS
unit = 380 * SS          # 1.0x = 380px
x_one = int(x0 + unit)
y0 = 292 * SS
rowh = 44 * SS
barh = 24 * SS

# 1.0x 基准虚线
for yy2 in range(y0 - 6 * SS, y0 + 4 * rowh + 6 * SS, 14 * SS):
    d.line([(x_one, yy2), (x_one, yy2 + 7 * SS)],
           fill=(225, 235, 245), width=2 * SS)
d.text((x_one - 32 * SS, y0 + 4 * rowh + 8 * SS), "1.0x",
       font=f(FONT_RG, 17), fill=(200, 225, 240))

lblf = f(FONT_RG, 21)
valf = f(FONT_BD, 21)
for i, (label, v) in enumerate(rows):
    y = y0 + i * rowh + (rowh - barh) // 2
    d.text((X, y + 2 * SS), label, font=lblf, fill=(205, 230, 242))
    end = int(x0 + v * unit)
    neg = v < 1.0
    col = (236, 104, 96) if neg else (66, 212, 172)
    d.rounded_rectangle([x0, y, x0 + int(1.4 * unit), y + barh],
                        radius=barh / 2, fill=(18, 52, 80))
    d.rounded_rectangle([x0, y, end, y + barh], radius=barh / 2, fill=col)
    d.text((end + 10 * SS, y + 1 * SS), f"{v:.2f}x", font=valf, fill=col)

# 图例
ly = y0 + 4 * rowh + 12 * SS
d.ellipse([X, ly, X + 12 * SS, ly + 12 * SS], fill=(236, 104, 96))
d.text((X + 18 * SS, ly - 3 * SS), "负优化（<1.0x）", font=f(FONT_RG, 17), fill=(205, 225, 238))
d.ellipse([X + 190 * SS, ly, X + 202 * SS, ly + 12 * SS], fill=(66, 212, 172))
d.text((X + 208 * SS, ly - 3 * SS), "正收益（>1.0x）", font=f(FONT_RG, 17), fill=(205, 225, 238))

# ---------- 底部：判定公式 + 关键数据 pills ----------
fy = 508 * SS
d.rounded_rectangle([X, fy, X + 900 * SS, fy + 50 * SS], radius=10 * SS,
                    fill=(12, 48, 74), outline=(70, 175, 210), width=2 * SS)
d.text((X + 20 * SS, fy + 11 * SS),
       "池化收益 = (构造成本 − 取用成本 − 归还成本) × 复用次数",
       font=f(FONT_RG, 24), fill=(205, 240, 252))

pills = [
    ("分配次数 −99.97%", (66, 212, 172)),
    ("首轮 0.57x  负优化", (236, 104, 96)),
    ("D 场景 heap −41%", (66, 212, 172)),
]
py = 572 * SS
px = X
pf = f(FONT_RG, 20)
for text, col in pills:
    bb = d.textbbox((0, 0), text, font=pf)
    pw = bb[2] - bb[0] + 32 * SS
    ph = 44 * SS
    d.rounded_rectangle([px, py, px + pw, py + ph], radius=ph / 2,
                        fill=(16, 58, 88), outline=col, width=2 * SS)
    d.text((px + 16 * SS, py + 9 * SS), text, font=pf, fill=col)
    px += pw + 18 * SS

d.text((w - 230 * SS, h - 42 * SS), "@ robinicon",
       font=f(FONT_MONO, 17), fill=(120, 160, 190))

# ---------- 缩小输出 ----------
img = img.resize((W, H), Image.LANCZOS)
out_dir = "C:/workspaces/bookskynet/csdn_cover"
img.save(out_dir + "/csdn_illust_02_pool_boundary.png")
img.save(out_dir + "/csdn_illust_02_pool_boundary.jpg", quality=94)
print("saved:", out_dir + "/csdn_illust_02_pool_boundary.png", img.size)
