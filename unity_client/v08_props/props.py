"""Props 泳道编解码与槽位分配 —— V08 配套。

做三件事：
  1. 槽位分段（bag / quest / skill / vip / system）的单一来源
  2. 增量 diff + 合并：只发变化的槽位，bits 用一条承载 64 个布尔
  3. 槽位冲突检测 —— 示例槽位表本身有重叠，工具必须能报出来（C-46）

PropValue 字段与 Msg_Common.proto 一致：slot / num / str / bits。
"""

from __future__ import annotations

from dataclasses import dataclass, field

# ---- 槽位分段 ---------------------------------------------------------------
# 段划分与 V08 正文的映射表一致。注意 quest_progress 是"3000 + qid 低 8 位"，
# 所以实际占用是动态区间，不是整齐的 3000~3999。
SEG_BAG = 1000          # 1000~1999 背包物品
SEG_BAG_EQUIP = 2000    # 2000~2999 装备槽
SEG_QUEST = 3000        # 3000~3999 任务（动态）
SEG_SKILL = 4000        # 4000~4999 技能
SEG_VIP = 5000          # 5000~5999 VIP
SEG_SYSTEM = 9000       # 9000+    系统保留

QUEST_PROGRESS_BASE = SEG_QUEST
QUEST_DONE_SLOT = 3100          # 任务完成位集合（bits）
QUEST_QID_MASK = 0xFF           # 正文原写法：qid 低 8 位

# 修正建议：把活跃任务数限制在 64，progress 占 3001~3063，done 用 3100，两者不重叠。
QUEST_QID_MASK_FIXED = 0x3F


def slot_bag(item_id: int) -> int:
    """物品槽 = 1000 + 物品 id 低 3 位（正文口径：物品 id 直接做槽位后缀）。"""
    if not 0 <= item_id <= 999:
        raise ValueError(f"item_id={item_id} 超出槽位段容量（0~999）")
    return SEG_BAG + item_id


def slot_equip(pos: int) -> int:
    if not 0 <= pos <= 999:
        raise ValueError(f"equip pos={pos} 越界")
    return SEG_BAG_EQUIP + pos


def slot_quest_progress(qid: int, mask: int = QUEST_QID_MASK) -> int:
    return QUEST_PROGRESS_BASE + (qid & mask)


def slot_skill(sid: int) -> int:
    if not 0 <= sid <= 999:
        raise ValueError(f"skill id={sid} 越界")
    return SEG_SKILL + sid


def slot_vip() -> int:
    return SEG_VIP


# ---- PropValue --------------------------------------------------------------
@dataclass(frozen=True)
class PropValue:
    slot: int
    num: int | None = None
    str: str | None = None
    bits: int | None = None

    def channel(self) -> str:
        n = sum(x is not None for x in (self.num, self.str, self.bits))
        if n != 1:
            raise ValueError(f"slot {self.slot} 必须且只能占用一个通道，当前 {n} 个")
        return "num" if self.num is not None else ("str" if self.str is not None else "bits")

    def to_wire(self) -> str:
        """模拟 protobuf 的可读编码（真实编码由 protoc 生成，这里只为比对）。"""
        c = self.channel()
        return f"{self.slot}:{c}={getattr(self, c)}"


def diff(old: dict[int, PropValue], new: dict[int, PropValue]) -> list[PropValue]:
    """只回传变化的槽位。槽位号单调，输出按 slot 排序，便于比包。"""
    out = []
    for slot in sorted(new):
        nv = new[slot]
        ov = old.get(slot)
        if ov != nv:
            out.append(nv)
    return out


def apply(base: dict[int, PropValue], deltas: list[PropValue]) -> dict[int, PropValue]:
    """把增量合并进基线（客户端侧）。返回新 dict，不改入参。"""
    merged = dict(base)
    for d in deltas:
        merged[d.slot] = d
    return merged


def pack_bits(flags: dict[int, bool]) -> int:
    """布尔集合打包成一个 uint64：位序号 = 任务序号（0~63）。"""
    v = 0
    for idx, on in flags.items():
        if not 0 <= idx <= 63:
            raise ValueError(f"bit index {idx} 超出 uint64")
        if on:
            v |= 1 << idx
    return v


def unpack_bits(v: int) -> list[int]:
    return [i for i in range(64) if (v >> i) & 1]


# ---- 槽位冲突检测 -----------------------------------------------------------
def check_slot_conflicts(active_qids: int = 120, mask: int = QUEST_QID_MASK) -> list[tuple[int, str, str]]:
    """检测槽位表是否自洽。

    quest_progress 用 3000 + (qid & mask)：mask 同时决定了"能容纳多少个活跃任务"。
    mask=0xFF 时容量 256，但 qid=100 会落到 3100 —— 正好撞 quest_done 的固定槽位。
    active_qids 超过 mask+1 时必然回绕重叠，所以容量是硬约束，不是建议。
    """
    taken: dict[int, str] = {QUEST_DONE_SLOT: "quest.done(bits)"}
    conflicts = []
    for qid in range(1, active_qids + 1):
        s = slot_quest_progress(qid, mask)
        owner = f"quest.progress(qid={qid})"
        if s in taken:
            conflicts.append((s, taken[s], owner))
        else:
            taken[s] = owner
    return conflicts


def layout_report(mask: int = QUEST_QID_MASK) -> str:
    """打印槽位分段占用，冲突一眼可见。"""
    lines = [
        f"{'段':<16}{'槽位':<16}{'容量':<10}说明",
        "-" * 72,
        f"{'bag':<16}{'1000~1999':<16}{1000:<10}物品 id 做后缀（0~999）",
        f"{'bag_equip':<16}{'2000~2999':<16}{1000:<10}装备槽位",
        f"{'quest.progress':<16}{f'3000+0~{mask}':<16}{mask + 1:<10}3000 + (qid & 0x{mask:02X})",
        f"{'quest.done':<16}{str(QUEST_DONE_SLOT):<16}{64:<10}bits，64 个任务完成位",
        f"{'skill':<16}{'4000~4999':<16}{1000:<10}技能序号",
        f"{'vip':<16}{str(SEG_VIP):<16}{1:<10}固定槽位",
        f"{'system':<16}{'9000+':<16}{'-':<10}保留",
    ]
    return "\n".join(lines)
