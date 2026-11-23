"""V05 覆盖度矩阵自测：断言"缺的正是那四条"，并守住 id 进制解析这个坑。

运行：python unity_client/v05_contract/test_coverage.py
"""

from __future__ import annotations

import io
import os
import sys
from contextlib import redirect_stdout

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import _selftest as T  # noqa: E402
import coverage as C  # noqa: E402
from _selftest import check, section  # noqa: E402


def test_registry_load():
    section("registry 载入")
    reg = C.load_registry()
    check("版本号为 3", reg.get("version") == 3, reg.get("version"))
    check("opcode 共 22 条", len(reg["opcodes"]) == 22, len(reg["opcodes"]))
    check("六个通道", len(reg["channels"]) == 6, sorted(reg["channels"]))


def test_id_radix():
    section("id 进制：YAML 已把 0x000D 解析成 13，不能再按 16 进制重解析")
    check("as_int(int) 原样返回", C.as_int(13) == 13)
    check("as_int('0x000F') == 15", C.as_int("0x000F") == 15)
    check("as_int(13) 不等于 int('13',16)=19", C.as_int(13) != 19)
    used = C.channel_usage(C.load_registry())
    check("CLI 占用 14 个", len(used["CLI"]) == 14, len(used["CLI"]))
    check("CLI 区间 0x0001~0x000E", (used["CLI"][0], used["CLI"][-1]) == (0x0001, 0x000E),
          f"0x{used['CLI'][0]:04X}~0x{used['CLI'][-1]:04X}")
    check("CLI 下一个可用 id 是 0x000F", C.next_free_id(used["CLI"]) == 0x000F,
          hex(C.next_free_id(used["CLI"])))


def test_matrix():
    section("矩阵：缺口正是 C-04 那四条中的三条请求 + 一条响应")
    rows = C.build_matrix(C.load_registry(), C.load_screens())
    check("6 个界面入矩阵", len(rows) == 6, len(rows))
    by = {r["prefab"]: r for r in rows}
    check("Login 已覆盖", by["Login"]["missing"] == [])
    check("RoleSelect 缺 CLI_ROLE_LIST_REQ",
          by["RoleSelect"]["missing"] == ["CLI_ROLE_LIST_REQ"])
    check("RoleCreate 缺 CLI_ROLE_CREATE_REQ",
          by["RoleCreate"]["missing"] == ["CLI_ROLE_CREATE_REQ"])
    check("Character (List) 被动，缺 RSP",
          by["Character (List)"]["missing"] == ["CLI_ROLE_LIST_RSP"]
          and by["Character (List)"]["passive"])
    check("Loading Bar 无协议需求", by["Loading Bar"]["needs"] == [])
    gaps = [r for r in rows if r["missing"]]
    check("缺口界面 3 个", len(gaps) == 3, len(gaps))


def test_proposals_free():
    section("提案 id 必须空闲（否则只增不改的前提就破了）")
    reg = C.load_registry()
    used = C.channel_usage(reg)
    screens = C.load_screens()
    for p in screens["proposals"]:
        pid = C.as_int(p["id"])
        check(f"{p['name']:<22} 0x{pid:04X} 空闲", pid not in used[p["channel"]],
              "已占用")
    ids = [C.as_int(p["id"]) for p in screens["proposals"]]
    check("四条提案 id 从 0x000F 起连续", ids == [0x000F, 0x0010, 0x0011, 0x0012],
          ids)


def test_cli_modes():
    section("CLI 模式：--strict 有缺口返回 1，--propose 打印可贴行")
    buf = io.StringIO()
    with redirect_stdout(buf):
        rc_plain = C.main([])
        rc_strict = C.main(["--strict"])
        rc_prop = C.main(["--propose"])
    out = buf.getvalue()
    check("默认模式 rc=0（盘点不阻断）", rc_plain == 0, rc_plain)
    check("--strict rc=1（有缺口）", rc_strict == 1, rc_strict)
    check("--propose rc=0（提案 id 全空闲）", rc_prop == 0, rc_prop)
    check("输出含矩阵表头", "界面" in out and "缺口" in out)
    check("输出含四条提案", out.count("CLI_ROLE_") >= 4, out.count("CLI_ROLE_"))


def main():
    test_registry_load()
    test_id_radix()
    test_matrix()
    test_proposals_free()
    test_cli_modes()
    return T.summary("V05 coverage")


if __name__ == "__main__":
    sys.exit(T.guard(main, "V05 coverage"))
