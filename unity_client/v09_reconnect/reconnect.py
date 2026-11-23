"""重连退避与状态机 —— V09 配套。

服务端 `ch12_disconnect` 的窗口是 100cs（1 秒），客户端心跳 15 秒才发现断线——
这个不等式决定了"重连必然落到重新读档"（台账 C-14）。工具把它算给你看。

退避区间与正文一致：1s→2s→4s→8s→15s，±20% 抖动，累计预算内否则转登录。
"""

from __future__ import annotations

from dataclasses import dataclass, field

# 正文给出的口径
DEFAULT_STEPS = (1.0, 2.0, 4.0, 8.0, 15.0)
JITTER = 0.20
SERVER_OFFLINE_WINDOW_S = 1.0     # CH12_OFFLINE_TIMEOUT = 100 cs
CLIENT_HEARTBEAT_S = 5.0
CLIENT_HEARTBEAT_TIMEOUT_S = 15.0
PRODUCT_BUDGET_S = 60.0           # "断线 60 秒内能续玩"


def backoff_delay(attempt: int, steps: tuple[float, ...] = DEFAULT_STEPS,
                  jitter_seed: int | None = None) -> float:
    """第 attempt 次（从 0 起）重试前的等待秒数，含抖动。

    jitter_seed 给定时用确定性伪随机，便于测试；None 用真随机。
    """
    if attempt < 0:
        raise ValueError("attempt 从 0 起")
    base = steps[min(attempt, len(steps) - 1)]
    if jitter_seed is None:
        import random
        k = random.uniform(-JITTER, JITTER)
    else:
        # 线性同余，确定且不依赖 random 的全局状态
        k = ((jitter_seed * 1103515245 + 12345) % 1000) / 1000.0 * 2 * JITTER - JITTER
    return round(base * (1 + k), 3)


def schedule(steps: tuple[float, ...] = DEFAULT_STEPS) -> list[float]:
    """无抖动的理论退避序列（用于文档与对比）。"""
    return [steps[min(i, len(steps) - 1)] for i in range(len(steps))]


def cumulative(steps: tuple[float, ...] = DEFAULT_STEPS) -> list[float]:
    """累计耗时：第 n 次重试前的累计等待。"""
    total, out = 0.0, []
    for d in schedule(steps):
        total += d
        out.append(total)
    return out


def reconnect_verdict(window_s: float = SERVER_OFFLINE_WINDOW_S,
                      heartbeat_s: float = CLIENT_HEARTBEAT_S,
                      timeout_s: float = CLIENT_HEARTBEAT_TIMEOUT_S) -> dict:
    """判断"发现断线"是否来得及时。

    客户端要等 heartbeat + timeout 才判定断线；服务端只守 window 秒。
    detect > window 时，重连到达时服务端已经 save_and_exit，只能走"重新读档"。
    """
    detect = heartbeat_s + timeout_s
    return {
        "detect_s": detect,
        "window_s": window_s,
        "late_by_s": round(detect - window_s, 2),
        "fallback_to_reload": detect > window_s,
    }


# ---- 状态机 -----------------------------------------------------------------
class State:
    IN_GAME = "InGame"
    RECONNECTING = "Reconnecting"
    REAUTH = "Reauth"
    RESYNC = "Resync"
    LOGIN = "Login"


@dataclass
class ReconnectSM:
    """客户端重连状态机。

    关键约束：退避累计超预算 → 转 Login；票据失效 → 转 Login；
    重连成功后必须 Resync（全量校准）再回 InGame，不能直接续玩（C-16）。
    """
    budget_s: float = PRODUCT_BUDGET_S
    steps: tuple[float, ...] = DEFAULT_STEPS
    state: str = State.IN_GAME
    attempt: int = 0
    elapsed_s: float = 0.0
    history: list[str] = field(default_factory=list)

    def _go(self, s: str) -> None:
        self.history.append(f"{self.state} → {s}")
        self.state = s

    def on_disconnect(self) -> None:
        if self.state != State.IN_GAME:
            raise RuntimeError(f"断线事件出现在 {self.state}，状态机被重复触发")
        self.attempt = 0
        self.elapsed_s = 0.0
        self._go(State.RECONNECTING)

    def next_attempt(self, jitter_seed: int | None = None) -> tuple[float, bool]:
        """返回 (本次等待秒数, 是否还有预算)。预算耗尽则转 Login。"""
        if self.state != State.RECONNECTING:
            raise RuntimeError(f"{self.state} 下不该发起重试")
        delay = backoff_delay(self.attempt, self.steps, jitter_seed)
        if self.elapsed_s + delay > self.budget_s:
            self._go(State.LOGIN)
            return delay, False
        self.elapsed_s += delay
        self.attempt += 1
        return delay, True

    def on_connected(self) -> None:
        if self.state != State.RECONNECTING:
            raise RuntimeError(f"{self.state} 下不该收到连上事件")
        self._go(State.REAUTH)

    def on_reauth_ok(self) -> None:
        if self.state != State.REAUTH:
            raise RuntimeError(f"{self.state} 下不该完成验票")
        self._go(State.RESYNC)

    def on_ticket_invalid(self) -> None:
        self._go(State.LOGIN)

    def on_resync_done(self) -> None:
        if self.state != State.RESYNC:
            raise RuntimeError(f"{self.state} 下不该完成校准")
        self._go(State.IN_GAME)


def run_until_budget(budget_s: float = PRODUCT_BUDGET_S) -> ReconnectSM:
    """模拟"一直连不上"，走到预算耗尽为止。"""
    sm = ReconnectSM(budget_s=budget_s)
    sm.on_disconnect()
    for i in range(100):
        _, ok = sm.next_attempt(jitter_seed=i)
        if not ok:
            break
    return sm
