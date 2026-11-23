"""V09 重连自测：退避序列、预算、以及"发现太晚"这条不等式（C-14）。"""

from __future__ import annotations

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)

import _selftest as T  # noqa: E402
import reconnect as R  # noqa: E402
from _selftest import check, check_raises, section  # noqa: E402


def test_backoff():
    section("退避：1→2→4→8→15，封顶 15")
    check("理论序列", R.schedule() == [1.0, 2.0, 4.0, 8.0, 15.0], R.schedule())
    check("第 6 次仍封顶 15", R.schedule((1.0, 2.0, 4.0, 8.0, 15.0))[-1] == 15.0)
    check("累计 1/3/7/15/30", R.cumulative() == [1.0, 3.0, 7.0, 15.0, 30.0], R.cumulative())

    d0 = R.backoff_delay(0, jitter_seed=0)
    check("抖动在 ±20% 内（第 1 次 0.8~1.2s）", 0.8 <= d0 <= 1.2, d0)
    d15 = R.backoff_delay(4, jitter_seed=7)
    check("封顶档抖动在 12~18s", 12.0 <= d15 <= 18.0, d15)
    check("同 seed 结果确定", R.backoff_delay(2, jitter_seed=42) == R.backoff_delay(2, jitter_seed=42))
    check_raises("负数 attempt 拒绝", lambda: R.backoff_delay(-1), ValueError)


def test_verdict():
    section("C-14：客户端发现断线的时刻 vs 服务端窗口")
    v = R.reconnect_verdict()
    check("客户端 5s 心跳 + 15s 超时 = 20s 才发现", v["detect_s"] == 20.0, v["detect_s"])
    check("服务端窗口 1s（CH12_OFFLINE_TIMEOUT=100cs）", v["window_s"] == 1.0)
    check("晚了 19s", v["late_by_s"] == 19.0, v["late_by_s"])
    check("结论：必然退化为重新读档", v["fallback_to_reload"] is True)

    ok = R.reconnect_verdict(window_s=30.0, heartbeat_s=5.0, timeout_s=15.0)
    check("若窗口放到 30s 则来得及", ok["fallback_to_reload"] is False, ok)

    tight = R.reconnect_verdict(window_s=8.0, heartbeat_s=3.0, timeout_s=9.0)
    check("心跳 3s/超时 9s + 窗口 8s 仍然晚 4s", tight["late_by_s"] == 4.0, tight)


def test_sm_happy():
    section("状态机：断线 → 重试 → 验票 → 全量校准 → 回游戏")
    sm = R.ReconnectSM()
    sm.on_disconnect()
    check("进入 Reconnecting", sm.state == R.State.RECONNECTING)
    d, ok = sm.next_attempt(jitter_seed=1)
    check("首次退避约 1s", 0.8 <= d <= 1.2, d)
    check("预算内继续", ok is True)
    sm.on_connected()
    check("连上后进入 Reauth", sm.state == R.State.REAUTH)
    sm.on_reauth_ok()
    check("验票通过进入 Resync", sm.state == R.State.RESYNC)
    sm.on_resync_done()
    check("校准完成回到 InGame", sm.state == R.State.IN_GAME)
    check("路径完整", sm.history == [
        "InGame → Reconnecting", "Reconnecting → Reauth",
        "Reauth → Resync", "Resync → InGame"], sm.history)


def test_sm_budget():
    section("预算耗尽 / 票据失效都转登录")
    sm = R.run_until_budget()
    check("最终状态 Login", sm.state == R.State.LOGIN, sm.state)
    check("累计未超 60s 预算", sm.elapsed_s <= 60.0, sm.elapsed_s)
    check("尝试次数有限（≤10）", sm.attempt <= 10, sm.attempt)

    sm2 = R.ReconnectSM()
    sm2.on_disconnect()
    sm2.next_attempt(jitter_seed=3)
    sm2.on_connected()
    sm2.on_ticket_invalid()
    check("票据失效直接回登录页", sm2.state == R.State.LOGIN)

    check_raises("未断线就重试要报错", lambda: R.ReconnectSM().next_attempt(), RuntimeError)
    check_raises("重复断线事件要报错", lambda: _double(sm2), RuntimeError)


def _double(sm):
    sm.state = R.State.RECONNECTING
    sm.on_disconnect()


def main():
    test_backoff()
    test_verdict()
    test_sm_happy()
    test_sm_budget()
    return T.summary("V09 reconnect")


if __name__ == "__main__":
    sys.exit(T.guard(main, "V09 reconnect"))
