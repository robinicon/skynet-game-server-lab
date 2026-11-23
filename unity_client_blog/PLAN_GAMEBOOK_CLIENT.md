# Unity 客户端博客规划 · 以 GameBookClient 为蓝本

> 本文档是**客户端系列的第二套规划**，蓝本为 `setuppf/GameBookClient`（《多人游戏框架实战》客户端源码仓库）。
> 第一套规划（基于 `C:\workspaces\legend3D` 真实工程）见同目录 `README.md` 与 `ARTICLE_OUTLINES.md`，两者的定位差异见第二节。
>
> **口径强制项**（沿用 skynet 系列，不因蓝本变化而放松）：
> 1. 标题统一 `[Unity 手记] xxx`；纯客户端系列只用 `[Unity 手记]`，不混入 `[Skynet 手记]`。
> 2. 全系列**不写下篇预告**，只保留回看上一篇的承接链接；末篇以系列小结收尾。
> 3. 全文统一用 **MMO / RPG** 表述。
> 4. 九段式：frontmatter + H1 + 摘要 → 开篇钩子 → 主体 → 复盘 → 已知环境限制 → 代码与运行 → 文末数据说明。
> 5. **有事实依据、不主观臆想**：凡引用必带仓库路径；凡是蓝本未公开的实现，必须明写"未公开"，改用设计层表述，不编代码、不编数字。

---

## 〇、一句话结论

`GameBookClient` 是一个**"美术资产 + 打包工具 + 空场景"组成的客户端仓库**：66 MB 体积，`Assets/Scripts` 下只有 1 个 7 KB 的编辑器打包脚本，业务代码不在公开仓库里。
因此这套规划能写**工程基线、资源打包、场景/prefab 组织、热更边界**（有硬证据），只能写**协议对齐、登录、断线重传的客户端设计**（业务代码未公开），不能写"我改了多少行 C#"。

**这恰好是它作为蓝本的价值**：它迫使每篇文章都区分"仓库能证明的"与"设计上应该做的"——这正是 skynet 系列"不写口号、只写动作"的同一标准。

---

## 一、蓝本画像（逐条可核实）

### 1.1 三个仓库的关系

| 仓库 | 语言 | Star | 许可证 | 角色 |
|---|---|---|---|---|
| `setuppf/GameBookClient` | ShaderLab/C# | 76 | MIT | 客户端（Unity 工程，`art/`） |
| `setuppf/GameBookServer` | C++ | 196 | MIT | 服务端（ECS + Actor + protobuf） |
| `setuppf/OtaServer` | — | 0 | MIT | OTA 更新服务 |

> 出处：GitHub API `repos` 元信息，2026-11 查询。
> 两者同属《多人游戏框架实战》（彭放，机械工业出版社，12 章，近 50 示例 / 近 80 流程图）。

### 1.2 客户端技术事实（全部可查证）

| 事实 | 值 | 出处 |
|---|---|---|
| Unity 版本 | `2018.3.7f1` | `art/ProjectSettings/ProjectVersion.txt` |
| 工程内路径 | `D:/coding.engine.gitee.v4/client/art` | `art/Assembly-CSharp.csproj` 的 HintPath |
| 程序集 | 仅 `Assembly-CSharp` / `Assembly-CSharp-Editor` | `art/*.csproj` |
| 热更框架 | **无**（无 XLua / ILRuntime / HybridCLR 程序集） | csproj 引用清单 |
| 依赖包 | `textmeshpro 1.3.0`、`ads 2.3.1`、`analytics 3.2.2`、`purchasing 2.0.3`、`collab-proxy 1.2.15` | `art/Packages/manifest.json` |
| 场景 | `Empty` / `Login` / `Roles` / `jiangxia` / `Environment` | `art/Assets/Scenes/` |
| UI prefab | 9 个：`Canvas`、`CanvasBG`、`Character (List)`、`Loading Bar`、`Login`、`Modal Box 0/1/2`、`RoleCreate`、`RoleSelect` | `art/Assets/UI/Prefabs/` |
| 角色资产 | `female`（xiaoqiao）/ `male`（zhaoyun），各含 Materials/models/prefab/texture，动画 `stand`/`move`/`stand02` | `art/Assets/Avatar/Player/` |
| 业务代码 | **仅** `Scripts/Editor/BuildAB.cs`（6989 B） | `art/Assets/Scripts/` |

### 1.3 两个"反直觉"的硬事实（本系列的核心素材）

**事实 A：三个场景文件字节完全相同。**
`Empty.unity`、`Login.unity`、`Roles.unity` 三者的 Git blob sha 都是 `2826522b14b6763fd1629412802216686786f991`，大小都是 `5199` 字节。
→ 客观结论：这是**同一份空壳场景**，靠改文件名区分用途。场景里没搭 UI，界面在 prefab 里。
→ 推断（需在编辑器打开验证后再写进文章）：运行时由代码加载 prefab 实例化。

**事实 B：66 MB 的仓库，业务代码只有 1 个脚本。**
仓库 `size=66805`（KB），`art/Assets/Scripts` 下只有 `Editor/BuildAB.cs`；其余全是模型、贴图、材质、prefab、动画。
→ 结论：公开仓库只托管**美术资产 + 打包工具**，网络层、登录逻辑、UI 驱动代码均未公开。
→ 对写作的影响：凡涉及这些层的篇目，只能写设计，不能写"实现细节"。

**事实 C（U02 的钩子）：`BuildAB.cs` 把 AB variant 当平台后缀用。**
脚本里 `importer.assetBundleVariant = ext`（`"win"` / `"android"`），而 Unity 的 variant 本是 `hd`/`sd` 这类资源变体概念。
→ 这是可讨论的真实工程取舍：用 variant 区分平台，换来"同一 assetBundleName 不同平台互不覆盖"，代价是变体语义被挪用。
→ 同时脚本**没有**生成版本清单、没有增量 diff，只调 `BuildPipeline.BuildAssetBundles(outPath, BuildAssetBundleOptions.None, buildTarget)`；依赖靠另一个窗口导出 `dependences.txt`。

### 1.4 对面的服务端（决定客户端要接什么）

`GameBookServer` 顶层目录与书章节一一对应：

```
01_01_network_first   01_02_network_nonblock   02_01_network_select
02_02_network_epoll   02_03_protobuf           03_01_thread
03_02_engine_thread   03_03_engine_message     04_01_engine_login
04_02_engine_robots   05_0x_性能/对象池        06_0x_ECS/类工厂/日志
07_01_db              08_0x_组件式编程         09_0x_AppMgr/HTTP
10_0x_game/redis      11_0x_resource/world/teleport
12_01_disconnect      12_02_move
```

客户端要对接的关键面：**protobuf 协议**（02_03）、**Actor 消息模型**（03_03）、**登录**（04_01）、**传送/场景**（11_03、11_04）、**断线**（12_01）、**移动**（12_02）。
→ 这六个面直接决定客户端篇目 05–08 的选题。

---

## 二、与 legend3D 版规划的关系

| 维度 | legend3D 版（README / ARTICLE_OUTLINES） | GameBookClient 版（本文档） |
|---|---|---|
| 素材性质 | 真实完整工程，只读审计 | 公开蓝本，业务代码未公开 |
| 证据强度 | 强（F001–F032 修复日志、审计报告、截图） | 中（结构/脚本/资产可证；逻辑层不可证） |
| Unity 版本 | 2021.3.15f1 | 2018.3.7f1 |
| 热更 | HybridCLR + xLua（代码热更） | 仅 AssetBundle（**无代码热更**） |
| UI 体系 | NGUI → UGUI 迁移（有迁移痛点） | 原生 UGUI + TMP（无迁移史） |
| 服务端 | skynet（Lua） | C++ ECS（GameBookServer） |
| 可写深度 | 可写"我改了什么、怎么验证" | 可写"工程怎么组织、为什么这样取舍" |
| 建议用法 | 实战踩坑番外（有血有肉） | 客户端主线（体系完整、可复现） |

**结论：两套并存，不互相替代。**
`legend3D` 版负责"真实事故复盘"（白屏、竞态、root motion）；`GameBookClient` 版负责"客户端工程体系"（打包、场景/prefab、热更边界、协议对齐）。
若只保留一套：优先 GameBookClient 版做主线（覆盖完整生命周期），legend3D 版挑 3 篇做事故番外。

---

## 三、证据分档：决定每篇能写多深

写作前先给每篇定档，**档位决定文章能写实到哪一层**，避免越界编造。

| 档 | 判定 | 可写内容 | 必须标注 |
|---|---|---|---|
| **A 强证据** | 仓库里有文件/脚本/清单可直接引用 | 逐行解析脚本、真实目录树、真实文件大小与 sha、依赖版本 | 引用路径 |
| **B 设计层** | 蓝本有对应模块但客户端实现未公开 | 交互设计、状态机、协议对齐方案、自写最小示例 | **"蓝本未公开客户端该层实现"** |
| **C 方法笔记** | 两端都只有方法论 | 选型对比、工程纪律、复盘 | **"非本项目实测"** |

> 铁律：A 档才能出现"这个脚本第 N 行"；B/C 档只能出现"应该这样设计"，且必须带免责句。

---

## 四、写作标准（沿用 skynet 系列九段式）

| 段 | 内容 | 强制 |
|---|---|---|
| 0 | frontmatter（`title`/`tags`/`categories`/`abbrlink`/`date`）+ H1 + 摘要块 | 是 |
| 1 | 一、开篇钩子：真实文件 / 真实 sha / 真实脚本行为 | 是 |
| 2 | 二～N、主体：一章一问题，先摆事实再讲取舍 | 是 |
| 3 | 复盘：3–6 条可复用经验 | 是 |
| 4 | 已知环境限制：Unity 2018.3.7f1 / 蓝本未公开层 / 未覆盖场景 | 是 |
| 5 | 代码与运行：真实目录树 + 可复制命令；引用蓝本代码须标 MIT 与出处 | 是 |
| 6 | 文末数据说明：证据出处、可复现入口，仅一处置底 | 是 |

---

## 五、10 篇安排总表

| 序号 | 标题 | 档 | 核心锚点 | 反直觉钩子 |
|---|---|---|---|---|
| U01 | [Unity 手记] 66 MB 的客户端仓库，业务代码只有 1 个脚本 | A | `size=66805`、`Scripts/Editor/BuildAB.cs` | 仓库大 ≠ 代码多 |
| U02 | [Unity 手记] 一个 30 行的打包脚本，把 AB variant 当平台后缀用 | A | `BuildAB.cs` 全文 | variant 本是 hd/sd，不是平台 |
| U03 | [Unity 手记] 三个场景文件字节完全相同：空场景 + prefab 的取舍 | A | 三个 `.unity` sha 均为 `2826522b…`，size 5199 | Empty/Login/Roles 是同一份 |
| U04 | [Unity 手记] 9 个 prefab 撑起全部界面：登录到选角的最小 UI 集 | A | `UI/Prefabs` 9 项 | 界面不在场景里 |
| U05 | [Unity 手记] 客户端如何接住 protobuf + Actor 的 C++ 服务端 | B | 服务端 02_03/03_03；客户端未公开 | 协议先定，客户端只是解码方 |
| U06 | [Unity 手记] 从 Login.prefab 到进服：登录链路的客户端侧设计 | B | `Login.prefab` + 服务端 04_01/06_05 | 登录场景是空的，界面是 prefab |
| U07 | [Unity 手记] 两个角色、三段动画：模型目录跑在代码前面 | A/B | `Avatar/Player/{female,male}`、stand/move/stand02 | 资产先就位，逻辑后接 |
| U08 | [Unity 手记] 断线与传送：服务端第 12 章讲了，客户端要补什么 | B | 服务端 12_01_disconnect、11_03/11_04_teleport | 服务端有"断线"，客户端得会"重来" |
| U09 | [Unity 手记] 没有 ILRuntime、没有 xLua：只做资源热更的边界 | A | csproj 无热更程序集；manifest 无热更包 | 热更 ≠ 必须代码热更 |
| U10 | [Unity 手记] 12 章服务端 vs 1 个客户端脚本：这套蓝本的取舍 | A/B | 全系列收束 + 章节目录对照 | 蓝本刻意只公开"能公开的" |

**节奏**：每周 1 篇，10 周；U02/U03/U09 是硬证据篇，优先写，先把"可信度"立住。

---

## 六、逐篇大纲

### U01 · [Unity 手记] 66 MB 的客户端仓库，业务代码只有 1 个脚本

**档位**：A  **证据**：`art/Assets/` 目录树、`art/ProjectSettings/ProjectVersion.txt`、`art/*.csproj`、`art/Packages/manifest.json`

**开篇钩子**：clone 下来 66 MB，以为能看到一整套客户端框架。打开 `Assets/Scripts`——只有一个 `Editor/BuildAB.cs`，7 KB。剩下全是模型和贴图。

**章节结构**：
1. 开篇：clone 后的第一眼（仓库体积 vs 代码量）
2. 工程四目录：`Avatar` / `Scenes` / `Scripts` / `UI`，各自的职责边界
3. 版本与技术栈：2018.3.7f1、TMP 1.3.0、纯 C#（csproj 只有 Assembly-CSharp）
4. 为什么公开仓库只有资产：蓝本的"可公开边界"（对应第七节开源裁定）
5. 读这种仓库的正确姿势：先看 csproj/manifest，再看目录，最后才找代码
6. 复盘：工程体积不等于代码量；先确认"哪些层可见"再定选题
7. 已知环境限制：Unity 2018.3.7f1；业务代码未公开；资产不含许可说明
8. 代码与运行：`art/` 目录树 + `ProjectVersion.txt` 原文

**配图**：封面 + 四目录职责图
**数据说明**：66 MB（66805 KB）、7 KB（6989 B）均为仓库原始值。

---

### U02 · [Unity 手记] 一个 30 行的打包脚本，把 AB variant 当平台后缀用

**档位**：A  **证据**：`art/Assets/Scripts/Editor/BuildAB.cs`（全文可引）

**开篇钩子**：Unity 的 `assetBundleVariant` 本来是给 `hd`/`sd` 这种资源变体用的。这个脚本把它设成了 `"win"` / `"android"`——一个约定俗成的挪用，能跑，但埋着坑。

**章节结构**：
1. 开篇：`importer.assetBundleVariant = ext` 这一行的用意
2. 脚本做了什么：遍历 `Application.dataPath` → 跳过 `.meta`/`.dll` → 跳过 `Assets\res\` 与 `StreamingAssets` → 读 `assetBundleName` → 设 variant → 输出到 `StreamingAssets/assetbundle.<ext>`
3. 三个取舍逐条评：
   - variant 当平台后缀：同名 AB 多平台不覆盖，但语义被挪用
   - `BuildAssetBundleOptions.None`：无压缩选项、无 deterministic，构建不可复现
   - 依赖靠另开窗口导出 `dependences.txt`：依赖管理是"人工 + 文本"，不是自动收集
4. 一个真实的坑：脚本排除 `Assets\res\`，但当前仓库顶层并无 `res` 目录——**读脚本必须对照实际目录**
5. 更稳的做法（设计层）：显式 `AssetBundleBuild[]` + `DeterministicAssetBundle` + 生成 manifest/版本号
6. 复盘：打包脚本是客户端最容易失控的地方；约定要写进文档；排除规则要和目录结构同步
7. 已知环境限制：仅 Windows 菜单入口；未在 Android 真机构建验证
8. 代码与运行：脚本关键片段（标注 MIT 与仓库出处）+ 复现步骤

**配图**：封面 + AB 打包流程图（输入→跳过规则→variant→输出）
**数据说明**：脚本行为逐条对应源码；`dependences.txt` 为脚本真实产物名。

---

### U03 · [Unity 手记] 三个场景文件字节完全相同：空场景 + prefab 的取舍

**档位**：A  **证据**：`Scenes/Empty.unity`、`Login.unity`、`Roles.unity` 三者 sha 均为 `2826522b14b6763fd1629412802216686786f991`，size 均 5199

**开篇钩子**：以为会看到三个不同的场景。查 Git 对象——三个文件的 blob sha 一模一样。`Empty`、`Login`、`Roles` 其实是同一份 5 KB 的空壳，只是改了名字。

**章节结构**：
1. 开篇：三个场景 sha 相同的发现过程（git 层面怎么看）
2. 这说明什么：场景只做"入口"，不承载 UI；界面靠 prefab 运行时实例化
3. 好处：场景切换代价低、UI 可复用、美术不用管场景层级
4. 代价：场景里没有任何可视化上下文，调试全靠 prefab 与 Inspector；多人协作时"界面在哪"不直观
5. 与"每个界面一个场景"的常见做法对比（设计层，不点名团队）
6. 复盘：场景是容器不是内容；sha 相同是"空壳"的强证据；用 git 对象验证工程假设
7. 已知环境限制：仅从文件层面推断，未在编辑器打开验证运行时加载链
8. 代码与运行：`git hash-object` / GitHub API 查 sha 的方法

**配图**：封面 + "三场景 → 一空壳 → prefab 实例化"示意图
**数据说明**：sha 与 size 为仓库真实值；运行时加载方式标注为待验证推断。

---

### U04 · [Unity 手记] 9 个 prefab 撑起全部界面：登录到选角的最小 UI 集

**档位**：A  **证据**：`UI/Prefabs` 9 项（Canvas、CanvasBG、Character (List)、Loading Bar、Login、Modal Box 0/1/2、RoleCreate、RoleSelect）

**开篇钩子**：一个 MMO 客户端，公开的 UI prefab 只有 9 个。没有背包、没有商店、没有战斗 HUD——因为蓝本只做到"登录 → 选角/创角 → 进主界面"这条最小闭环。

**章节结构**：
1. 开篇：9 个 prefab 清单（逐个说职责）
2. 分层：`Canvas`/`CanvasBG` 是壳，`Login`/`RoleSelect`/`RoleCreate` 是流程，`Modal Box 0/1/2` 是通用弹窗，`Loading Bar` 是过渡
3. 通用弹窗为什么做三个而不是一个：形态差异 vs 复用成本的取舍
4. `Character (List)` 与 `RoleSelect` 的关系：列表与详情分离
5. UI 与场景的关系（承接 U03）：prefab 是内容，场景是容器
6. 复盘：最小 UI 集要围绕"一条闭环"设计；通用件（弹窗/loading）先抽象
7. 已知环境限制：仅目录级证据，未展开 prefab 内部层级；无美术资源许可说明
8. 代码与运行：`UI/Prefabs` 清单与命名规范

**配图**：封面 + UI 流程图（Login → RoleSelect → RoleCreate → Canvas）
**数据说明**：9 个 prefab 名称与数量为仓库真实值。

---

### U05 · [Unity 手记] 客户端如何接住 protobuf + Actor 的 C++ 服务端

**档位**：B（客户端网络层未公开，**必须标注**）

**证据**：服务端 `02_03_protobuf`、`03_03_engine_message`、`03_02_engine_thread`；客户端仅 `manifest` 含 `unitywebrequestassetbundle` 等模块，无网络协议代码

**开篇钩子**：翻遍公开仓库，找不到一行客户端协议代码。但服务端第 2、3 章把 protobuf 和 Actor 消息模型讲得很细——那客户端这一侧到底该长什么样？

**章节结构**：
1. 开篇：一个"缺失的一侧"（客户端代码未公开这一事实先摆出来）
2. 服务端约定：protobuf 定协议、Actor 定消息投递（引用服务端目录与书章节）
3. 客户端要做的三件事：序列化对齐 / 消息号路由 / 连接与收发线程模型
4. 最小可运行示例（**自写**，非蓝本代码）：一个 protobuf 解码 + 消息分发的骨架
5. 为什么客户端最容易在"消息号"上翻车：双端各写一份枚举
6. 复盘：协议先定死；消息号单一来源；编解码与业务分发解耦
7. 已知环境限制：**蓝本未公开客户端网络层实现**，本篇为设计层；示例代码为自写最小实现
8. 代码与运行：自写示例目录 + 与服务端目录的对应关系表

**配图**：封面 + 客户端/服务端协议对齐图
**数据说明**：服务端模块名与服务端目录一致；客户端实现标注"未公开"。

---

### U06 · [Unity 手记] 从 Login.prefab 到进服：登录链路的客户端侧设计

**档位**：B

**证据**：`UI/Prefabs/Login.prefab`、`Scenes/Login.unity`（空壳）、服务端 `04_01_engine_login`、`06_05_login`

**开篇钩子**：`Login.unity` 是空场景，登录界面全靠 `Login.prefab`。那"点登录按钮到进服"这条链，客户端每一步该做什么？

**章节结构**：
1. 开篇：空场景 + 一个 prefab 的登录界面
2. 链路拆解：输入校验 → 建连 → 发登录请求 → 收响应 → 拉角色列表 → 进场景
3. 与服务端对应：`04_01_engine_login` 处理什么、`06_05_login` 又是什么关系（引用目录）
4. 客户端状态机：未连接 / 连接中 / 已登录 / 选角中 / 进服
5. 失败分支：超时、密码错、服务器满——分别怎么提示与重试
6. 复盘：登录是状态机不是一条直线；失败分支比成功分支更需要设计
7. 已知环境限制：客户端业务代码未公开；状态机为设计稿
8. 代码与运行：状态机图 + `Login.prefab` 与场景的关系

**配图**：封面 + 登录状态机图
**数据说明**：prefab/场景为真实文件；流程为设计层。

---

### U07 · [Unity 手记] 两个角色、三段动画：模型目录跑在代码前面

**档位**：A（资产）/ B（驱动逻辑）

**证据**：`Avatar/Player/female/{Materials,models,prefab,texture}`、`male/...`，动画 `stand`/`move`/`stand02`；角色名 xiaoqiao / zhaoyun

**开篇钩子**：打开 `Avatar/Player`，两个角色整整齐齐：小乔、赵云，各带三套动画。但驱动它们的代码在公开仓库里没有——**资产先就位，逻辑后接**，这是外包/分工项目的常态。

**章节结构**：
1. 开篇：两个角色目录的完整结构
2. 资产组织规范：Materials/models/prefab/texture 四件套 + 命名
3. 三段动画的语义：stand（待机）/ move（移动）/ stand02（第二待机）——为什么是两个待机
4. prefab 的角色装配：模型 + 材质 + 动画控制器怎么挂（目录推断，需编辑器验证）
5. 客户端要做的：状态机驱动动画切换（B 档，设计层）
6. 复盘：资产规范要在开工前定；命名即契约；待机多套是为了避免"死站"
7. 已知环境限制：仅目录与文件级证据；动画控制器内部未展开
8. 代码与运行：`Avatar/Player` 目录树

**配图**：封面 + 角色资产结构图
**数据说明**：目录与动画名为真实值；装配方式标注待验证。

---

### U08 · [Unity 手记] 断线与传送：服务端第 12 章讲了，客户端要补什么

**档位**：B

**证据**：服务端 `12_01_disconnect`、`12_02_move`、`11_03_teleport`、`11_04_teleport`、`11_02_world`

**开篇钩子**：服务端目录里，"断线"和"传送"各自占了一整章。服务端负责判定与状态迁移，客户端要负责的，是"让玩家感觉不到断裂"。

**章节结构**：
1. 开篇：服务端 11/12 章的目录结构
2. 传送的客户端侧：请求 → 过场（Loading Bar 在这里派上用场）→ 新场景就位 → 恢复控制
3. 断线的客户端侧：检测（心跳/超时）→ 提示 → 重连 → 重新登录 → 重建视图
4. 一个关键认知：服务端的"断线"是销毁会话，客户端的"重连"是新建会话——两边语义不对齐就会"回档"
5. 与 `Loading Bar.prefab`、`Modal Box` 的配合（承接 U04）
6. 复盘：断线重连要当新会话处理；过场是体验不是遮羞布；超时参数要可配
7. 已知环境限制：客户端实现未公开；本篇为设计层
8. 代码与运行：服务端目录对照表 + 客户端状态图

**配图**：封面 + 传送/断线时序图
**数据说明**：服务端章节为真实目录；客户端流程为设计稿。

---

### U09 · [Unity 手记] 没有 ILRuntime、没有 xLua：只做资源热更的边界

**档位**：A  **证据**：`art/*.csproj` 仅 Assembly-CSharp（无热更程序集）、`manifest.json` 无热更包、`BuildAB.cs` 只打 AB

**开篇钩子**：现在做 Unity 项目，很多人默认要上 ILRuntime 或 xLua。但这个蓝本一行热更框架都没有——csproj 里只有 `Assembly-CSharp`。它把"热更"这件事，压缩到了 AssetBundle 这一层。

**章节结构**：
1. 开篇：csproj 引用清单里缺了什么（反证法）
2. 三种热更的分层：资源热更（AB）/ 代码热更（Lua、ILRuntime、HybridCLR）/ 配置热更
3. 只做资源热更能解决什么：换皮、改数值、换 UI、修美术——**不能**改逻辑
4. 代价：逻辑 bug 只能发版；好处：无 VM 开销、无 AOT 坑、包体小
5. 什么时候必须上代码热更：强运营、长线、审核周期长
6. 复盘：热更先定"要热什么"再选技术；资源热更是基础盘，代码热更是加分项
7. 已知环境限制：Unity 2018.3.7f1；仅从工程文件推断，未验证运行时加载
8. 代码与运行：csproj/manifest 关键行 + `BuildAB.cs` 的 AB 输出路径

**配图**：封面 + 三层热更边界图
**数据说明**：无热更框架为 csproj/manifest 反证结果，非官方声明。

---

### U10 · [Unity 手记] 12 章服务端 vs 1 个客户端脚本：这套蓝本的取舍

**档位**：A/B（收束篇）

**证据**：全系列证据汇总 + `GameBookServer` 12 章目录 + `GameBookClient` 公开边界

**开篇钩子**：同一个蓝本，服务端公开了 12 章完整实现（196★），客户端只公开了资产和 1 个打包脚本（76★）。这不是偷懒，是**刻意的公开边界**。

**章节结构**：
1. 开篇：两端公开程度的巨大落差（目录对比）
2. 服务端 12 章 → 客户端 10 篇的映射表（哪一章对应哪一篇）
3. 客户端这一侧真正难的不是写代码，是"没有代码时怎么把设计讲清楚"
4. 三类证据的分野：仓库能证的、设计该做的、方法可借的（呼应第三节）
5. 系列复盘：10 篇里 A 档 6 篇、B 档 4 篇，边界清晰才不虚
6. 给读者的建议：拿蓝本学"结构"，拿自己项目练"实现"
7. 已知环境限制：蓝本为 2019–2020 年代码，Unity 2018.3，部分做法已过时（如 AB variant 用法）
8. 代码与运行：两端目录对照 + 系列文章索引

**配图**：封面 + 服务端 12 章 / 客户端 10 篇映射图
**数据说明**：Star 数、章节数为 2026-11 查询值；"已过时"判断需在正文逐条给理由。

**系列小结（本篇末尾，非预告）**：
一句话收束：**这套蓝本教的是"边界感"——哪些该公开、哪些只能设计、哪些干脆别碰。**
把 10 篇按档位排一张表，A 档立可信度，B 档讲设计，读者自己判断哪里能抄、哪里只能借鉴。

---

## 七、开源裁定

对齐 `skynet-game-server-lab` 纪律，**非强制**，逐篇判：

| 篇 | 能否开源 | 理由 |
|---|---|---|
| U01 | 否 | 只有目录与清单，无独立可运行代码 |
| U02 | **可**（有限） | 可开源一个**自写的**最小 AB 打包复现脚本 + README；蓝本 `BuildAB.cs` 只引用不复制（MIT，注明出处） |
| U03 | 否 | 空场景无代码；验证方法用命令即可 |
| U04 | 否 | prefab 属美术资源，一律不开源 |
| U05 | **可** | 自写的 protobuf 解码 + 消息分发最小示例（不含蓝本代码） |
| U06 | 否 | 状态机为设计稿 |
| U07 | 否 | 模型/贴图/动画均为美术资源 |
| U08 | 否 | 设计稿 |
| U09 | 否 | 结论来自工程文件反证 |
| U10 | 否 | 复盘篇 |

**三条硬规则**：
1. **美术资源一律不开源**：模型、贴图、材质、prefab、动画、音频、字体、场景文件都不进仓库。
2. **蓝本代码只引用不复制**：`BuildAB.cs` 属 setuppf 的 MIT 代码，文章可摘片段并标注仓库与许可，但不整文件拷进本仓库。
3. **片段即掠过**：只为说明问题的几行代码，不单独开源。

---

## 八、配图规划

沿用 `csdn_cover/` 现有视觉规范：

- **封面** 1200×512；**插图** 1200×675。
- 深蓝→青色对角渐变 + 双色光晕 + 右侧节点网络 + 半透明代码水印。
- 微软雅黑 / Consolas，本地 PIL，2 倍超采样。
- 脚本按篇命名：`make_cover_u01.py` … `make_illustration_u0x.py`。
- **不引用蓝本美术资源做配图**（许可与纪律双重约束），一律本地绘制；目录树用等宽字体排版即可。

---

## 九、红线：不许编

这套蓝本最大的风险是"业务代码不可见"，所以把红线写死：

1. **不许编客户端类名/方法名**。凡蓝本没有的，一律写"设计上应有"，并给自写示例。
2. **不许编性能数字**。没有实测的地方，只写定性结论（如"多一次网络往返"），不写毫秒。
3. **不许把推断写成事实**。U03 的"运行时加载 prefab"、U07 的"prefab 装配方式"，必须标"待编辑器验证"。
4. **不许把服务端行为安到客户端头上**。两端分开写，引用服务端时明确标注"服务端"。
5. **不许省略免责句**。B/C 档篇目，正文第一次出现实现描述时必须写明"蓝本未公开该层"。

---

## 十、发布前检查清单

- [ ] 标题以 `[Unity 手记]` 开头，全系列不混入 `[Skynet 手记]`
- [ ] 九段式齐全，**无下篇预告**
- [ ] 全文统一 MMO / RPG 表述
- [ ] 每篇开篇钩子是真实文件 / sha / 脚本行为，非虚构场景
- [ ] 档位已在文首标注（A/B/C），B/C 档含免责句
- [ ] 所有路径能在 `setuppf/GameBookClient@master` 对上
- [ ] 无编造的类名、方法名、性能数字
- [ ] 推断已标"待验证"
- [ ] 未复制蓝本代码整文件；引用处标 MIT 与出处
- [ ] 未使用蓝本美术资源做配图
- [ ] 数据说明仅文末一处
- [ ] 封面/插图中文无乱码、无裁切

---

## 附：本规划的证据索引（写作时直接查）

```
setuppf/GameBookClient@master
├── art/ProjectSettings/ProjectVersion.txt        → 2018.3.7f1
├── art/Assembly-CSharp.csproj                     → 仅 Assembly-CSharp，无热更程序集
├── art/Packages/manifest.json                     → TMP 1.3.0 等依赖
├── art/Assets/Avatar/Player/{female,male}/        → 小乔/赵云四件套 + 三段动画
├── art/Assets/Scenes/{Empty,Login,Roles}.unity    → 三者 sha 相同（2826522b…，5199 B）
├── art/Assets/Scenes/{jiangxia,Environment}/      → 场景资源目录
├── art/Assets/Scripts/Editor/BuildAB.cs           → 唯一的业务侧脚本（6989 B）
└── art/Assets/UI/Prefabs/                         → 9 个界面 prefab
```
