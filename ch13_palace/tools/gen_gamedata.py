#!/usr/bin/env python3
"""Generate generated/gamedata_generated.lua from conf/gamedata.xlsx.

Usage (from ch13_palace):
    python3 tools/gen_gamedata.py           # write Lua + JSON mirror
    python3 tools/gen_gamedata.py --check   # verify everything is in sync (exit 1 if not)

Same discipline as gen_schema.py: Excel is the only source, output is
deterministic, and a readable JSON mirror is emitted for audit but never read
by the runtime.
"""

import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import xlsx

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = ROOT / "conf" / "gamedata.xlsx"
OUT_LUA = ROOT / "generated" / "gamedata_generated.lua"
MIRROR = ROOT / "conf" / "gamedata.json"

VALID_ITEM_KINDS = {"elixir", "material", "gold", "silver"}


def load_rows():
    if not SOURCE.exists():
        raise FileNotFoundError("source workbook missing: %s" % SOURCE)
    book = xlsx.read_book(SOURCE)
    return {
        name: xlsx.rows_to_dicts(book.get(name, []))
        for name in ("hero", "hero_exp", "hero_surmount", "hero_week", "item", "mission",
                     "stage", "shop", "sign", "online", "gacha", "home", "errand", "meta")
    }


def build_doc(rows):
    errors = []

    hero = {}
    for r in rows["hero"]:
        tpl = int(r["templateId"])
        maxLv = int(r["maxLv"])
        if tpl in hero:
            errors.append("duplicate hero templateId %d" % tpl)
        if maxLv <= 1:
            errors.append("hero %d maxLv must be > 1" % tpl)
        hero[tpl] = {"templateId": tpl, "name": r["name"], "quality": int(r["quality"]), "maxLv": maxLv}

    hero_exp = {}
    for r in rows["hero_exp"]:
        lv = int(r["lv"])
        exp = int(r["exp"])
        if lv in hero_exp:
            errors.append("duplicate hero_exp lv %d" % lv)
        if exp <= 0:
            errors.append("hero_exp lv %d exp must be > 0" % lv)
        hero_exp[lv] = exp
    if not hero_exp:
        errors.append("hero_exp sheet is empty")

    hero_max_lv = (max(hero_exp) + 1) if hero_exp else 0

    surmount = {}
    for r in rows["hero_surmount"]:
        tpl = int(r["templateId"])
        adv = int(r["advanceLv"])
        if tpl not in hero:
            errors.append("hero_surmount references unknown templateId %d" % tpl)
        surmount.setdefault(tpl, {})[adv] = {
            "lvLimit": int(r["lvLimit"]),
            "costItem": int(r["costItem"]),
            "costNum": int(r["costNum"]),
        }

    week = {}
    for r in rows["hero_week"]:
        tpl = int(r["templateId"])
        lv = int(r["limitLv"])
        if tpl not in hero:
            errors.append("hero_week references unknown templateId %d" % tpl)
        week.setdefault(tpl, {})[lv] = {
            "breakLvLimit": int(r["breakLvLimit"]),
            "costItem": int(r["costItem"]),
            "costNum": int(r["costNum"]),
        }

    item = {}
    for r in rows["item"]:
        tpl = int(r["templateId"])
        kind = r["kind"]
        if kind not in VALID_ITEM_KINDS:
            errors.append("item %d unknown kind %r" % (tpl, kind))
        if tpl in item:
            errors.append("duplicate item templateId %d" % tpl)
        item[tpl] = {
            "templateId": tpl, "name": r["name"], "kind": kind,
            "value": int(r["value"]), "sellPrice": int(r["sellPrice"]), "stack": int(r["stack"]),
        }

    mission = {}
    for r in rows["mission"]:
        mid = int(r["missionId"])
        if mid in mission:
            errors.append("duplicate missionId %d" % mid)
        mission[mid] = {
            "missionId": mid, "type": int(r["type"]), "target": int(r["target"]),
            "rewardItem": int(r["rewardItem"]), "rewardNum": int(r["rewardNum"]),
        }

    # stage（关卡）：10 关，逐关推进；奖励与掉落必须引用存在的道具
    stage = {}
    for r in rows["stage"]:
        sid = int(r["stageId"])
        if sid in stage:
            errors.append("duplicate stageId %d" % sid)
        stage[sid] = {
            "stageId": sid, "needLevel": int(r["needLevel"]), "needPower": int(r["needPower"]),
            "exp": int(r["exp"]), "gold": int(r["gold"]),
            "dropItem": int(r["dropItem"]), "dropNum": int(r["dropNum"]),
        }
    if not stage:
        errors.append("stage sheet is empty")
    for sid, s in stage.items():
        if s["dropNum"] > 0 and s["dropItem"] not in item:
            errors.append("stage %d dropItem %d not in item sheet" % (sid, s["dropItem"]))

    # shop（商店）：currency 必须 gold/silver；货品必须存在
    shop = {}
    for r in rows["shop"]:
        gid = int(r["goodsId"])
        if gid in shop:
            errors.append("duplicate goodsId %d" % gid)
        cur = r["currency"]
        if cur not in ("gold", "silver"):
            errors.append("shop %d unknown currency %r" % (gid, cur))
        shop[gid] = {
            "goodsId": gid, "itemId": int(r["itemId"]), "currency": cur,
            "price": int(r["price"]), "limit": int(r["limit"]),
        }
    for gid, g in shop.items():
        if g["itemId"] not in item:
            errors.append("shop %d itemId %d not in item sheet" % (gid, g["itemId"]))

    # sign（签到，7 天循环）
    sign = {}
    for r in rows["sign"]:
        day = int(r["day"])
        if day in sign:
            errors.append("duplicate sign day %d" % day)
        sign[day] = {"day": day, "itemId": int(r["itemId"]), "count": int(r["count"])}
    for day, s in sign.items():
        if s["itemId"] not in item:
            errors.append("sign day %d itemId %d not in item sheet" % (day, s["itemId"]))

    # online（在线时长档位）
    online = {}
    for r in rows["online"]:
        minutes = int(r["minutes"])
        if minutes in online:
            errors.append("duplicate online minutes %d" % minutes)
        online[minutes] = {"minutes": minutes, "itemId": int(r["itemId"]), "count": int(r["count"])}
    for minutes, o in online.items():
        if o["itemId"] not in item:
            errors.append("online %d itemId %d not in item sheet" % (minutes, o["itemId"]))

    # cost items referenced by gates must exist
    for tpl, table in surmount.items():
        for adv, gate in table.items():
            if gate["costItem"] not in item:
                errors.append("hero_surmount %d/%d costItem %d not in item sheet" % (tpl, adv, gate["costItem"]))
    for tpl, table in week.items():
        for lv, gate in table.items():
            if gate["costItem"] not in item:
                errors.append("hero_week %d/%d costItem %d not in item sheet" % (tpl, lv, gate["costItem"]))
    for mid, m in mission.items():
        if m["rewardItem"] not in item:
            errors.append("mission %d rewardItem %d not in item sheet" % (mid, m["rewardItem"]))

    # gacha（抽卡概率表，U6）
    gacha = {}
    for r in rows["gacha"]:
        tpl = int(r["tpl"])
        if tpl in gacha:
            errors.append("duplicate gacha tpl %d" % tpl)
        if tpl not in hero:
            errors.append("gacha tpl %d not in hero sheet" % tpl)
        gacha[tpl] = {"tpl": tpl, "weight": int(r["weight"]), "rare": int(r["rare"])}
    if not any(g["rare"] == 1 for g in gacha.values()):
        errors.append("gacha has no rare tier")

    # home（家园建筑，U6）
    home = {}
    for r in rows["home"]:
        lv = int(r["level"])
        if lv in home:
            errors.append("duplicate home level %d" % lv)
        if int(r["produceItem"]) not in item:
            errors.append("home level %d produceItem not in item sheet" % lv)
        home[lv] = {"level": lv, "upgradeGold": int(r["upgradeGold"]),
                    "produceItem": int(r["produceItem"]), "produceNum": int(r["produceNum"])}

    # errand（办差，U6）
    errand = {}
    for r in rows["errand"]:
        eid = int(r["id"])
        if eid in errand:
            errors.append("duplicate errand id %d" % eid)
        if int(r["itemId"]) not in item:
            errors.append("errand %d itemId not in item sheet" % eid)
        errand[eid] = {"id": eid, "gold": int(r["gold"]),
                       "itemId": int(r["itemId"]), "itemNum": int(r["itemNum"])}

    version = 1
    gacha_cost, gacha_pity = 100, 10
    for r in rows["meta"]:
        if r.get("key") == "version":
            version = int(r["value"])
        elif r.get("key") == "gacha_cost":
            gacha_cost = int(r["value"])
        elif r.get("key") == "gacha_pity":
            gacha_pity = int(r["value"])

    tiers = sorted(
        ({"templateId": i["templateId"], "value": i["value"]} for i in item.values() if i["kind"] == "elixir"),
        key=lambda x: x["value"],
    )

    return {
        "version": version,
        "hero": hero,
        "hero_exp": hero_exp,
        "hero_max_lv": hero_max_lv,
        "hero_surmount": surmount,
        "hero_week": week,
        "item": item,
        "mission": mission,
        "stage": stage,
        "shop": shop,
        "sign": sign,
        "online": online,
        "gacha": gacha,
        "home": home,
        "errand": errand,
        "gacha_cost": gacha_cost,
        "gacha_pity": gacha_pity,
        "elixir_tiers": tiers,
    }, errors


def lua_str(s):
    return '"%s"' % str(s).replace("\\", "\\\\").replace('"', '\\"')


def render(doc):
    out = []
    out.append("-- GENERATED FILE - do not edit. Source: conf/gamedata.xlsx")
    out.append("-- 游戏内容配置：英雄/经验曲线/加官/进爵/道具/任务。字段在库里只有 fid，语义来自这里。")
    out.append("local M = {}")
    out.append("M.version = %d" % doc["version"])

    out.append("M.hero = {")
    for tpl in sorted(doc["hero"]):
        h = doc["hero"][tpl]
        out.append('    [%d] = { templateId=%d, name=%s, quality=%d, maxLv=%d },'
                   % (tpl, h["templateId"], lua_str(h["name"]), h["quality"], h["maxLv"]))
    out.append("}")

    out.append("M.hero_exp = {")
    for lv in sorted(doc["hero_exp"]):
        out.append("    [%d] = %d," % (lv, doc["hero_exp"][lv]))
    out.append("}")
    out.append("M.hero_max_lv = %d" % doc["hero_max_lv"])

    out.append("M.hero_surmount = {")
    for tpl in sorted(doc["hero_surmount"]):
        out.append("    [%d] = {" % tpl)
        for adv in sorted(doc["hero_surmount"][tpl]):
            g = doc["hero_surmount"][tpl][adv]
            out.append("        [%d] = { lvLimit=%d, costItem=%d, costNum=%d },"
                       % (adv, g["lvLimit"], g["costItem"], g["costNum"]))
        out.append("    },")
    out.append("}")

    out.append("M.hero_week = {")
    for tpl in sorted(doc["hero_week"]):
        out.append("    [%d] = {" % tpl)
        for lv in sorted(doc["hero_week"][tpl]):
            g = doc["hero_week"][tpl][lv]
            out.append("        [%d] = { breakLvLimit=%d, costItem=%d, costNum=%d },"
                       % (lv, g["breakLvLimit"], g["costItem"], g["costNum"]))
        out.append("    },")
    out.append("}")

    out.append("M.item = {")
    for tpl in sorted(doc["item"]):
        i = doc["item"][tpl]
        out.append('    [%d] = { templateId=%d, name=%s, kind=%s, value=%d, sellPrice=%d, stack=%d },'
                   % (tpl, i["templateId"], lua_str(i["name"]), lua_str(i["kind"]),
                      i["value"], i["sellPrice"], i["stack"]))
    out.append("}")

    out.append("M.mission = {")
    for mid in sorted(doc["mission"]):
        m = doc["mission"][mid]
        out.append("    [%d] = { missionId=%d, type=%d, target=%d, rewardItem=%d, rewardNum=%d },"
                   % (mid, m["missionId"], m["type"], m["target"], m["rewardItem"], m["rewardNum"]))
    out.append("}")

    out.append("M.stage = {")
    for sid in sorted(doc["stage"]):
        s = doc["stage"][sid]
        out.append("    [%d] = { stageId=%d, needLevel=%d, needPower=%d, exp=%d, gold=%d, dropItem=%d, dropNum=%d },"
                   % (sid, s["stageId"], s["needLevel"], s["needPower"], s["exp"],
                      s["gold"], s["dropItem"], s["dropNum"]))
    out.append("}")

    out.append("M.shop = {")
    for gid in sorted(doc["shop"]):
        g = doc["shop"][gid]
        out.append('    [%d] = { goodsId=%d, itemId=%d, currency=%s, price=%d, limit=%d },'
                   % (gid, g["goodsId"], g["itemId"], lua_str(g["currency"]), g["price"], g["limit"]))
    out.append("}")

    out.append("M.sign = {")
    for day in sorted(doc["sign"]):
        s = doc["sign"][day]
        out.append("    [%d] = { day=%d, itemId=%d, count=%d },"
                   % (day, s["day"], s["itemId"], s["count"]))
    out.append("}")

    out.append("M.online = {")
    for minutes in sorted(doc["online"]):
        o = doc["online"][minutes]
        out.append("    [%d] = { minutes=%d, itemId=%d, count=%d },"
                   % (minutes, o["minutes"], o["itemId"], o["count"]))
    out.append("}")

    out.append("M.gacha_cost = %d" % doc["gacha_cost"])
    out.append("M.gacha_pity = %d" % doc["gacha_pity"])
    out.append("M.gacha = {")
    for tpl in sorted(doc["gacha"]):
        g = doc["gacha"][tpl]
        out.append("    [%d] = { tpl=%d, weight=%d, rare=%d }," % (tpl, g["tpl"], g["weight"], g["rare"]))
    out.append("}")

    out.append("M.home = {")
    for lv in sorted(doc["home"]):
        h = doc["home"][lv]
        out.append("    [%d] = { level=%d, upgradeGold=%d, produceItem=%d, produceNum=%d },"
                   % (lv, h["level"], h["upgradeGold"], h["produceItem"], h["produceNum"]))
    out.append("}")

    out.append("M.errand = {")
    for eid in sorted(doc["errand"]):
        e = doc["errand"][eid]
        out.append("    [%d] = { id=%d, gold=%d, itemId=%d, itemNum=%d },"
                   % (eid, e["id"], e["gold"], e["itemId"], e["itemNum"]))
    out.append("}")

    out.append("M.elixir_tiers = {")
    for t in doc["elixir_tiers"]:
        out.append("    { templateId=%d, value=%d }," % (t["templateId"], t["value"]))
    out.append("}")
    out.append("return M")
    return "\n".join(out) + "\n"


def render_mirror(doc):
    def conv(v):
        if isinstance(v, dict):
            return {str(k): conv(x) for k, x in v.items()}
        if isinstance(v, list):
            return [conv(x) for x in v]
        return v
    return json.dumps(conv(doc), ensure_ascii=False, indent=2, sort_keys=True) + "\n"


def main(argv):
    check = "--check" in argv
    rows = load_rows()
    doc, errors = build_doc(rows)
    if errors:
        for e in errors:
            print("gamedata error: " + e)
        return 1

    lua_text = render(doc)
    mirror_text = render_mirror(doc)

    counts = "hero=%d exp=%d surmount=%d week=%d item=%d mission=%d stage=%d shop=%d sign=%d online=%d gacha=%d home=%d errand=%d" % (
        len(doc["hero"]), len(doc["hero_exp"]), sum(len(v) for v in doc["hero_surmount"].values()),
        sum(len(v) for v in doc["hero_week"].values()), len(doc["item"]), len(doc["mission"]),
        len(doc["stage"]), len(doc["shop"]), len(doc["sign"]), len(doc["online"]),
        len(doc["gacha"]), len(doc["home"]), len(doc["errand"]))

    if check:
        problems = []
        if not OUT_LUA.exists() or OUT_LUA.read_text(encoding="utf-8") != lua_text:
            problems.append("generated/gamedata_generated.lua out of sync")
        if not MIRROR.exists() or MIRROR.read_text(encoding="utf-8") != mirror_text:
            problems.append("conf/gamedata.json mirror out of sync")
        if problems:
            for p in problems:
                print("gamedata check: " + p)
            return 1
        print("gamedata check: %s, lua + mirror in sync" % counts)
        return 0

    OUT_LUA.parent.mkdir(parents=True, exist_ok=True)
    OUT_LUA.write_text(lua_text, encoding="utf-8")
    MIRROR.write_text(mirror_text, encoding="utf-8")
    print("gamedata: %s -> %s" % (counts, OUT_LUA.relative_to(ROOT)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
