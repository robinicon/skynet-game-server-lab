"""Android 出包三条硬约束 —— V13 配套。

对应台账 C-38 / C-39 / C-40：参考工程的配置是"能出包、但装不上/上不了架"的状态。
本脚本把它们变成 rc != 0 的检查，避免"打出来了"被当成"可以发了"。

用法：
    python unity_client/v13_build/check_android.py
    python unity_client/v13_build/check_android.py --file /path/ProjectSettings.asset
"""

from __future__ import annotations

import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import project_settings as PS  # noqa: E402

MIN_SDK = 22
_R_BUNDLE_ID = re.compile(r"^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$")


def check(settings: dict) -> list[str]:
    """返回问题列表。空 = 可以出包。"""
    p: list[str] = []

    arch = settings.get("AndroidTargetArchitectures")
    if not isinstance(arch, int):
        p.append("AndroidTargetArchitectures 缺失 —— 应显式设为 3（ARMv7+ARM64）")
    elif not (arch & 2):
        p.append(f"AndroidTargetArchitectures={arch}（{PS.arch_name(arch)}）缺 ARM64 —— "
                 f"Google Play 与多数国产商店要求 64 位，纯 ARMv7 包会被拒")
    elif arch != 3:
        p.append(f"AndroidTargetArchitectures={arch}（{PS.arch_name(arch)}）非预期组合，"
                 f"建议 3（ARMv7+ARM64）")

    backend = PS.sub(settings, "scriptingBackend", "Android")
    if backend is None:
        p.append("scriptingBackend 未为 Android 显式设置（当前空）—— 默认会落 Mono，"
                 "与 IL2CPP 定案不符；应设为 1")
    elif backend != 1:
        p.append(f"scriptingBackend.Android={backend}（{PS.scripting_backend_name(backend)}）"
                 f"—— 应为 IL2CPP(1)")

    appid = PS.sub(settings, "applicationIdentifier", "Android")
    if not appid:
        p.append("applicationIdentifier 未设置 —— 包名会落到默认 com.DefaultCompany.*，"
                 "无法上架，也不能覆盖安装")
    elif not _R_BUNDLE_ID.match(str(appid)):
        p.append(f"applicationIdentifier `{appid}` 不符合反向域名规范")

    minsdk = settings.get("AndroidMinSdkVersion")
    if isinstance(minsdk, int) and minsdk < MIN_SDK:
        p.append(f"AndroidMinSdkVersion={minsdk} 低于 {MIN_SDK}")

    tsdk = settings.get("AndroidTargetSdkVersion")
    if tsdk == 0:
        p.append("AndroidTargetSdkVersion=0（自动取最高）—— 可接受，但商店审核前应固定，"
                 "否则每次打包目标 API 都在变")

    ver = PS.bundle_version(settings)
    code = PS.android_code(settings)
    if not ver:
        p.append("bundleVersion 未设置")
    if not isinstance(code, int) or code < 1:
        p.append("AndroidBundleVersionCode 缺失或非正数")

    return p


def summary(settings: dict) -> str:
    arch = settings.get("AndroidTargetArchitectures", 0)
    backend = PS.sub(settings, "scriptingBackend", "Android")
    appid = PS.sub(settings, "applicationIdentifier", "Android")
    return (
        f"bundleVersion={PS.bundle_version(settings) or '?'}  "
        f"versionCode={PS.android_code(settings) or '?'}  "
        f"arch={PS.arch_name(arch)}  "
        f"backend={PS.scripting_backend_name(backend)}  "
        f"appId={appid or '未设置'}"
    )


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", default=PS.DEFAULT_PATH)
    args = ap.parse_args(argv)

    if not os.path.isfile(args.file):
        print(f"找不到 {args.file}（用 --file 指定 ProjectSettings.asset）")
        return 2

    s = PS.load(args.file)
    print(summary(s))
    problems = check(s)
    print()
    if problems:
        print(f"Android 出包检查：{len(problems)} 项不通过")
        for x in problems:
            print(f"  ✗ {x}")
        return 1
    print("Android 出包检查：通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
