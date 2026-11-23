# unity_client · Unity 客户端开源代码集

与 skynet 各章（`ch4_login` ~ `ch12_disconnect`）**同级、同规则**发布的客户端侧代码：
一章一目录、每目录可独立运行验证、零美术资源依赖、MIT。

规则与 skynet 版本完全一致：**部分代码开源 / 美术资源一律不开源 / 仅为片段则掠过 / 非强制**。

> 定位代号统一为 MMO / RPG。本目录与服务端模块各自独立，不刻意强调前后端联动叙事。

## 一、目录 → 篇目映射

| 目录 | 对应篇目 | 提供什么 | 断言数 |
|---|---|---|---|
| [`v03_frame/`](./v03_frame/README.md) | V03 四套信封收敛 | 信封黄金实现 + Lua 参考实现 + 跨语言等价 | 32 |
| [`protocol/`](./protocol) + [`tools/`](./tools) | V04 opcode 单一来源 | 注册表、三端产物生成、只增不改校验 | 1 |
| [`v05_contract/`](./v05_contract/README.md) | V05 契约覆盖度矩阵 | 界面→协议对撞，输出缺口与提案 | 26 |
| [`v06_errcode/`](./v06_errcode/README.md) | V06 登录五条失败分支 | 两套错误码撞车检测 + 语义映射校验 | 23 |
| [`v07_role_schema/`](./v07_role_schema/README.md) | V07 选角与创角 | roles 表结构检查 + v1→v2 迁移 | 23 |
| [`v08_props/`](./v08_props/README.md) | V08 进服与属性同步 | 泳道编解码、增量 diff、槽位冲突检测 | 29 |
| [`v09_reconnect/`](./v09_reconnect/README.md) | V09 断线不是接着玩 | 退避序列、预算、五状态状态机 | 26 |
| [`v10_jump/`](./v10_jump/README.md) | V10 跳转窗口期 | 缓存重放、回滚、超时、溢出、去重 | 31 |
| [`v12_art_pipeline/`](./v12_art_pipeline/README.md) | V12 美术资源 AI 化边界 | manifest 校验 + 入库前图片质检 | 24 |
| [`v13_build/`](./v13_build/README.md) | V13 / V14 / V15 出包 | Android / iOS / 小游戏检查器 | 39 |
| [`v16_gate/`](./v16_gate/README.md) | V16 联调验收 | 四关门禁 + 回滚清单检查 | 22 |

**合计 276 条断言，全绿。**

## 二、一条命令跑完

```bash
python unity_client/run_tests.py              # 全部
python unity_client/run_tests.py v03 v06      # 指定篇目
python unity_client/run_tests.py --list       # 列出模块
```

依赖：Python 3.10+、PyYAML（v05）、Pillow（v12）。跨语言等价项额外需要 WSL 里的 `lua`，
缺失时该项明确报"环境缺失"而不是静默通过。

## 三、未开源（掠过及原因）

| 篇目 | 内容 | 处置 | 原因 |
|---|---|---|---|
| V01 | 仓库基线（体积/版本/脚本数） | 掠过 | 是只读外部仓库的统计命令，无本仓库代码 |
| V02 | 空场景与 9 个 prefab | 掠过 | prefab / 场景属美术资产；只引用文件名，不引用内部结构 |
| V11 | 编辑器 AI 助手 | 掠过 | C 档方法笔记，无配套工程；只有目录约定与环境变量说明 |
| — | `tools/unity-mcp/**` | 掠过 | 第三方 AssetStore 包测试工程，非自有代码 |
| — | `_legacy_excluded/NGUI-Examples/**` | 掠过 | 美术资源 + NGUI 示例 |
| — | `screenshots/**`、`*.png/.psd/.fbx/.prefab/.mat/.anim` | 掠过 | 美术资源，一律不开源 |
| — | `tools/dev/*.ps1` | 掠过 | 硬编码本机绝对路径，不可独立复现 |
| — | `client/` | 掠过 | 原工程标注"阶段3 展开"，实际目录不存在 |

V12 虽然讲美术 AI 化，但开源的是**规则与校验器**，不是任何图片。测试图由 PIL 现场生成。

## 四、protocol / tools（V04 底座，保持原始层级）

脚本内部用 `parents[2]` 定位根目录，**层级不可改动**。

```
protocol/
├── opcode_registry.yaml      # opcode 唯一来源（只增不改），22 项 / v3
├── opcode_snapshot.yaml      # 只增不改校验快照（源状态为 v2）
├── protos/                   # 5 个 proto2 契约（客户端 ↔ 认证/选服/游戏/存储）
└── gen/
    ├── gen_opcodes.py        # 注册表 → C++ / C# / Lua 三端产物生成器
    ├── Opcode.cs             # C# 产物（Unity 客户端接入用）
    ├── opcode.h              # C++ 产物（协议对照用）
    └── opcode.lua            # Lua 产物（skynet 侧协议对照用）
tools/
├── checkers/check_opcode.py  # 「只增不改」CI 校验器
└── config_pipeline/csv2lua.py# CSV → 只读 Lua 配置表构建期管线
```

说明：

- 生成器以 `opcode_registry.yaml` 为唯一来源，按 `(channel << 16) | id` 组合，并检测重复值。
- 校验器比对 registry 与快照：新增放行、修改/删除/复用打回（`exit 1`）。快照已与 registry 同步到 **v3**，
  所以 `run_tests.py` 是幂等的——跑多少次都不会改工作区。若想亲眼看"新增放行"这一分支，
  把 `opcode_snapshot.yaml` 手工回退到 v2 再跑一次，校验器会检测到 v3 新增的两个版本门禁 opcode
  （`CLI_VERSION_CHECK_REQ/RSP`）并自动升级快照——这是设计行为，非错误。
- 三端产物哈希一致性已实测：重新生成前后 `Opcode.cs` / `opcode.h` / `opcode.lua` 的 SHA-256 完全一致。

## 五、开源红线

1. **美术资源一律不入库**：图片、模型、动画、prefab、场景、字体，一条都不放。
2. **蓝本代码只引用不复制**：`setuppf/GameBookClient` 是 MIT，但本目录不复制其代码，
   只引用文件名、行号与结构做分析（V01/V02 的处理方式）。
3. **片段即掠过**：不能独立跑起来的零散片段不收录，避免"看起来开源了、实际用不了"。
4. **不编数据**：所有检查器读真实文件或由测试构造，不内置"估算值"冒充实测。

## 六、许可证

[MIT](../LICENSE)（沿用仓库根许可证）。
