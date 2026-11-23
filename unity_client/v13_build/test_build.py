"""V13/V14/V15 出包检查自测。

用构造的 ProjectSettings 文本验证"坏配置能拦住、好配置能通过"，
不依赖本机是否真的装了 Unity / Android SDK。
"""

from __future__ import annotations

import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)

import _selftest as T  # noqa: E402
import check_android as A  # noqa: E402
import check_ios as I  # noqa: E402
import check_minigame as MG  # noqa: E402
import project_settings as PS  # noqa: E402
from _selftest import check, section  # noqa: E402

# 复刻参考工程现状：ARMv7-only、scriptingBackend 空、包名空
BROKEN = """%YAML 1.1
%TAG !u! tag:unity3d.com,2011:
--- !u!129 &1
PlayerSettings:
  m_ObjectHideFlags: 0
  AndroidTargetArchitectures: 1
  scriptingBackend: {}
  applicationIdentifier: {}
  bundleVersion: 0.1
  AndroidBundleVersionCode: 1
  AndroidMinSdkVersion: 22
  AndroidTargetSdkVersion: 0
"""

FIXED = """%YAML 1.1
%TAG !u! tag:unity3d.com,2011:
--- !u!129 &1
PlayerSettings:
  m_ObjectHideFlags: 0
  AndroidTargetArchitectures: 3
  scriptingBackend:
    Android: 1
    iPhone: 1
  applicationIdentifier:
    Android: com.example.game
    iPhone: com.example.game
  bundleVersion: 1.0.0
  AndroidBundleVersionCode: 7
  AndroidMinSdkVersion: 23
  AndroidTargetSdkVersion: 33
  iOSTargetOSVersionString: 12.0
"""


def test_parse():
    section("解析：位掩码与嵌套 map")
    s = PS.parse(BROKEN)
    check("arch 读出 1", s["AndroidTargetArchitectures"] == 1)
    check("scriptingBackend 空 map", s["scriptingBackend"] == {})
    # Unity 里 bundleVersion 语义是字符串；解析层把它当数字，取值时归一
    check("bundleVersion 归一为字符串 '0.1'", PS.bundle_version(s) == "0.1",
          PS.bundle_version(s))
    check("versionCode 读出 1", PS.android_code(s) == 1)
    check("空 map 取子键得 None", PS.sub(s, "scriptingBackend", "Android") is None)

    f = PS.parse(FIXED)
    check("arch 3 = ARMv7+ARM64", PS.arch_name(f["AndroidTargetArchitectures"]) == "ARMv7+ARM64")
    check("Android 后端 1 = IL2CPP", PS.sub(f, "scriptingBackend", "Android") == 1)
    check("android 包名读出", PS.sub(f, "applicationIdentifier", "Android") == "com.example.game")
    check("arch 名称：1 = ARMv7", PS.arch_name(1) == "ARMv7")
    check("后端名称：0 = Mono", PS.scripting_backend_name(0) == "Mono")
    check("后端名称：None 显示未设置",
          PS.scripting_backend_name(None) == "未设置(None)")


def test_android():
    section("V13 Android：三条硬约束")
    bad = A.check(PS.parse(BROKEN))
    check("坏配置至少 3 条", len(bad) >= 3, len(bad))
    check("检出缺 ARM64", any("ARM64" in x for x in bad))
    check("检出 backend 未设", any("scriptingBackend" in x for x in bad))
    check("检出包名为空", any("applicationIdentifier" in x for x in bad))
    check("检出 targetSdk=0 未固定", any("AndroidTargetSdkVersion=0" in x for x in bad))

    good = A.check(PS.parse(FIXED))
    check("修好的配置 0 问题", good == [], good)


def test_ios():
    section("V14 iOS：IL2CPP 与包名")
    bad = I.check_config(PS.parse(BROKEN))
    check("坏配置检出 3 条", len(bad) == 3, bad)
    check("检出 iPhone backend 缺失", any("iPhone" in x for x in bad))
    check("检出 iPhone 包名缺失", any("applicationIdentifier(iPhone)" in x for x in bad))
    check("检出未固定最低系统版本", any("iOSTargetOSVersionString" in x for x in bad))

    good = I.check_config(PS.parse(FIXED))
    check("修好的配置 0 问题", good == [], good)


def test_hotfix_scan():
    section("V14 热更痕迹扫描（2.5.2 红线的可执行证明）")
    with tempfile.TemporaryDirectory() as tmp:
        os.makedirs(os.path.join(tmp, "Scripts"), exist_ok=True)
        with open(os.path.join(tmp, "Scripts", "Loader.cs"), "w", encoding="utf-8") as f:
            f.write("// 正常代码\nclass Loader { void Start() { } }\n")
        hits = I.scan_hotfix(tmp)
        check("干净工程 0 命中", hits == [], hits)

        with open(os.path.join(tmp, "Scripts", "Hot.cs"), "w", encoding="utf-8") as f:
            f.write("using HybridCLR;\nclass Hot { void Load(){ Assembly.Load(bytes); } }\n")
        hits = I.scan_hotfix(tmp)
        check("HybridCLR 命中", any("HybridCLR" in h[2] for h in hits), hits)
        check("Assembly.Load 命中", any("Assembly.Load" in h[2] for h in hits))
        check("命中带行号", all(isinstance(h[1], int) and h[1] > 0 for h in hits))


def _manifest(main_mb: float, sub_mb: float = 0.0) -> dict:
    return {
        "main": [{"path": "dist/webgl.wasm", "bytes": int(main_mb * MG.MB)}],
        "sub": ([{"path": "dist/role.bundle", "bytes": int(sub_mb * MG.MB)}]
                if sub_mb else []),
    }


def test_minigame_budget():
    section("V15 首包预算")
    ok = MG.check_budget(_manifest(3.0, 10.0))
    check("3MB 首包通过", ok == [], ok)

    over = MG.check_budget(_manifest(5.0))
    check("5MB 首包被拦", any("超限" in x for x in over), over)
    check("给出超出的具体开销", any("webgl.wasm" in x for x in over), over)

    huge = MG.check_budget(_manifest(3.0, 20.0))
    check("总包超 20MB 被拦", any("总包" in x for x in huge), huge)

    empty = MG.check_budget({"main": [], "sub": []})
    check("空清单拒绝估算", any("没有 main" in x for x in empty), empty)

    try:
        MG.sum_bytes([{"path": "x", "bytes": "1024"}])
        check("非整数 bytes 应抛错", False)
    except ValueError:
        check("非整数 bytes 抛 ValueError", True)


def test_minigame_transport():
    section("V15 传输：只能 WSS，且必须域名")
    check("wss + 域名通过",
          MG.check_transport("wss://game.example.com/ws") == [])
    check("ws:// 被拦", any("wss://" in x for x in MG.check_transport("ws://a.com/ws")))
    check("IP 直连被拦", any("IP" in x for x in MG.check_transport("wss://1.2.3.4/ws")))
    check("缺 endpoint 被拦", any("未提供" in x for x in MG.check_transport(None)))


def test_minigame_perf():
    section("V15 性能阈值：缺数据就报缺")
    p = MG.check_perf(None, None, None)
    check("三项全缺报 3 条", len(p) == 3, p)
    ok = MG.check_perf(30, 300 * MG.MB, 140)
    check("达标通过", ok == [], ok)
    bad = MG.check_perf(24, 400 * MG.MB, 200)
    check("三项超标都报", len(bad) == 3, bad)


def main():
    test_parse()
    test_android()
    test_ios()
    test_hotfix_scan()
    test_minigame_budget()
    test_minigame_transport()
    test_minigame_perf()
    return T.summary("V13-V15 build")


if __name__ == "__main__":
    sys.exit(T.guard(main, "V13-V15 build"))
