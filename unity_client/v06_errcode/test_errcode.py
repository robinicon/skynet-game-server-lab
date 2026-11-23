"""V06 错误码 lint 自测：断言撞车 6 处、映射表有效、豁免规则本身没把真撞车放过去。

运行：python unity_client/v06_errcode/test_errcode.py
"""

from __future__ import annotations

import io
import os
import sys
from contextlib import redirect_stdout

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)

import _selftest as T  # noqa: E402
import errcode_lint as L  # noqa: E402
from _selftest import check, section  # noqa: E402


def test_parse():
    section("解析两侧错误码")
    sv = L.parse_lua()
    cl = L.parse_proto()
    check("服务端 11 个", len(sv) == 11, len(sv))
    check("契约 7 个", len(cl) == 7, len(cl))
    check("服务端含负数系统码", sv.get("ERR_INTERNAL") == -1 and sv.get("ERR_TIMEOUT") == -3)
    check("契约 ERR_OK = 0", cl.get("ERR_OK") == 0)
    check("服务端 ERR_TOKEN_EXPIRED = 4", sv.get("ERR_TOKEN_EXPIRED") == 4)
    check("契约 ERR_TICKET_EXPIRED = 2", cl.get("ERR_TICKET_EXPIRED") == 2)


def test_normalize():
    section("等价判定：OK / ERR_OK 同义，token / ticket 不同义")
    check("OK 与 ERR_OK 归一后相同", L.normalize("OK") == L.normalize("ERR_OK"))
    check("ERR_TOKEN_EXPIRED ≠ ERR_TICKET_EXPIRED",
          L.normalize("ERR_TOKEN_EXPIRED") != L.normalize("ERR_TICKET_EXPIRED"))
    check("ERR_INVALID_TOKEN ≠ ERR_TICKET_INVALID",
          L.normalize("ERR_INVALID_TOKEN") != L.normalize("ERR_TICKET_INVALID"))


def test_collisions():
    section("撞车：正好 1~6 六处（0 值同义被豁免）")
    cols = L.find_collisions(L.parse_lua(), L.parse_proto())
    values = [v for v, _, _ in cols]
    check("撞车 6 处", len(cols) == 6, values)
    check("撞车值是 1..6", values == [1, 2, 3, 4, 5, 6], values)

    by_val = {v: (s, c) for v, s, c in cols}
    check("1 = ERR_UNKNOWN_ACCOUNT vs ERR_TICKET_INVALID",
          by_val[1] == (["ERR_UNKNOWN_ACCOUNT"], ["ERR_TICKET_INVALID"]), by_val[1])
    check("4 = ERR_TOKEN_EXPIRED vs ERR_SERVER_FULL",
          by_val[4] == (["ERR_TOKEN_EXPIRED"], ["ERR_SERVER_FULL"]), by_val[4])
    check("6 = ERR_LOGIN_QUEUE_FULL vs ERR_DB_TIMEOUT",
          by_val[6] == (["ERR_LOGIN_QUEUE_FULL"], ["ERR_DB_TIMEOUT"]), by_val[6])


def test_semantic_map():
    section("语义映射：两端必须都存在（过期映射比撞车更危险）")
    sv, cl = L.parse_lua(), L.parse_proto()
    check("映射表无过期项", L.check_map(sv, cl) == [], L.check_map(sv, cl))
    check("ERR_TOKEN_EXPIRED → ERR_TICKET_EXPIRED",
          L.SEMANTIC_MAP["ERR_TOKEN_EXPIRED"] == "ERR_TICKET_EXPIRED")
    check("ERR_INVALID_TOKEN → ERR_TICKET_INVALID",
          L.SEMANTIC_MAP["ERR_INVALID_TOKEN"] == "ERR_TICKET_INVALID")


def test_drift_and_cli():
    section("同名不同值 + CLI 退出码")
    sv, cl = L.parse_lua(), L.parse_proto()
    check("当前无同名项，漂移 0", L.find_drift(sv, cl) == [])

    # 造一份同名不同值的假数据，确认漂移检测真的会报
    fake = dict(cl)
    fake["ERR_OK"] = 99
    drifted = L.find_drift({"ERR_OK": 0}, fake)
    check("漂移检测生效（ERR_OK: 0 vs 99）",
          drifted == [("ERR_OK", 0, 99)], drifted)

    buf = io.StringIO()
    with redirect_stdout(buf):
        rc_plain = L.main([])
        rc_strict = L.main(["--strict"])
    out = buf.getvalue()
    check("默认模式 rc=0（报告不阻断）", rc_plain == 0, rc_plain)
    check("--strict rc=1（确有不一致）", rc_strict == 1, rc_strict)
    check("报告含撞车表头", "数值撞车 6 处" in out)
    check("报告含结论句", "错误提示会系统性错配" in out)


def main():
    test_parse()
    test_normalize()
    test_collisions()
    test_semantic_map()
    test_drift_and_cli()
    return T.summary("V06 errcode")


if __name__ == "__main__":
    sys.exit(T.guard(main, "V06 errcode"))
