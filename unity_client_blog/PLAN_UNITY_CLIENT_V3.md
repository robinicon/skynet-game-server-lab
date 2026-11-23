# Unity 客户端联调 skynet · 规划 v3（GameBookClient 主蓝本）

> **本文档相对 v2 的三处修正**：
>
> | 维度 | v2 | **v3（本文）** |
> |---|---|---|
> | 主蓝本 | GameBookClient + legend3D 三端定案并列 | **GameBookClient 为主**，其余仅作参考 |
> | 服务端 | 未指定，隐含 GameBookServer（C++） | **skynet（`ch4_login`–`ch12_disconnect`）** |
> | 主线 | 工业级交付（基线→预算→三端） | **契约收敛 → 覆盖度补齐 → 逐条联调** |
>
> 保留 v2 已被验证的部分：九段式、证据分档、每篇一个交付物、三端发布口径、"不许编"红线。
>
> **口径强制项**（与 `skynet-game-server-lab` 一致）：标题统一 `[Unity 手记]`；不写下篇预告；全文 MMO / RPG；
> 引用必带路径；蓝本未公开处明写"未公开"；开源遵循"部分开源 / MIT / 美术不开源 / 片段即掠过 / 非强制"。

---

## 〇、一句话结论

GameBookClient 提供了**客户端的形**（场景、9 个 prefab、角色资产、打包脚本），skynet 提供了**服务端的实**（登录、存盘、组件、跳转、重连）。
两者之间唯一真正的鸿沟不是业务，是**信封**：客户端契约发 `[opcode:u32 + protobuf]`，skynet 网关收 `[len:u16 + sproto + session:u32]`。

**所以 v3 的第一篇技术文章不写登录，写信封。** 信封不统一，后面每一条联调都是伪联调。

---

## 一、相对 v2 的修正清单

| # | v2 的做法 | v3 的修正 | 原因 |
|---|---|---|---|
| 1 | 以 legend3D 三端定案为核心证据 | 降为**参考**，仅在 iOS/小游戏约束处引用 | 用户指定 GameBookClient 为主蓝本 |
| 2 | 服务端对接面按 GameBookServer 12 章（C++）表述 | 改为 **skynet `ch4`–`ch12`** 的实际模块 | 服务端已用 skynet 重构并开源 |
| 3 | 篇目按"工程能力"组织（打包、场景、UI、预算） | 按**联调顺序**组织（基线 → 信封 → 契约 → 联调 → 三端） | "对标联调"要求每篇有服务端对应物 |
| 4 | 未处理两端协议差异 | 新增第三节「四套信封」与第四节「覆盖度矩阵」 | 这是联调的真实成本所在 |
| 5 | 热更边界单列一篇 | 并入三端篇（iOS 2.5.2 / 小游戏无 JIT 是根因） | 避免与三端篇重复论证 |
| 6 | 16 篇含 4 篇纯工程篇 | 压到 **2 篇基线**，把篇幅让给联调 | 联调是主诉求 |

---

## 二、主蓝本画像（GameBookClient，逐条可核实）

| 事实 | 值 | 出处 |
|---|---|---|
| Unity 版本 | `2018.3.7f1` | `art/ProjectSettings/ProjectVersion.txt` |
| 仓库体积 | `size=66805` KB（约 66 MB） | GitHub API `repos` |
| 业务脚本 | **仅** `Scripts/Editor/BuildAB.cs`（6989 B） | `art/Assets/Scripts/` |
| 程序集 | 仅 `Assembly-CSharp` / `-Editor` | `art/*.csproj` |
| 热更框架 | **无**（无 XLua / ILRuntime / HybridCLR 程序集） | csproj 引用清单 |
| 依赖 | TMP 1.3.0、ads 2.3.1、analytics 3.2.2、purchasing 2.0.3 | `art/Packages/manifest.json` |
| 场景 | `Empty` / `Login` / `Roles` 三者 blob sha 同为 `2826522b14b6763fd1629412802216686786f991`，均 5199 B | Git 对象 |
| UI prefab | 9 个：`Canvas`、`CanvasBG`、`Character (List)`、`Loading Bar`、`Login`、`Modal Box 0/1/2`、`RoleCreate`、`RoleSelect` | `art/Assets/UI/Prefabs/` |
| 角色资产 | `female`(xiaoqiao) / `male`(zhaoyun)，动画 `stand`/`move`/`stand02` | `art/Assets/Avatar/Player/` |

**关键判断**：这个蓝本的客户端**没有任何网络层代码**。所以"联调"不是"把现成的客户端接上服务端"，而是**按它已经定型的 UI 与资产结构，反推需要哪些协议，再把协议补齐**。

这正是它作为主蓝本的价值：**协议清单是被 UI 逼出来的，不是拍脑袋列的。**

---

## 三、联调第一发现：四套信封，互不兼容

### 3.1 对照表（全部可查证）

| 层 | 信封结构 | 序列化 | 代码位置 |
|---|---|---|---|
| **客户端契约**（`unity_client/`） | `[opcode:u32 = channel<<16 \| id][payload]` | **protobuf** | `protocol/opcode_registry.yaml` v3；`gen/Opcode.cs`：`AUTH_LOGIN_REQ = 0x00060001` |
| **skynet ch4 网关** | 上行 `[len:u16][payload][session:u32]`；下行 `[len:u16][content][ok:u8][session:u32]` | **sproto** | `ch4_login/gateway/gated.lua:36`、`:133-140` |
| **skynet ch4 业务包** | `[cmd:u8][payload]`，`cmd=1` Ping / `cmd=2` echo | **sproto** | `ch4_login/service/agent.lua:80-102`、`proto/game.proto` 注释 |
| **参考工程**（legend3D，非本蓝本） | 8B `[len:u32 LE][opcode:u32 LE]` | protobuf | `docs/施工计划/skynet版本施工计划.md:167`（含"4B+2B 勘误"记录） |

> 参考工程的 8B 口径有明确勘误记录：原计划写"4B len + 2B opcode"，实际冻结版为 `[len:u32][opcode:u32]`（`server/src/net/Frame.h`）。
> **这一条只作对照，不写进客户端篇的"事实"里**——本蓝本没有网络层，8B 不是它的实现。

### 3.2 差异清单（五个维度，逐条要补）

| 维度 | 客户端契约 | skynet ch4 | 缺口与后果 |
|---|---|---|---|
| **长度前缀** | 无（依赖 TCP/WS 帧边界） | 网关 2B `u16`（`netpack`） | 客户端必须补长度，或服务端改帧；否则粘包 |
| **消息标识** | `opcode:u32`（channel 高位） | 首包固定 `login_req`，后续 `1B cmd` | **无法表达 AUTH/CLI/DB 三类通道** |
| **序列化** | protobuf（5 个 `Msg_*.proto`） | sproto（`game.proto`） | 同一份消息两套 IDL，必然漂移 |
| **会话关联** | 无字段（需另定请求 id） | 末尾 4B `session` | 上行缺 session，网关取 `message:sub(-4)` 会吃掉 payload |
| **首包语义** | `CLI_VERSION_CHECK`（v3 新增，接入第一帧） | 固定 `login_req` | **版本门禁没有位置安放** |

### 3.3 收敛方案（本篇要给出的交付物）

**方案 A（推荐）：服务端向契约靠**

- 网关改为 `[len:u32][opcode:u32][protobuf payload]`，与 `opcode_registry` 对齐；
- 请求关联用 `opcode` 内的 `request_id`（或在 payload 头部 4B），不再用尾部 session；
- 首包按 `opcode` 分派：`CLI_VERSION_CHECK_REQ` → 版本门禁，`AUTH_LOGIN_REQ` → 认证；
- 好处：**单一 IDL、单一信封**，三端产物（`Opcode.cs` / `opcode.h` / `opcode.lua`）直接可用；
- 代价：改 `gated.lua` + 弃用 `proto/proto.lua` 的 sproto 编解码（约一章工作量）。

**方案 B（不推荐）：客户端加适配层**

把 `opcode` 映射成 sproto tag。代价是双份协议、双份生成器，`只增不改`纪律形同虚设。

**方案 C（过渡期）：双栈判别**

网关读首字节判别：`0x00` 走旧 sproto `login_req`，否则按 `opcode`。用于灰度期，**不作为终态**。

> 交付物：一张「信封收敛决策表」+ 迁移步骤（旧客户端兼容窗口、回滚条件）。
> 这是 v3 系列里唯一必须动服务端代码的一篇，也是后面 8 篇联调的前置。

---

## 四、联调第二发现：契约覆盖度缺口

### 4.1 9 个 prefab × opcode 矩阵

客户端 UI 只做到「登录 → 选角/创角 → 进主界面」，把这条闭环拆成能力，再对契约：

| prefab | 需要的能力 | 契约 opcode（`opcode_registry.yaml` v3） | 状态 |
|---|---|---|---|
| `Canvas` / `CanvasBG` | 壳层 | — | 纯 UI |
| `Login` | 版本校验 → 登录 → 选服 | `CLI_VERSION_CHECK_REQ/RSP`、`AUTH_LOGIN_REQ/RSP`、`CLI_SELECT_SERVER_REQ/RSP` | **已覆盖** |
| `Loading Bar` | 过渡 | — | 纯 UI |
| `Modal Box 0/1/2` | 错误提示 | `Msg_Common.ErrCode`（`ERR_SERVER_FULL`、`ERR_TICKET_EXPIRED` 等） | **已覆盖** |
| `RoleSelect` | **角色列表** | **无** | **缺口** |
| `Character (List)` | 列表项数据 | **无** | **缺口** |
| `RoleCreate` | **创角** | **无** | **缺口** |
| （进主界面） | 进服 + 属性 | `CLI_ENTER_GAME_REQ/RSP`、`CLI_SYNC_PROPS` | **已覆盖** |

### 4.2 缺口的具体形态

- 契约侧：缺 `CLI_ROLE_LIST_REQ/RSP`、`CLI_ROLE_CREATE_REQ/RSP` 两对（**只增不改**，取未占用 id）。
- 服务端侧：`ch4_login/service/agent.lua` 只有 `CMD_PING` / `CMD_ECHO` 两个业务 cmd，没有角色相关 handler。
- 存储侧：`ch7_db` 已有 `RoleLoadReq` / `RoleSaveReq`（`Msg_DG`，DB 通道），**可直接复用**，不必新写存储。
- 客户端侧：`RoleSelect` / `RoleCreate` 的事件绑定无代码可循（蓝本未公开），需自写最小实现并标 B 档。

**结论**：缺的不是"一大块功能"，是**两对 opcode + 两个 agent handler**。这是可控工作量，也是 v3 能在 16 篇内讲清联调的原因。

### 4.3 补齐顺序（不可颠倒）

```
① 信封收敛（V03）→ ② 补 opcode + 三端重新生成（V04/V05）
   → ③ agent 加 role_list/role_create handler，复用 ch7_db（V07）
   → ④ 客户端绑定 RoleSelect/RoleCreate（V07）
   → ⑤ 进服与属性同步联调（V08）
   → ⑥ 断线重连与跳转（V09/V10）
```

---

## 五、三源定位：谁主、谁参考

| 源 | 定位 | 用在哪 | 不许用它做什么 |
|---|---|---|---|
| **`setuppf/GameBookClient`** | **主蓝本**：客户端的形 | 场景、9 prefab、资产规范、打包脚本、程序集反证 | 不许当作"有网络层"；不许编类名 |
| **`bookskynet/ch4–ch12` + `unity_client/protocol`** | **服务端与契约的事实源** | 信封、opcode、模块职责、测试口径 | 不许把服务端内部消息当客户端协议 |
| **`legend3D` 三端定案 / ComfyUI / DSH** | **参考**：约束与方法的旁证 | iOS 2.5.2、小游戏 WSS 与包体、AI 工具链 | 不许写成"本蓝本的实现"；数字标"参考/待复核" |

**证据分档**：A 强证据（有文件/条款，可直接引路径）｜B 设计层（有对应模块但客户端未公开，须免责句）｜C 方法笔记（非本项目实测）。

---

## 六、16 篇总表

**节奏**：每周 1 篇，16 周。Part 1 契约三篇必须最先写（后面全部依赖它）。

| # | 标题 | 档 | 联调对象（skynet） | 交付物 |
|---|---|---|---|---|
| V01 | [Unity 手记] 66 MB 的客户端仓库，业务代码只有 1 个脚本 | A | — | 客户端基线清单 |
| V02 | [Unity 手记] 空场景 + 9 个 prefab：界面与入口不在同一层 | A | — | 场景/prefab 职责表 |
| V03 | [Unity 手记] 客户端发 opcode，服务端收 session：四套信封怎么合成一套 | **A** | `ch4_login/gateway/gated.lua` | 信封收敛决策表 + 迁移步骤 |
| V04 | [Unity 手记] opcode 为什么是 channel<<16\|id：单一来源与只增不改 | A | `unity_client/protocol` | 三端生成 + 校验跑通记录 |
| V05 | [Unity 手记] 9 个 prefab 逼出 4 对 opcode：契约覆盖度矩阵 | A | `ch4_login/service/agent.lua` | 覆盖度矩阵 + 缺口清单 |
| V06 | [Unity 手记] 从 Login.prefab 到 Ticket：登录链路的五条失败分支 | B | `ch4_login` gate/login/center | 状态机 + 超时参数表 |
| V07 | [Unity 手记] 选角与创角：补两对 opcode，复用 ch7_db 的存盘 | B | `ch7_db` + `ch4_login/agent` | 新增 proto/opcode + handler 骨架 |
| V08 | [Unity 手记] 进服与属性同步：SyncProps 泳道对得上组件式 Agent 吗 | B | `ch8_components` | 字段映射表 + 同步频次预算 |
| V09 | [Unity 手记] 断线不是接着玩：offline/rebind 与客户端退避怎么对齐 | B | `ch12_disconnect` | 重连状态机 + 退避表 |
| V10 | [Unity 手记] 跨节点跳转：窗口期缓存对客户端意味着什么 | B | `ch11_jump` | 过场与恢复时序图 |
| V11 | [Unity 手记] 编辑器里的 AI 助手：只在开发机跑，不进玩家包 | C | — | Key 放置规范 + 接入清单 |
| V12 | [Unity 手记] 美术资源 AI 化的边界：CPU 能做什么，必须上云做什么 | B | — | 本机/云端分工表 + manifest 规范 |
| V13 | [Unity 手记] Android 出包：ARM64、IL2CPP 与 targetSdk 的三条硬约束 | A（参考） | — | 出包检查清单 |
| V14 | [Unity 手记] iOS 出包：2.5.2 那条红线，决定了客户端不能热更代码 | A（参考） | — | 审核自查表 + 隐私清单模板 |
| V15 | [Unity 手记] 微信小游戏：只能 WSS，首包 4 MB 怎么活 | A（参考） | `ch4` 的 TCP 帧要改造 | WSS 改造点 + 首包清单 |
| V16 | [Unity 手记] 联调验收：版本门禁、灰度回滚与首日值班 | A | `ch9_http` 管理面 | 门禁脚本 + 回滚手册 |

**档位统计**：A 档 9 篇、B 档 6 篇、C 档 1 篇。
**权重**：Part 1（契约）+ Part 2（联调）共 8 篇，占一半——这是 v3 与 v2 最实质的差别。

---

## 七、逐篇大纲

### Part 0 · 基线（V01–V02）

#### V01 · [Unity 手记] 66 MB 的客户端仓库，业务代码只有 1 个脚本

**档** A ｜ **交付物** 客户端基线清单（一页）

**开篇钩子**：clone 下来 66 MB，打开 `Assets/Scripts`——只有一个 `Editor/BuildAB.cs`，7 KB。剩下全是模型和贴图。这不是残缺，是**公开边界**。

**章节**：
1. 66 MB vs 7 KB：仓库体积不等于代码量（66805 KB / 6989 B）
2. 四目录职责：`Avatar` / `Scenes` / `Scripts` / `UI`
3. 技术栈只从三处读：`ProjectVersion.txt`、`manifest.json`、`*.csproj`
4. 反证法：csproj 里没有 XLua / ILRuntime / HybridCLR → 这个客户端**不做代码热更**（与 V14 呼应）
5. 基线清单模板（版本/依赖/程序集/资源目录/构建入口/许可）
6. 复盘 3 条
7. 已知环境限制：2018.3.7f1；网络层未公开；资产无许可说明
8. 代码与运行：目录树 + 三份配置原文

**配图**：封面 + 四目录职责图 ｜ **数据说明**：66 MB / 7 KB 为仓库原始值

---

#### V02 · [Unity 手记] 空场景 + 9 个 prefab：界面与入口不在同一层

**档** A ｜ **交付物** 场景/prefab 职责表

**开篇钩子**：`Empty`、`Login`、`Roles` 三个场景的 blob sha 一模一样，都是 5199 字节。界面根本不在场景里。

**章节**：
1. 怎么发现：`git hash-object` / Git API 查 sha
2. 9 个 prefab 分层：壳（`Canvas`/`CanvasBG`）/ 流程（`Login`/`RoleSelect`/`RoleCreate`）/ 通用（`Modal Box 0/1/2`）/ 过渡（`Loading Bar`）
3. 为什么"一界面一场景"在这里不成立：切换代价、UI 复用、美术不碰场景层级
4. 代价：调试全靠 prefab 与 Inspector；协作时"界面在哪"不直观
5. **对联调的意义**：UI 分层直接决定协议分组（下篇 V05 的矩阵就是这么来的）
6. 复盘 3 条
7. 已知环境限制：仅文件层推断，未在编辑器验证运行时加载链
8. 代码与运行：查 sha 命令 + prefab 清单

**配图**：封面 + "三场景 → 一空壳 → prefab 实例化"图 ｜ **数据说明**：sha/size 为真实值；加载方式标"待验证"

---

### Part 1 · 契约收敛（V03–V05）

#### V03 · [Unity 手记] 客户端发 opcode，服务端收 session：四套信封怎么合成一套

**档** A ｜ **交付物** 信封收敛决策表 + 迁移步骤 ｜ **联调对象** `ch4_login/gateway/gated.lua`

**开篇钩子**：客户端按 `[opcode:u32][protobuf]` 发，skynet 网关按 `[len:u16][sproto][session:u32]` 收。两边都能编译，接上就是不通——而且报错会指向"解析失败"，指向不了信封。

**章节**：
1. 四套信封并列（客户端契约 / ch4 网关 / ch4 业务包 / 参考工程 8B）
2. 五个维度的差异：长度前缀、消息标识、序列化、会话关联、首包语义
3. 为什么"客户端适配一下"是坏方案：双份 IDL 必然漂移，`只增不改`失效
4. 推荐方案 A：网关改 `[len:u32][opcode:u32][protobuf]`，首包按 opcode 分派
5. 过渡期方案 C：首字节判别双栈，兼容窗口与回滚条件
6. 迁移步骤（改 gate → 跑 ch4 现有测试 → 双栈灰度 → 摘旧路径）
7. 复盘 3 条（第一条：先对齐信封，再谈业务）
8. 已知环境限制：网关改动为设计稿，未提交服务端；ch4 现有 18 断言须全绿才算迁移成功
9. 代码与运行：`gated.lua:36` 与 `:133-140` 原文对照 + 新帧格式示例

**配图**：封面 + 四套信封对照图 ｜ **数据说明**：四处结构均给文件与行号

---

#### V04 · [Unity 手记] opcode 为什么是 channel<<16|id：单一来源与只增不改

**档** A ｜ **交付物** 三端生成 + 校验跑通记录 ｜ **联调对象** `unity_client/protocol`

**开篇钩子**：客户端和服务端各写一份枚举，是最常见的翻车点——两边都能编译，联调时才发现 3 号消息在对面是另一个东西。

**章节**：
1. channel 分组的理由：`CLI/DB/CROSS/GATE/CHAT/AUTH`，高位定通道、低位定消息
2. 生成器怎么算：`value = (channel << 16) | id`（`gen_opcodes.py`）
3. 三端同源：`Opcode.cs` / `opcode.h` / `opcode.lua`，`AUTH_LOGIN_REQ = 0x00060001`
4. 校验器拦什么：重复值、通道未定义、快照回退（`check_opcode.py`、`opcode_snapshot.yaml`）
5. `只增不改`怎么落地：快照对比 + CI 拦截
6. 复盘 3 条
7. 已知环境限制：registry 为 v3；新增 opcode 需同步 `opcode_snapshot.yaml`
8. 代码与运行：生成与校验命令（`python gen_opcodes.py` / `check_opcode.py`）

**配图**：封面 + opcode 位域图 ｜ **数据说明**：哈希一致、校验 rc=0 为实际执行结果

---

#### V05 · [Unity 手记] 9 个 prefab 逼出 4 对 opcode：契约覆盖度矩阵

**档** A ｜ **交付物** 覆盖度矩阵 + 缺口清单 ｜ **联调对象** `ch4_login/service/agent.lua`

**开篇钩子**：把 9 个 prefab 摊开，逐个数它们要什么消息，会发现契约缺了一整块——选角和创角没有 opcode，而服务端 agent 只有 Ping 和 echo。

**章节**：
1. 方法：从 UI 闭环反推能力，再对 opcode（不是先列协议再找界面）
2. 矩阵逐行过：覆盖 6 项、缺口 2 对、纯 UI 3 类
3. 缺口形态：缺 `CLI_ROLE_LIST_REQ/RSP`、`CLI_ROLE_CREATE_REQ/RSP`；agent 缺 handler
4. 好消息：存储不用新写——`ch7_db` 的 `RoleLoadReq`/`RoleSaveReq` 可直接复用
5. 补齐顺序（不可颠倒的 6 步）
6. 复盘 3 条（UI 是协议的第一需求方；缺口要可枚举，不要"感觉还差很多"）
7. 已知环境限制：矩阵基于 registry v3；服务端 handler 为待实现
8. 代码与运行：矩阵表 + 逐 prefab 清单

**配图**：封面 + 覆盖度矩阵图 ｜ **数据说明**：opcode 名称与 id 全部来自 registry v3

---

### Part 2 · 逐条联调（V06–V10）

#### V06 · [Unity 手记] 从 Login.prefab 到 Ticket：登录链路的五条失败分支

**档** B（客户端实现未公开）｜ **交付物** 状态机 + 超时参数表 ｜ **联调对象** `ch4_login`

**开篇钩子**：登录不是一条直线。成功路径只有一条，失败分支有五条，而线上 80% 的工单来自后面那五条。

**章节**：
1. 链路：版本校验 → 建连 → `AUTH_LOGIN_REQ` → Ticket → 选服 → 进服
2. 服务端侧：gate 首包 `login_req` → login → center 发 token（128bit 随机串，不哈希）
3. 状态机：未连接 / 连接中 / 已认证 / 选服中 / 进服
4. 五条失败分支：超时、票据失效（`ERR_TICKET_EXPIRED`）、票据重放（`ERR_TICKET_REPLAY`）、服务器满（`ERR_SERVER_FULL`）、重复登录踢号
5. 超时与重试参数表（心跳、重连退避，标"待实测定参"）
6. 复盘 3 条
7. 已知环境限制：蓝本未公开客户端登录实现；本篇为设计稿
8. 代码与运行：状态机图 + `Login.prefab` 与场景关系

**配图**：封面 + 登录状态机图 ｜ **数据说明**：错误码来自 `shared/error_code.lua` 与 `Msg_Common`

---

#### V07 · [Unity 手记] 选角与创角：补两对 opcode，复用 ch7_db 的存盘

**档** B ｜ **交付物** 新增 proto/opcode + handler 骨架 ｜ **联调对象** `ch7_db` + `ch4_login/agent`

**开篇钩子**：`RoleSelect` 和 `RoleCreate` 两个 prefab 摆在那儿，但契约里没有一条消息能填满它们。补协议不是"加两个字段"，是补齐一条从 UI 到存盘的竖切。

**章节**：
1. 先定契约：`CLI_ROLE_LIST_REQ/RSP`、`CLI_ROLE_CREATE_REQ/RSP`（只增不改，取未占用 id）
2. 复用存储：`Msg_DG.RoleLoadReq` / `RoleSaveReq` 已存在，不新造表
3. 服务端 handler：agent 增两个 cmd，转调 db 服务（ch7 的事务与写合并直接继承）
4. 客户端绑定：列表 → 详情分离（`Character (List)` 与 `RoleSelect` 的关系），创角表单校验
5. 边界：角色数量上限、重名、创建失败回滚
6. 复盘 3 条
7. 已知环境限制：客户端绑定代码为自写最小实现；服务端 handler 待实现
8. 代码与运行：proto 片段 + opcode 注册行 + handler 骨架

**配图**：封面 + 创角竖切图 ｜ **数据说明**：`RoleLoadReq`/`RoleSaveReq` 为既有定义

---

#### V08 · [Unity 手记] 进服与属性同步：SyncProps 泳道对得上组件式 Agent 吗

**档** B ｜ **交付物** 字段映射表 + 同步频次预算 ｜ **联调对象** `ch8_components`

**开篇钩子**：客户端要的是"哪些字段变了"，服务端给的是"组件表里哪一列变了"。两边都叫属性同步，粒度不一样。

**章节**：
1. 契约侧：`CLI_SYNC_PROPS` + `PropValue`（`Msg_Common`）
2. 服务端侧：`ch8_components` 的组件式 Agent——属性归属哪个组件
3. 映射表：组件字段 → 泳道 → 客户端表现
4. 全量兜底 + 增量提效：什么时候必须全量
5. 同步频次预算：与帧率、带宽、小游戏弱网的关系（定性 + 待实测）
6. 复盘 3 条
7. 已知环境限制：客户端表现层未公开；频次为设计目标
8. 代码与运行：映射表 + 消息示例

**配图**：封面 + 属性同步泳道图 ｜ **数据说明**：组件名来自 ch8 实际目录

---

#### V09 · [Unity 手记] 断线不是接着玩：offline/rebind 与客户端退避怎么对齐

**档** B ｜ **交付物** 重连状态机 + 退避表 ｜ **联调对象** `ch12_disconnect`

**开篇钩子**：服务端把连接标记 offline、等新 fd rebind；客户端以为"网卡了一下"。两边对"断线"的定义不同，就会出现回档。

**章节**：
1. 服务端：`gate_reconnect` 的 fd → agent 映射、`on_reconnect(newfd)`、offline 超时
2. 客户端：心跳检测 → 提示 → 重连 → 重新认证 → 重建视图
3. 对齐点：超时时长必须双端一致（`OFFLINE_TIMEOUT_CS` 与服务端一致）
4. 退避策略表（次数/间隔/上限）
5. 失败兜底：重连失败回登录，不是无限重试
6. 复盘 3 条
7. 已知环境限制：客户端实现未公开；本篇为设计层
8. 代码与运行：服务端状态迁移 + 客户端状态机

**配图**：封面 + 断线重连时序图 ｜ **数据说明**：超时常量与 `agent_reconnect.lua` 对齐

---

#### V10 · [Unity 手记] 跨节点跳转：窗口期缓存对客户端意味着什么

**档** B ｜ **交付物** 过场与恢复时序图 ｜ **联调对象** `ch11_jump`

**开篇钩子**：服务端跳转有个"窗口期"，期间消息要缓存重放。客户端如果在这段时间继续发操作，要么被丢，要么被重放两次。

**章节**：
1. 服务端：`scene_host` / `agent_jumper` / `gate_redirect` 三段职责
2. 窗口期是什么：fd 切换期间的消息缓存与重放
3. 客户端侧：锁输入 → 过场（`Loading Bar`）→ 新场景就位 → 恢复控制
4. 幂等：重放的消息客户端要能识别
5. 与 Modal/错误提示的配合（承接 V02）
6. 复盘 3 条
7. 已知环境限制：客户端实现未公开；本篇为设计层
8. 代码与运行：三段服务职责表 + 时序图

**配图**：封面 + 跳转窗口期时序图 ｜ **数据说明**：模块名来自 ch11 实际文件

---

### Part 3 · AI 接入（V11–V12，旁支）

#### V11 · [Unity 手记] 编辑器里的 AI 助手：只在开发机跑，不进玩家包

**档** C（**非本项目实测**）｜ **交付物** Key 放置规范 + 接入清单

**开篇钩子**：给客户端接 AI，最快见效的不是运行时 NPC，而是编辑器工具——不进玩家包，出问题删脚本就回滚。而本蓝本连网络层都没有，从编辑器起步是唯一低风险入口。

**章节**：
1. 为什么从编辑器起步：不进包、可回滚、不占预算
2. 最小链路：EditorWindow → 后端代理 → 模型 → 落盘
3. Key 不进客户端：环境变量或服务端代理（`EditorPrefs` 既不是安全边界，也不是泄露路径，别把因果写反）
4. 能做什么：生成配置草稿、样板代码、批量改名、解释报错
5. 不能做什么：替代编译验证与真机验证
6. 复盘 3 条
7. 已知环境限制：**方法笔记，无配套工程与实测数据**
8. 代码与运行：接入清单（不含 Key）

**配图**：封面 + 编辑器 AI 链路图 ｜ **数据说明**：标注"方法整理，非项目实测"

---

#### V12 · [Unity 手记] 美术资源 AI 化的边界：CPU 能做什么，必须上云做什么

**档** B（文档级方案，带来源标注）｜ **交付物** 本机/云端分工表 + manifest 规范

**开篇钩子**：本蓝本的 66 MB 全是美术资产。想用 AI 补图，先别问"哪个模型好"，先问"这台机器能跑几步"。

**章节**：
1. 硬件先判：只能 `--cpu` 推理【实测】【官方】
2. 两套工作流：SD1.5 + LCM 批量出图 / 参考图 + LoRA 一致性
3. 透明背景三条路线
4. 分工：本机=设计/低频验证，云端=训练/批量生产
5. 工程化：manifest（seed 可复现）、自动质检（透明通道/尺寸）、Unity 导入对接
6. 成本：本机电费 / 云端按小时 / LoRA 单次
7. 复盘 3 条
8. 已知环境限制：数据带原四级标注；未在本项目批量验证
9. 代码与运行：manifest 字段表 + 质检骨架

**配图**：封面 + 本机/云端分工图 ｜ **数据说明**：保留 `【实测】【官方】【社区经验】【推断】`

---

### Part 4 · 三端发布（V13–V16）

#### V13 · [Unity 手记] Android 出包：ARM64、IL2CPP 与 targetSdk 的三条硬约束

**档** A（参考工程定案）｜ **交付物** 出包检查清单

**开篇钩子**：出包不是点一下 Build。三条约束任一不满足，包要么装不上，要么上不了架。

**章节**：
1. ARM64 + IL2CPP：32 位包不能再作为唯一产物
2. targetSdk：按商店当年要求，**不写死版本号**，接入前复核
3. 权限最小化：只申请网络与必要存储
4. 返回键走 UI 栈；分屏下暂停渲染
5. 构建配置核对清单（后端/架构/压缩/签名/版本号）
6. 出包后自检：安装、冷启动、登录、断线重连
7. 复盘 3 条
8. 已知环境限制：参考工程定案，未实机出包；本蓝本为 2018.3，升级到 IL2CPP 需单独验证
9. 代码与运行：检查清单

**配图**：封面 + Android 出包流程 ｜ **数据说明**：约束标"参考定案，待复核"

---

#### V14 · [Unity 手记] iOS 出包：2.5.2 那条红线，决定了客户端不能热更代码

**档** A（参考工程定案）｜ **交付物** 审核自查表 + 隐私清单模板

**开篇钩子**：iOS 审核最贵的不是技术，是来回拒包。2.5.2 一旦踩到，改代码也救不回来——而这条红线恰好解释了，为什么本蓝本 csproj 里没有任何热更程序集。

**章节**：
1. 2.5.2：禁止下载可执行代码 → 客户端只做资源热更（与 V01 反证呼应）
2. `PrivacyInfo.xcprivacy`：声明数据类型与用途
3. ATT：做广告/归因才需要，别为"完整"硬加
4. 账号删除入口：账号删除 ≠ 角色删除
5. 64 位 + IL2CPP + Metal
6. 审核自查表
7. 复盘 3 条
8. 已知环境限制：定案口径，未实际提交审核；条款以审核时版本为准
9. 代码与运行：清单模板 + 提审材料

**配图**：封面 + iOS 审核红线图 ｜ **数据说明**：条款标"审核时版本为准"

---

#### V15 · [Unity 手记] 微信小游戏：只能 WSS，首包 4 MB 怎么活

**档** A（参考工程定案）｜ **交付物** WSS 改造点 + 首包清单

**开篇钩子**：原生端能跑 TCP，小游戏只能 `wx.connectSocket`。而 skynet 的 ch4 网关是按 TCP 的 `netpack` 写的——这一层不改造，小游戏连门都进不去。

**章节**：
1. 硬约束：只能 WSS、无原生 Socket/Thread/System.IO、无 JIT、不能动态加载程序集、不能用 `Application.Quit`
2. 网关改造：TCP `[len:u16][payload][session]` → WSS binary 帧 + `[len:u32][opcode:u32][protobuf]`（承接 V03）
3. 首包 4 MB 怎么切：引擎裁剪、登录/选服/建角、首场景低模、最小音效；其余分包 CDN
4. 域名与证书：ICP 备案 + 受信任 CA，不支持自签
5. 性能预算：30fps、内存 <350 MB、drawcall <150、ASTC/ETC2 双套
6. 复盘 3 条
7. 已知环境限制：限额以当年公告为准（接入前复核）；未实机验证首屏
8. 代码与运行：改造点清单 + 首包清单

**配图**：封面 + 小游戏首包/分包图 ｜ **数据说明**：4 MB / 20 MB 标"公告口径，待复核"

---

#### V16 · [Unity 手记] 联调验收：版本门禁、灰度回滚与首日值班

**档** A ｜ **交付物** 门禁脚本 + 回滚手册 ｜ **联调对象** `ch9_http`

**开篇钩子**：联调通了不等于能上线。上线日期是 `max(团队完工周, 备案下证周 + 2 周)`——这两个日期必须分开汇报。

**章节**：
1. 版本门禁：`CLI_VERSION_CHECK_REQ/RSP` 三版本校验（client/config/resource），不符返回强更，不静默进服
2. 管理面：`ch9_http` 的职责边界（只做运维入口，不放业务）
3. 灰度：10%→100%，回滚 <5 min
4. 压测口径：3000 CCU、p99 <50 ms（设计目标，非实测普遍结论）
5. 合规外部轨道：备案/版号典型 3–6 个月；**未下证不可发布**，可先出包/内测/灰度
6. 上线检查单：备份、监控、告警、容量，每项有责任人与验证命令
7. 首日值班：应急预案、客服话术、服务端 Lua 热修
8. 复盘 3 条
9. 已知环境限制：排程与定案口径，非本项目上线记录
10. 代码与运行：门禁脚本 + 回滚手册目录

**配图**：封面 + 上线门禁/灰度流程 ｜ **数据说明**：灰度与压测数字标"目标/待复核"

**系列小结（非预告）**：
16 篇排下来，真正反复出现的只有一件事：**先对齐边界，再写业务**。信封是格式边界，opcode 是命名边界，覆盖度是需求边界，三端是平台边界，备案是时间边界。v3 把这些边界逐条摊开，是因为**联调失败从来不是"某一行代码写错"，而是边界从没被写下来过**。

---

## 八、与服务端 9 篇的联调映射

服务端系列（`docs/blog/01–09`）已发布，客户端 16 篇按"同一现象的两侧"对齐，各篇只写自己这一端。

| 服务端篇 | 模块 | 客户端篇 | 联调接缝 |
|---|---|---|---|
| 01 ch4 登录 | gate/login/center | **V03 / V06** | 信封（V03）+ 首包与失败分支（V06） |
| 02 ch5 对象池 | 池化 | — | 纯服务端，客户端不蹭 |
| 03 ch6 ECS | 双语言 ECS | — | 纯服务端 |
| 04 ch7 存盘 | memory/MySQL 双驱动 | **V07** | 创角落库复用 `RoleLoad/Save` |
| 05 ch8 组件式 Agent | 组件与依赖方向 | **V08** | 属性字段 → 泳道映射 |
| 06 ch9 HTTP | 管理接口 | **V16** | 版本门禁与管理面边界 |
| 07 ch10 分布式登录 | 跨节点容错 | — | 客户端无感，不写 |
| 08 ch11 跳转 | 跨进程边界 | **V10** | 窗口期缓存 ↔ 客户端锁输入 |
| 09 ch12 重连热更 | offline/rebind | **V09** | 超时常量双端一致 |

**跨端纪律**：客户端篇只写客户端动作；引用服务端必须标"服务端"，不写成联调复盘。

---

## 九、开源计划

### 9.1 目录

```
bookskynet/
├── ch4_login … ch12_disconnect        # 服务端（已发布 4 章）
└── unity_client/                       # 客户端契约与工具（已暂存 13 文件）
    ├── protocol/
    │   ├── opcode_registry.yaml        # v3，本篇系列的唯一契约源
    │   ├── opcode_snapshot.yaml
    │   ├── protos/Msg_*.proto ×5
    │   └── gen/{gen_opcodes.py, Opcode.cs, opcode.h, opcode.lua}
    ├── tools/
    │   ├── checkers/check_opcode.py
    │   └── config_pipeline/csv2lua.py
    └── docs/                            # v3 新增（自写，不含蓝本代码）
        ├── frame_decision.md            # V03 信封收敛决策表
        ├── contract_matrix.md           # V05 覆盖度矩阵
        ├── reconnect_policy.md          # V09 退避与超时对齐
        └── release_checklist_{android,ios,minigame}.md  # V13–V15
```

### 9.2 逐篇裁定

| 篇 | 开源 | 内容 | 理由 |
|---|---|---|---|
| V01 | 否 | — | 目录与清单 |
| V02 | 否 | — | prefab 属美术资源 |
| **V03** | **是** | `frame_decision.md` | 决策表可独立复用；不含服务端源码 |
| **V04** | **是** | `protocol/**` + `check_opcode.py` | 已暂存；三端同源，可独立校验 |
| **V05** | **是** | `contract_matrix.md` | 矩阵可复算 |
| V06 | 否 | — | 状态机设计稿 |
| **V07** | **是（有限）** | 新增 proto 片段 + opcode 注册行 | 契约补齐可复现；handler 骨架标"待实现" |
| V08 | 否 | — | 映射表依赖工程上下文 |
| **V09** | **是（有限）** | `reconnect_policy.md` | 参数表可复用 |
| V10 | 否 | — | 时序图 |
| V11 | 否 | — | 片段 + 依赖工程，按"片段即掠过" |
| V12 | 否 | — | 方法笔记 |
| **V13/V14/V15** | **是（有限）** | 三份检查清单 | 清单可独立使用，无敏感信息 |
| **V16** | **是（有限）** | 门禁脚本 | 与服务端发布纪律对齐 |

**三条硬规则**：① 美术资源一律不开源；② 蓝本代码只引用不复制（MIT + 出处）；③ 片段即掠过。

### 9.3 提交顺序（一章一提交）

1. `unity_client/`（已在暂存区，13 文件）→ `feat: 客户端契约与 opcode 校验最小集`
2. `docs/frame_decision.md` → V03
3. `docs/contract_matrix.md` + 新增 proto/opcode → V05/V07
4. `docs/reconnect_policy.md` → V09
5. 三份 `release_checklist_*.md` → V13–V15
6. 根 `README.md` 目录树同步（**当前仍写"只包含 ch4_login"，已漂移**）

---

## 十、配图规范

- 封面 1200×512；插图 1200×675；PNG/JPEG 双格式。
- 深蓝→青色渐变 + 双色光晕 + 右侧节点网络 + 半透明代码水印；微软雅黑 / Consolas，本地 PIL，2 倍超采样。
- 脚本按篇命名：`make_cover_v01.py` … `make_illustration_v16.py`。
- **不引用蓝本美术资源做配图**，一律本地绘制。
- 图内数字与正文一致；标"待复核"的不得在图中写成实测。

---

## 十一、红线：不许编

1. **不许编客户端类名/方法名**。本蓝本网络层完全未公开，凡涉及必须写"设计上应有"并给自写示例。
2. **不许把参考工程当本蓝本**。legend3D 的 8B Frame、三端定案、4 MB 首包，引用时必须标"参考"。
3. **不许把服务端内部消息当客户端协议**。`Msg_DG` 是 DB 通道，不是客户端可见消息。
4. **不许编性能数字**。没有实测只写定性；目标值标"设计目标/待复核"。
5. **不许省略免责句**。B/C 档首次出现实现描述时必须写"蓝本未公开该层"或"非本项目实测"。
6. **不许把限额写成永久值**。4 MB / 20 MB / targetSdk 一律标"以当年公告为准，接入前复核"。
7. **不许在信封未收敛时就写"联调成功"**。V03 未落地，V06–V10 只能写设计稿。

---

## 十二、发布前检查清单

- [ ] 标题以 `[Unity 手记]` 开头，不混 `[Skynet 手记]`
- [ ] 九段式齐全，**无下篇预告**
- [ ] 全文 MMO / RPG 表述
- [ ] 开篇钩子是真实文件 / sha / 行号 / 日志，非虚构
- [ ] 档位已标，B/C 档含免责句
- [ ] 交付物随文给出
- [ ] 联调对象已标（服务端模块名或"无"）
- [ ] 参考工程内容已标"参考"
- [ ] 路径可在 `GameBookClient@master` / `bookskynet` / `legend3D` 对上
- [ ] 无编造类名、方法名、性能数字
- [ ] 未复制蓝本代码整文件；引用标 MIT
- [ ] 未使用蓝本美术资源做配图
- [ ] 数据说明仅文末一处
- [ ] 封面/插图中文无乱码、无裁切

---

## 附：证据索引

```
【主蓝本】setuppf/GameBookClient@master
├── art/ProjectSettings/ProjectVersion.txt        → 2018.3.7f1
├── art/Assembly-CSharp.csproj                     → 仅 Assembly-CSharp，无热更程序集
├── art/Packages/manifest.json                     → TMP 1.3.0 等
├── art/Assets/Scenes/{Empty,Login,Roles}.unity    → sha 2826522b…，5199 B（同一空壳）
├── art/Assets/UI/Prefabs/                         → 9 个界面 prefab
├── art/Assets/Scripts/Editor/BuildAB.cs           → 唯一业务脚本（6989 B）
└── art/Assets/Avatar/Player/{female,male}/        → 四件套 + stand/move/stand02

【服务端与契约】bookskynet
├── unity_client/protocol/opcode_registry.yaml     → v3，channel<<16|id，AUTH_LOGIN_REQ=0x00060001
├── unity_client/protocol/gen/gen_opcodes.py       → 三端生成
├── unity_client/protocol/gen/Opcode.cs            → C# 产物（RegistryVersion=3）
├── unity_client/protocol/protos/Msg_{AUTH,CG,CL,DG,Common}.proto
├── ch4_login/gateway/gated.lua:36,:133-140        → [len:u16][payload][session:u32]
├── ch4_login/proto/game.proto                     → sproto：login_req/ping/echo
├── ch4_login/service/agent.lua:80-102             → [cmd:u8][sproto]
├── ch7_db/                                        → RoleLoad/SaveReq 可复用
├── ch8_components/                                → 属性归属组件
├── ch11_jump/                                     → scene_host/agent_jumper/gate_redirect
└── ch12_disconnect/                               → gate_reconnect/on_reconnect/OFFLINE_TIMEOUT_CS

【参考，非本蓝本】legend3D
├── docs/施工计划/skynet版本施工计划.md:167         → 8B [len:u32][opcode:u32]（含 4B+2B 勘误）
├── docs/三端重制排程/01_三端架构与技术选型.md §6   → 三端差异、小游戏 WSS/4MB、iOS 2.5.2
├── docs/三端重制排程/02_排程总表.md §8            → 备案 3–6 个月，未下证不可发布
└── docs/分析报告/ComfyUI_图片资源自动化全攻略.md   → AI 美术分工与成本
```

---

> **最后一句**：v3 与前两版最大的不同，是它敢承认"接不上"——四套信封不兼容、契约缺两对 opcode。承认缺口，才有补齐顺序；假装能接，联调时会用十倍时间还回来。
