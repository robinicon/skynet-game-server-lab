"""信封层黄金实现（golden implementation）—— V03 配套代码。

这不是客户端运行时。它是"契约的单一可执行定义"：C# 客户端、Lua 网关、
测试用例三端都以本文件的字节序列为准，任何一端实现漂移都能被 test_frame.py 抓到。

正式帧（方案 A + 过渡期魔数）：
    [len:u32 BE][ver:u8][opcode:u32 BE][payload]
    len = 1(ver) + 4(opcode) + len(payload)，不含 len 自身 4 字节

ver：0x02 = 新帧（protobuf），0x01 = 旧帧（sproto，仅过渡期存在）
opcode = channel << 16 | id

C-21 的教训写进了 sniff_legacy()：不能用"首字节"判别新旧——
小包 len 高位是 0x00，旧 sproto 首字节也常是 0x00，必然撞车。
"""

from __future__ import annotations

import struct
from dataclasses import dataclass

MAGIC_V2 = 0x02          # 新信封
MAGIC_V1 = 0x01          # 过渡期旧信封
HEADER_LEN = 9           # 4(len) + 1(ver) + 4(opcode)
MAX_FRAME = 1 << 20      # 1 MiB 硬上限，防御性拒绝

# 通道号，与 opcode_registry.yaml 一致
CHANNEL_AUTH = 0x0006
CHANNEL_CLI = 0x0001
CHANNEL_DG = 0x0007
CHANNEL_CL = 0x0008


class FrameError(Exception):
    """信封层错误。带 code 便于服务端映射成关闭码，而不是一律'解析失败'。"""

    def __init__(self, code: str, detail: str = ""):
        super().__init__(f"{code}: {detail}" if detail else code)
        self.code = code
        self.detail = detail


@dataclass(frozen=True)
class Frame:
    opcode: int
    payload: bytes
    ver: int = MAGIC_V2

    @property
    def channel(self) -> int:
        return (self.opcode >> 16) & 0xFFFF

    @property
    def msg_id(self) -> int:
        return self.opcode & 0xFFFF


def make_opcode(channel: int, msg_id: int) -> int:
    if not (0 <= channel <= 0xFFFF and 0 <= msg_id <= 0xFFFF):
        raise FrameError("BAD_OPCODE", f"channel={channel} id={msg_id} 越界")
    return (channel << 16) | msg_id


def encode(opcode: int, payload: bytes = b"", ver: int = MAGIC_V2) -> bytes:
    """组一个完整帧（含 4 字节长度头）。"""
    if not isinstance(payload, (bytes, bytearray)):
        raise FrameError("BAD_PAYLOAD", f"需要 bytes，得到 {type(payload).__name__}")
    body_len = 1 + 4 + len(payload)
    if body_len > MAX_FRAME:
        raise FrameError("FRAME_TOO_LARGE", f"{body_len}B > {MAX_FRAME}B")
    return struct.pack(">IBI", body_len, ver, opcode) + bytes(payload)


def decode(buf: bytes) -> Frame:
    """解一个完整帧。长度不足 / 超限 / 版本未知都抛 FrameError。"""
    if len(buf) < HEADER_LEN:
        raise FrameError("FRAME_TOO_SHORT", f"{len(buf)}B < {HEADER_LEN}B")

    body_len, ver, opcode = struct.unpack(">IBI", buf[:HEADER_LEN])
    if body_len < 5 or body_len > MAX_FRAME:
        raise FrameError("BAD_LENGTH_FIELD", f"len={body_len}")
    if ver not in (MAGIC_V1, MAGIC_V2):
        raise FrameError("BAD_VERSION", f"ver=0x{ver:02x}")
    if len(buf) != 4 + body_len:
        raise FrameError("LENGTH_MISMATCH", f"声明 {body_len}B，实际 {len(buf) - 4}B")
    return Frame(opcode=opcode, payload=buf[HEADER_LEN:], ver=ver)


def sniff(buf: bytes) -> int:
    """读版本字节（第 5 字节）。

    这是 C-21 的修复形态：判别位放在固定偏移 4，而不是"首字节"。
    """
    if len(buf) < 5:
        raise FrameError("FRAME_TOO_SHORT", f"{len(buf)}B，无法判别版本")
    return buf[4]


def sniff_legacy_naive(buf: bytes) -> str:
    """C-21 的错误做法，保留用于回归演示：按首字节猜新旧。

    len=51 的新帧首字节是 0x00；旧 sproto 小包首字节也常是 0x00 —— 判别必然失效。
    不要在生产代码里用它。
    """
    return "new" if buf and buf[0] >= 0x02 else "legacy"


def split_stream(stream: bytes) -> list[Frame]:
    """从粘包字节流里切出多帧（netpack 语义：4 字节长度头，可一次收到多帧）。"""
    out, off = [], 0
    while off < len(stream):
        if off + 4 > len(stream):
            raise FrameError("TRUNCATED_HEADER", f"offset={off}")
        (body_len,) = struct.unpack(">I", stream[off:off + 4])
        if body_len < 5 or body_len > MAX_FRAME:
            raise FrameError("BAD_LENGTH_FIELD", f"offset={off} len={body_len}")
        end = off + 4 + body_len
        if end > len(stream):
            raise FrameError("TRUNCATED_BODY", f"need {end-off}B, have {len(stream)-off}B")
        out.append(decode(stream[off:end]))
        off = end
    return out


def hexdump(frame_bytes: bytes) -> str:
    """给联调用的可读转储，V03 正文里那张帧示例就是这么来的。"""
    f = decode(frame_bytes)
    head = frame_bytes[:HEADER_LEN]
    return (
        f"len={struct.unpack('>I', head[:4])[0]:<6d} "
        f"ver=0x{f.ver:02x}  opcode=0x{f.opcode:08X} "
        f"(ch=0x{f.channel:04X} id=0x{f.msg_id:04X}) payload={len(f.payload)}B\n"
        f"  bytes: {' '.join(f'{b:02x}' for b in head)} ..."
    )
