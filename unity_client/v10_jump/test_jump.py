"""V10 跳转窗口期自测：缓存、重放顺序、回滚、超时、溢出、去重。"""

from __future__ import annotations

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)

import _selftest as T  # noqa: E402
import jump as J  # noqa: E402
from _selftest import check, section  # noqa: E402


def _gate(**kw) -> J.GateRedirect:
    g = J.GateRedirect(**kw)
    g.bind(31, "node_a", 1001)
    return g


def test_buffered():
    section("窗口期：消息进 buffer，不投递")
    g = _gate()
    check("未开窗口时直接投递", g.route(31, J.Msg(0x9001)) == "delivered")
    g.begin_jump(31, now=0.0)
    check("开窗口后进 buffer", g.route(31, J.Msg(0x9002)) == "buffered")
    check("第二条也进 buffer", g.route(31, J.Msg(0x9003)) == "buffered")
    check("buffer 有 2 条", len(g.fd_to_agent[31].buffer) == 2)
    check("投递记录只有窗口前那 1 条", len(g.delivered) == 1, len(g.delivered))


def test_rebind_order():
    section("rebind：先建新表再重放，重放不能再进 buffer")
    g = _gate()
    g.begin_jump(31, now=0.0)
    g.route(31, J.Msg(0x9002))
    g.route(31, J.Msg(0x9003))
    buf = g.rebind(31, "node_b", 2002)
    check("返回被重放的 2 条", len(buf) == 2)
    check("重放真的投递出去了", len(g.delivered) == 2, len(g.delivered))
    a = g.fd_to_agent[31]
    check("新表指向 node_b", a.node == "node_b" and a.addr == 2002)
    check("窗口已关闭", a.window is False)
    check("buffer 已清空（重放没回填）", a.buffer == [], a.buffer)
    check("重放后新消息直接投递", g.route(31, J.Msg(0x9004)) == "delivered")


def test_rollback():
    section("失败回滚：不关窗口会把 fd 卡死")
    g = _gate()
    g.begin_jump(31, now=0.0)
    g.route(31, J.Msg(0x9002))
    g.rollback(31, "node_a", 1001)
    a = g.fd_to_agent[31]
    check("绑回旧 agent", a.node == "node_a" and a.addr == 1001)
    check("窗口已关闭", a.window is False)
    check("记录回滚", g.rolled_back == [31])
    check("回滚后消息能投递（不再堆 buffer）", g.route(31, J.Msg(0x9005)) == "delivered")


def test_timeout():
    section("C-32：窗口超时强制回滚")
    g = _gate()
    g.begin_jump(31, now=0.0)
    g.route(31, J.Msg(0x9002))
    check("未到超时不回滚", g.tick(now=9.9) == [])
    check("到 10s 超时回滚", g.tick(now=10.01) == [31])
    check("回滚后窗口关闭", g.fd_to_agent[31].window is False)
    check("窗口 10s 为正文建议值", g.timeout_s == J.WINDOW_TIMEOUT_S == 10.0)


def test_overflow():
    section("C-32：buffer 上限，溢出丢最旧")
    g = _gate(buffer_max=3)
    g.begin_jump(31, now=0.0)
    for i in range(5):
        g.route(31, J.Msg(0x9000 + i))
    a = g.fd_to_agent[31]
    check("buffer 不超过上限 3", len(a.buffer) == 3, len(a.buffer))
    check("丢弃 2 条", a.dropped == 2, a.dropped)
    check("保留的是最新 3 条", [m.opcode for m in a.buffer] == [0x9002, 0x9003, 0x9004],
          [m.opcode for m in a.buffer])


def test_dedup():
    section("C-15：重放去重，同一 request_id 只执行一次")
    g = _gate()
    check("首次见到 id=7 不算重复", g.seen(7) is False)
    check("再见到 id=7 算重复", g.seen(7) is True)
    check("id=0 不参与去重", g.seen(0) is False and g.seen(0) is False)

    g.begin_jump(31, now=0.0)
    g.route(31, J.Msg(0x9002, request_id=7))     # 旧 agent 可能已处理过 7
    g.route(31, J.Msg(0x9003, request_id=8))
    sent, skipped = g.replay_dedup(31)
    check("重放投递 1 条、跳过 1 条", (sent, skipped) == (1, 1), (sent, skipped))
    check("buffer 被清空", g.fd_to_agent[31].buffer == [])
    check("投递的是 id=8", g.delivered[-1][1].request_id == 8)


def test_dedup_window():
    section("去重窗口有界（不会无限长）")
    g = _gate()
    for i in range(1, 300):
        g.seen(i)
    check("去重集合不超过 256", len(g.dedup_set) <= J.DEDUP_WINDOW, len(g.dedup_set))
    check("最旧的 id 已被挤出", g.seen(1) is False)
    check("最近的仍被记住", g.seen(299) is True)


def main():
    test_buffered()
    test_rebind_order()
    test_rollback()
    test_timeout()
    test_overflow()
    test_dedup()
    test_dedup_window()
    return T.summary("V10 jump")


if __name__ == "__main__":
    sys.exit(T.guard(main, "V10 jump"))
