"""V16 门禁自测：用可注入传输模拟三种服务端，验证判定逻辑。

三种场景：
  A. 正常服务端 —— 四关全过
  B. 管理面裸奔（C-44：空 token 放行）—— 必须被抓住
  C. 版本门禁失效 —— 必须被抓住

不启任何真实服务，所以能在 CI 里稳定跑。
"""

from __future__ import annotations

import json
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)

import _selftest as T  # noqa: E402
import gate as G  # noqa: E402
from _selftest import check, section  # noqa: E402


class Fake:
    """可编程的假服务端。"""

    def __init__(self, gm_auth: str = "strict", force_update: bool = True,
                 health_ok: bool = True):
        self.gm_auth = gm_auth            # strict | open | empty_only_open
        self.force_update = force_update
        self.health_ok = health_ok
        self.calls: list[str] = []

    def get(self, url, headers=None):
        self.calls.append(f"GET {url}")
        if url.endswith("/health"):
            return 200, json.dumps({"ok": self.health_ok, "uptime": 12})
        return 404, "not found"

    def post(self, url, data=None, headers=None):
        data = data or {}
        self.calls.append(f"POST {url} {data}")
        if not url.endswith("/gm"):
            return 404, "not found"

        auth = (headers or {}).get("Authorization")
        if self.gm_auth == "open":
            pass                                      # 完全不校验
        elif self.gm_auth == "empty_only_open":
            if auth is None:                          # 不带头 → 放行（C-44 形态）
                pass
            elif auth.strip() == "Bearer":            # 空 token → 放行
                pass
            elif not auth.startswith("Bearer "):
                return 401, "unauthorized"
        else:
            if not auth or auth.strip() == "Bearer":
                return 401, "unauthorized"

        if data.get("command") == "check_version":
            return 200, json.dumps({"force_update": self.force_update})
        return 200, json.dumps({"ok": True})


def checker(t: Fake, token: str | None = "test-token") -> G.GateChecker:
    return G.GateChecker(base="http://fake", token=token, transport=t)


def test_healthy():
    section("A. 正常服务端：四关全过")
    t = Fake()
    rs = checker(t).run()
    check("health 通过", rs[0].ok, rs[0].detail)
    check("version_gate 通过", rs[1].ok, rs[1].detail)
    check("unauthorized 通过", rs[2].ok, rs[2].detail)
    check("empty_token 通过", rs[3].ok, rs[3].detail)
    check("四关总数 4 且全过", len(rs) == 4 and all(r.ok for r in rs))


def test_open_admin():
    section("B. 管理面裸奔（C-44）：必须被抓住")
    rs = checker(Fake(gm_auth="open")).run()
    check("health 仍通过", rs[0].ok)
    check("unauthorized 失败（不带 token 也 200）", not rs[2].ok, rs[2].detail)
    check("诊断指向 C-44", "C-44" in rs[2].detail, rs[2].detail)
    check("empty_token 也失败", not rs[3].ok, rs[3].detail)


def test_empty_only():
    section("B2. 只对空 token 放行（ch9 的真实形态）")
    rs = checker(Fake(gm_auth="empty_only_open")).run()
    check("不带 Authorization 头 → 200，被抓", not rs[2].ok, rs[2].detail)
    check("空 Bearer → 200，被抓", not rs[3].ok, rs[3].detail)


def test_gate_broken():
    section("C. 版本门禁失效")
    rs = checker(Fake(force_update=False)).run()
    check("version_gate 失败", not rs[1].ok, rs[1].detail)
    check("提示 force_update=false", "force_update" in rs[1].detail)


def test_health_broken():
    section("C2. health 不健康 / 服务不可达")
    rs = checker(Fake(health_ok=False)).run()
    check("ok=false 被判失败", not rs[0].ok, rs[0].detail)

    class Down:
        def get(self, url, headers=None):
            return 0, "connection refused"

        def post(self, url, data=None, headers=None):
            return 0, "connection refused"

    rs = checker(Down()).run()
    check("服务不可达时 health 失败", not rs[0].ok)
    check("服务不可达不会抛异常，四关都给出结论", len(rs) == 4)


def test_no_token():
    section("未配置 token 时，管理面检查应拒绝而不是放行")
    t = Fake(gm_auth="strict")
    rs = checker(t, token=None).run()
    check("无 token 时 unauthorized 通过（因为服务端确实要求鉴权）", rs[2].ok, rs[2].detail)
    check("无 token 时 empty_token 通过", rs[3].ok)


def test_rollback_dir():
    section("回滚清单静态检查")
    with tempfile.TemporaryDirectory() as tmp:
        missing = G.check_rollback_dir(tmp)
        check("空目录报缺 4 项", len(missing) == 4, len(missing))
        check("缺项带说明", all("（" in m for m in missing))

        for fn in G.ROLLBACK_FILES:
            with open(os.path.join(tmp, fn), "w", encoding="utf-8") as f:
                f.write("# 占位\n")
        check("补齐后通过", G.check_rollback_dir(tmp) == [])

    check("目录不存在也有明确报错",
          "不存在" in G.check_rollback_dir(os.path.join(HERE, "__nope__"))[0])


def main():
    test_healthy()
    test_open_admin()
    test_empty_only()
    test_gate_broken()
    test_health_broken()
    test_no_token()
    test_rollback_dir()
    return T.summary("V16 gate")


if __name__ == "__main__":
    sys.exit(T.guard(main, "V16 gate"))
