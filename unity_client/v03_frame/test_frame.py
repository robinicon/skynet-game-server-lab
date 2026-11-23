"""V03 信封层自测：字节向量、边界、粘包、C-21 复现、Lua 等价性。

运行：python unity_client/v03_frame/test_frame.py
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import _selftest as T  # noqa: E402
import frame as F  # noqa: E402
from _selftest import check, check_raises, section  # noqa: E402


def test_vector():
    section("帧向量：AUTH_LOGIN_REQ（V03 正文那张字节图）")
    op = F.make_opcode(F.CHANNEL_AUTH, 0x0001)
    check("AUTH_LOGIN_REQ == 0x00060001", op == 0x00060001, f"0x{op:08X}")

    payload = bytes(range(47))                      # 47B 占位 protobuf
    f = F.encode(op, payload)
    check("总长 = 4 + 1 + 4 + 47 = 56", len(f) == 56, len(f))
    check("len 字段 = 52（不含自身）", int.from_bytes(f[:4], "big") == 52)
    check("ver = 0x02", f[4] == 0x02)
    check("opcode 大端在偏移 5..8", int.from_bytes(f[5:9], "big") == 0x00060001)

    back = F.decode(f)
    check("往返 payload 一致", back.payload == payload)
    check("往返 opcode 一致", back.opcode == op)
    check("channel / id 拆分正确", (back.channel, back.msg_id) == (0x0006, 0x0001))

    dump = F.hexdump(f)
    check("hexdump 含 opcode 与通道", "0x00060001" in dump and "ch=0x0006" in dump)


def test_boundary():
    section("边界：空包 / 超限 / 长度不符 / 未知版本")
    check("空 payload 合法（len=5）", F.decode(F.encode(0x00010001)).payload == b"")
    check_raises("超 1MiB 拒绝", lambda: F.encode(0x00010001, b"\x00" * (F.MAX_FRAME)),
                 F.FrameError, "FRAME_TOO_LARGE")
    check_raises("短于 9B 拒绝", lambda: F.decode(b"\x00" * 8),
                 F.FrameError, "FRAME_TOO_SHORT")
    check_raises("声明长度与实际不符", lambda: F.decode(F.encode(0x00010001, b"\x01" * 10)[:-1]),
                 F.FrameError, "LENGTH_MISMATCH")
    bad_ver = F.encode(0x00010001) 
    bad_ver = bad_ver[:4] + b"\x7f" + bad_ver[5:]
    check_raises("版本 0x7f 拒绝", lambda: F.decode(bad_ver), F.FrameError, "BAD_VERSION")


def test_stream():
    section("粘包：一次收到三帧")
    a = F.encode(F.make_opcode(F.CHANNEL_CLI, 0x0001), b"\x0a\x01")
    b = F.encode(F.make_opcode(F.CHANNEL_CLI, 0x0004), b"")
    c = F.encode(F.make_opcode(F.CHANNEL_DG, 0x0001), b"\xff" * 30)
    frames = F.split_stream(a + b + c)
    check("切出 3 帧", len(frames) == 3, len(frames))
    check("顺序与 opcode 正确",
          [x.opcode for x in frames] == [0x00010001, 0x00010004, 0x00070001])
    check("第三帧 payload 30B", len(frames[2].payload) == 30)
    check_raises("半包（少 1 字节）报 TRUNCATED_BODY",
                 lambda: F.split_stream(a + c[:-1]), F.FrameError, "TRUNCATED_BODY")


def test_c21_trap():
    section("C-21 复现：首字节判别为什么必然失效")
    small_new = F.encode(F.make_opcode(F.CHANNEL_AUTH, 0x0001), b"\x0a")   # len=6，首字节 0x00
    check("新帧首字节确实是 0x00", small_new[0] == 0x00)
    check("朴素判别把它判成 legacy（错误）",
          F.sniff_legacy_naive(small_new) == "legacy")
    check("固定偏移 4 判别正确", F.sniff(small_new) == F.MAGIC_V2)

    # 旧 sproto 包首字节也常是 0x00：两者在"首字节"维度上完全不可分
    legacy_like = b"\x00\x00" + bytes(20)
    check("旧包首字节同样 0x00，判别依据撞车",
          F.sniff_legacy_naive(small_new) == F.sniff_legacy_naive(legacy_like))


def _run_lua_dump(here: str) -> str | None:
    """调 WSL 里的 lua 跑 frame_dump.lua，返回 stdout；不可用则 None。

    lua 装在 /home/dev/bin，只有登录 shell 的 PATH 才有它 —— 所以走 bash -lc。
    """
    win = here.replace("\\", "/")
    lua_dir = "/mnt/" + win[0].lower() + win[2:] if win[1:2] == ":" else win
    if not shutil.which("wsl.exe"):
        return None
    cmd = ["wsl.exe", "-d", "Ubuntu", "-e", "bash", "-lc",
           f"cd {lua_dir} && lua frame_dump.lua"]
    try:
        r = subprocess.run(cmd, capture_output=True, timeout=120)
    except Exception as e:  # noqa: BLE001
        print(f"  SKIP  调用 wsl/lua 失败：{e}")
        return None
    if r.returncode != 0:
        print(f"  SKIP  lua 执行失败 rc={r.returncode}：{r.stderr.decode('utf-8', 'ignore')[:200]}")
        return None
    return r.stdout.decode("utf-8", "ignore")


def test_lua_equivalence():
    section("Lua 参考实现与 Python 黄金实现字节级等价")
    here = os.path.dirname(os.path.abspath(__file__))
    if not check("frame_ref.lua 存在", os.path.exists(os.path.join(here, "frame_ref.lua"))):
        return

    out = _run_lua_dump(here)
    if out is None:
        check("Lua 向量可生成（本机需 WSL + lua）", False, "环境缺失，非代码失败")
        return

    rows = [ln.split() for ln in out.strip().splitlines() if ln.strip()]
    check("Lua 输出 4 组向量", len(rows) == 4, len(rows))
    if len(rows) != 4:
        return

    py_cases = [
        (F.make_opcode(F.CHANNEL_AUTH, 0x0001), b"\x01" * 47),
        (F.make_opcode(F.CHANNEL_AUTH, 0x0002), b""),
        (F.make_opcode(F.CHANNEL_CLI, 0x000F), b"\x0a\x01\x12\x03abc"),
        (F.make_opcode(F.CHANNEL_DG, 0x0001), b"\xff" * 30),
    ]
    for (op_hex, _ver, lua_hex), (op, payload) in zip(rows, py_cases):
        py_hex = F.encode(op, payload).hex()
        check(f"opcode 0x{op:08X} 逐字节一致", lua_hex == py_hex,
              f"lua={lua_hex[:24]}… py={py_hex[:24]}…")
        check(f"opcode 0x{op:08X} 长度 {len(py_hex)//2}B",
              len(lua_hex) == len(py_hex))


def main():
    test_vector()
    test_boundary()
    test_stream()
    test_c21_trap()
    test_lua_equivalence()
    return T.summary("V03 frame")


if __name__ == "__main__":
    sys.exit(T.guard(main))
