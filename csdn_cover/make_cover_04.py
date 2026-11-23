# -*- coding: utf-8 -*-
"""CSDN 封面：第 04 篇（ch7_db）并发存盘对照实验
科技蓝渐变 + 节点/代码水印 + 双驱动数据卡，2 倍超采样保证中文清晰。
标题与数字取自 docs/blog/04-ch7-db-并发存盘安全.md，不新增无依据数据。
输出 1200x512，PNG/JPEG 双格式。
"""
import math
import random
import numpy as np
from PIL import Image, ImageDraw, ImageFont

SS = 2
W, H = 1200, 512
w, h = W * SS, H * SS

FONT_BD = "C:/Windows/Fonts/msyhbd.ttc"
FONT_RG = "C:/Windows/Fonts/msyh.ttc"
FONT_MONO = "C:/Windows/Fonts/consola.ttf"


def f(path, size):
    return ImageFont.truetype(path, int(size * SS))


# ---------- 背景：对角渐变 + 双色光晕 ----------
yy, xx = np.mgrid[0:h, 0:w]
nx, ny = xx / w, yy / h
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

overlay = Image.new("RGBA", (w, h), (0, 0, 0, 0))
ov = ImageDraw.Draw(overlay)

# ---------- 右侧节点网络（并发协程交错概念） ----------
random.seed(7)
nodes = []
for _ in range(20):
    x = random.uniform(w * 0.52, w * 0.97)
    y = random.uniform(h * 0.05, h * 0.95)
    nodes.append((x, y))
for i, (x1, y1) in enumerate(nodes):
    for x2, y2 in nodes[i + 1:]:
        dist = math.hypot(x2 - x1, y2 - y1)
        if dist < 200 * SS:
            alpha = int(66 * (1 - dist / (200 * SS)))
            ov.line([(x1, y1), (x2, y2)], fill=(90, 200, 235, alpha), width=1 * SS)
for (x, y) in nodes:
    r = random.uniform(2.5, 5.0) * SS
    ov.ellipse([x - r, y - r, x + r, y + r], fill=(120, 225, 255, 160))
    ov.ellipse([x - r * 2.5, y - r * 2.5, x + r * 2.5, y + r * 2.5],
               outline=(90, 200, 235, 40), width=1 * SS)

# ---------- 半透明代码水印 ----------
mono = f(FONT_MONO, 30)
codes = [
    ("load_role(uid)", 0.60, 0.10),
    ("skynet.queue()", 0.70, 0.28),
    ("yield", 0.94, 0.40),
    ("save_async", 0.58, 0.60),
    ("COALESCE()", 0.86, 0.80),
    ("serial(uid)", 0.64, 0.92),
]
for s, px, py in codes:
    ov.text((w * px, h * py), s, font=mono, fill=(150, 215, 245, 36))

# ---------- 左侧竖向高亮条 ----------
ov.rounded_rectangle([118 * SS, 232 * SS, 130 * SS, 716 * SS],
                     radius=6 * SS, fill=(60, 220, 235, 230))
ov.rounded_rectangle([112 * SS, 226 * SS, 136 * SS, 722 * SS],
                     radius=8 * SS, fill=(60, 220, 235, 40))

img = Image.alpha_composite(img.convert("RGBA"), overlay).convert("RGB")
draw = ImageDraw.Draw(img)

X = 200 * SS
RED = (236, 104, 96)
GREEN = (66, 212, 172)

# kicker
draw.text((X, 46 * SS), "[ SKYNET 手记 ]   ·   第 7 章  数据库与并发安全",
          font=f(FONT_BD, 23), fill=(120, 225, 240))
# 主标题
draw.text((X, 100 * SS), "20 次存盘丢了 19 次", font=f(FONT_BD, 70),
          fill=(245, 252, 255))
# 副标题
draw.text((X + 3 * SS, 196 * SS), "一次并发存盘的真实对照实验",
          font=f(FONT_RG, 32), fill=(135, 220, 245))
# 技术行
draw.text((X + 3 * SS, 248 * SS),
          "LOST UPDATE  /  skynet.queue  /  WRITE COALESCING  /  MYSQL 8.4",
          font=f(FONT_MONO, 17), fill=(150, 190, 215))

draw.line([(X, 292 * SS), (X + 936 * SS, 292 * SS)], fill=(70, 150, 190), width=2 * SS)

# ---------- 双驱动数据卡 ----------
def data_card(px, py, pw, ph, tag, big, detail, col):
    draw.rounded_rectangle([px, py, px + pw, py + ph], radius=12 * SS,
                           fill=(12, 44, 70), outline=col, width=2 * SS)
    draw.text((px + 18 * SS, py + 12 * SS), tag, font=f(FONT_BD, 18), fill=col)
    draw.text((px + 18 * SS, py + 38 * SS), big, font=f(FONT_BD, 30),
              fill=(245, 252, 255))
    draw.text((px + 18 * SS, py + 74 * SS), detail, font=f(FONT_RG, 16),
              fill=(185, 218, 236))

card_y, card_h = 306 * SS, 104 * SS
data_card(X, card_y, 452 * SS, card_h, "无 queue  ·  丢失更新",
          "hp = 1   （20 次只落 1 次）", "memory ~22ms / MySQL ~346ms", RED)
data_card(X + 484 * SS, card_y, 452 * SS, card_h, "有 queue  ·  串行化正确",
          "hp = 20  （全部正确）", "memory ~30ms / MySQL ~400ms", GREEN)

# 底部标签
pills = ["Skynet", "Lua", "并发安全", "MySQL 8.4", "写合并", "双向对照"]
pf = f(FONT_RG, 17)
px = X
for p in pills:
    bb = draw.textbbox((0, 0), p, font=pf)
    tw = bb[2] - bb[0]
    pw = tw + 28 * SS
    ph = 38 * SS
    py = 428 * SS
    draw.rounded_rectangle([px, py, px + pw, py + ph], radius=ph / 2,
                           outline=(70, 175, 210), width=2 * SS,
                           fill=(20, 70, 100, 255))
    draw.text((px + 14 * SS, py + 7 * SS), p, font=pf, fill=(205, 240, 252))
    px += pw + 14 * SS

draw.text((w - 250 * SS, h - 44 * SS), "@ robinicon", font=f(FONT_MONO, 17),
          fill=(120, 160, 190))

img = img.resize((W, H), Image.LANCZOS)
out_dir = "C:/workspaces/bookskynet/csdn_cover"
img.save(out_dir + "/csdn_cover_04.png")
img.save(out_dir + "/csdn_cover_04.jpg", quality=94)
print("saved:", out_dir + "/csdn_cover_04.png", img.size)
