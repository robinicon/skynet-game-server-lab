-- GENERATED FILE - do not edit. Source: conf/gamedata.xlsx
-- 游戏内容配置：英雄/经验曲线/加官/进爵/道具/任务。字段在库里只有 fid，语义来自这里。
local M = {}
M.version = 1
M.hero = {
    [2001] = { templateId=2001, name="关羽", quality=3, maxLv=60 },
    [2002] = { templateId=2002, name="张飞", quality=3, maxLv=60 },
    [2003] = { templateId=2003, name="赵云", quality=4, maxLv=80 },
    [2004] = { templateId=2004, name="黄忠", quality=2, maxLv=60 },
}
M.hero_exp = {
    [1] = 100,
    [2] = 150,
    [3] = 200,
    [4] = 250,
    [5] = 300,
    [6] = 350,
    [7] = 400,
    [8] = 450,
    [9] = 500,
    [10] = 550,
    [11] = 600,
    [12] = 650,
    [13] = 700,
    [14] = 750,
    [15] = 800,
    [16] = 850,
    [17] = 900,
    [18] = 950,
    [19] = 1000,
    [20] = 1050,
    [21] = 1100,
    [22] = 1150,
    [23] = 1200,
    [24] = 1250,
    [25] = 1300,
    [26] = 1350,
    [27] = 1400,
    [28] = 1450,
    [29] = 1500,
    [30] = 1550,
    [31] = 1600,
    [32] = 1650,
    [33] = 1700,
    [34] = 1750,
    [35] = 1800,
    [36] = 1850,
    [37] = 1900,
    [38] = 1950,
    [39] = 2000,
    [40] = 2050,
    [41] = 2100,
    [42] = 2150,
    [43] = 2200,
    [44] = 2250,
    [45] = 2300,
    [46] = 2350,
    [47] = 2400,
    [48] = 2450,
    [49] = 2500,
    [50] = 2550,
    [51] = 2600,
    [52] = 2650,
    [53] = 2700,
    [54] = 2750,
    [55] = 2800,
    [56] = 2850,
    [57] = 2900,
    [58] = 2950,
    [59] = 3000,
    [60] = 3050,
    [61] = 3100,
    [62] = 3150,
    [63] = 3200,
    [64] = 3250,
    [65] = 3300,
    [66] = 3350,
    [67] = 3400,
    [68] = 3450,
    [69] = 3500,
    [70] = 3550,
    [71] = 3600,
    [72] = 3650,
    [73] = 3700,
    [74] = 3750,
    [75] = 3800,
    [76] = 3850,
    [77] = 3900,
    [78] = 3950,
    [79] = 4000,
}
M.hero_max_lv = 80
M.hero_surmount = {
    [2001] = {
        [0] = { lvLimit=10, costItem=3001, costNum=5 },
        [1] = { lvLimit=20, costItem=3001, costNum=10 },
        [2] = { lvLimit=30, costItem=3001, costNum=20 },
        [3] = { lvLimit=40, costItem=3001, costNum=40 },
    },
    [2002] = {
        [0] = { lvLimit=10, costItem=3001, costNum=5 },
        [1] = { lvLimit=20, costItem=3001, costNum=10 },
        [2] = { lvLimit=30, costItem=3001, costNum=20 },
        [3] = { lvLimit=40, costItem=3001, costNum=40 },
    },
    [2003] = {
        [0] = { lvLimit=10, costItem=3001, costNum=5 },
        [1] = { lvLimit=20, costItem=3001, costNum=10 },
        [2] = { lvLimit=30, costItem=3001, costNum=20 },
        [3] = { lvLimit=40, costItem=3001, costNum=40 },
    },
    [2004] = {
        [0] = { lvLimit=10, costItem=3001, costNum=5 },
        [1] = { lvLimit=20, costItem=3001, costNum=10 },
        [2] = { lvLimit=30, costItem=3001, costNum=20 },
        [3] = { lvLimit=40, costItem=3001, costNum=40 },
    },
}
M.hero_week = {
    [2001] = {
        [0] = { breakLvLimit=2, costItem=3002, costNum=2 },
        [1] = { breakLvLimit=3, costItem=3002, costNum=4 },
        [2] = { breakLvLimit=4, costItem=3002, costNum=8 },
        [3] = { breakLvLimit=5, costItem=3002, costNum=16 },
    },
    [2002] = {
        [0] = { breakLvLimit=2, costItem=3002, costNum=2 },
        [1] = { breakLvLimit=3, costItem=3002, costNum=4 },
        [2] = { breakLvLimit=4, costItem=3002, costNum=8 },
        [3] = { breakLvLimit=5, costItem=3002, costNum=16 },
    },
    [2003] = {
        [0] = { breakLvLimit=2, costItem=3002, costNum=2 },
        [1] = { breakLvLimit=3, costItem=3002, costNum=4 },
        [2] = { breakLvLimit=4, costItem=3002, costNum=8 },
        [3] = { breakLvLimit=5, costItem=3002, costNum=16 },
    },
    [2004] = {
        [0] = { breakLvLimit=2, costItem=3002, costNum=2 },
        [1] = { breakLvLimit=3, costItem=3002, costNum=4 },
        [2] = { breakLvLimit=4, costItem=3002, costNum=8 },
        [3] = { breakLvLimit=5, costItem=3002, costNum=16 },
    },
}
M.item = {
    [1001] = { templateId=1001, name="小还丹", kind="elixir", value=100, sellPrice=10, stack=999 },
    [1002] = { templateId=1002, name="中还丹", kind="elixir", value=500, sellPrice=40, stack=999 },
    [1003] = { templateId=1003, name="大还丹", kind="elixir", value=2000, sellPrice=150, stack=999 },
    [3001] = { templateId=3001, name="官印", kind="material", value=0, sellPrice=0, stack=999 },
    [3002] = { templateId=3002, name="爵位令", kind="material", value=0, sellPrice=0, stack=999 },
    [9001] = { templateId=9001, name="金锭", kind="gold", value=1000, sellPrice=200, stack=999 },
    [9002] = { templateId=9002, name="银锭", kind="silver", value=500, sellPrice=0, stack=999 },
}
M.mission = {
    [5001] = { missionId=5001, type=1, target=3, rewardItem=9001, rewardNum=1 },
    [5002] = { missionId=5002, type=1, target=5, rewardItem=9002, rewardNum=2 },
    [5003] = { missionId=5003, type=2, target=1, rewardItem=1002, rewardNum=3 },
}
M.stage = {
    [1] = { stageId=1, needLevel=1, needPower=0, exp=100, gold=50, dropItem=1001, dropNum=1 },
    [2] = { stageId=2, needLevel=2, needPower=10, exp=120, gold=60, dropItem=1001, dropNum=1 },
    [3] = { stageId=3, needLevel=3, needPower=20, exp=140, gold=70, dropItem=1001, dropNum=1 },
    [4] = { stageId=4, needLevel=4, needPower=30, exp=160, gold=80, dropItem=1001, dropNum=2 },
    [5] = { stageId=5, needLevel=5, needPower=40, exp=180, gold=90, dropItem=1001, dropNum=2 },
    [6] = { stageId=6, needLevel=6, needPower=50, exp=200, gold=100, dropItem=1002, dropNum=2 },
    [7] = { stageId=7, needLevel=7, needPower=60, exp=220, gold=110, dropItem=1002, dropNum=3 },
    [8] = { stageId=8, needLevel=8, needPower=70, exp=240, gold=120, dropItem=1002, dropNum=3 },
    [9] = { stageId=9, needLevel=9, needPower=80, exp=260, gold=130, dropItem=1002, dropNum=3 },
    [10] = { stageId=10, needLevel=10, needPower=90, exp=280, gold=140, dropItem=1002, dropNum=4 },
}
M.shop = {
    [101] = { goodsId=101, itemId=1001, currency="gold", price=100, limit=0 },
    [102] = { goodsId=102, itemId=1002, currency="gold", price=350, limit=5 },
    [103] = { goodsId=103, itemId=3001, currency="silver", price=200, limit=0 },
}
M.sign = {
    [1] = { day=1, itemId=9001, count=1 },
    [2] = { day=2, itemId=1001, count=2 },
    [3] = { day=3, itemId=9002, count=2 },
    [4] = { day=4, itemId=1002, count=2 },
    [5] = { day=5, itemId=3001, count=5 },
    [6] = { day=6, itemId=1003, count=1 },
    [7] = { day=7, itemId=9001, count=2 },
}
M.online = {
    [30] = { minutes=30, itemId=1001, count=1 },
    [60] = { minutes=60, itemId=9001, count=1 },
    [120] = { minutes=120, itemId=1002, count=2 },
}
M.gacha_cost = 100
M.gacha_pity = 10
M.gacha = {
    [2001] = { tpl=2001, weight=60, rare=0 },
    [2002] = { tpl=2002, weight=30, rare=0 },
    [2003] = { tpl=2003, weight=9, rare=0 },
    [2004] = { tpl=2004, weight=1, rare=1 },
}
M.home = {
    [1] = { level=1, upgradeGold=100, produceItem=1001, produceNum=1 },
    [2] = { level=2, upgradeGold=200, produceItem=1001, produceNum=2 },
    [3] = { level=3, upgradeGold=300, produceItem=1001, produceNum=3 },
    [4] = { level=4, upgradeGold=400, produceItem=1001, produceNum=4 },
    [5] = { level=5, upgradeGold=500, produceItem=1001, produceNum=5 },
}
M.errand = {
    [1] = { id=1, gold=50, itemId=1001, itemNum=1 },
    [2] = { id=2, gold=120, itemId=3001, itemNum=2 },
    [3] = { id=3, gold=300, itemId=9001, itemNum=1 },
}
M.elixir_tiers = {
    { templateId=1001, value=100 },
    { templateId=1002, value=500 },
    { templateId=1003, value=2000 },
}
return M
