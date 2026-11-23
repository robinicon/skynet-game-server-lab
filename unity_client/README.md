# unity_client · Unity / MMO 客户端可复用代码子集

从 legend3D 工程整理出的、**与服务端模块同级**发布的客户端侧代码子集。内容均为本项目自建、可独立复现、零美术资源依赖的协议与工具链代码，沿用仓库统一的开源口径（MIT、部分开源、非强制、片段掠过）。

> 定位代号统一为 **MMO / RPG**。本目录与服务端模块各自独立，不刻意强调前后端联动叙事。

## 开源范围（已纳入）

保持原始相对目录结构，脚本内部用 `parents[2]` 定位根目录，层级不可改动。

```
unity_client/
├── protocol/
│   ├── opcode_registry.yaml      # opcode 唯一来源（只增不改），22 项 / v3
│   ├── opcode_snapshot.yaml      # 只增不改校验快照（源状态为 v2，见下方说明）
│   ├── protos/                   # 5 个 proto2 契约（客户端 ↔ 认证/选服/游戏/存储）
│   │   ├── Msg_AUTH.proto
│   │   ├── Msg_CG.proto
│   │   ├── Msg_CL.proto
│   │   ├── Msg_Common.proto
│   │   └── Msg_DG.proto
│   └── gen/
│       ├── gen_opcodes.py        # 注册表 → C++ / C# / Lua 三端产物生成器
│       ├── Opcode.cs             # C# 产物（Unity 客户端接入用）
│       ├── opcode.h              # C++ 产物（服务端/协议对照用）
│       └── opcode.lua            # Lua 产物（skynet 侧协议对照用）
└── tools/
    ├── checkers/
    │   └── check_opcode.py       # opcode「只增不改」CI 校验器
    └── config_pipeline/
        └── csv2lua.py            # CSV → 只读 Lua 配置表构建期管线
```

共 **13 个文件 / 797 行**，全部字节级忠实于 legend3D 源文件。

## 未纳入（掠过及原因）

按既定开源规则（**美术资源一律不开源 / 代码仅为片段则掠过 / 非强制**）逐项判定：

| 源位置 | 内容 | 处置 | 原因 |
|---|---|---|---|
| `tools/unity-mcp/**` | 735 个 `.cs` | 掠过 | 第三方 AssetStore 包测试工程，非本项目自有代码 |
| `_legacy_excluded/NGUI-Examples/**` | 32 个 `.cs` + 贴图/模型/动画 | 掠过 | 美术资源 + NGUI 示例，属禁开源范围 |
| `screenshots/**`、`*.png/.psd/.fbx/.prefab/.mat/.anim` | 运行时截图与美术资产 | 掠过 | 美术资源，一律不开源 |
| `tools/dev/*.ps1` | 本机构建/调度脚本 | 掠过 | 硬编码本机绝对路径，仅为环境片段，不可独立复现 |
| `tools/dev/migrate_assets.py` | 资源迁移工具 | 掠过 | 依赖具体资产台账与本机路径，非通用模块 |
| `client/` | Unity 壳工程 | 掠过 | 标注「阶段3 展开」，实际目录不存在，无内容可整理 |

## 复现（可复现即标准）

依赖 Python 3 + PyYAML（`pip install pyyaml`）。在本目录下执行：

```bash
cd unity_client

# 1. opcode「只增不改」校验（CI 门禁）
python tools/checkers/check_opcode.py

# 2. 重新生成三端产物（应覆盖生成出同样的 Opcode.cs / opcode.h / opcode.lua）
python protocol/gen/gen_opcodes.py
```

说明：

- 生成器以 `protocol/opcode_registry.yaml` 为唯一来源，按 `(channel << 16) | id` 组合 opcode 值，并检测重复值。
- 校验器比对 registry 与快照：新增放行、修改/删除/复用打回（`exit 1`）。随仓库分发的 `opcode_snapshot.yaml` 保持源仓库的 v2 状态；首次运行校验器会检测到 v3 新增的 2 个版本门禁 opcode（`CLI_VERSION_CHECK_REQ/RSP`），按设计自动把快照更新到 v3——这是预期行为，非错误。
- 生成产物验证：本次整理已实测，重新生成前后 `Opcode.cs` / `opcode.h` / `opcode.lua` 的 SHA-256 完全一致。

## 许可证

[MIT](../LICENSE)（沿用仓库根许可证）。
