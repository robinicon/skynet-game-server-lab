# -*- coding: utf-8 -*-
"""第 04 篇 CSDN 双插图：并发存盘丢失更新（对照实验 + 补偿机制）
科技蓝渐变 + 节点/代码水印，本地 PIL 2 倍超采样保证中文清晰。
所有数字取自 docs/blog/04-ch7-db-并发存盘安全.md，不新增无依据数据。
生成两张：
  _a_lost_update.png  —— 交错窗口 + 双向对照结果
  _b_coalescing.png   —— 写合并 + 三条安全规则 + 按 uid 串行化
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


def make_bg(seed):
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

    overlay = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    ov = ImageDraw.Draw(overlay)
    random.seed(seed)
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
    return Image.alpha_composite(img.convert("RGBA"), overlay).convert("RGB")


def header(d, chapter, kicker, title, subtitle):
    X = 92 * SS
    d.text((X, 36 * SS), chapter, font=f(FONT_BD, 20), fill=(120, 225, 240))
    d.text((X, 72 * SS), title, font=f(FONT_BD, 48), fill=(245, 252, 255))
    d.text((X + 3 * SS, 140 * SS), subtitle, font=f(FONT_RG, 27), fill=(135, 220, 245))
    d.line([(X, 194 * SS), (X + 1016 * SS, 194 * SS)], fill=(70, 150, 190), width=2 * SS)


def watermark_codes(d, codes):
    mono = f(FONT_MONO, 25)
    for s, px, py in codes:
        d.text((w * px, h * py), s, font=mono, fill=(150, 215, 245, 26))


GREEN = (66, 212, 172)
RED = (236, 104, 96)
AMBER = (240, 180, 90)
BLUE = (120, 205, 240)
PALE = (205, 230, 242)


# ============================================================
# 插图 A：交错窗口 + 双向对照
# ============================================================
def build_a():
    img = make_bg(seed=7)
    d = ImageDraw.Draw(img)
    header(d,
           "技 术 实 战  ·  第 7 章  CONCURRENT SAVE",
           "",
           "20 次存盘，只生效 1 次",
           "一次并发存盘的真实对照实验")

    X = 92 * SS

    # ---- 上半：交错窗口时序 ----
    d.text((X, 208 * SS), "丢失更新：两个协程在 yield 窗口交错",
           font=f(FONT_BD, 21), fill=(235, 248, 255))

    col_a = X
    col_b = X + 560 * SS
    d.text((col_a, 240 * SS), "协程 A", font=f(FONT_BD, 18), fill=BLUE)
    d.text((col_b, 240 * SS), "协程 B", font=f(FONT_BD, 18), fill=AMBER)

    # 行号 0..3；A 占 0,1,2；B 占 1,2,3 —— B 的 load 正好落在 A 的 yield 行
    sy, step_gap, box_h = 266, 36, 28
    a_steps = {
        0: ("load → hp=10", BLUE),
        1: ("yield  ← 网络往返", (150, 200, 225)),
        2: ("save hp=11", BLUE),
    }
    b_steps = {
        1: ("load → hp=10", AMBER),      # 与 A 的 yield 同刻：读到旧值
        2: ("yield  ← 网络往返", (150, 200, 225)),
        3: ("save hp=11", AMBER),
    }
    for row, (txt, col) in a_steps.items():
        y = (sy + row * step_gap) * SS
        d.rounded_rectangle([col_a, y, col_a + 470 * SS, y + box_h * SS],
                            radius=8 * SS, fill=(14, 48, 74), outline=col, width=2 * SS)
        d.text((col_a + 16 * SS, y + 4 * SS), txt, font=f(FONT_RG, 18), fill=col)
    for row, (txt, col) in b_steps.items():
        y = (sy + row * step_gap) * SS
        d.rounded_rectangle([col_b, y, col_b + 470 * SS, y + box_h * SS],
                            radius=8 * SS, fill=(14, 48, 74), outline=col, width=2 * SS)
        d.text((col_b + 16 * SS, y + 4 * SS), txt, font=f(FONT_RG, 18), fill=col)

    d.text((X, 414 * SS), "B 读到与 A 相同的旧值 10 → 两次 +1 只落了一次",
           font=f(FONT_RG, 18), fill=(200, 225, 238))

    # ---- 下半：双向对照结果卡片 ----
    d.line([(X, 444 * SS), (X + 1016 * SS, 444 * SS)], fill=(70, 150, 190), width=2 * SS)
    d.text((X, 456 * SS), "双向对照：20 次并发 hp = hp + 1",
           font=f(FONT_BD, 20), fill=(235, 248, 255))

    def result_card(px, py, pw, ph, title, hp, time, ok, col):
        d.rounded_rectangle([px, py, px + pw, py + ph], radius=12 * SS,
                            fill=(12, 44, 70), outline=col, width=2 * SS)
        d.text((px + 20 * SS, py + 14 * SS), title,
               font=f(FONT_BD, 20), fill=col)
        d.text((px + 20 * SS, py + 50 * SS), hp,
               font=f(FONT_BD, 32), fill=(245, 252, 255))
        d.text((px + 20 * SS, py + 92 * SS), time,
               font=f(FONT_RG, 18), fill=(190, 220, 238))
        badge = "PASS" if ok else "FAIL"
        bw = 96 * SS
        d.rounded_rectangle([px + pw - bw - 18 * SS, py + 16 * SS,
                             px + pw - 18 * SS, py + 46 * SS],
                            radius=12 * SS, fill=col)
        d.text((px + pw - bw - 4 * SS, py + 20 * SS), badge,
               font=f(FONT_BD, 18), fill=(10, 30, 48))

    cy = 490 * SS
    ch = 118 * SS
    result_card(X, cy, 470 * SS, ch, "无 queue · 丢失更新",
                "hp = 1 ~ 2  ·  丢失更新", "memory ~22 ms  ·  MySQL ~346 ms", False, RED)
    result_card(X + 500 * SS, cy, 470 * SS, ch, "有 queue · 串行化正确",
                "hp = 20  ·  全部正确", "memory ~30 ms（约14×） · MySQL ~400 ms", True, GREEN)

    # 底部说明（数据边界声明）
    d.text((X, 622 * SS),
           "数据说明：两套驱动口径——memory（注入 yield）与真实 MySQL 8.4；耗时为实测记录，以 ch7_db/log/ 当次日志为准。",
           font=f(FONT_RG, 14), fill=(165, 200, 222))
    d.text((X, 644 * SS),
           "真实 MySQL 下“无 queue”并不比“有 queue”快多少（346 vs 400 ms）—— 性能倍数取决于 I/O 基线。",
           font=f(FONT_RG, 14), fill=(165, 200, 222))
    d.text((w - 240 * SS, h - 34 * SS), "@ robinicon",
           font=f(FONT_MONO, 17), fill=(120, 160, 190))

    return img


# ============================================================
# 插图 B：写合并 + 三条安全规则 + 按 uid 串行化
# ============================================================
def build_b():
    img = make_bg(seed=9)
    d = ImageDraw.Draw(img)
    header(d,
           "技 术 实 战  ·  第 7 章  WRITE COALESCING",
           "",
           "100 次存盘，合并成 1 次",
           "串行化有延迟代价，用写合并把代价赚回来")

    X = 92 * SS

    # ---- 上半：写合并流程 ----
    d.text((X, 210 * SS), "覆盖式写入：中间状态没有意义，只留最后一次",
           font=f(FONT_BD, 20), fill=(235, 248, 255))

    # 输入箭头链：save_async(hp=1..100)
    d.text((X, 248 * SS), "save_async:", font=f(FONT_BD, 18), fill=BLUE)
    chips = ["hp=1", "hp=2", "…", "hp=99", "hp=100"]
    cx = X + 170 * SS
    cf = f(FONT_MONO, 16)
    for c in chips:
        bb = d.textbbox((0, 0), c, font=cf)
        cw = bb[2] - bb[0] + 26 * SS
        d.rounded_rectangle([cx, 244 * SS, cx + cw, 278 * SS], radius=12 * SS,
                            fill=(16, 58, 88), outline=(70, 175, 210), width=2 * SS)
        d.text((cx + 13 * SS, 250 * SS), c, font=cf, fill=(205, 240, 252))
        cx += cw + 12 * SS

    # 合并汇聚箭头（向下）
    ax = X + 470 * SS
    d.line([(ax, 282 * SS), (ax, 310 * SS)], fill=GREEN, width=3 * SS)
    d.polygon([(ax - 8 * SS, 304 * SS), (ax + 8 * SS, 304 * SS), (ax, 314 * SS)], fill=GREEN)
    d.text((ax + 18 * SS, 292 * SS), "合并 99 次", font=f(FONT_BD, 18), fill=GREEN)

    # 结果：一次落盘
    d.rounded_rectangle([X + 300 * SS, 326 * SS, X + 640 * SS, 386 * SS],
                        radius=12 * SS, fill=(12, 52, 44), outline=GREEN, width=2 * SS)
    d.text((X + 320 * SS, 338 * SS), "1 次实际落盘  (−99% 写次数)",
           font=f(FONT_BD, 22), fill=GREEN)

    # C3 校验：999
    d.rounded_rectangle([X + 670 * SS, 326 * SS, X + 1010 * SS, 386 * SS],
                        radius=12 * SS, fill=(14, 48, 74), outline=BLUE, width=2 * SS)
    d.text((X + 688 * SS, 332 * SS), "C3 校验", font=f(FONT_BD, 18), fill=BLUE)
    d.text((X + 688 * SS, 358 * SS), "async hp=1..10 + sync hp=999 → 999",
           font=f(FONT_RG, 16), fill=(200, 230, 244))

    # ---- 中部：三条安全规则 ----
    d.line([(X, 404 * SS), (X + 1016 * SS, 404 * SS)], fill=(70, 150, 190), width=2 * SS)
    d.text((X, 416 * SS), "三条安全规则（合并不能破坏顺序）",
           font=f(FONT_BD, 20), fill=(235, 248, 255))

    rules = [
        "1  save_sync 接管 pending：合并未落盘数据一起写，并清空",
        "2  flush 发现 pending 为空则跳过，避免写回已覆盖的旧值",
        "3  flush 与 save_sync 共用同一条 serial(uid) 队列",
    ]
    ry = 452
    for i, r in enumerate(rules):
        d.text((X + 4 * SS, (ry + i * 32) * SS), r,
               font=f(FONT_RG, 18), fill=PALE)

    # ---- 底部：按 uid 串行化 ----
    d.line([(X, 556 * SS), (X + 1016 * SS, 556 * SS)], fill=(70, 150, 190), width=2 * SS)
    d.rounded_rectangle([X, 566 * SS, X + 1010 * SS, 634 * SS], radius=12 * SS,
                        fill=(12, 44, 70), outline=(70, 175, 210), width=2 * SS)
    d.text((X + 20 * SS, 574 * SS), "按 uid 建队列，不是全局锁",
           font=f(FONT_BD, 20), fill=(235, 248, 255))
    d.text((X + 20 * SS, 598 * SS),
           "某 uid 慢操作 300 ms 时，另一 uid 的 load：memory 8.54 ms / MySQL 2.0~2.1 ms —— 完全并行",
           font=f(FONT_RG, 16), fill=(190, 220, 238))

    d.text((X, 643 * SS),
           "注意：读-改-写（如 incr_hp）不能合并；合并只适用于覆盖式写入。",
           font=f(FONT_RG, 15), fill=(165, 200, 222))
    d.text((w - 240 * SS, h - 32 * SS), "@ robinicon",
           font=f(FONT_MONO, 17), fill=(120, 160, 190))

    return img


# ============================================================
# 插图 C：真实 MySQL 复测（补齐 memory-only 短板）
# ============================================================
def build_c():
    img = make_bg(seed=13)
    d = ImageDraw.Draw(img)
    header(d,
           "技 术 实 战  ·  第 7 章  MYSQL VERIFIED",
           "",
           "真实 MySQL 复测：补齐短板",
           "mock 只能验证逻辑，真实驱动才能验证 SQL 语义")

    X = 92 * SS

    # ---- 上半：环境 + 认证坑 ----
    d.text((X, 208 * SS), "环境：WSL Ubuntu / MySQL 8.4.13 / CH7_DB_DRIVER=mysql",
           font=f(FONT_BD, 20), fill=(235, 248, 255))

    # 认证坑卡片（红）
    d.rounded_rectangle([X, 242 * SS, X + 1010 * SS, 304 * SS], radius=12 * SS,
                        fill=(52, 26, 32), outline=RED, width=2 * SS)
    d.text((X + 20 * SS, 250 * SS), "认证坑  errno:1251",
           font=f(FONT_BD, 19), fill=RED)
    d.text((X + 20 * SS, 276 * SS),
           "skynet 纯 Lua 驱动走 sha1 握手，不支持默认 caching_sha2_password",
           font=f(FONT_RG, 16), fill=(240, 210, 210))

    # 解决卡片（绿）
    d.rounded_rectangle([X, 314 * SS, X + 1010 * SS, 376 * SS], radius=12 * SS,
                        fill=(12, 52, 44), outline=GREEN, width=2 * SS)
    d.text((X + 20 * SS, 322 * SS), "解法：专用账号 + mysql_native_password",
           font=f(FONT_BD, 19), fill=GREEN)
    d.text((X + 20 * SS, 348 * SS),
           "mysqld.cnf 加 mysql_native_password=ON 后重启；不动现有业务账号",
           font=f(FONT_RG, 16), fill=(205, 240, 230))

    # ---- 中部：双驱动结果表 ----
    d.line([(X, 392 * SS), (X + 1016 * SS, 392 * SS)], fill=(70, 150, 190), width=2 * SS)
    d.text((X, 402 * SS), "双驱动实测对照（均 37 PASS / 反向对照 13P1F）",
           font=f(FONT_BD, 19), fill=(235, 248, 255))

    # 表头
    ty = 430
    col1, col2, col3 = X, X + 400 * SS, X + 700 * SS
    d.text((col1, ty * SS), "项目", font=f(FONT_BD, 17), fill=BLUE)
    d.text((col2, ty * SS), "memory 驱动", font=f(FONT_BD, 17), fill=BLUE)
    d.text((col3, ty * SS), "真实 MySQL 8.4", font=f(FONT_BD, 17), fill=BLUE)
    d.line([(X, (ty + 26) * SS), (X + 1010 * SS, (ty + 26) * SS)],
           fill=(70, 150, 190), width=1 * SS)

    rows = [
        ("有 queue（20 次 incr_hp）", "~30 ms", "396~473 ms"),
        ("无 queue（反向对照）", "hp=1，~22 ms", "hp=1~2，~346 ms"),
        ("慢 uid 隔离（C5）", "8.54 ms", "2.00~2.13 ms"),
        ("写合并（C7）", "100 → 1 落盘", "100 → 1 落盘"),
    ]
    for i, (a, b, c) in enumerate(rows):
        ry = (ty + 34 + i * 30) * SS
        d.text((col1, ry), a, font=f(FONT_RG, 17), fill=PALE)
        d.text((col2, ry), b, font=f(FONT_RG, 17), fill=(190, 220, 238))
        d.text((col3, ry), c, font=f(FONT_RG, 17), fill=GREEN)

    # ---- 底部：真实驱动暴露的 bug ----
    d.line([(X, 578 * SS), (X + 1016 * SS, 578 * SS)], fill=(70, 150, 190), width=2 * SS)
    d.text((X, 588 * SS), "真实驱动暴露、而 mock 掩盖的 bug",
           font=f(FONT_BD, 19), fill=(235, 248, 255))
    d.text((X, 616 * SS),
           "D3.2 部分更新：mysql 原写法把未提供的 gold 抹成 0，memory 逐字段合并却一直绿",
           font=f(FONT_RG, 16), fill=(240, 210, 210))
    d.text((X, 640 * SS),
           "修复：hp/gold = COALESCE(新值, 旧列) —— 新值为 NULL 时保留原列，双驱动 37 用例全绿",
           font=f(FONT_RG, 16), fill=(195, 235, 220))

    d.text((w - 240 * SS, h - 30 * SS), "@ robinicon",
           font=f(FONT_MONO, 16), fill=(120, 160, 190))
    return img


out_dir = "C:/workspaces/bookskynet/csdn_cover"
for name, img in [
    ("csdn_illust_04a_lost_update", build_a()),
    ("csdn_illust_04b_coalescing", build_b()),
    ("csdn_illust_04c_mysql_verified", build_c()),
]:
    im = img.resize((W, H), Image.LANCZOS)
    im.save(out_dir + "/" + name + ".png")
    im.save(out_dir + "/" + name + ".jpg", quality=94)
    print("saved:", name, im.size)
