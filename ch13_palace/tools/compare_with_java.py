#!/usr/bin/env python3
"""compare_with_java.py — 批次对账门禁

用法（WSL，工程根目录）：
    python3 tools/compare_with_java.py --batch hero
    python3 tools/compare_with_java.py --batch all
    python3 tools/compare_with_java.py --sample docs/samples/hero.json --verbose
    python3 tools/compare_with_java.py --batch hero --record   # 审核后刷新基线

工作原理：
    1. 读 docs/samples/<batch>.json：每个 case 有 seed / op / params / expect
    2. 起一个 skynet 进程跑 service/replay.lua，在干净实体上逐条回放
    3. 比对 err、result（子集）、state（点路径），输出差异表；有差异即非零退出

expect 的语义是「必须成立的部分」，不要求逐字段全等：
    result 里写了什么就比什么，没写的不管
    state 用 "heroes.h1.lv" 这类路径点名，期望 null 表示该键应缺失
"""

import argparse
import json
import os
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
SKYNET = ROOT.parent / "skynet" / "skynet"
CONF = "conf/skynet.conf"
SAMPLES = ROOT / "docs" / "samples"
MISSING = object()


def resolve(obj, path):
    """按点路径取值；空/缺键/类型不匹配都返回 MISSING。"""
    cur = obj
    for part in path.split("."):
        if isinstance(cur, dict):
            if part in cur:
                cur = cur[part]
                continue
            try:
                num = int(part)
            except ValueError:
                return MISSING
            if num in cur:
                cur = cur[num]
                continue
            return MISSING
        if isinstance(cur, list):
            try:
                idx = int(part)
            except ValueError:
                return MISSING
            if 0 <= idx < len(cur):
                cur = cur[idx]
                continue
            return MISSING
        return MISSING
    return cur


def same(a, b):
    if isinstance(a, bool) or isinstance(b, bool):
        return a is b or a == b
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        return abs(float(a) - float(b)) < 1e-9
    return a == b


def diff_result(expected, actual, prefix, out):
    """期望是实际值的子集：只校验期望里出现的键。"""
    if isinstance(expected, dict):
        if not isinstance(actual, dict):
            out.append((prefix or "<result>", expected, actual))
            return
        for k, v in expected.items():
            nxt = "%s.%s" % (prefix, k) if prefix else k
            if k not in actual:
                out.append((nxt, v, MISSING))
            else:
                diff_result(v, actual[k], nxt, out)
    elif isinstance(expected, list):
        if not isinstance(actual, list) or len(actual) != len(expected):
            out.append((prefix, expected, actual))
            return
        for i, v in enumerate(expected):
            diff_result(v, actual[i], "%s[%d]" % (prefix, i), out)
    else:
        if not same(expected, actual):
            out.append((prefix, expected, actual))


def run_replay(sample_path, driver):
    out_path = pathlib.Path(tempfile.gettempdir()) / ("ch13_replay_%s_%d.json" % (sample_path.stem, os.getpid()))
    env = dict(os.environ)
    env["CH13_REPLAY_FILE"] = str(sample_path)
    env["CH13_REPLAY_OUT"] = str(out_path)
    env["CH13_SNAPSHOT"] = str(pathlib.Path(tempfile.gettempdir()) / "ch13_replay_snapshot.json")
    env["CH13_TEST_TARGET"] = "__none__"
    env["CH13_DB_DRIVER"] = driver
    env.pop("CH13_GATE_PORT", None)

    proc = subprocess.run(
        [str(SKYNET), CONF], cwd=str(ROOT), env=env,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180,
    )
    log = proc.stdout.decode("utf-8", "replace")
    if proc.returncode != 0 or not out_path.exists():
        raise RuntimeError("replay failed (rc=%s)\n%s" % (proc.returncode, log[-4000:]))
    doc = json.loads(out_path.read_text(encoding="utf-8"))
    return doc


def check_sample(sample_path, driver, verbose):
    sample = json.loads(sample_path.read_text(encoding="utf-8"))
    got = run_replay(sample_path, driver)
    got_by_name = {c.get("name"): c for c in got.get("cases", [])}

    failures = []
    checked = 0
    for case in sample.get("cases", []):
        name = case.get("name")
        expect = case.get("expect", {})
        actual = got_by_name.get(name)
        problems = []
        if actual is None:
            problems.append(("<case>", "case executed", "missing from replay output"))
        else:
            if "err" in expect and not same(expect["err"], actual.get("err")):
                problems.append(("err", expect["err"], actual.get("err")))
            if "result" in expect:
                diff_result(expect["result"], actual.get("result") or {}, "result", problems)
            state = actual.get("state") or {}
            for path, want in (expect.get("state") or {}).items():
                have = resolve(state, path)
                if want is None:
                    if have is not MISSING and have is not None:
                        problems.append(("state." + path, None, have))
                elif have is MISSING:
                    problems.append(("state." + path, want, MISSING))
                elif not same(want, have):
                    problems.append(("state." + path, want, have))

        checked += 1
        if problems:
            failures.append((name, case.get("derivation", ""), problems))
            print("  FAIL  %-36s %s" % (name, case.get("derivation", "")[:60]))
            for path, want, have in problems:
                print("          %-28s want=%r got=%r" % (path, want, have))
        elif verbose:
            print("  ok    %-36s (%d assertions)" % (name, 1 + len(expect.get("result") or {}) +
                                                     len(expect.get("state") or {})))

    return checked, failures, sample, got


def record(sample, got):
    by_name = {c.get("name"): c for c in got.get("cases", [])}
    for case in sample.get("cases", []):
        actual = by_name.get(case.get("name"))
        if not actual:
            continue
        case["expect"] = {
            "err": actual.get("err"),
            "result": actual.get("result") or {},
            "state": {},
        }
    return sample


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--batch", default="all", help="hero | item | mission | all")
    ap.add_argument("--sample", help="直接指定样本文件（覆盖 --batch）")
    ap.add_argument("--driver", default=os.environ.get("CH13_DB_DRIVER", "memory"),
                    help="memory | mysql（默认 memory）")
    ap.add_argument("--record", action="store_true", help="用当前输出刷新基线（需人工审核后再提交）")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args(argv)

    if not SKYNET.exists():
        print("skynet binary not found: %s" % SKYNET)
        return 2

    if args.sample:
        samples = [pathlib.Path(args.sample)]
    elif args.batch == "all":
        samples = sorted(SAMPLES.glob("*.json"))
    else:
        samples = [SAMPLES / ("%s.json" % args.batch)]

    total_checked, total_fail = 0, 0
    for path in samples:
        if not path.exists():
            print("sample missing: %s" % path)
            return 2
        print("== %s (driver=%s)" % (path.name, args.driver))
        checked, failures, sample, got = check_sample(path, args.driver, args.verbose)
        total_checked += checked
        total_fail += len(failures)
        print("   %d cases, %d failed" % (checked, len(failures)))
        if args.record:
            refreshed = record(sample, got)
            path.write_text(json.dumps(refreshed, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            print("   baseline recorded -> %s (review the diff before committing)" % path)

    print("\n=== RECONCILE: %d cases, %d failed ===" % (total_checked, total_fail))
    return 1 if total_fail else 0


if __name__ == "__main__":
    sys.exit(main())
