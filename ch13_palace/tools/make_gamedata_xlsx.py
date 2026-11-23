#!/usr/bin/env python3
"""Generate conf/gamedata.xlsx — the game-content workbook (Excel source of truth).

Usage (from ch13_palace):
    python3 tools/make_gamedata_xlsx.py --force   # refuse to overwrite without --force
    python3 tools/make_gamedata_xlsx.py --stdout  # preview sheets without writing

Design notes
------------
`conf/schema.xlsx` describes *abstract carriers* (fid meaning, op routing).
This workbook describes *game content*: hero templates, exp curve, advance cost,
item definitions, mission rewards. Field values in the database stay meaningless
until these tables give them meaning — same thesis, second workbook.

Values are taken from the original Java server's data shape (HeroExpData /
SurmountData / WeekData / ItemData / MissionData), reduced to the subset the
migrated actions actually read. Numbers are authored demo content, not a dump of
the original 284 generated tables; each batch's reconciliation sample records
which rule each expectation descends from.
"""

import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import xlsx

ROOT = pathlib.Path(__file__).resolve().parents[1]
TARGET = ROOT / "conf" / "gamedata.xlsx"

HERO_MAX_LV = 80   # hero_exp sheet covers 1..79 transitions


def hero_rows():
    return [
        ["templateId", "name", "quality", "maxLv"],
        [2001, "关羽", 3, 60],
        [2002, "张飞", 3, 60],
        [2003, "赵云", 4, 80],
        [2004, "黄忠", 2, 60],
    ]


def hero_exp_rows():
    """exp needed to step lv -> lv+1: 100 + (lv-1)*50 (documented curve, not dumped)."""
    rows = [["lv", "exp"]]
    for lv in range(1, HERO_MAX_LV):
        rows.append([lv, 100 + (lv - 1) * 50])
    return rows


def hero_surmount_rows():
    """advance (加官) gates: lvLimit reached at current advance, cost to next."""
    rows = [["templateId", "advanceLv", "lvLimit", "costItem", "costNum"]]
    for tpl in (2001, 2002, 2003, 2004):
        for adv, limit, num in ((0, 10, 5), (1, 20, 10), (2, 30, 20), (3, 40, 40)):
            rows.append([tpl, adv, limit, 3001, num])
    return rows


def hero_week_rows():
    """limit (进爵) gates: requires advance >= breakLvLimit, cost to next."""
    rows = [["templateId", "limitLv", "breakLvLimit", "costItem", "costNum"]]
    for tpl in (2001, 2002, 2003, 2004):
        for lv, req, num in ((0, 2, 2), (1, 3, 4), (2, 4, 8), (3, 5, 16)):
            rows.append([tpl, lv, req, 3002, num])
    return rows


def item_rows():
    return [
        ["templateId", "name", "kind", "value", "sellPrice", "stack"],
        [1001, "小还丹", "elixir", 100, 10, 999],
        [1002, "中还丹", "elixir", 500, 40, 999],
        [1003, "大还丹", "elixir", 2000, 150, 999],
        [3001, "官印", "material", 0, 0, 999],
        [3002, "爵位令", "material", 0, 0, 999],
        [9001, "金锭", "gold", 1000, 200, 999],
        [9002, "银锭", "silver", 500, 0, 999],
    ]


def mission_rows():
    return [
        ["missionId", "type", "target", "rewardItem", "rewardNum"],
        [5001, 1, 3, 9001, 1],
        [5002, 1, 5, 9002, 2],
        [5003, 2, 1, 1002, 3],
    ]


def stage_rows():
    """关卡表：10 关，逐关推进。needLevel=关号；needPower 供 fight 判定胜负。
    exp/gold 为确定性奖励；drop 为固定掉落。数值为 authored demo content，
    具体期望由 docs/samples/stage.json 的 derivation 逐条记录。"""
    rows = [["stageId", "needLevel", "needPower", "exp", "gold", "dropItem", "dropNum"]]
    for i in range(1, 11):
        drop_item = 1001 if i <= 5 else 1002
        drop_num = 1 + (i - 1) // 3
        rows.append([i, i, (i - 1) * 10, 80 + i * 20, 40 + i * 10, drop_item, drop_num])
    return rows


def shop_rows():
    """商店货品：currency ∈ {gold, silver}；limit=0 表示不限购。"""
    return [
        ["goodsId", "itemId", "currency", "price", "limit"],
        [101, 1001, "gold", 100, 0],
        [102, 1002, "gold", 350, 5],
        [103, 3001, "silver", 200, 0],
    ]


def sign_rows():
    """签到 7 天奖励，第 8 天循环回第 1 天。"""
    return [
        ["day", "itemId", "count"],
        [1, 9001, 1],
        [2, 1001, 2],
        [3, 9002, 2],
        [4, 1002, 2],
        [5, 3001, 5],
        [6, 1003, 1],
        [7, 9001, 2],
    ]


def online_rows():
    """在线时长档位奖励（分钟）。"""
    return [
        ["minutes", "itemId", "count"],
        [30, 1001, 1],
        [60, 9001, 1],
        [120, 1002, 2],
    ]


def gacha_rows():
    """抽卡概率表：hero tpl + weight；rare=1 为稀有档（保底目标）。
    确定性 LCG seed=(draws*1103515245+12345)%2^31，具体期望见 samples/gacha.json。"""
    return [
        ["tpl", "weight", "rare"],
        [2001, 60, 0],
        [2002, 30, 0],
        [2003, 9, 0],
        [2004, 1, 1],
    ]


def home_rows():
    """家园主城建筑：level→升级花费与产出；产出在升级时结算旧等级。不做摆件/寻路。"""
    rows = [["level", "upgradeGold", "produceItem", "produceNum"]]
    for lv in range(1, 6):
        rows.append([lv, 100 * lv, 1001, lv])
    return rows


def errand_rows():
    """办差差事：id→奖励；派遣即完成（不做计时/加速），重复领取防护。"""
    return [
        ["id", "gold", "itemId", "itemNum"],
        [1, 50, 1001, 1],
        [2, 120, 3001, 2],
        [3, 300, 9001, 1],
    ]


def meta_rows():
    return [
        ["key", "value", "note"],
        ["version", 1, "game content workbook"],
        ["hero_max_lv", HERO_MAX_LV, "derived from hero_exp coverage"],
        ["gacha_cost", 100, "gold per draw (U6)"],
        ["gacha_pity", 10, "rare pity draw count (U6)"],
    ]


def build():
    return {
        "hero": hero_rows(),
        "hero_exp": hero_exp_rows(),
        "hero_surmount": hero_surmount_rows(),
        "hero_week": hero_week_rows(),
        "item": item_rows(),
        "mission": mission_rows(),
        "stage": stage_rows(),
        "shop": shop_rows(),
        "sign": sign_rows(),
        "online": online_rows(),
        "gacha": gacha_rows(),
        "home": home_rows(),
        "errand": errand_rows(),
        "meta": meta_rows(),
    }


def main(argv):
    force = "--force" in argv
    if TARGET.exists() and not force and "--stdout" not in argv:
        print("refusing to overwrite %s (use --force)" % TARGET)
        return 1
    sheets = build()
    if "--stdout" in argv:
        for name, rows in sheets.items():
            print("=== %s (%d rows) ===" % (name, len(rows) - 1))
            for row in rows[:4]:
                print("   ", row)
        return 0
    xlsx.write_book(TARGET, sheets)
    print("wrote %s: %s" % (TARGET, ", ".join("%s=%d" % (k, len(v) - 1) for k, v in sheets.items())))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
