# -*- coding: utf-8 -*-
"""第 03 篇 CSDN 插图：双语言 ECS 的性能真相与数据边界
信息图；科技蓝渐变 + 代码/节点元素，本地 PIL 2 倍超采样保证中文清晰。
所有数字直接取自 docs/blog/03-ch6-ecs-双语言ECS设计.md，不新增无依据数据。
"""
import math
import random
import numpy as np
from PIL import Image, ImageDraw, ImageFont

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
    (0.88, 0.08, 0.55, 6, 72, 88),
    (0.04, 0.96, 0.50, 4, 30, 56),
]:
    d0 = np.sqrt(((nx - gx) * 1.5) ** 2 + ((ny - gy) * 1.0) ** 2)
    glow = np.clip(1 - d0 / rad, 0, 1) ** 2
    R += glow * cr
    G += glow * cg
    B += glow * cb
arr = np.stack([R, G, B], axis=-1).clip(0, 255).astype("uint8")
img = Image.fromarray(arr, "RGB")

# ---------- 装饰层：节点网络 + 代码水印 ----------
overlay = Image.new("RGBA", (w, h), (0, 0, 0, 0))
ov = ImageDraw.Draw(overlay)
random.seed(6)
nodes = [(random.uniform(w * 0.52, w * 0.99), random.uniform(h * 0.04, h * 0.96))
         for _ in range(20)]
for i, (x1, y1) in enumerate(nodes):
    for x2, y2 in nodes[i + 1:]:
        dist = math.hypot(x2 - x1, y2 - y1)
        if dist < 185 * SS:
            ov.line([(x1, y1), (x2, y2)],
                    fill=(90, 200, 235, int(36 * (1 - dist / (185 * SS)))),
                    width=1 * SS)
for x, y in nodes:
    r = random.uniform(2, 4) * SS
    ov.ellipse([x - r, y - r, x + r, y + r], fill=(120, 225, 255, 105))
mono = f(FONT_MONO, 25)
for s, px, py in [("sparse_set[]", 0.63, 0.05), ("SoA lanes", 0.86, 0.18),
                  ("swap_remove", 0.68, 0.90), ("-O3 == -O2", 0.89, 0.76)]:
    ov.text((w * px, h * py), s, font=mono, fill=(150, 215, 245, 28))

img = Image.alpha_composite(img.convert("RGBA"), overlay).convert("RGB")
d = ImageDraw.Draw(img)

X = 92 * SS

# ---------- 标题区 ----------
d.text((X, 36 * SS), "技 术 实 战  ·  第 6 章  DUAL-LANGUAGE ECS",
       font=f(FONT_BD, 20), fill=(120, 225, 240))
d.text((X, 72 * SS), "快 800 倍，还是快 39 倍？", font=f(FONT_BD, 50), fill=(245, 252, 255))
d.text((X + 3 * SS, 142 * SS), "双语言 ECS 的性能真相与数据边界",
       font=f(FONT_RG, 27), fill=(135, 220, 245))
d.line([(X, 196 * SS), (X + 1016 * SS, 196 * SS)], fill=(70, 150, 190), width=2 * SS)

GREEN = (66, 212, 172)
RED = (236, 104, 96)
AMBER = (240, 180, 90)
PALE = (205, 230, 242)

# ---------- 左栏：三层对比（对数刻度条形） ----------
d.text((X, 211 * SS), "三层对比 · 1000 实体 × 1000 帧",
       font=f(FONT_BD, 21), fill=(235, 248, 255))

rows = [
    ("Lua 通用 each()", 412.65, "412.65 μs", RED),
    ("Lua 专用 tick()", 102.22, "102.22 μs", AMBER),
    ("C  bench()", 1.24, "1.24 μs", GREEN),
]
x0 = X
bar_top = [258, 318, 378]
bar_h = 26 * SS
log_vals = [math.log10(v + 1) for _, v, _, _ in rows]
unit = (420 * SS) / max(log_vals)

lblf = f(FONT_RG, 19)
valf = f(FONT_BD, 20)
for (label, _, valtext, col), top, lv in zip(rows, bar_top, log_vals):
    y = top * SS
    d.text((x0, y - 25 * SS), label, font=lblf, fill=PALE)
    end = int(x0 + lv * unit)
    d.rounded_rectangle([x0, y, x0 + 428 * SS, y + bar_h],
                        radius=bar_h / 2, fill=(18, 52, 80))
    d.rounded_rectangle([x0, y, end, y + bar_h], radius=bar_h / 2, fill=col)
    d.text((end + 9 * SS, y + 1 * SS), valtext, font=valf, fill=col)

d.text((X, 434 * SS), "每帧耗时（μs，条形为对数刻度）",
       font=f(FONT_RG, 16), fill=(165, 200, 222))
d.text((X, 458 * SS), "C 比 Lua 专用 tick 快 82×，比通用 each 快 333×",
       font=f(FONT_RG, 17), fill=(170, 215, 235))

# ---------- 右栏：两个关键倍数卡片 ----------
CX, CW = 650 * SS, 460 * SS
d.text((CX, 211 * SS), "同一份数据，两个相反的答案",
       font=f(FONT_BD, 21), fill=(235, 248, 255))


def card(top, height, big, sub1, sub2, col, tag):
    y1 = top * SS
    y2 = (top + height) * SS
    d.rounded_rectangle([CX, y1, CX + CW, y2], radius=14 * SS,
                        fill=(12, 44, 70), outline=col, width=2 * SS)
    d.text((CX + 20 * SS, y1 + 20 * SS), big, font=f(FONT_BD, 62), fill=col)
    d.text((CX + 224 * SS, y1 + 26 * SS), sub1,
           font=f(FONT_RG, 16), fill=(210, 235, 246))
    d.text((CX + 224 * SS, y1 + 56 * SS), sub2,
           font=f(FONT_RG, 16), fill=(160, 200, 222))
    tw = d.textbbox((0, 0), tag, font=f(FONT_RG, 14))[2] - d.textbbox((0, 0), tag, font=f(FONT_RG, 14))[0]
    d.rounded_rectangle([CX + CW - tw - 34 * SS, y1 + 12 * SS,
                         CX + CW - 14 * SS, y1 + 40 * SS],
                        radius=12 * SS, fill=col)
    d.text((CX + CW - tw - 24 * SS, y1 + 16 * SS), tag,
           font=f(FONT_RG, 14), fill=(10, 30, 48))


card(238, 106, "800×", "验收余量", "0.00124 ms < 1 ms/帧", GREEN, "达标")
card(380, 112, "39×", "读回代价", "52 μs vs 1.35 μs/帧", RED, "陷阱")
d.text((CX + 12 * SS, 356 * SS), "前提：system 完整放在 C 内，数据不外流",
       font=f(FONT_RG, 16), fill=(190, 220, 238))

# ---------- 底部：设计规则 pills ----------
d.line([(X, 498 * SS), (X + 1016 * SS, 498 * SS)], fill=(70, 150, 190), width=2 * SS)
pills = [
    ("system 完整放在 C 内", GREEN),
    ("只回传广播增量", GREEN),
    ("不要逐实体读回 Lua", RED),
]
px = X
py = 512 * SS
pf = f(FONT_RG, 18)
for text, col in pills:
    bb = d.textbbox((0, 0), text, font=pf)
    pw = bb[2] - bb[0] + 46 * SS
    ph = 44 * SS
    d.rounded_rectangle([px, py, px + pw, py + ph], radius=ph / 2,
                        fill=(16, 58, 88), outline=col, width=2 * SS)
    d.ellipse([px + 14 * SS, py + 16 * SS, px + 26 * SS, py + 28 * SS], fill=col)
    d.text((px + 34 * SS, py + 9 * SS), text, font=pf, fill=col)
    px += pw + 16 * SS

# ---------- 数据说明 ----------
note = f(FONT_RG, 15)
d.text((X, 572 * SS), "数据说明：WSL Ubuntu 历史实测；读回倍数本轮复测约 24×，-O2 与 -O3 实测一致。",
       font=note, fill=(165, 200, 222))
d.text((X, 596 * SS), "绝对值随 CPU / 编译器 / 环境波动，量级与结论稳定，以 ch6_ecs/log/ 当次日志为准。",
       font=note, fill=(165, 200, 222))
d.text((w - 240 * SS, h - 42 * SS), "@ robinicon",
       font=f(FONT_MONO, 17), fill=(120, 160, 190))

# ---------- 缩小输出 ----------
img = img.resize((W, H), Image.LANCZOS)
out_dir = "C:/workspaces/bookskynet/csdn_cover"
png = out_dir + "/csdn_illust_03_ecs_boundary.png"
jpg = out_dir + "/csdn_illust_03_ecs_boundary.jpg"
img.save(png)
img.save(jpg, quality=94)
print("saved:", png, img.size)
print("saved:", jpg)
