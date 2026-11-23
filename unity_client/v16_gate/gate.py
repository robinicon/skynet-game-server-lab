"""联调验收门禁 —— V16 配套。

把"发版前必须过的三关"写成可执行检查：
  1. /health 返回 ok=true
  2. 版本门禁：旧版本必须被拦住（force_update=true）
  3. 管理面：不带 token 必须 401

第 3 关专门用来抓台账 C-44：ch9_http 的 `check_token` 对空 token 直接放行，
导致不设 `CH9_GM_TOKEN` 时管理面全开放。检查器不只看状态码，还会判"是不是
把空 token 当成了合法 token"。

传输层可注入，所以不需要真的起服务也能验证判定逻辑（见 test_gate.py）。
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from dataclasses import dataclass, field
from typing import Callable, Protocol

HERE = os.path.dirname(os.path.abspath(__file__))

Response = tuple[int, str]


class Transport(Protocol):
    def get(self, url: str, headers: dict | None = None) -> Response: ...
    def post(self, url: str, data: dict | bytes | None = None,
             headers: dict | None = None) -> Response: ...


class UrllibTransport:
    """真实 HTTP。只用于本机/内网联调，不做重试与连接池。"""

    def __init__(self, timeout: float = 5.0):
        self.timeout = timeout

    def _do(self, req) -> Response:
        import urllib.error
        import urllib.request
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as r:
                return r.status, r.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode("utf-8", "replace")
        except Exception as e:  # noqa: BLE001
            return 0, str(e)

    def get(self, url, headers=None) -> Response:
        import urllib.request
        return self._do(urllib.request.Request(url, headers=headers or {}, method="GET"))

    def post(self, url, data=None, headers=None) -> Response:
        import urllib.request
        body = None
        hdrs = dict(headers or {})
        if isinstance(data, dict):
            body = "&".join(f"{k}={v}" for k, v in data.items()).encode()
            hdrs.setdefault("Content-Type", "application/x-www-form-urlencoded")
        elif isinstance(data, bytes):
            body = data
        return self._do(urllib.request.Request(url, data=body, headers=hdrs, method="POST"))


@dataclass
class Result:
    name: str
    ok: bool
    detail: str = ""


@dataclass
class GateChecker:
    base: str = "http://127.0.0.1:8080"
    token: str | None = None
    transport: Transport = field(default_factory=UrllibTransport)

    # -- 工具 --------------------------------------------------------------
    def _json(self, body: str) -> dict:
        try:
            v = json.loads(body)
            return v if isinstance(v, dict) else {}
        except (json.JSONDecodeError, TypeError):
            return {}

    def _auth(self) -> dict:
        return {"Authorization": f"Bearer {self.token}"} if self.token else {}

    # -- 三关 --------------------------------------------------------------
    def check_health(self) -> Result:
        code, body = self.transport.get(f"{self.base}/health")
        if code != 200:
            return Result("health", False, f"HTTP {code}：{body[:120]}")
        doc = self._json(body)
        if doc.get("ok") is True:
            return Result("health", True, body[:120])
        return Result("health", False, f"ok 不为 true：{body[:120]}")

    def check_version_gate(self, stale_version: str = "0.0.1") -> Result:
        """旧版本必须被拦住。这里用 gm 的 check_version 走管理面。"""
        code, body = self.transport.post(
            f"{self.base}/gm",
            data={"command": "check_version", "client_version": stale_version},
            headers=self._auth(),
        )
        if code != 200:
            return Result("version_gate", False, f"HTTP {code}：{body[:120]}")
        doc = self._json(body)
        if doc.get("force_update") is True:
            return Result("version_gate", True, f"旧版本 {stale_version} 被拦")
        return Result("version_gate", False,
                      f"旧版本 {stale_version} 未被拦（force_update={doc.get('force_update')!r}）")

    def check_unauthorized(self) -> Result:
        """不带 token 必须 401。返回 200 说明管理面无鉴权（C-44）。"""
        code, body = self.transport.post(f"{self.base}/gm", data={"command": "noop"})
        if code == 401:
            return Result("unauthorized", True, "未授权访问被拒")
        if code == 200:
            return Result("unauthorized", False,
                          "不带 token 也返回 200 —— 管理面无鉴权（见台账 C-44："
                          "check_token 对空 token 直接放行）")
        return Result("unauthorized", False, f"HTTP {code}，期望 401")

    def check_empty_token(self) -> Result:
        """显式发空 token，确认不会被当成合法凭据。"""
        code, _ = self.transport.post(f"{self.base}/gm",
                                      data={"command": "noop"},
                                      headers={"Authorization": "Bearer "})
        if code == 401:
            return Result("empty_token", True, "空 token 被拒")
        return Result("empty_token", False,
                      f"空 token 返回 {code} —— 服务端把空串当成了合法 token")

    def run(self) -> list[Result]:
        return [self.check_health(), self.check_version_gate(),
                self.check_unauthorized(), self.check_empty_token()]


# ---- 回滚清单静态检查 -------------------------------------------------------
ROLLBACK_FILES = {
    "01_config_rollback.md": "配置回滚：切 hash → 验证 → 观察 30 min",
    "02_lua_hotfix.md": "Lua 热修：deploy_v2 → 验证 → 必要时切回",
    "03_client_pull.md": "客户端：渠道下架 → 修复 → 重提审",
    "04_incident_log.md": "事故记录模板",
}


def check_rollback_dir(path: str) -> list[str]:
    """回滚清单缺一项，就等于出事时现场编流程。"""
    problems = []
    if not os.path.isdir(path):
        return [f"回滚目录不存在：{path}"]
    for fn, why in ROLLBACK_FILES.items():
        if not os.path.isfile(os.path.join(path, fn)):
            problems.append(f"缺 {fn}（{why}）")
    return problems


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://127.0.0.1:8080")
    ap.add_argument("--token", default=os.environ.get("CH9_GM_TOKEN"))
    ap.add_argument("--rollback-dir", default=os.path.join(HERE, "rollback"))
    args = ap.parse_args(argv)

    results = GateChecker(base=args.base, token=args.token).run()
    for r in results:
        print(f"  {'PASS' if r.ok else 'FAIL'}  {r.name:<14}{r.detail}")

    rollback_problems = check_rollback_dir(args.rollback_dir)
    if rollback_problems:
        print(f"\n回滚清单：{len(rollback_problems)} 项缺失")
        for p in rollback_problems:
            print(f"  ✗ {p}")

    failed = [r for r in results if not r.ok]
    print(f"\n门禁：{len(results) - len(failed)}/{len(results)} 通过"
          + (f"，回滚清单缺 {len(rollback_problems)} 项" if rollback_problems else ""))
    return 1 if (failed or rollback_problems) else 0


if __name__ == "__main__":
    sys.exit(main())
