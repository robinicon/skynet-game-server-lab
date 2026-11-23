"""跨节点跳转窗口期 —— V10 配套。

复刻 `ch11_jump/service/gate_redirect.lua` 的 fd 路由表语义，并补上正文指出的
两个缺口（台账 C-32）：窗口没有超时、buffer 没有上限。

不变量（测试逐条断言）：
  1. 窗口期消息进 buffer，不投递
  2. rebind 先建新表再重放 —— 重放不能再进 buffer
  3. 失败必须回滚，否则 fd 卡在 window=true，后续消息全堆在 buffer
  4. 超时要能自救（C-32）
  5. buffer 要有上限，溢出丢最旧（C-32）
  6. 重放要按 request_id 去重，否则同一指令执行两次（C-15）
"""

from __future__ import annotations

from collections import deque
from dataclasses import dataclass, field

WINDOW_TIMEOUT_S = 10.0     # 正文建议值
BUFFER_MAX = 256            # 正文建议值
DEDUP_WINDOW = 256          # 最近处理过的 request_id 条数


@dataclass
class Msg:
    opcode: int
    payload: bytes = b""
    request_id: int = 0


@dataclass
class AgentRef:
    node: str
    addr: int
    window: bool = False
    buffer: list[Msg] = field(default_factory=list)
    opened_at: float = 0.0
    dropped: int = 0        # 因溢出丢弃的条数


class GateRedirect:
    """网关侧 fd → agent 路由表。"""

    def __init__(self, timeout_s: float = WINDOW_TIMEOUT_S, buffer_max: int = BUFFER_MAX):
        self.fd_to_agent: dict[int, AgentRef] = {}
        self.timeout_s = timeout_s
        self.buffer_max = buffer_max
        self.delivered: list[tuple[int, Msg]] = []       # 真正投递出去的
        self.dedup: deque[int] = deque(maxlen=DEDUP_WINDOW)
        self.dedup_set: set[int] = set()
        self.rolled_back: list[int] = []

    # -- 绑定 --------------------------------------------------------------
    def bind(self, fd: int, node: str, addr: int) -> None:
        self.fd_to_agent[fd] = AgentRef(node=node, addr=addr)

    # -- 窗口期开关 --------------------------------------------------------
    def begin_jump(self, fd: int, now: float = 0.0) -> bool:
        a = self.fd_to_agent.get(fd)
        if a is None:
            return False
        a.window = True
        a.opened_at = now
        a.buffer.clear()
        a.dropped = 0
        return True

    # -- 消息投递（窗口期进 buffer）----------------------------------------
    def route(self, fd: int, msg: Msg) -> str:
        """返回 'delivered' | 'buffered' | 'dropped'。"""
        a = self.fd_to_agent.get(fd)
        if a is None:
            return "dropped"
        if a.window:
            if len(a.buffer) >= self.buffer_max:
                a.buffer.pop(0)          # 丢最旧
                a.dropped += 1
            a.buffer.append(msg)
            return "buffered"
        self.delivered.append((fd, msg))
        return "delivered"

    # -- 重绑 + 重放 -------------------------------------------------------
    def rebind(self, fd: int, node: str, addr: int) -> list[Msg]:
        """顺序必须是"先建新表、再重放"：重放走 route 时 window 已为 False。"""
        old = self.fd_to_agent.get(fd)
        buf = list(old.buffer) if old else []
        self.fd_to_agent[fd] = AgentRef(node=node, addr=addr, window=False)
        for m in buf:
            self.route(fd, m)
        return buf

    # -- 失败回滚 ----------------------------------------------------------
    def rollback(self, fd: int, node: str, addr: int) -> None:
        """目标场景建 agent 失败：关窗口、清缓存、绑回旧 agent。"""
        self.fd_to_agent[fd] = AgentRef(node=node, addr=addr, window=False)
        self.rolled_back.append(fd)

    # -- 超时自救（C-32）---------------------------------------------------
    def tick(self, now: float) -> list[int]:
        """扫一遍窗口超时的 fd，强制回滚。返回被回滚的 fd 列表。"""
        expired = []
        for fd, a in self.fd_to_agent.items():
            if a.window and now - a.opened_at > self.timeout_s:
                self.rollback(fd, a.node, a.addr)
                expired.append(fd)
        return expired

    # -- 幂等去重（C-15）---------------------------------------------------
    def seen(self, request_id: int) -> bool:
        """True = 这条例已处理过，调用方应丢弃。"""
        if request_id == 0:
            return False
        if request_id in self.dedup_set:
            return True
        if len(self.dedup) == self.dedup.maxlen:
            old = self.dedup.popleft()
            self.dedup_set.discard(old)
        self.dedup.append(request_id)
        self.dedup_set.add(request_id)
        return False

    def replay_dedup(self, fd: int) -> tuple[int, int]:
        """重放 buffer 并按 request_id 去重。返回 (投递数, 跳过数)。"""
        a = self.fd_to_agent.get(fd)
        if not a:
            return (0, 0)
        sent = skipped = 0
        for m in list(a.buffer):
            if self.seen(m.request_id):
                skipped += 1
                continue
            self.delivered.append((fd, m))
            sent += 1
        a.buffer.clear()
        return (sent, skipped)
