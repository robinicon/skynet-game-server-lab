#!/usr/bin/env python3
"""CSV → Lua 配置管线（构建期生成，运行时只 load 产物）

输入约定（继承一期 C/S/B 前缀分流语义）：
  C_xxx.csv  → config/share_data/xxx.lua     （客户端+服务器共用）
  S_xxx.csv  → config/server_data/xxx.lua    （仅服务器）
  B_xxx.csv  → 两边都生成

CSV 格式：首行表头（第一列必须为 id），其余列按字符串/数字自动推断。
产物为只读 Lua 表：configs.xxx[id] = {...}

用法: python tools/config_pipeline/csv2lua.py [--config DIR] [--out-root DIR]
"""
import argparse
import csv
import hashlib
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]


def cell(v: str):
    v = v.strip()
    if v == "":
        return None
    try:
        f = float(v)
        return int(f) if f.is_integer() and "." not in v and "e" not in v.lower() else f
    except ValueError:
        return v


def lua_value(v):
    if v is None:
        return "nil"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return str(v)
    return '"' + str(v).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def csv_to_lua(csv_path: pathlib.Path):
    with csv_path.open(encoding="utf-8-sig") as f:
        rows = list(csv.reader(f))
    if len(rows) < 2:
        sys.exit(f"[错误] {csv_path.name} 至少需要表头+一行数据")
    headers = [h.strip() for h in rows[0]]
    if headers[0] != "id":
        sys.exit(f"[错误] {csv_path.name} 首列必须为 id")
    entries = []
    for r in rows[1:]:
        if not r or not r[0].strip():
            continue
        fields = ", ".join(f"{h} = {lua_value(cell(v))}" for h, v in zip(headers, r))
        entries.append(f"  [{lua_value(cell(r[0]))}] = {{{fields}}},")
    name = csv_path.stem[2:]  # 去掉 C_/S_/B_ 前缀
    return "\n".join([
        f"-- 由 csv2lua.py 生成自 {csv_path.name} · 禁止手改",
        f"local data = {{",
        *entries,
        "}",
        "local wrapped = setmetatable({}, {",
        "  __index = data,",
        f'  __newindex = function(_, k) error("配置只读({name}): " .. tostring(k), 2) end,',
        "  __metatable = false,",
        "})",
        f"configs = configs or {{}}",
        f"configs.{name} = wrapped",
        f"return wrapped",
    ]) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default=str(ROOT / "config" / "csv"))
    ap.add_argument("--out-root", default=str(ROOT / "config"))
    args = ap.parse_args()
    csv_dir = pathlib.Path(args.config)
    if not csv_dir.exists():
        print(f"[跳过] 无 CSV 目录: {csv_dir}")
        return
    hashes = {}
    for csv_path in sorted(csv_dir.glob("*.csv")):
        prefix, name = csv_path.stem[:1], csv_path.stem[2:]
        targets = {"C": ["share_data"], "S": ["server_data"], "B": ["share_data", "server_data"]}.get(prefix)
        if not targets:
            sys.exit(f"[错误] {csv_path.name} 前缀必须是 C_/S_/B_")
        content = csv_to_lua(csv_path)
        hashes[name] = hashlib.sha256(content.encode()).hexdigest()[:16]
        for t in targets:
            out = pathlib.Path(args.out_root) / t / f"{name}.lua"
            out.parent.mkdir(parents=True, exist_ok=True)
            out.write_text(content, encoding="utf-8")
            print(f"[OK] {csv_path.name} -> {out.relative_to(ROOT)}")
    manifest = pathlib.Path(args.out_root) / "config_manifest.yaml"
    manifest.write_text(
        "# csv2lua.py 产物清单 · 双端一致性校验用\n" +
        "\n".join(f"{k}: {v}" for k, v in hashes.items()) + "\n",
        encoding="utf-8")
    print(f"[OK] 产物清单 -> {manifest.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
