#!/usr/bin/env python3
"""opcode 注册表 → C++ / C# / Lua 三端产物生成器
唯一来源: protocol/opcode_registry.yaml · 只增不改
用法: python tools/gen_opcodes.py [--out DIR]
"""
import argparse
import pathlib
import sys

try:
    import yaml
except ImportError:
    sys.exit("需要 PyYAML: pip install pyyaml")

ROOT = pathlib.Path(__file__).resolve().parents[2]
REGISTRY = ROOT / "protocol" / "opcode_registry.yaml"


def to_hex(v):
    return v if isinstance(v, int) else int(str(v), 16)


def load():
    data = yaml.safe_load(REGISTRY.read_text(encoding="utf-8"))
    channels = {name: to_hex(v) for name, v in data["channels"].items()}
    opcodes = []
    for op in data["opcodes"]:
        ch = op["channel"]
        if ch not in channels:
            sys.exit(f"[错误] opcode {op['name']} 通道 {ch} 未定义")
        value = (channels[ch] << 16) | to_hex(op["id"])
        opcodes.append((op["name"], ch, to_hex(op["id"]), value, op.get("note", "")))
    dup = len(opcodes) - len({o[3] for o in opcodes})
    if dup:
        sys.exit(f"[错误] 存在 {dup} 个重复 opcode 值")
    return data["version"], channels, opcodes


def gen_cpp(version, channels, opcodes):
    lines = [
        "// 由 gen_opcodes.py 生成 · 禁止手改 · 只增不改",
        "#pragma once",
        "#include <cstdint>",
        "#include <string_view>",
        "",
        "namespace mmo {",
        "",
        f"inline constexpr uint32_t kOpcodeRegistryVersion = {version};",
        "",
    ]
    lines.append("enum class Channel : uint16_t {")
    for name, v in channels.items():
        lines.append(f"  {name} = 0x{v:04X},")
    lines.append("};")
    lines.append("")
    lines.append("enum class Opcode : uint32_t {")
    for name, _ch, _id, value, _note in opcodes:
        lines.append(f"  {name} = 0x{value:08X},")
    lines.append("};")
    lines.append("")
    lines.append("inline std::string_view opcode_name(uint32_t v) {")
    lines.append("  switch (v) {")
    for name, _ch, _id, value, _note in opcodes:
        lines.append(f'    case 0x{value:08X}: return "{name}";')
    lines.append('    default: return "UNKNOWN";')
    lines.append("  }")
    lines.append("}")
    lines.append("")
    lines.append("}  // namespace mmo")
    return "\n".join(lines) + "\n"


def gen_lua(version, channels, opcodes):
    lines = [
        "-- 由 gen_opcodes.py 生成 · 禁止手改 · 只增不改",
        "-- 防脏写：挂只读 metatable",
        f"local VERSION = {version}",
        "local t = {}",
        "t.VERSION = VERSION",
    ]
    for name, _ch, _id, value, _note in opcodes:
        lines.append(f"t.{name} = 0x{value:08X}")
    lines += [
        "local frozen = setmetatable({}, {",
        "  __index = t,",
        '  __newindex = function(_, k) error("Opcode 只读，禁止新增/修改: " .. tostring(k), 2) end,',
        "  __metatable = false,",
        "})",
        "Opcode = frozen",
        "return frozen",
    ]
    return "\n".join(lines) + "\n"


def gen_cs(version, channels, opcodes):
    lines = [
        "// 由 gen_opcodes.py 生成 · 禁止手改 · 只增不改",
        "namespace Legend3D.Protocol {",
        f"  public static class OpcodeRegistryVersion {{ public const uint Value = {version}u; }}",
        "  public static class Channel {",
    ]
    for name, v in channels.items():
        lines.append(f"    public const ushort {name} = 0x{v:04X};")
    lines += ["  }", "  public static class Opcode {"]
    for name, _ch, _id, value, _note in opcodes:
        lines.append(f"    public const uint {name} = 0x{value:08X}u;")
    lines += ["  }", "}"]
    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(ROOT / "protocol" / "gen"))
    args = ap.parse_args()
    version, channels, opcodes = load()
    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    (out / "opcode.h").write_text(gen_cpp(version, channels, opcodes), encoding="utf-8")
    (out / "opcode.lua").write_text(gen_lua(version, channels, opcodes), encoding="utf-8")
    (out / "Opcode.cs").write_text(gen_cs(version, channels, opcodes), encoding="utf-8")
    print(f"[OK] 生成 {len(opcodes)} 个 opcode (registry v{version}) -> {out}")


if __name__ == "__main__":
    main()
