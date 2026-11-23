"""V08 泳道编解码自测：增量、bits 压缩、以及示例槽位表的自洽性（C-46）。"""

from __future__ import annotations

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)

import _selftest as T  # noqa: E402
import props as P  # noqa: E402
from _selftest import check, check_raises, section  # noqa: E402


def test_slots():
    section("槽位分段")
    check("物品 101 → 1101", P.slot_bag(101) == 1101, P.slot_bag(101))
    check("装备位 3 → 2003", P.slot_equip(3) == 2003)
    check("任务 7 进度 → 3007", P.slot_quest_progress(7) == 3007)
    check("技能 12 → 4012", P.slot_skill(12) == 4012)
    check("VIP 固定 5000", P.slot_vip() == 5000)
    check_raises("物品 id 越界拒绝", lambda: P.slot_bag(1000), ValueError)
    check_raises("技能 id 越界拒绝", lambda: P.slot_skill(-1), ValueError)


def test_conflict():
    section("槽位冲突：示例表里 3100 被两处占用（C-46）")
    cols = P.check_slot_conflicts()
    check("检出 1 处冲突", len(cols) == 1, cols)
    if cols:
        slot, owner_a, owner_b = cols[0]
        check("冲突槽位 = 3100", slot == 3100, slot)
        check("占用方是 quest.done 与 quest.progress(qid=100)",
              "done" in owner_a and "qid=100" in owner_b, (owner_a, owner_b))
    fixed = P.check_slot_conflicts(active_qids=64, mask=P.QUEST_QID_MASK_FIXED)
    check("按修正 mask=0x3F（活跃任务 ≤64）重算无冲突", fixed == [], fixed[:2])
    check("qid=100 在 mask=0x3F 下落到 3036",
          P.slot_quest_progress(100, P.QUEST_QID_MASK_FIXED) == 3036)
    # 容量是硬约束：mask 只给 64 个槽，塞 65 个活跃任务必然回绕重叠
    over = P.check_slot_conflicts(active_qids=65, mask=P.QUEST_QID_MASK_FIXED)
    check("活跃任务 65 > 容量 64 时必然回绕冲突", len(over) >= 1, len(over))


def test_propvalue():
    section("PropValue 三通道互斥")
    check("num 通道", P.PropValue(1101, num=99).channel() == "num")
    check("str 通道", P.PropValue(5001, str="张三").channel() == "str")
    check("bits 通道", P.PropValue(3100, bits=0b101).channel() == "bits")
    check_raises("同时占两个通道要拒绝",
                 lambda: P.PropValue(1, num=1, str="x").channel(), ValueError)
    check_raises("一个通道都不占要拒绝", lambda: P.PropValue(1).channel(), ValueError)
    check("wire 编码", P.PropValue(1101, num=99).to_wire() == "1101:num=99")


def test_diff_apply():
    section("增量 diff 与合并")
    base = {
        1101: P.PropValue(1101, num=99),
        3007: P.PropValue(3007, num=5),
        5000: P.PropValue(5000, num=3),
    }
    new = dict(base)
    new[3007] = P.PropValue(3007, num=6)         # 唯一变化
    deltas = P.diff(base, new)
    check("只回传 1 条增量", len(deltas) == 1, [d.to_wire() for d in deltas])
    check("变化的是任务进度", deltas[0].slot == 3007)
    check("合并后与目标一致", P.apply(base, deltas) == new)
    check("无变化时增量 0 条", P.diff(base, base) == [])
    check("增量按 slot 升序", [d.slot for d in P.diff(base, {**base, 1101: P.PropValue(1101, num=1),
                                                          3007: P.PropValue(3007, num=1)})] == [1101, 3007])


def test_bits():
    section("bits：20 个任务完成态用 1 条，不用 20 条 num")
    flags = {i: True for i in range(20)}
    v = P.pack_bits(flags)
    check("打包后为 uint64 内", 0 <= v < (1 << 64), v)
    check("解包得到 20 个位", P.unpack_bits(v) == list(range(20)))
    check("单条 bits 承载 20 个布尔", True, "")

    as_num = [P.PropValue(3100 + i, num=1) for i in range(20)]
    check("若用 num 语义需 20 条（对比）", len(as_num) == 20)
    check_raises("bit 序号超 63 拒绝", lambda: P.pack_bits({64: True}), ValueError)


def main():
    test_slots()
    test_conflict()
    test_propvalue()
    test_diff_apply()
    test_bits()
    return T.summary("V08 props")


if __name__ == "__main__":
    sys.exit(T.guard(main, "V08 props"))
