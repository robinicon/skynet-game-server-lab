# -*- coding: utf-8 -*-
"""CSDN 封面：第 05 篇（ch8_components）组件式 Agent
科技蓝渐变 + 中心-卫星依赖图 + 对照数据卡，2 倍超采样保证中文清晰。
标题、概念与数字取自 docs/blog/05-ch8-components-组件式Agent.md，不新增无依据数据。
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


# ---------- 背景：对角渐变 + 双色光晕（与 01-04 同族） ----------
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

# ---------- 右侧中心-卫星依赖图 ----------
# 中心 = Agent Core，三个卫星 = bag / skill / quest；卫星之间不连线。
cx, cy = int(w * 0.88), int(h * 0.30)
satellites = [
    (int(w * 0.960), int(h * 0.10), "bag", (120, 225, 255)),
    (int(w * 0.970), int(h * 0.44), "skill", (120, 225, 255)),
    (int(w * 0.830), int(h * 0.48), "quest", (120, 225, 255)),
]
for sx, sy, _, _ in satellites:
    ov.line([(cx, cy), (sx, sy)], fill=(90, 200, 235, 105), width=2 * SS)
    # 消息路由上的小包点
    for q in (0.35, 0.68):
        px = cx + (sx - cx) * q
        py = cy + (sy - cy) * q
        ov.ellipse([px - 3 * SS, py - 3 * SS, px + 3 * SS, py + 3 * SS],
                   fill=(180, 240, 255, 170))

ov.ellipse([cx - 34 * SS, cy - 34 * SS, cx + 34 * SS, cy + 34 * SS],
           fill=(16, 78, 108, 220), outline=(110, 230, 250, 235), width=3 * SS)
ov.ellipse([cx - 52 * SS, cy - 52 * SS, cx + 52 * SS, cy + 52 * SS],
           outline=(90, 200, 235, 45), width=2 * SS)
cf = f(FONT_BD, 18)
bb = ov.textbbox((0, 0), "CORE", font=cf)
ov.text((cx - (bb[2] - bb[0]) / 2, cy - 12 * SS), "CORE", font=cf,
        fill=(220, 250, 255, 255))

sf = f(FONT_MONO, 19)
for sx, sy, name, col in satellites:
    ov.ellipse([sx - 22 * SS, sy - 22 * SS, sx + 22 * SS, sy + 22 * SS],
               fill=(12, 52, 80, 225), outline=col, width=2 * SS)
    bb = ov.textbbox((0, 0), name, font=sf)
    ov.text((sx - (bb[2] - bb[0]) / 2, sy - 11 * SS), name, font=sf,
            fill=(190, 235, 252, 255))

# 卫星之间画一条极淡的断开虚线，明示"不互相 require"
p1 = satellites[2]  # quest
p2 = satellites[1]  # skill
for i in range(9):
    q = (i + 0.5) / 9
    px = p1[0] + (p2[0] - p1[0]) * q
    py = p1[1] + (p2[1] - p1[1]) * q
    ov.ellipse([px - 2 * SS, py - 2 * SS, px + 2 * SS, py + 2 * SS],
               fill=(120, 160, 185, 60))
mx = (p1[0] + p2[0]) / 2
my = (p1[1] + p2[1]) / 2
ov.line([(mx - 12 * SS, my - 12 * SS), (mx + 12 * SS, my + 12 * SS)],
        fill=(235, 120, 110, 150), width=3 * SS)
ov.line([(mx - 12 * SS, my + 12 * SS), (mx + 12 * SS, my - 12 * SS)],
        fill=(235, 120, 110, 150), width=3 * SS)

# ---------- 半透明代码水印 ----------
mono = f(FONT_MONO, 29)
codes = [
    ("core:dispatch()", 0.60, 0.06),
    ("init(ctx)", 0.72, 0.24),
    ("shutdown()", 0.60, 0.02),
    ("inject()", 0.58, 0.52),
    ("pcall()", 0.88, 0.60),
    ("require? NO", 0.64, 0.95),
]
for s, px, py in codes:
    ov.text((w * px, h * py), s, font=mono, fill=(150, 215, 245, 34))

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
draw.text((X, 46 * SS), "[ SKYNET 手记 ]   ·   第 8 章  组件式编程",
          font=f(FONT_BD, 23), fill=(120, 225, 240))
# 主标题
draw.text((X, 100 * SS), "组件化的价值不在拆文件", font=f(FONT_BD, 66),
          fill=(245, 252, 255))
# 副标题
draw.text((X + 3 * SS, 196 * SS), "不是拆文件，是控制依赖方向",
          font=f(FONT_RG, 32), fill=(135, 220, 245))
# 技术行
draw.text((X + 3 * SS, 248 * SS),
          "DEPENDENCY DIRECTION  /  NO MUTUAL REQUIRE  /  RUNTIME INJECT  /  REVERSE SHUTDOWN",
          font=f(FONT_MONO, 14), fill=(150, 190, 215))

draw.line([(X, 292 * SS), (X + 936 * SS, 292 * SS)], fill=(70, 150, 190), width=2 * SS)

# ---------- 对照数据卡 ----------
def data_card(px, py, pw, ph, tag, big, detail, col):
    draw.rounded_rectangle([px, py, px + pw, py + ph], radius=12 * SS,
                           fill=(12, 44, 70), outline=col, width=2 * SS)
    draw.text((px + 18 * SS, py + 12 * SS), tag, font=f(FONT_BD, 18), fill=col)
    draw.text((px + 18 * SS, py + 38 * SS), big, font=f(FONT_BD, 28),
              fill=(245, 252, 255))
    draw.text((px + 18 * SS, py + 74 * SS), detail, font=f(FONT_RG, 16),
              fill=(185, 218, 236))


card_y, card_h = 306 * SS, 104 * SS
data_card(X, card_y, 452 * SS, card_h, "朴素写法  ·  组件互相 require",
          "quest 直接改 self.bag", "依赖纠缠，拆不动、热更不了", RED)
data_card(X + 484 * SS, card_y, 452 * SS, card_h, "约定后  ·  只走消息路由",
          "core:dispatch(\"bag.add\")", "30 断言 · 回滚 / 逆序销毁 / 异常隔离", GREEN)

# 底部标签
pills = ["Skynet", "Lua", "组件式 Agent", "依赖方向", "运行时注入", "30 用例"]
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
img.save(out_dir + "/csdn_cover_05.png")
img.save(out_dir + "/csdn_cover_05.jpg", quality=94)
print("saved:", out_dir + "/csdn_cover_05.png", img.size)
