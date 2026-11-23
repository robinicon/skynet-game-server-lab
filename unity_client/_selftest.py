"""极简自测框架 —— 与 skynet 各章的 `check()/PASS/FAIL` 输出风格保持一致。

不用 pytest：这套代码要能在没有 pip 的机器上直接 `python xxx_test.py` 跑。
"""

from __future__ import annotations

import sys
import traceback

_ok = 0
_fail = 0
_failures: list[str] = []


def check(name: str, cond, detail="") -> bool:
    """记一条断言。cond 为假则计 FAIL 并打印细节。"""
    global _ok, _fail
    if cond:
        _ok += 1
        print(f"  PASS  {name}")
        return True
    _fail += 1
    msg = f"{name}" + (f"  <{detail}>" if detail != "" else "")
    _failures.append(msg)
    print(f"  FAIL  {msg}")
    return False


def check_raises(name: str, fn, exc_type, expect_code: str | None = None) -> bool:
    """断言某个调用必须抛指定异常（可选校验 .code 字段）。"""
    try:
        fn()
    except exc_type as e:
        got = getattr(e, "code", None)
        if expect_code is not None and got != expect_code:
            return check(name, False, f"code={got} 期望 {expect_code}")
        return check(name, True)
    except Exception as e:  # noqa: BLE001
        return check(name, False, f"抛了 {type(e).__name__}: {e}")
    return check(name, False, "没有抛异常")


def section(title: str) -> None:
    print(f"\n=== {title} ===")


def summary(title: str) -> int:
    """打印汇总并返回进程退出码（0 = 全绿）。"""
    total = _ok + _fail
    print(f"\n{title}: {_ok} PASS, {_fail} FAIL, {total} TOTAL")
    if _fail:
        print("失败项：")
        for f in _failures:
            print(f"  - {f}")
        return 1
    return 0


def guard(fn, title: str = "") -> int:
    """包住整段用例，未捕获异常也让退出码非零。"""
    try:
        fn()
    except Exception:  # noqa: BLE001
        traceback.print_exc()
        global _fail
        _fail += 1
    return summary(title or getattr(fn, "__module__", "suite").replace("__main__", "suite"))


def reset() -> None:
    global _ok, _fail
    _ok = _fail = 0
    _failures.clear()


if __name__ == "__main__":
    check("自测框架可用", True)
    sys.exit(summary("_selftest"))
