# 新版客户端设计 · 机制审计 · 排期（v2 · Unity + 微信小游戏）

> 配套服务端：`C:\workspaces\bookskynet\ch13_palace`（skynet，`make verify` 327 PASS / 23 cases）
> 审计对象：`C:\workspaces\palaceserver\trunk`（Java 原服，525,578 行）、`C:\workspaces\Lovely`（原客户端，152,386 行）
> **纪律：两个老仓一行不改。** 新客户端独立建仓 `C:\workspaces\palaceclient`，只读原仓。
> 性质：**评估 + 设计 + 排期，待确认后执行**。本文不含任何已落地代码。
>
> **v2 修订（2026-11-22）**：引擎由 Cocos Creator 改为 **Unity**；新增 **微信小游戏发布约束**专章（§5）；跨服类功能改为「机制分析 + 优化设计 + 最小可运行骨架」，独立成文 `docs/CROSS_SERVER.md`；排期按「最小可运行优先」重排（§8）。
> 相对 v1 的三个实质变化：① 传输前置从「WS 就行」变成「WS + wss + ICP 备案」；② 客户端多了一条**没有多线程**的硬约束，它反过来把「服务端结算」从设计选择变成了物理必然；③ 跨服从「放弃」升级为「分析清楚、只落最小链路」。

---

## 0. 一页结论

**要做什么**：一个与 skynet 版配套的 **Unity 客户端**，只还原**玩法闭环**，不做运营/社交/活动/充值的重复类功能；发布目标同时覆盖 **微信小游戏** 与 **PC/浏览器 WebGL**；跨服类功能只做**机制分析与最小骨架**（排行合并），不做完整跨服战。

**不做什么**：不移植 279 个窗口、不搬 Lovely 的 prefab/scene、不复刻 13,384 行逐帧战斗、不做 SDK/支付/热更/GM 后台/聊天独立服/世界 Boss/公会战。

**关键判断五条**：

1. **客户端不能靠"裁剪老代码"得到。** 老客户端 152k 行里，核心玩法窗口只有约 **47 个（17%）**，运营/社交/活动类约 **182 个（65%）**。裁剪 65% 的代码，成本高于新建——而且被改过的代码没有可信基线。
2. **内核必须是纯 .NET 类库，不是 MonoBehaviour。** 玩法逻辑（协议、状态、规则）放进 `netstandard2.1` 类库，用 `dotnet test` 无头跑；Unity 只是它的一个渲染宿主。这样客户端第一次拥有和 `make verify` 同级的可复跑门禁——这是老客户端最缺的东西（它的 `NetSvc.ts` 直接 `extends Component`，网络层被焊进引擎，无法单测）。
3. **规则不要复刻，要查表。** 能在 `gamedata.xlsx` 里表达成一张表的，就不要写进代码。这消掉了"客户端算一遍、服务端再算一遍"的双份状态机。
4. **微信小游戏不是一个"发布渠道"，是一组硬约束，会反向改写设计。** 主包 4MB / 总包 20~30MB 决定资源必须外置；WASM 无多线程决定客户端不能做重计算；不能动态生成代码决定协议序列化不能用反射库。**这三条每一条都落到具体设计上**（§5）。
5. **跨服要分析清楚，但不落地完整。** 原服跨服是「global 中心 + Redis + fight 独立进程」三层设施，问题在"中心定时全量轮询"和"同步阻塞取数据"。新版用 skynet 内一个 `hub` 单服务替代三层，排行改"推"、战斗改"两阶段"，本次只落排行最短链路（3 人日）。

**工作量**（1 名熟悉 C#/Unity + 该游戏的工程师；服务端另计）：

| 档 | 范围 | 客户端 | 服务端 |
|---|---|---:|---:|
| **MR 最小可运行** | WS 入口 + 跨服 hub 骨架 + Unity 工程骨架 + 登录/快照/重连 + 将星/背包/任务 + **小游戏真机能跑** | **24~32** | **5~6** |
| **核心循环** | + 战斗（结算版）/ 关卡 / 商店 / 奖励 / 跨服排行 UI | +8~11 | +7~11 |
| **M3 次要玩法** | + 排行 / 抽卡 / 家园（简化）/ 经营（简化） | +8~12 | +8~14 |
| **表现打磨**（可无限延后） | 主题、图集、关键界面 | +8~12 | — |
| **合计** | | **48~67** | **20~31** |

**与 v1（Cocos）相比，MR 从 20~26 涨到 29~38**，多出的 9~12 人日是：小游戏构建链路 4~6（v1 没有）、C# 协议层与生成器 2~3（TS 有 npm 生态，C# 要手写 codec）、Unity 工程与 asmdef 分层 2~3。**这不是估算变松，是范围真的变多了。**

---

## 1. 边界与前提

| 项 | 约定 |
|---|---|
| 原服 `palaceserver/trunk` | **只读**。作为规则事实源（`*Service.java` 的公式与上限）与对账出处 |
| 原客户端 `Lovely` | **只读**。作为交互事实源（界面结构、字段用途）与**原图**来源（png/字体可取，prefab/scene 不可用） |
| 新客户端 | 独立仓 `palaceclient/`，不与 `Lovely` 共享工程文件 |
| 新服务端 | 沿用 `ch13_palace`，只按 §6 增补 handler 与 `hub`，不改既有 15 个动作语义 |
| 验收 | 一律命令可复跑；客户端 `dotnet test` 与服务端 `make verify` 同构 |

### 1.1 本机环境实测

| 项 | 状态 | 结论 |
|---|---|---|
| Unity | `2021.3.15f1c1` 已装（`C:\Program Files\Unity\Hub\Editor\`） | 在官方已验证区间 `2021.2.11~2021.3.33` 内 ✅ |
| Unity 模块 | **仅 `windowsstandalonesupport`，无 WebGL** | **必装 WebGL Build Support（含 IL2CPP）**，否则无法构建 |
| Unity 许可证 | `C:\ProgramData\Unity\Unity_lic.ulf` 存在 | 可批处理构建 |
| .NET SDK | **只有 runtime，无 SDK**（`dotnet --list-sdks` 为空） | **必装 .NET SDK 8**，否则 `dotnet test` 不可用 |
| 微信开发者工具 | **未安装** | 必装 **Stable 版**（官方明确：不要用小游戏版 Minigame Build） |
| Node | `v22.22.2` | 可用于转换后的辅助脚本 |
| WSL + MySQL | 已就绪（`dev/dev123`） | 服务端验收不变 |

**这四项都是 0.5~1 天的环境准备，但会阻塞排期起点，必须在 U0 之前完成。**

---

## 2. 机制审计

审计口径：**复用**＝可直接拿来用；**参考**＝思路对、需重写；**分析**＝只做机制分析与最小骨架，不完整落地；**放弃**＝成本/收益不成立。

### 2.1 服务端（Java 原服）机制

| # | 机制 | 原实现 | 判定 | 理由 / 落到哪 |
|---|---|---|---|---|
| S1 | `@Rpc(fullAlias)` 注解路由 | 636 个注解，op 与实现同处 | **参考** | 新版用 `schema.actions.handler` 替代；"路由与实现同处"这一原则写进客户端 `domain` 契约（一个动作一个方法，不建注册表） |
| S2 | Entity 串行执行（guardian gas） | 每玩家一 Entity，方法串行 | **复用（已实现）** | skynet `agent.lua` 同构；客户端对应"单写者 store" |
| S3 | 配表生成（Excel → 279 个 Java 类） | 298,071 行生成物 | **参考** | 生成方向对，目标错（静态类）。新版：服务端 → Lua table（已做）；客户端 → **C# 常量 + 类型 + codec** |
| S4 | `@Rpc` 位置参数 + 类型反射 | `itemSale(ctx, rpc, String json)` | **放弃** | 客户端照抄签名导致"改类型不报错"。新版一律命名参数（`params` 对象） |
| S5 | EventBus 跨服务事件 | 仅 2 个事件 / 14 处 | **参考** | 事件克制是优点。新版用 `EVENT` 信封，只用于真正的广播 |
| S6 | DBS 定时落库 | `DbsService` 定时器 | **复用（已实现）** | 新版 `expire` + 脏分区落盘，语义更强 |
| S7 | **跨服：global 中心 + Redis + fight 进程** | `palace-global` 3,541 行；`cross/` 6 文件 356 行；`co.*` 7 / `gl.*` 39 / `gld.*` 7 | **分析 + 最小**（v1 为「放弃」） | 三层拓扑本身合理（控制面/数据面/战斗面分离），但"中心定时全量轮询"与"同步阻塞取数据"有真问题。详见 `docs/CROSS_SERVER.md`；本次只落 `hub` 排行链路 3 人日 |
| S8 | 多进程（login/chat/global/gms） | 6 进程 | **放弃** | 新版单进程 + gate；聊天不做，GM 用 `u.dev.*` 替代 |
| S9 | `fight` 独立进程 + `FightClient` | 102 文件 / 13,384 行 | **放弃（进程），参考（分离）** | 进程边界不要（结算是一次纯函数调用）；但"结算/战报/回放"三分离要保留，战报落 `fight_record` |
| S10 | 分服 / 合服 | `ServerConfigService`、合服脚本 | **分析** | 新版用 `(gid, sid)` 整数二元组替代 `cross$group$sid` 字符串；合服只改映射表，不迁历史数据 |
| S11 | 运营数据 `OptColumn`（String + 类型注解） | 已有"配置驱动字段类型"雏形 | **参考** | 与新版 `schema.fields.type` 同源；客户端 `PanelSpec` 也用同样的"类型注解驱动渲染" |
| S12 | 逐帧战斗模拟 | 30 余效果控制器 | **放弃（降级）** | 改为"服务端结算 + 客户端结果展示"。**注意：这一条在 v2 里从"设计选择"变成了"物理必然"**——WebGL 无多线程（§5.3） |

### 2.2 客户端（Lovely）机制

| # | 机制 | 原实现 | 判定 | 理由 / 落到哪 |
|---|---|---|---|---|
| C1 | MVC 分层（`FrameworkDesign`） | Architecture/Model/System/Command/Query，IOC 容器 | **参考** | 分层思想保留，`IOC + GetModel/GetSystem` 的运行期字符串查找换成编译期引用 |
| C2 | `BindableProperty` 细粒度绑定 | 1,461 处 | **复用（改写）** | 保留"字段级订阅"语义，换成 `store.Watch(fid)`；不生成 62×4 行样板 |
| C3 | 栈式窗口 + 暂停/恢复 | `UIManager.wndStack` | **复用** | 栈语义是产品行为，直接搬到 `router`；`pauseWnd/resumeWnd` 保留 |
| C4 | 事件总线 743 个字符串 | `EventConst` | **参考** | 收敛为 `evt.action.<aid>` / `evt.field.<fid>`，由生成器产出 |
| C5 | 配表 `CfgController` + 44 处懒加载 | 319 JSON，34MB | **参考** | 懒加载方向对，缺"声明式依赖"。新版 `PanelSpec.tables` 声明，router 自动预加载 |
| C6 | `ResourceManager` + 对象池 + AssetBundle | `RealFram/ResourceFrame` | **参考** | Unity 侧用 Addressables/AB + 对象池；小游戏必须换成 `WxAssetBundle`（§5.3） |
| C7 | `EnhancedScroller` 虚拟列表 | `Script/Common/ScrollView` | **参考** | UGUI 固定行高虚拟列表 + 节点池，约 150 行 |
| C8 | 断线重连窗 + 心跳 pong 检测 | `NetSvc` 15s + `ReconnetWnd` | **复用** | 新版对 `wire=2` 的 `PING`；重连带 token（服务端已支持） |
| C9 | 本地预演（战斗/经营） | 客户端算一遍 | **放弃** | 见 §4.5"查表不复刻"；且无多线程，算不动 |
| C10 | 红点系统 | `RedPointItem` + 事件驱动 | **参考** | 红点条件写成 `selector + 比较`，配置驱动 |
| C11 | 多语言（两张 4.7MB 表常驻） | `LanguageTextData` + `LanguageCnData` | **放弃** | 只留一张中文表，按域分包（小游戏主包 4MB，常驻 9.4MB 不可能） |
| C12 | SDK / 支付 / 热更 / 埋点 | `YFYSdkUtil`、`HotUpdate` | **放弃** | 与"还原玩法"无关；小游戏另有适配层，见 §5.5 |
| C13 | 客户端本地存档/缓存 | `UserDefaultUtil` | **参考** | 只缓存 token 与设置项（小游戏映射到 `wx.setStorage`），不缓存游戏数据 |
| C14 | `Com` 通用组件（30 个） | 奖励预览、消耗确认、规则说明… | **参考** | 抽成 5 个原语（§4.6），其余丢弃 |
| C15 | **美术资源（prefab/scene/anim）** | Cocos 3.5.2 工程 | **放弃（仅取原图）** | **prefab/scene 无法跨引擎复用**，只能取 png 图集与字体。这是 Unity 方案表现层成本高于 Cocos 的根本原因 |

### 2.3 审计小结

| 判定 | 服务端 | 客户端 | 合计 |
|---|---:|---:|---:|
| 复用 | 3 | 3 | **6** |
| 参考 | 5 | 8 | **13** |
| 分析（仅最小） | 2 | — | **2** |
| 放弃 | 3 | 4 | **7** |

**最值得带到新版的 6 项**：Entity 串行（S2）、脏分区落库（S6）、配表生成（S3/S11 思想）、栈式窗口（C3）、字段级绑定（C2）、断线重连（C8）。

**最容易被误带进来的 3 项**：位置参数协议（S4）、本地预演（C9）、事件总线万能化（C4）。

**v2 新增的一条**：**控制面/数据面分离**（S7）——这一条原服做对了，v1 因为"放弃跨服"而漏掉了它，现在补回来。

---

## 3. 玩法盘点与还原原则

### 3.1 规模（双维度：协议面 / UI 面）

| 玩法域 | 协议方法数（Proxy） | UI 窗口数 | 服务端业务代码（行） |
|---|---:|---:|---:|
| 账号/角色/散装（User） | 55 | MainCity 9 + Login 9 | UserService 1,565 |
| 经营·办差（Manage/BanChai） | 44 | **32** | ManageService 2,797 |
| 排位·竞技（Grade） | 41 | Rank 11 | GradePowerService 1,607 |
| 家园（HomeLand） | 39 | — | HomeLandService 1,686 |
| 运营活动（OptHuodong/Xianshi/MengHui） | 25 | **89** | OptHuodongService 1,616 |
| 将星（Hero） | 25 | 含于 MainCity | HeroService 2,763 |
| 奖励·签到（Reward） | 19 | — | — |
| 皇子（Prince） | 18 | — | — |
| 公会（GongHui×5） | 44 | — | GongHuiService 1,793 + Helper 2,226 |
| 社交（Social/Shitu/Flower） | 49 | Friend 12 + Chat 13 + Zhiji 5 | — |
| 背包（User 内） | — | Bag 9 | — |
| 任务（Mission） | 8 | Mission 8 | — |
| 战斗（Fight） | 5 | Fight 6 | fight 102 文件 / **13,384** |
| 商店（Store） | 6 | Shop 2 | — |
| 抽卡（Chouka） | — | Chouka 4 | — |
| 巡游/主题/装扮（Xunyou/Dress） | 3 | 31 | — |
| **跨服（Kuafu/Kfst/Rank 全局）** | **0 独立 Proxy**（挂在 Rank/Chat 内） | Rank 11 含跨服页 | `palace-global` 3,541 + `cross/` 356 |

**关键比例**：核心玩法窗口（Login 9 + MainCity 9 + Bag 9 + Mission 8 + Fight 6 + Shop 2 + Chouka 4）= **47 个 / 279 = 17%**；运营+社交+经营+活动 = **182 个 / 279 = 65%**。

### 3.2 三档划分

| 档 | 定义 | 玩法 |
|---|---|---|
| **P0 核心闭环** | 有状态机、有数值规则、有对账价值，缺一环就玩不下去 | 登录/角色、将星养成、背包道具、任务、关卡推进、战斗结算、商店 |
| **P1 次要玩法** | 有独立规则但不影响主循环 | 家园（简化）、经营·办差（简化）、排行、签到奖励、抽卡、**跨服排行（只读）** |
| **P2 重复类/运营类** | 交互范式与 P0 相同，只是数据不同 | 活动（17 类）、限时（39 界面）、梦回（50 界面）、社交、公会、充值、**跨服战/世界 Boss**、GM 后台、聊天 |

### 3.3 还原原则（六条，作为后续所有争议的裁决依据）

- **R1 只还原"有状态"的玩法**：纯展示（排行、活动页）不进 P0/P1，用配置驱动，不写专用代码。
- **R2 同一范式只实现一次**：P2 的 179 个界面归约为"列表 / 详情 / 表单 / 确认 / HUD"五个原语（§4.6）。
- **R3 没有服务端 handler 的玩法不做**：客户端不造"假界面"。凡要显示的数值，服务端必须有对应 fid。
- **R4 依赖外部系统的功能不做**：支付 SDK、独立聊天进程、热更、世界 Boss 编排。
- **R5 表现可后补，规则不能后补**：MR 阶段用最朴素的 UGUI 把规则跑对；表现打磨（U7）只换皮不改逻辑。
- **R6（v2 新增）平台约束优先于代码整洁**：主包 4MB、无多线程、无动态代码这三条，先满足再看架构。任何"优雅但要 5MB 主包"的方案直接否掉。

### 3.4 新版玩法清单

| 优先级 | 玩法 | 服务端 handler | 客户端 domain | 备注 |
|---|---|---|---|---|
| **P0-1** | 登录 / 建角 / 快照 | `login` ✅ / `view` ✅ / `wire` ✅ | `login` | 已具备 |
| **P0-2** | 将星升级·加官·进爵 | `hero` ✅（3 动作） | `hero` | 已具备 |
| **P0-3** | 背包使用·出售 | `item` ✅（2 动作） | `item` | 已具备 |
| **P0-4** | 任务领奖 | `mission` ✅（1 动作） | `mission` | 已具备 |
| **P0-5** | 关卡推进 / 挂机产出 | `stage` ❌ 待补 | `stage` | 核心循环前置 |
| **P0-6** | 战斗（结算版） | `fight` ❌ 待补 | `fight` | 只做胜负+奖励 |
| **P0-7** | 商店买卖 | `shop` ❌ 待补 | `shop` | 表驱动 |
| **P1-0** | **跨服排行（只读）** | `hub` + `cross` ✅ 待补（3 人日） | `cross` | 本次唯一落地的跨服能力 |
| **P1-1** | 签到 / 在线奖励 | `reward` ❌ 待补 | `reward` | 表驱动 |
| **P1-2** | 排行（本服，只读） | `rank` ❌ 待补 | `rank` | 服务端聚合 |
| **P1-3** | 抽卡 | `gacha` ❌ 待补 | `gacha` | 概率表 + 保底 |
| **P1-4** | 家园（简化） | `home` ❌ 待补 | `home` | 不做摆件/寻路 |
| **P1-5** | 经营·办差（简化） | `errand` ❌ 待补 | `errand` | 不做货架/加速 |
| **P2** | 活动/社交/公会/充值/**跨服战**/世界 Boss | — | — | **不还原**；跨服战只做机制设计（`CROSS_SERVER.md` §3.3） |

---

## 4. 客户端设计（Unity）

### 4.1 选型对比（v2 已定 Unity，此表保留为决策依据）

| 方案 | 做法 | 优点 | 缺点 | MR 人日 |
|---|---|---|---|---:|
| A 重建 Cocos 工程（v1 选择） | 3.8 工程 + TS 内核 | 2D 包体小、小游戏链路成熟、原工程同引擎 | 原工程 3.5.2 且被改过，升级会带历史问题 | 20~26 |
| **B 重建 Unity 工程（v2 选定）** | Unity 2021.3 + C# 内核 + UGUI | 与你现有团队/资产栈匹配；`dotnet test` 可无头验收；C# 强类型利于生成器 | 包体大、需 wasm 分包、prefab 不可复用 | **24~32** |
| C 裁剪 Lovely 副本 | 复制一份删 64% 代码 | 复用既有 UI | 152k 行里删 179 个窗口的连带依赖无法静态判定 | 50+ |

**选定 B。** 理由不是"Unity 更好"，而是：① 你的新服是 Lua/skynet，客户端语言选 C# 与 Lua 的"生成器驱动"配合更紧（强类型让生成物能被编译器校验）；② C# 内核可以脱离引擎跑 `dotnet test`，这是 Cocos/TS 方案做不到那么干净的（TS 也能，但要额外配 tsconfig 的 `lib` 隔离）；③ 后续若要出 App 包，Unity 原生通道更直接。

**代价必须说清**：小游戏包体是 Unity 的天然劣势（§5.2），且 `Lovely` 的 prefab/scene 一个都用不上（C15）——**表现层等于从零做**，这是 v2 比 v1 贵的最大一项。

### 4.1.1 决策记录

| # | 决策 | 选定 | 说明 |
|---|---|---|---|
| D1 | 客户端引擎 | **Unity 2021.3.15f1c1**（本机已装） | 发布前用 2022.3.x 复验包体，见 §5.1 |
| D2 | 战斗深度 | **服务端结算 + 结果页** | 不做逐帧；WebGL 无多线程使之成为物理必然 |
| D3 | 本次范围 | **MR 最小可运行**（v1 为"到 M3"） | 先证明"能发布、能登录、能玩三个玩法"，再谈扩展 |
| D4 | 服务端缺口谁补 | 本次一并补（P0/P0.5/U4 三批） | 客户端做不出没有 handler 的界面（R3） |
| D5 | 新仓 | `C:\workspaces\palaceclient`（独立仓） | 与两个老仓物理隔离 |
| **D6** | 内核形态 | **`netstandard2.1` 类库 + `dotnet test`**，源码放 `unity/Assets/Core`，独立 csproj 用 glob 引用 | Unity 侧用 `noEngineReferences: true` 编译期禁止引用 UnityEngine；dotnet 侧零复制 |
| **D7** | 跨服 | **只做 hub + 排行最小链路**（3 人日），跨服战只设计 | 见 `docs/CROSS_SERVER.md` |
| **D8** | 发布目标 | **微信小游戏 + PC/浏览器 WebGL 双目标**，同一份产物 | 差异只在网络适配层与生命周期（§5.4） |
| **D9** | UI 形态 | **程序化 UGUI**，不建 279 个 prefab | 界面 = 配置 + 五原语；只有极少数动效界面手搭 |

### 4.2 工程结构

```
palaceclient/
├── unity/                                  # Unity 2021.3.15f1c1 工程
│   ├── Assets/
│   │   ├── Core/                           # ★ 纯 C#，源码真身（唯一）
│   │   │   ├── Palace.Core.asmdef          # noEngineReferences: true（编译期铁律）
│   │   │   ├── Wire/
│   │   │   │   ├── Envelope.cs             # 7 种 kind
│   │   │   │   ├── Json.cs                 # 手写 scanner/writer（无反射）
│   │   │   │   ├── Codec.cs                # 请求/响应配对 + 推送分发
│   │   │   │   └── ITransport.cs           # Connect/Send/Close + 事件回调
│   │   │   ├── State/
│   │   │   │   ├── Store.cs                # fid → value + rev + Watch
│   │   │   │   ├── Delta.cs                # base_rev 严格校验
│   │   │   │   └── Selectors.cs
│   │   │   ├── Domain/                     # 一个玩法一个目录
│   │   │   │   ├── Login/ Hero/ Item/ Mission/ Cross/
│   │   │   │   └── <D>/IDomain.cs          # { Actions, Panels, OnEvent }
│   │   │   ├── Config/                     # ★ 全部生成，勿手改
│   │   │   │   ├── Ids.cs  Fields.cs  GameData.cs  Routes.cs
│   │   │   └── Util/
│   │   ├── Game/                           # 表现层，唯一允许 using UnityEngine
│   │   │   ├── Palace.Game.asmdef          # references: Palace.Core
│   │   │   ├── Main.cs                     # 引导：Canvas、连接、注册 domain
│   │   │   ├── Transport/
│   │   │   │   ├── WebSocketTransport.cs   # 浏览器/编辑器：#if PLATFORM_WX 分支
│   │   │   │   └── WxTransport.cs          # 小游戏：WX.ConnectSocket
│   │   │   ├── Render/
│   │   │   │   ├── ListView.cs  DetailView.cs  FormView.cs  DialogView.cs  HudView.cs
│   │   │   │   └── Router.cs               # 栈式窗口 + 暂停/恢复（C3）
│   │   │   ├── Theme/                      # 颜色/字号/间距（表现可整体替换）
│   │   │   └── Lifecycle.cs                # OnApplicationPause / wx.onHide
│   │   ├── Scenes/Main.unity               # 唯一场景
│   │   └── Res/                            # 图集、字体（从 Lovely 取原图）
│   ├── Packages/manifest.json              # 含 minigame 转换 SDK
│   └── ProjectSettings/
├── build/
│   ├── PalaceCore/PalaceCore.csproj        # <Compile Include="../../unity/Assets/Core/**/*.cs" />
│   └── PalaceCore.Tests/                   # NUnit，dotnet test
├── tools/
│   ├── gen_cs.py                           # schema.xlsx + gamedata.xlsx → Core/Config/*.cs
│   └── minigame/                           # 转换配置、包体预算表、发布清单
└── docs/
```

**为什么源码放 Unity 工程里、csproj 反向 glob**：Unity 的 `.meta`/GUID 体系要求源码在 `Assets` 下；如果反过来把源码放工程外，要么用 local package（Windows 软链需权限），要么每次同步复制（双份事实源）。**反向 glob 是唯一"零复制 + 零链接"的方案。**

### 4.3 分层铁律与三道门禁

| 门禁 | 手段 | 通过标准 |
|---|---|---|
| **编译期** | `Palace.Core.asmdef` 设 `"noEngineReferences": true` | Core 程序集**根本无法** `using UnityEngine`；写了就编译失败 |
| 静态 | `grep -rn "UnityEngine" unity/Assets/Core` | 空 |
| 无头 | `dotnet test build/PalaceCore.Tests` | 全绿（不启动 Unity，秒级） |

**为什么把"不能引用引擎"做成编译期而不是约定**：老客户端的 `NetSvc.ts` 直接 `extends Component`，网络层被焊进 Cocos，导致网络逻辑无法单测、无法复用。**约定会被违反，编译器不会。**

### 4.4 协议层：手写 codec，不用反射库

**微信小游戏禁用动态代码生成**（§5.3），这意味着 `Newtonsoft.Json` 的默认路径（运行期反射构建存取器）在小游戏上要么被 IL2CPP 裁掉、要么极慢。而 `JsonUtility` 又太窄（不支持 `Dictionary`、不支持 `object` 多态、不能区分 null 与缺省）——而我们的信封恰好需要 `fid → 任意值`。

**结论：自己写一个 150 行的 JSON scanner/writer，配 schema 生成的字段映射。**

```csharp
// Core/Wire/Json.cs（接口示意）—— 无反射、无 Linq、无 GC 压力大的字符串拼接
public static class Json {
    public static JsonValue Parse(string s);          // 一次性解析成树
    public static string  Write(JsonValue v);         // 树写回
}
public readonly struct JsonValue { /* null/bool/num/str/arr/obj + 索引器 */ }
```

```csharp
// Core/Config/Fields.cs（生成物示意）
public static class Fields {
    public const int Gold = 1001;
    public const int Heroes = 1002;
    // ... 由 schema.xlsx 生成
}
```

**配套的 `Envelope`**：

```csharp
public struct Envelope {
    public int Kind;        // 1 HELLO / 2 REQ / 3 RES / 4 SNAPSHOT / 5 DELTA / 6 EVENT / 7 PING
    public int Seq;
    public int Aid;
    public int Rev;
    public JsonValue Params;
    public int Err;
}
```

**收益**：① 小游戏上不触雷；② 解析耗时可控（不用反射）；③ 生成物能被 C# 编译器校验（`Fields.Gold` 写错就是编译错误，不是运行期空值）。**代价**：多写 150 行 + 生成器多一个 C# 后端。这就是 §0 里那 2~3 人日的来源。

**心跳与重连**：15 秒 `PING`，2 个周期无 `PONG` 触发重连；重连带 `token`。

### 4.5 状态层：查表，不复刻规则

```csharp
// Core/State/Store.cs（接口示意）
public sealed class Store {
    public void ApplySnapshot(Snapshot s);            // rev + partitions
    public bool ApplyDelta(Delta d);                  // base_rev != local → false，调用方拉快照
    public T Get<T>(int fid, T def = default);
    public IDisposable Watch(int fid, Action<JsonValue, JsonValue> fn);
    public int Rev { get; }
}
```

**核心决策：客户端不实现公式，只查表。**

```csharp
// 反面（老客户端做法）：客户端复刻升级消耗公式 → 两套 bug
// 正面（新版）：消耗本身就在 gamedata 表里，客户端只查表算"够不够"
public static bool CanUpgrade(Hero h, Store store) {
    var cost = GameData.HeroExp[h.Tpl][h.Lv + 1].Gold;   // 生成物，强类型
    return store.Get<int>(Fields.Gold) >= cost;
}
```

判断标准：**能在 `gamedata.xlsx` 里表达成一张表的，就不要写进代码。** 真正需要过程的只有战斗结算与随机，那部分服务端单方面权威。

`delta` 的严格性照搬服务端 `client_state.lua`：`base_rev != localRev` 直接拒绝并主动拉快照，避免"半新半旧"。

### 4.6 UI 层：五个原语替代 279 个窗口

| 原语 | 覆盖的原窗口类型 | 声明式配置要点 |
|---|---|---|
| `List` | 背包、将星列表、商店、任务、排行、活动列表 | `Source`（map/fid）、`Item` 模板、`RowActions` |
| `Detail` | 英雄详情、道具详情、建筑详情 | `Fields`（标签 + `@path`）、`Actions` |
| `Form` | 登录、改名、数量输入 | `Fields` + `Submit` |
| `Dialog` | 确认、奖励预览、规则说明 | `Title/Body/Buttons` |
| `Hud` | 主城顶部货币、红点、倒计时 | `Fids` + 格式化 |

**为什么是这五个**：179 个 P2 界面里，超过 90% 可以拆成"一个列表 + 一个详情 + 一个确认框"。做成原语后，P2 不需要"还原"，只需要**写配置**——这兑现了 R2。

### 4.7 表现层：程序化 UGUI，不建 279 个 prefab

```csharp
// Game/Render/ListView.cs（示意）
var go = new GameObject(spec.Id, typeof(RectTransform), typeof(Image));
var layout = go.AddComponent<VerticalLayoutGroup>();
layout.childControlHeight = true;
foreach (var row in rows) pool.Rent().Bind(row);   // 节点池 + 虚拟列表
```

**为什么程序化而不是 prefab**：

1. **界面数量 × 变更频次是大头**：MR 阶段约 15 个界面，全部做 prefab 等于手工搭 15 次，且改布局要开编辑器。
2. **可测试**：`PanelSpec` 是纯数据，"取数 → 行模型"（`BuildRowModel(spec, store)`）能在 `dotnet test` 里断言，不依赖渲染。
3. **小游戏包体**：prefab 与场景会显著增加资源体积，程序化几乎为零。

**代价**：动效与特效弱于手搭 prefab。需要重点表现的界面（战斗结果、抽卡演出）单独用 prefab 做，其余仍走程序化。

**为什么 UGUI 而不是 UI Toolkit**：UGUI 的移动端成熟度、TextMeshPro 文本质量、虚拟列表实践都更稳；UI Toolkit 在 2021.3 的运行时仍是半成品（缺 world-space、样式调试弱）。**小游戏上不赌。**

### 4.8 配表

| 项 | 做法 |
|---|---|
| 上游 | 与服端同一份 `conf/gamedata.xlsx` |
| 生成 | `gen_cs.py` → `Core/Config/GameData.cs`（`static readonly` 数组 + 强类型 struct），**不生成 MonoBehaviour** |
| 分包 | 按 domain 切；首屏只加载 `login + hud` 所需 |
| 语言 | 只留中文，按域分包 |
| 校验 | `contract.test` 断言生成物与 `schema.json` / `gamedata.json` 一致，进门禁 |
| 小游戏侧 | 生成物是 C# 常量 → 编译进 wasm，**不占主包资源**；这对 4MB 主包是好事 |

### 4.9 测试与验收（客户端也有 `make verify`）

```csharp
// build/PalaceCore.Tests/Flow/HeroFlow.cs（示意）
[Test]
public async Task UpgradeAuto_DeductsGold() {
    using var c = await Client.Connect(Env.Gate);        // 直接连 gate，不需要 Unity
    await c.Login("dev_hero", "p");
    var before = c.Store.Get<int>(Fields.Gold);
    await c.Domain.Hero.UpgradeAuto(new { heroId = "rc-h1" });
    Assert.AreEqual(before - 100, c.Store.Get<int>(Fields.Gold));
}
```

四道门禁：

| 门禁 | 命令 | 通过标准 |
|---|---|---|
| 类型/构建 | `dotnet build build/PalaceCore` | 零错误；Core 无 UnityEngine 引用（编译期已禁） |
| 契约一致 | `dotnet test --filter Contract` | 生成物 ↔ schema/gamedata 一致 |
| 玩法流程 | `dotnet test --filter Flow` | 登录→将星→背包→任务 四条链路断言通过 |
| 对账同源 | `dotnet test --filter Replay` | 回放 `docs/samples/*.json`，与服务端 `reconcile` 同结论 |

最后一条是本次设计的关键纪律延伸：**服务端用样本回放对账，客户端回放同一批样本，两端必须同结论**。这比"看界面对不对"可靠得多。

**Unity 编辑器内另有一层**：EditMode 测试只覆盖"UGUI 原语在给定 PanelSpec 下生成的节点数量与层级"，不做视觉断言（视觉靠人看）。

---

## 5. 微信小游戏端（v2 新增）

> 本节所有数字来自微信开放文档（2026-07 版）与本机实测。**这一节是 v2 相对 v1 最大的增量，也是最容易在排期上被低估的部分。**

### 5.1 引擎版本与工具链

官方口径：适配方案支持 **Unity 2018~2022 + 团结引擎**；按验证程度给出推荐区间。

| 引擎 | 压缩纹理/音频 | 编译体积 | 已验证小版本 |
|---|---|---|---|
| 2021 | 全支持 DXT/ETC2/ASTC | 80% | **2021.2.11~2021.3.33** |
| **2022（推荐）** | 全支持 | 80% | 2022.3.1~2022.3.14 |
| 团结引擎（推荐） | 全支持 | 60~80% | 基于 2022.3.2，包体与内存进一步优化 |

**决策**：开发用本机 **2021.3.15f1c1**（在已验证区间内，纹理全支持）；**发布前必须用 2022.3.x 复验一次包体**——官方明确"2021~2022 编译体积更小、压缩纹理更全、强烈建议 2022.3"。若包体卡在 20MB 边缘，切团结引擎是最后一招（官方称其包体/内存优于 Unity 原生）。

**工具链**：

| 组件 | 获取 | 说明 |
|---|---|---|
| WebGL Build Support | Unity Hub 添加模块 | **本机缺失，必装**（含 IL2CPP） |
| 小游戏转换 SDK | PackageManager git：`minigame-tuanjie-transform-sdk.git` | 菜单出现"微信小游戏 → 转换小游戏" |
| 微信开发者工具 | 官网下载 **Stable 版** | 官方明确：**不要用小游戏版 Minigame Build** |
| 小游戏 AppID | MP 后台创建（类目选"游戏"） | 转换时必填，为空无法导出 |
| 快适配能力 | MP → 能力地图 → 生产提效包 → 快适配 | **需在后台开通**，否则转换工具不可用 |

### 5.2 包体预算（最硬的约束）

| 项 | 限制 | 来源 |
|---|---|---|
| 代码包主包 | **≤ 4MB** | 官方「代码包」/「分包加载」 |
| 代码包总量（主包+分包） | **≤ 20MB**；开通虚拟支付后 **≤ 30MB** | 同上（2023-10 调整） |
| 单个独立分包 | ≤ 4MB | 同上 |
| 单个普通分包 | 不限 | 同上 |
| 首屏 wasm 建议 | ≤ 20MB | 团结引擎公开分享口径 |

**这对 Unity 意味着什么**：

一个空 Unity WebGL 构建的 `framework.js + wasm` 通常在 5~8MB 量级（IL2CPP + 中等 strip），**直接超过主包 4MB**。所以必须：

1. **启用 wasm 代码分包**（转换 SDK 提供）：主包只留加载器与首个 wasm 分片，其余按需下载。
2. **资源全部外置**：图集、音频、字体走 CDN 或资源分包，主包只留"加载界面 + 空场景"。
3. **裁剪**：`Managed Stripping Level = High`、`Engine Code Strip`、移除未用的 Unity Module（Video/Physics2D/XR 等）。
4. **压缩纹理三套**：iOS ASTC / Android ETC2 / PC DXT（2021 全支持，无需额外插件）。

**MR 阶段的预算表**（作为 U3 的验收口径）：

| 分项 | 预算 | 说明 |
|---|---:|---|
| 主包（加载器 + framework + 首 wasm 分片） | **≤ 4MB** | 硬上限，超了直接转换失败 |
| wasm 总计 | ≤ 12MB | 含全部玩法代码 + 生成物 |
| 资源分包 | ≤ 6MB | 首屏图集 + 字体 + 音频 |
| **总计** | **≤ 20MB** | 未开虚拟支付的硬上限 |

### 5.3 运行时约束（会改写设计的五条）

| 约束 | 事实 | 对设计的影响 |
|---|---|---|
| **无多线程** | WebGL 无 pthreads；小游戏不支持 SharedArrayBuffer 线程 | **客户端不能做重计算**：逐帧战斗模拟、批量排序、大表计算全部不行。→ ① 战斗必须服务端结算（D2 从"选择"变"必然"）；② 排行分页由服务端切好；③ 配表预处理在导表期做完，运行期只做 O(1) 查表 |
| **无动态代码** | 不支持 `Reflection.Emit` / `dynamic` / `Expression.Compile` | 协议序列化不能用反射库（§4.4 手写 codec）；DI 容器不能用运行期生成；`Activator.CreateInstance` 慎用 |
| **IL2CPP 裁剪** | 未引用的泛型实例、反射访问的成员会被 strip | 需 `link.xml` 保护；**每个玩法域必须有真机冒烟测试**，不能只信编辑器 |
| **内存** | iOS 单进程上限 1.4GB；wasm 运行时内存 ≈ 7~10 × wasm 大小 | wasm 控在 12MB 内（→ 约 100MB 内存）；图集常驻要控；Unity Heap 设 256~512MB |
| **存储** | 只能用 `wx.setStorage`（有配额） | `PlayerPrefs` 由转换 SDK 映射；**不要在本地缓存游戏数据**（C13），只存 token 与设置 |

### 5.4 网络：从 ws 到 wss + 合规

| 项 | 事实 | 应对 |
|---|---|---|
| 传输 API | 只有 `wx.connectSocket`（C# 侧用 SDK 封装） | P0 的 `ws_gate` 是唯一入口 |
| 协议 | **只支持 `wss://`**，`ws://` 被强制拦截 | 服务端必须上 TLS（nginx 反代到 `ws_gate`） |
| 域名 | 必须 **ICP 备案**；不能是 IP（局域网 IP 除外，基础库 2.4.0+）；不能是 localhost | 开发期用开发者工具勾"不校验合法域名"，**但发布前必须关掉逐项验证**——这是上线当天才爆的雷 |
| 端口 | 域名不配端口则 URL 里连 443 都不能写；**wss 无需配端口** | nginx 用 443 |
| 并发 | `wx.connectSocket` 最多 **5** 个 | 单连接设计（不要连接池） |
| 切后台 | 后台 5 秒内未完成的请求 → `fail interrupted`；回前台前网络 API 不可用 | 见下 |

**生命周期设计（小游戏特有）**：

```
用户切后台 → wx.onHide
  → 客户端主动 Close()（不留半死连接）
  → 服务端 3s grace 到期 → agent 落盘退出（现有语义，不改）

用户回前台 → wx.onShow
  → 用缓存 token 重新 HELLO
  → 服务端 resume 失败（agent 已退出）→ 走新 login
  → 拉全量 SNAPSHOT（13 个 fid，几 KB）
```

**关键决策：不延长服务端 grace。** 现有 `session_grace = 300`（3 秒）对"切后台几分钟"是不够的，但延长 grace 意味着每个挂起玩家的 `agent` 服务常驻内存（skynet 每服务有固定开销），几百人切后台就吃满。而全量快照只有 13 个 fid，重建成本极低。**所以正确做法是"接受重建"，而不是"延长挂起"。** 这一点值得写进共识，否则很容易被当成 bug 去修。

**开发/生产两套地址**：

| 环境 | 地址 | 说明 |
|---|---|---|
| 本机联调 | `ws://127.0.0.1:9814`（浏览器/编辑器） | 开发者工具勾"不校验合法域名、TLS、HTTPS 证书" |
| 小游戏真机（开发） | `wss://dev.example.com`（反代到 9814） | 需已备案域名 + 有效证书 |
| 生产 | `wss://game.example.com` | 备案 + 后台白名单 + 关掉"不校验" |

### 5.5 构建与发布流程（U3 交付物）

```
1. Unity: Switch Platform → WebGL
2. 菜单「微信小游戏 → 转换小游戏」
     游戏 AppID          ← MP 后台
     首包资源加载方式     ← 小游戏包内 / CDN
     Unity Heap 内存      ← 256~512MB
     → 生成 minigame/ 目录
3. 微信开发者工具（Stable）→ 导入 minigame/ → 填 AppID
4. 预览（扫码真机）→ 冒烟：登录 / 将星 / 背包 / 任务
5. 上传 → MP 后台设体验版 → 提审 → 发布
6. 非技术前置（排期外，但必须提前 2~4 周启动）：
     小游戏类目（一级"游戏"，通过后不可改）
     软著 / 版号（按类目要求）
     健康忠告启动图（48 字）
     隐私协议
```

**MR 阶段的 U3 验收口径**：真机能进主城、能升级一次将星、能领一次任务奖励；`minigame/` 主包 ≤ 4MB，总量 ≤ 20MB。

### 5.6 双目标：同一份产物，两个宿主

| 层 | 浏览器/编辑器 | 微信小游戏 | 差异处理 |
|---|---|---|---|
| 传输 | `System.Net.WebSockets` / 原生 WS | `wx.connectSocket` | `ITransport` 两个实现，`#if PLATFORM_WX` 切换 |
| 生命周期 | `OnApplicationPause/Focus` | `WX.OnHide/OnShow` | `Lifecycle.cs` 归一成 `Suspended/Resumed` 事件 |
| 存储 | `PlayerPrefs` | `wx.setStorage`（SDK 已映射） | 直接用 `PlayerPrefs` |
| 资源 | `UnityWebRequest` / AB | **`WxAssetBundle`** | 必须换——官方明确 `UnityWebRequest` 在小游戏上会长期驻留内存 |
| 音频 | AudioSource | SDK 适配 | 需用户手势后才能播 |

**这个表的每一行都是一个 `#if`。** 所以传输与生命周期必须在 U0 就做成接口，不能等 U3 再抽——这是排期上"U3 不能完全后置"的原因。

### 5.7 小游戏专项风险

| 风险 | 影响 | 缓解 |
|---|---|---|
| 主包 4MB 卡死 | 无法导出 | 第一天就做"空工程全链路构建"（U0 末尾），量出空包基线；超了立刻裁模块 |
| IL2CPP 裁剪导致真机 `MissingMethodException` | 编辑器全绿、真机崩 | `link.xml` + 每域真机冒烟；不接受"编辑器通过即通过" |
| wasm 内存超限（iOS 被杀） | 低端机闪退 | wasm ≤ 12MB；纹理 ASTC + 分辨率上限；Performance+ |
| 备案/类目/版号 | 无法上线 | 第 0 周就启动，与技术并行 |
| `wss` 证书链（iOS 严格） | 真机握手失败 | 用受信 CA，`openssl s_client` 预验；iOS 不支持自签 |
| 转换 SDK 与引擎版本不匹配 | 转换失败 | 锁 2021.3.15 + SDK 指定版本，不随意升级 |

---

## 6. 服务端配套缺口

### 6.1 本次要补（MR + 核心循环）

| 批次 | 动作（示意） | 依赖表 | 人日 | 档 |
|---|---|---|---|---:|---|
| `ws_gate` | 新增服务：WebSocket 入口（文本帧 JSON），复用 `login`/`agent` | — | 2~3 | P0 |
| `hub` | `service/hub.lua` + `handler/cross.lua`：排行提交/查询/幂等/三级开关/snapshot | — | 3 | P0.5 |
| `stage` | `u.stageChallenge` / `u.stageSweep` / `u.stageInfo` | `guanka` / `monster_group` | 2~3 | U4 |
| `fight` | `u.fightStart` / `u.fightSettle` | `skill_formula` / `hero` | 3~5 | U4 |
| `shop` | `u.shopList` / `u.shopBuy` | `shop` / `item` | 1~2 | U4 |
| `reward` | `u.rewardSign` / `u.rewardOnline` | `sign` / `online` | 1 | U4 |

**MR 前置合计：5~6 人日**（P0 + P0.5）；核心循环再 +7~11。

### 6.2 暂不补

`rank`（本服）/ `gacha` / `home` / `errand`：属 M3 档，各自 1~5 人日，届时按阶段 5 的批次流水线补。

---

## 7. 跨服类功能：分析与最小落地

完整分析见 **`docs/CROSS_SERVER.md`**，这里只留结论。

### 7.1 原服机制（一句话）

`global` 中心进程（控制面）+ Redis（数据面）+ `fight` 独立进程（战斗面），用 7 个 `co.*` + 39 个 `gl.*` + 7 个 `gld.*` 串起来；跨服排行靠"中心每 5 分钟向所有服广播，各服回推 top-200，中心 `synchronized` 全量合并"。

**一个容易看错的数字**：这 46 个 GAS→中心常量里，师徒占 21（46%）、邀请码占 14（30%），**跨服排行只占 2 个（4%）、跨服战只占 4 个（9%）**。也就是说"跨服"在原服是一个**共享中心被多种玩法复用**，排行只是其中最薄的一层——所以新版必须把它做成通用设施（`hub`），而不是给排行写死一条链路。

### 7.2 五个真问题

| # | 问题 | 后果 |
|---|---|---|
| 1 | 中心定时全量轮询 | O(服数 × 200) 定时突刺；排行新鲜度恒为"上一轮" |
| 2 | 中心纯内存（`CACHE_GLOBAL_RANK_MAP`） | global 重启 → 排行清空 → 空窗一个周期 |
| 3 | 跨服战同步回源无超时（`syncOppInfo`） | 对端掉线 → 中心悬挂 |
| 4 | 单开关 `OPEN_CROSS` | 无法按分组/特性/比例灰度 |
| 5 | `cross$group$sid` 字符串做路由 | 格式靠 split；合服需迁历史数据 |

### 7.3 新版方案（只设计，不全落）

| 维度 | 原服 | 新版 |
|---|---|---|
| 拓扑 | global 进程 + Redis + fight 进程 | skynet 内 **一个 `hub` 服务** |
| 排行 | 中心拉，5 分钟全量 | **服推 + 版本号 + 按需对齐**（稳态零轮询） |
| 跨服战 | 同步取两侧 + 结算 | **两阶段 + TTL + 超时降级**，调用永不悬挂 |
| ID | `cross$group$sid` 字符串 | **`(gid, sid)` 整数二元组** |
| 开关 | 单开关 | **总闸 / 分组 / 特性 / 比例** 四级 |
| 幂等 | 无 | 每条带 `(sid, seq)`，`seq <= last_seq` 丢弃 |

### 7.4 本次只落最小可运行

| 交付 | 内容 | 人日 |
|---|---|---:|
| `service/hub.lua` | 排行提交/查询、`last_seq` 幂等、snapshot、三级开关 | 2 |
| `handler/cross.lua` | `u.crossSubmit` / `u.crossRank` | 0.5 |
| `test/test_cross.lua` | 4 条断言（合并正确 / 幂等 / 乱序丢弃 / 开关独立生效） | 0.5 |

**明确不做**：跨服战 `settle`、世界 Boss、公会战、跨服邮件/喇叭、hub 多实例、Redis 后端。全部只留接口与注释，不写半成品。

---

## 8. 排期（v2 重排）

> 单位：人日。1 名熟悉 C#/Unity + 该游戏的工程师；服务端批次同一人或服务端同学并行。
> 每个阶段都要有可复跑命令，无凭据不算完成。

### 8.1 阶段表

| 阶段 | 交付 | 验收 | 客户端 | 服务端 | 依赖 |
|---|---|---|---:|---:|---|
| **E0 环境** ✅部分 | .NET SDK 8 ✅ / Node ✅ / crypt.so ✅；**WebGL 模块、微信开发者工具需 GUI 手动装；Unity 许可证已过期需激活** | `dotnet --list-sdks` 8.0.428 ✅；`node -v` ✅；Unity 批处理启动即退（license expired）❌ | — | — | — |
| **P0 WS 入口** ✅完成 | `ws_gate.lua` + `lualib/skynet/crypt.lua` 桥接 + `tools/ws_smoke.mjs` + `test_ws_gate` | `make test` **377 PASS/0 FAIL**（老 327 无回归）；`make reconcile` 23/0；`make ws-smoke` **14 PASS** | — | 2~3 | — |
| **P0.5 跨服 hub** ✅完成 | `hub.lua` + `cross.lua` + aid16/17 + agent 跨服通道 + `test_cross` | `make test-cross` **30 PASS**；`make verify` **427 PASS** + reconcile 23/0（详见 §17） | — | 3 | — |
| **U0 骨架** ✅主体 | Unity 工程 + 3 个 asmdef、Core 1194 行（Json/Codec/Store/Delta）、`gen_cs.py`、74 项无头测试、真实线帧夹具 | `verify.py` **4 关全过**；`dotnet build` 0 警告 0 错；`dotnet test` **74/74**。**包体基线与 Unity 编译验证被许可证阻塞**（见 §12） | **7~9** | — | E0, P0 |
| **U1 登录/快照** ✅完成 | `Domain/Login`、`Form`/`Hud` 原语、`ITransport` 两个实现、`Lifecycle`、重连带 token；**另修 `ws_gate` token 免密缺陷** | `verify.py` **5 关全过**、142 项测试；**E2E 真连服务端 30/30**（首包 4 fid / grace 内恢复 / 超 grace 重建 / 冷启动 / rev 不回退） | **5~7** | **+0.3**（缺陷修正） | U0 |
| **U3 小游戏链路**（离线部分 ✅ / 真机 ❌） | 中文字体子集、IL2CPP `link.xml`、WebGL 构建脚本、wss 地址配置、转换模板、静态兼容门禁、冒烟清单 | 离线：`verify.py` **8/8**、`--e2e` **9/9**、Unity 编译 0 error；**真机进主城 / 主包 ≤4MB 尚未验证**（WebGL 模块、开发者工具、备案域名、商用字体均缺） | **4~6** | **+0** | U0, U2 |
| **U2 三玩法** ✅完成 | `hero`/`item`/`mission` + `List`/`Detail`/`Dialog` 原语 + `routes` 预加载；**另修 `u.snapshot` 只回 SNAPSHOT 的会话缺陷** | 客户端 `verify.py` **6/6**、152 项测试；回放 **23/23 同结论**；**E2E 真连服务端 46/46**（登录/将星/背包/任务）；Unity 批处理编译 0 error | **8~10** | **+0.2**（离线回放导出开关） | U1 |
| **MR 小计** | | | **24~32** | **5~6** | |
| **U4 战斗与关卡** ✅完成 | `stage`/`fight`/`shop`/`reward` 四 handler + 三域 + 结算页；10 连打/掉落经验/战斗结算/商店/签到 | `test_u4` **73 PASS**；reconcile **46/0**；客户端 161 项 + Unity 0 error（详见 §18） | 6~8 | 7~11 | MR |
| **U5 跨服排行 UI** ✅完成 | 只读列表 + 我的名次 + 灰度开关表现；`RankView` 纯函数解析 ACTION_RES 临时榜 + `CrossDomain`/页签 | 客户端 8/8、167 项；两 zone 同榜由 P0.5 `test_cross` T1 验证；灰度 `enabled=false` → 提示行不报错；Unity 0 error（详见 §19） | 2~3 | — | U4, P0.5 |
| **核心循环小计** | | | **32~43** | **12~17** | |
| **U6 M3 次要玩法** ✅完成 | `rank`/`gacha`/`home`/`errand`（降级版）+ hub `upsert` + 四域/四页签 + 11 批回放夹具 | `test_u6` **51 PASS**；reconcile **63/0**；客户端 183 项 + 8/8 + E2E 9/9 + Unity 0 error（详见 §20） | 8~12 | 8~14 | 核心循环 |
| **U7 表现打磨** ✅规则层完成（视觉验收延后） | 主题 v2（配色/字号/圆角 token）+ 运行时 9-slice 圆角 + 五原语改版 + 语义色（抽卡/结算/家园）+ 关键界面结论文案 | 客户端 **8/8**、185 项、Unity 0 error（详见 §21）；**人眼/真机视觉验收待资源与设备** | 8~12 | — | U6 或 U5 |
| **合计** | | | **48~67** | **20~31** | |

### 8.2 关键路径与两条排期判断

**关键路径**：`E0 → P0 → U0 → (U1 ∥ U3) → U2` = **MR 29~38 人日**（客户端 24~32 + 服务端 5~6）。

**判断一：U3 必须与 U1 并行，不能后置。**
最大不确定性不是"玩法能不能写对"，而是"**Unity 产物能不能塞进 4MB 主包并在真机跑起来**"。这个风险必须在 MR 前段就证伪——如果 U3 打不通，U2 写得再对也没用。所以顺序是「先证明能发布，再堆玩法」，而不是「先做完玩法再上小游戏」。

**判断二：U0 末尾就要量空包基线。**
`空场景 WebGL 构建 → 转小游戏 → 看主包大小`。这个数一旦超过 3MB，后续所有资源预算都要重算，甚至要换 2022.3/团结引擎。**这个测量只要半天，但能避免 U3 阶段推倒重来。**

### 8.3 与 v1（Cocos）的差额

| 项 | v1 | v2 | 差额 | 原因 |
|---|---:|---:|---:|---|
| MR 客户端 | 18~23 | 24~32 | **+6~9** | 小游戏链路 4~6、C# 协议层 2~3、asmdef/UGUI 骨架 2~3（部分与 v1 重叠） |
| MR 服务端 | 2~3 | 5~6 | **+3** | hub 跨服骨架新增 |
| 全量客户端 | 41~56 | 48~67 | **+7~11** | 主要是表现层（prefab 不可复用，C15） |
| 全量服务端 | 16~25 | 20~31 | **+4~6** | hub + 跨服排行 handler + fight 批次上浮 |

**一句话**：多出来的钱主要花在"Unity 能发布到小游戏"和"prefab 一个都用不上"这两件事上，不是玩法变多了。

### 8.4 分期建议

**先做 `E0 + P0 + U0 + U1 + U3`（约 19~26 人日，含环境准备）**——这一步的产出是"Unity 客户端能在微信真机上登录进主城"，四个关键假设同时被验证：小游戏包体能过、`wss` 通、无头测试能跑、程序化 UGUI 够用。`P0.5`（hub）可与这段并行，不影响主体路径。

**验证通过再投 U2**（8~10 人日拿到三玩法）。**不要一次性押 48~67 人日。**

---

## 9. 风险

| 风险 | 影响 | 缓解 |
|---|---|---|
| 主包 4MB 超限 | 无法发布 | U0 末尾量空包基线；`Engine Code Strip` + wasm 分包 + 移除未用 Module；兜底换团结引擎 |
| IL2CPP 裁剪导致真机崩 | 编辑器绿、真机红 | `link.xml` + 每域真机冒烟，纳入验收 |
| iOS wasm 内存被杀 | 低端机闪退 | wasm ≤12MB；ASTC + 分辨率上限；Performance+ |
| 服务端 handler 缺口被低估 | U4 阻塞 | U4 前先把 `stage`/`fight` 的样本与规则定下来（照阶段 5 流水线） |
| "查表不复刻"在带随机结算中不成立 | 客户端算不出预览值 | 预览只显示"可能范围"，最终值以服务端返回为准 |
| 程序化 UI 被质疑"不像游戏" | 决策反复 | MR 明确定位为"规则验证壳"；表现放 U7，Core 不改 |
| 原服规则只在 Java 代码里 | 数值/上限靠猜 | 每个 handler 批次附 `source`（Java 文件:行号）+ `derivation`，沿用 `docs/samples` 格式 |
| 生成器漂移 | 类型与协议不一致 | `contract.test` 进门禁 |
| 备案/类目耗时 | 无法上线 | 第 0 周启动，与技术并行 |
| 美术资源不可复用 | U7 超支 | 只取 png/字体；关键界面用通用素材先跑通，美术后补 |

---

## 10. 待确认

| # | 决策 | 选项 | 建议 |
|---|---|---|---|
| **Q1** | 本次做到哪 | **MR 最小可运行**（29~38）/ MR+核心循环（44~60）/ 一直到 M3（68~98） | **MR**，验证四个假设后再扩 |
| **Q2** | 引擎版本策略 | **2021.3.15 开发 + 2022.3 发布前复验** / 直接上 2022.3 / 直接上团结引擎 | 先 2021.3.15（已装），U3 量完包体再定 |
| **Q3** | 跨服落地边界 | **只 hub+排行**（3 人日）/ 加跨服战（+3~4）/ 全量 | **只排行**，跨服战等 `fight` |
| **Q4** | 服务端缺口谁补 | **本次一并补** / 服务端同学补 / 不补（客户端停在 U2） | 一并补，否则 U4 阻塞 |
| **Q5** | 域名与备案 | 已有备案域名 / 需新申请 | 影响 U3 真机联调时间，需尽早确认 |
| **Q6** | 美术来源 | 只取 `Lovely` 原图 / 另出设计稿 / 先用占位 | MR 用占位，U7 再定 |

---

## 11. 前置 P0：服务端 WebSocket 入口

### 11.1 为什么必须做

| 端 | 传输 | 说明 |
|---|---|---|
| `ch13_palace` 现有网关 `gated` | 裸 TCP + netpack（2 字节长度 + JSON + 4 字节 session），端口 9813 | `snax.gateserver` |
| 老客户端 `Lovely` | WebSocket + zlib 二进制帧 | 原 Java 服是 WS |
| **Unity / 微信小游戏** | **只能 WebSocket（小游戏只能 wss）** | 无法走裸 TCP |

### 11.2 设计

新增 `service/ws_gate.lua`，与 `gated` 并存、互不影响：

```
Unity(编辑器) ──ws://127.0.0.1:9814──────────► ws_gate ──► login / agent（同一套 handler/schema）
小游戏        ──wss://game.example.com(443)──► nginx ──► ws_gate
老工具        ──tcp:9813────────────────────► gated  ──► agent
```

- **帧内容：纯文本 JSON**（不做 zlib）。便于抓包；M1~M3 数据量下体积不显著；需要时再加 `clib/zlib.c`。
- **信封：7 种 kind**，不走 legacy 位置参数。
  - `{kind:1 HELLO, wire:2, params:{account,password,token}}`
  - `{kind:2 REQ, seq, aid, params:{...}}`
  - `{kind:3 RES, seq, aid, err, result}`
  - `{kind:4 SNAPSHOT | 5 DELTA | 6 EVENT | 7 PING}`
- **会话复用**：`ws_gate` 只做"握手 / 帧拆装 / fd 映射"，鉴权、实体创建、delta 生成、断线挂起全部调用现有 `login` / `agent`。
- **不需要给 `agent` 加 transport 抽象**（v1 曾以为需要）：现有结构里 `agent` 只 `return` 结果，发包在 `gated` 的 `send_envelope(fd, ...)`。`ws_gate` 复制一份自己的 `send_envelope`（走 `websocket.write`）即可，**`agent` 与 `gated` 一行不改**。

### 11.3 依赖与构建

```bash
# crypt（websocket.lua 握手要 sha1 + base64）—— 已实测可编译
cd skynet && gcc -O2 -fPIC -shared -I3rd/lua \
    -o luaclib/crypt.so lualib-src/lua-crypt.c lualib-src/lsha1.c -lcrypto
# 依赖已确认：/usr/include/openssl/sha.h、/usr/include/zlib.h（WSL）
```

`lualib/http/websocket.lua`（576 行）已具备 server 端能力：`M.accept / M.read / M.write(id, data, "text")`，握手内部算 `Sec-WebSocket-Accept`。**不需要自己实现握手。**

### 11.4 验收

```bash
make run                     # 终端 A：起服务（9813 TCP + 9814 WS）
make ws-smoke                # 终端 B：外部冒烟
make test                    # 门禁：含 test_ws_gate（50 断言）
make reconcile               # 门禁：23 用例
```

**已实测（P0 完成，2026-11-22）**

| 项 | 结果 |
|---|---|
| `make test` | **377 PASS / 0 FAIL**（原 327 + test_ws_gate 50）——老 327 项无回归 |
| `make reconcile` | **23 cases / 0 failed**（memory 驱动） |
| `make ws-smoke` | **14 PASS / 0 FAIL**（HELLO → SNAPSHOT → ACTION_REQ → ACTION_RES+DELTA → PING） |

`test_ws_gate.lua` 覆盖：W1 HELLO+快照、W2 动作与独立 delta（两个 fid 键）、W3 PING、W4 未知 aid、W5 未登录 REQ、W6 带 token 重连（rev 不回退、实体状态保留）、W7 顶号、W8 grace 到期落盘。

### 11.5 落地时修正的三处设计假设

设计稿里有三处与实测不符，已按实测修：

**① `crypt.so` 不能直接 `require`。** 设计稿假定 `luaclib/crypt.so` 装好即可，实测该 .so 只导出 `luaopen_skynet_crypt` / `luaopen_client_crypt`，没有 `luaopen_crypt`；而 `websocket.lua` 首行是 `require "skynet.crypt"`（标准 skynet 里该模块是 `luaclib/skynet/crypt.so`）。本工程加了一层桥接 `lualib/skynet/crypt.lua`：按 `package.cpath` 定位文件，再用 `package.loadlib(path, "luaopen_skynet_crypt")` 显式取入口，不改 skynet 库本身。`conf/skynet.conf` 的 `lua_path` 首项加 `./lualib/?.lua`。

**② 首包 fid 数不是 13。** 设计稿写「SNAPSHOT(13 fid)」，实际 `snapshot_by_policy` 会按 replicate 策略过滤：`snapshot`/`delta` 类下发，`on_demand` 需订阅，`none` 永不下发。新实体只初始化 `uid/account/level/gold` 四个字段，所以首包是 **4 个 fid**；全部可下发字段上限是 **9 个**（13 减去 on_demand 的 missions/activity 与 none 的 last_login/client_flags）。

**③ 出站 JSON 形状不稳定——这是真缺陷，不是假设。** 分区与 `delta.values` 用 fid 做键，fid 连续时（1,2,3,4）会被 `json.encode` 判成数组，下发 `[1000,"acc",1,0]`；fid 稀疏时又是对象。同一份客户端代码要在两种形状间猜。更糟的是稀疏表的 `#t` 在 Lua 里是未定义边界（实测 `{[1]=a,[3]=b}` 返回 1），旧实现按 `#t > 0` 判定会**静默丢掉 fid 3**。

修法两层：
- `shared/json.lua`：`is_array` 改为完整校验（键必须是 1..n 连续整数），并新增 `json.object(t)` 用元表显式打标强制 object；
- `shared/message.lua`：`encode` 出站前把 `SNAPSHOT.partitions[*]` 与 `DELTA.values` 统一标记为 object，`mask` 保持数组。

这两条都有回归守卫（`test_message` 新增 7 条断言）。

### 11.6 E0 环境状态

| 依赖 | 状态 | 说明 |
|---|---|---|
| .NET SDK 8 | ✅ 已装 8.0.428 | `dotnet --list-sdks` 可见（U0 的 `dotnet test` 前置已满足） |
| Node.js | ✅ v22.22.2 | 内置 WebSocket，冒烟脚本零依赖 |
| Unity 编辑器 | ✅ 2021.3.15f1c1 | 在官方已验证区间内 |
| `crypt.so` | ✅ 已编译 | WSL 中产物，WS 握手依赖 |
| **Unity WebGL 模块** | ❌ **需手动安装** | 该 Hub 版本禁用 headless CLI（`bad option: --headless`）。打开 Unity Hub → 安装 → 2021.3.15f1c1 → 添加模块 → **WebGL Build Support**（含 IL2CPP）。不装无法做 U3 的包体基线 |
| **微信开发者工具** | ❌ **需手动安装** | 官方要求 **Stable 版**（不要 Minigame Build）。U3 真机/模拟器调试用 |
| **Unity 许可证** | ❌ **已过期** | `C://ProgramData//Unity//Unity_lic.ulf` 存在但批处理报 `Unity license has expired`。打开 Unity Hub 登录并激活 Personal 版即可（U0 实测，2026-11-22） |

两项手动项都不阻塞 U0/U1（`.NET` 类库与无头测试不依赖 WebGL），但**阻塞 U3**，建议在 U0 并行期间装好。

---

## 12. U0 落地摘要（2026-11-22）

完整记录见 `C://workspaces//palaceclient//docs//U0.md`。

**成果**：`palaceclient` 独立仓已建；Core 手写 1194 行（`Json` 416 / `JsonValue` 194 / `Store` 196 / `Codec` 118 / 其余），生成物 418 行；
74 项无头测试 **0 失败**（JSON 16 / Codec 14 / Store 16 / Transport 7 / **真实线帧回放 7** / 契约 14）；
四道门禁统一入口 `tools/verify.py`（不依赖 make —— Windows Git Bash 没有 make，WSL 又没有 .NET SDK）。

**三个实测发现**（都已加回归守卫）：

1. **`long` 经 `double` 往返会改数**：`9007199254740993` 被静默写成 `...992`。`JsonValue` 加 `IsInteger` 标记，整数整段走 `long`。
2. **服务端会发 schema 之外的错误码**：真实帧里 `err=-200, reason="avatar_level_limit"`，而 schema 只有 7 个码。
   这不是 bug 而是分层——schema 管协议级错误，handler 管业务拒绝。客户端**不能做白名单**，必须保留原值 + 透出 `reason`。
3. **首包 fid 数取决于角色进度**：新号 4 个，有英雄后 5 个。§11.5 说的"可下发上限 9"是 schema 口径。

**两项被环境阻塞**（都只影响 U3，不影响 U1）：

| 项 | 原因 | 解除 |
|---|---|---|
| Unity 批处理编译验证（asmdef 是否真拦得住 `using UnityEngine`） | 许可证过期，批处理启动即退 | Unity Hub 登录激活 Personal |
| 空包体量基线（wasm / 主包 MB） | 无 WebGL 模块 + 许可证过期 | Hub 添加 WebGL Build Support |

替代措施已落地：分层铁律改成**静态门禁** `tools/check_layering.py`（校验 `noEngineReferences`、
`Game → Core` 单向、Core 无引擎引用、**每个 `.cs` 都被 asmdef 覆盖**），并备好 `tools/measure_build.py`（4MB/20MB/12MB 三档预算）。

**一个要提前知道的后果**：许可证不解决，U1 的 `Game/Render`（UGUI）代码只能「写完待验」，不能算交付；
但 U1 的核心（登录、状态、重连）全在 `Core` 里，`dotnet test` 可完整验收。

## 13. U1 落地摘要（2026-11-22）

完整记录见 `C://workspaces//palaceclient//docs//U1.md`。

**成果**：Core 新增约 1900 行（`Session` 536 / `LoginFlow` 267 / `Lifecycle` 193 / `PanelBuilder` 189 /
`PanelSpec` 141 / `ClientWebSocketTransport` 141 / `GameClient` 123 / `DomainHost` 102 / 其余），
无头测试从 74 → **142 项**；`Game/` 689 行（UGUI 原语 + jslib，**写完待验**）；新增
`build/PalaceHeadless`（真连 ws_gate 的验收客户端）与 `tools/e2e_login.py`（一条命令起停服务端并跑 E2E）。
门禁从四关扩到**五关 + 可选第六关 E2E**。

**真链路 30 项断言全过**：登录两帧配对 / 首包 4 fid / DELTA 独立成帧并应用 / grace 内切后台恢复 /
超 grace（=切后台 3 分钟）会话重建 / 冷启动 token 免密 / rev 全程不回退。

**四个实测发现**：

1. **token 续连在服务端原本不成立（真缺陷，已修）**：`do_hello` 无条件要求 password 非空，
   "客户端只存 token"必然 `BAD_ACCOUNT`。改为两级查找（网关内存会话 → `login.login_by_token`），
   回归守卫 `test_ws_gate` W9~W11（服务端 384 → **394 PASS**）。
2. **一次 HELLO 收到两帧同 seq**：`ACTION_RES(aid=1)` + `SNAPSHOT` 共用 seq 且顺序不保证；
   按 1:1 处理会让快照成孤儿（表现为"登录成功但主城空白"且日志无错）。Session 用 `WantsSnapshot` 显式建模 1:2。
3. **凭据口径必须全局唯一**：服务端算 `md5(客户端串 .. salt)`，一半明文一半 md5 会让同一账号互斥。
   摘要只在 `LoginFlow.LoginWithPlainPassword` 一处做。
4. **rev 跟着实体走**：`expire` 落盘、重建读回，所以"切后台 3 分钟后 rev 不回退"可以写成硬断言；
   客户端另加 `Store.MaxRev/RevRegressed` 识别"换了角色"。

**`Game/` 仍受环境阻塞**（许可证过期）：UGUI 与 jslib 只能写完待验。另记一个坑：内置 Arial 无中文字形，
WebGL 会显示方块，U3 前必须放一份中文子集字体。

---

## 14. U2 落地摘要（2026-11-22）

完整记录见 `C://workspaces//palaceclient//docs//U2.md`。

**成果**：Core 新增三域 + 三原语 + `RoutesBootstrap`（约 1200 行），`Game/` 补
`ListView`/`DetailView`/`DialogView` 并在 `Main` 接上三个页签；无头测试 142 → **152 项**；
E2E 30 → **46 项**。门禁从五关扩到**六关**（+回放夹具齐全），`--e2e` 为第七关。
许可证恢复后，**`Game/` 层第一次用 Unity 真编译通过**，并抓出两个 headless 看不到的
`Ui.Row/Column` 返回布局组而非 `RectTransform` 的错误。

**四个实测发现**：

1. **`u.snapshot` 只回 SNAPSHOT 帧**（`agent.lua:142-161`），`Session.RequestSnapshot` 原本按
   普通 `Call` 等 ACTION_RES，实测必然 8 秒超时；`Pending.SnapshotOnly` 修正后 routes 预加载才成立。
2. **订阅集不跨 agent 重建**：`subscribed` 是会话局部变量，grace 到期后清空；客户端每次 Ready
   都重新 `subscribe + snapshot`（`RouteBootstraps` 可断言）。
3. **回放快照的 fid 连续分区必须打对象标记**：`base` 的 fid 1..n 会被 json 编码成数组，
   客户端展平拿不到键；复用 P0 的 `json.object()`。
4. **新版没有 EVENT**：原版 `MISSION_AWARD_CLAIMED` 之类被折叠进 DELTA，结果提示只能来自
   `ACTION_RES.result.ok/reason`；schema 外 `-200` 原值保留、reason 透出到 Dialog。

**对账方式**：`service/replay.lua` 加可选 `CH13_REPLAY_WIRE_OUT`，从与 `make reconcile`
同一条 handler 路径导出 seed 快照 + `ACTION_RES` + 独立 `DELTA` 帧；客户端回放这 23 条真帧，
按同一份 expect 断言 err / result 子集 / state 点路径。默认对账输出一个字节不变
（`make verify` 394 PASS、`make reconcile` 23/0 复验）。

**剩余阻塞只剩 U3**：WebGL Build Support 与微信开发者工具仍未安装（已实测确认），
中文子集字体仍缺；真机冒烟与 ≤4MB 主包基线尚未验证，不能声称 U3 通过。

---

## 15. U3 落地摘要（2026-11-22，仅离线部分）

完整记录见 `C://workspaces//palaceclient//docs//U3.md`，真机清单见 `U3_SMOKE.md`。

**先核验环境**：许可证 ✅，但 WebGL Build Support（`PlaybackEngines/` 只有 windowsstandalonesupport）、
微信开发者工具（注册表与常见目录均无）、中文字体（仓库无任何 ttf/otf）三项仍缺。
所以本次只做**不依赖这三项即可机器验证**的部分，没有把"配置写好了"写成"真机通过了"。

**成果**：205KB / 884 字的中文子集字体 + 覆盖校验（`build_font.py --check`）、IL2CPP `link.xml`、
`BuildWebGL.cs`（PlayerSettings 代码化 + 场景自举 + wss 地址注入）、
`budget.json`（包体与 wss 唯一事实源）、`minigame/template/` 转换模板、
`check_webgl_compat.py` 静态铁律、5 组真机冒烟清单。
门禁 6 关 → **8 关**（+WebGL 兼容 +字体覆盖），`--e2e` 为第 9 关；Unity 批处理编译 0 error。

**五个实测发现**：

1. Unity 2021.3 的枚举是 `WebGLExceptionSupport.ExplicitlyThrownExceptionsOnly`，不是
   `ExplicitlyThrownExceptions`；headless 编译看不到 Editor 脚本，只有 Unity 真编译抓得到。
2. 字体必须做"覆盖源码字符"校验：新增带中文的构建脚本后旧子集立刻缺字，门禁当场失败；
   重建后 884 字符全过。
3. wss 地址原本硬编码在场景组件（`ws://127.0.0.1:9814`），小游戏上必被拦且无可读报错；
   改为 `budget.json → BuildWebGL → Resources/ws-url.txt → Main.ResolveUrl()`。
4. 模块裁剪要看依赖锁：`com.unity.ugui` 只依赖 ui + imgui，故可安全移除 8 个未用模块；
   animation / jsonserialize 保留。裁剪后 Unity 编译仍 0 error。
5. **字体授权是上线阻塞项**：子集源 simhei 是 Windows 系统字体，不可分发；
   上线前必须换 SIL OFL 授权的 Noto Sans SC 重跑脚本。

**未完成（不能声称 U3 验收通过）**：wasm 出包与主包 ≤4MB / 总量 ≤20MB 实测基线、
转换 SDK 产物、真机四 flow、OFL 字体替换。解锁条件是装 WebGL 模块 + Stable 版开发者工具 +
提供备案域名/AppID，然后按 `U3_SMOKE.md` 逐项勾选。

---

## 16. 一句话

**v2 相对 v1 的核心变化不是"换个引擎"，而是承认了三件物理事实：微信小游戏的主包只有 4MB，所以资源必须外置；WebGL 没有多线程，所以战斗必须在服务端算；小游戏不能动态生成代码，所以协议层必须自己写。这三条一旦写进设计，Unity 方案就从"更重"变成了"约束更清楚"——而跨服那部分，原服的三层设施其实是对的，问题只在"用轮询实现排行、用阻塞实现战斗"，新版把这两条对调，只花 3 个人日就能把最短链路跑起来。**

---

## 17. P0.5 跨服 hub 落地摘要（2026-11-22）

完整记录见 `CROSS_SERVER.md` 配套文档 `docs/P0_5_HUB_DEVLOG.md`。

**落地了什么**：按 §7.4 / `CROSS_SERVER.md` §4 落"排行"最短链路——`service/hub.lua`（提交/查询、`(sid,seq)` 幂等、乱序丢弃、三级开关、JSON 快照）、`service/handler/cross.lua`（`u.crossSubmit`/`u.crossRank`）、schema aid 16/17、agent 跨服通道（`ctx.call_hub`/`ctx.uid`）、`test_cross` 30 断言、`make test-cross`。`settle` 只留接口占位，不做跨服战/U4。

**凭据**：`make test-cross` 30/0；`make verify` **427 PASS / 0 FAIL**（基线 394，+33 = test_schema +3、test_cross +30）+ reconcile 23/0；check-schema 17 actions 同步。既有测试无回退。

**三个实测发现**：
1. `ctx` 既有契约禁止 handler 直接持有服务地址——跨服调用必须经 `ctx.call_hub` 显式注入（agent→网关→main 逐层传 hub 地址），不用 `skynet.localname`（历史失效教训）。
2. hub 的 `last_seq` 键是数字 sid，快照必须 `json.object()` 标记，否则被编码成数组丢语义——与 P0 的 fid 同坑。
3. 导表加 action 会撞 `test_schema` 的"action 数 == 15"硬断言；改为下界 + 具名校验后不再随加表腐烂。

**未做（保持设计边界）**：跨服战 `settle`、世界 Boss、公会战、跨服邮件/喇叭、hub 多实例、Redis 后端——全部未写半成品。下一步候选是 U4 战斗与关卡（服务端先补 stage/fight/shop/reward 样本与规则），U5 跨服排行 UI 依赖 P0.5 + U4。

---

## 18. U4 战斗与关卡落地摘要（2026-11-22）

完整记录见 `docs/U4_DEVLOG.md`（含 6 条问题归档）。

**落地了什么**：按 §6.1 补 MR 核心循环最后四批次——服务端 `service/handler/{stage,fight,shop,reward}.lua`（10 关逐关推进 + 扫荡、服务端权威战斗结算、商店买卖限购、签到/在线奖励），共享 `award`/`progress` 模块避免规则双写；gamedata 加 stage/shop/sign/online 四表、schema 加 aid 18~26；客户端 `palaceclient` 加 GameData 四表生成、Stage/Shop/Reward 三域与战斗结算页 Dialog、Game 层三页签。运行时进度态复用现有 `activity` map，**不新增 schema field**（保护 23 条既有回放基线）。

**凭据**：
- 服务端 `make test-u4` **73 PASS / 0 FAIL**；`make reconcile` **46 cases / 0 failed**（23→46，四批样本自动纳入 glob）。
- 客户端 `verify.py` **8/8**、无头测试 **161 项**（152+5 PanelU4+4 回放批次）；7 批真服务端 wire 夹具；Unity 2021.3 batchmode 编译 **0 error**；中文字体子集重建 209568B/901 字符。

**四个实测发现**：
1. 战斗结算与关卡推进共用 `award.apply_stage`，`fightSettle` 重打旧关只发奖不回退 `clearMax`——规则单点，杜绝双写。
2. 客户端 `gen_cs.py` 的局部变量 `stage` 被既有 `for stage in ...` 覆盖（Python for 变量函数级作用域）；改变量名规避。这类"生成器新变量撞循环变量"是隐蔽陷阱。
3. 加中文界面字（商店/签到/关卡）会让字体子集检查失败——每次新 UI 文案后必须 `build_font.py` 重建。
4. 硬编码"数量 == N"断言（域数量、action 数、批次清单）每加一批就腐烂——一律改下界 + 具名校验；回放 batch 清单目前两处硬编码（capture_replay/ReplayTests），下阶段应收成单一事实源。

**未做（保持设计边界）**：逐帧战斗、跨服战 `settle`（仍占位）、跳日真实日期源（签到 day 由客户端声明、服务端校验连续性）、U5 跨服排行 UI、U6 M3 玩法、U7 表现打磨。发布验证项（wasm 出包/主包≤4MB/真机四 flow/OFL 字体/域名 AppID）仍按用户要求延后。下一步候选：U5 跨服排行 UI（依赖已就绪的 P0.5 + U4）。

---

## 19. U5 跨服排行 UI — 落地摘要（2026-11-22）

**服务端零改动**：`hub.lua` + `handler/cross.lua` + aid 16/17 已在 P0.5 落地并由 `test_cross` T1（两 zone 同榜）/ T4（三级开关）验证。U5 只补客户端，不重造服务端链路。

**落地了什么**：
- 新增 `Core/Domain/Cross/`：`CrossDomain`（Name=cross，Actions 来自 generated Routes）+ `CrossPanels`（刷新榜/提交战力两动作）+ `RankView` 纯函数。
- 关键设计：排行是 `u.crossRank` 的 `ACTION_RES.result` 临时数据（cross handler 明确不写玩家 state），现有 `List` 原语只吃 store map——故用 `RankView.Parse(result)` 把回执解析成视图模型，`ToListModel()` 转成 List 原语能吃的列（名次/玩家/战力），Game 层只渲染。延续 U4 结算页"规则在 Core、渲染层不拼字段"的纪律。
- **灰度语义**：服务端开关关闭时 `err=OK` 但 `result.enabled=false`——不能用 `CallResult.Ok` 判灰度。`RankView` 归一成"正常榜 / 灰度关闭 / 网络失败"三态；灰度时返回提示行（`Disabled=true`），入口灰掉显示原因而非弹错误框，正是 `CROSS_SERVER.md` §3.5 要求。
- `GameClient.QueryCrossRank()` 把网络结果与 RankView 解析封装在 Core；Main.cs 加"跨服排行"页签，异步回执按 panelId 丢弃过期结果。

**凭据**：
- 客户端 `verify.py` **8/8**、无头测试 **167 项**（161+6 PanelU5）；`verify.py --e2e` 见开发记录；Unity 2021.3 batchmode 编译 **0 error**；中文字体子集重建 213168B/915 字符。
- 两 zone 同榜由 P0.5 `test_cross` T1 验证；服务端 `make verify` 500 PASS 不回退。

**实测发现**：改 Game 层（Main.cs）时 headless/dotnet test 看不到，必须有 Unity batchmode 编译关卡——本次 U5 再次抓到一次缺 using（ListModel 等），补 `using Palace.Core.UI` 后 0 error。verify.py 串行两次 dotnet build + test 超工具前台上限，改后台跑。

**未做（保持边界）**：跨服战 `settle`（仍占位）、排行分数自动提交（本次只做手动按钮）、hub 多实例/Redis。发布验证继续延后。下一步候选：U6 M3 次要玩法（rank/gacha/home/errand，依赖核心循环已就绪）。

## 20. U6 M3 次要玩法 — 落地摘要（2026-11-22）

**做了什么**：把 `CLIENT_V2_DESIGN` P1 表里四个"经营/养成外壳"降到"只留规则"的最小闭环——本服战力榜、抽卡、家园、办差，各自 flow 跑通，演出与运营壳一律不做。

**服务端（aid 27~32）**：
- `handler/rank.lua`：复用 P0.5 hub 的 `local.power` bucket。**新增 `hub.upsert`**（无 `(sid,seq)` 幂等门）——本服榜是单实例权威，用秒级 seq 走 `submit` 会导致"同一秒内战力变化被当 duplicate 丢弃"；跨服榜继续走 `submit`。
- `handler/gacha.lua`：确定性 LCG（`shared/lcg.lua`，整数运算，无真随机）+ 10 抽保底 + 重复返还 50 金币；权重表先按 tpl 排序再累加（`pairs` 顺序不可依赖）。
- `handler/home.lua`：等级 1~5，升级顺带结算旧等级产出（不再加"领取"action）。
- `handler/errand.lua`：派遣即完成、领取即发奖，`activity.errand.claimed` 防重。
- 全部进度仍在 `activity` map 子键里，**不新增 schema field**，23+23 条既有回放基线不受影响。

**客户端**：
- `Core/Domain/{Rank,Gacha,Home,Errand}` 四域；本服榜直接复用 U5 的 `RankView`（回执结构一致），不写第二份解析。
- 新增 `FieldSource.OfTableKey`：单页 Detail 能按**常量键**查配表（差事奖励文案），界面不重抄数值。
- `GameClient` 加 `QueryLocalRank/DrawGacha/QueryHome/UpgradeHome/QueryErrands`；`Main.cs` 四页签，结算弹窗显示 Core 拼好的结论（"获得 X · 第 3 抽"、"家园升到 Lv.3，花费 200 金币"），不弹"操作成功"。
- 家园页读 `homeInfo` 回执而非 store：**"下一级花费"要 level+1 查表**，静态 FieldSource 表达不了；满级时**不给按钮**（灰入口语义，与跨服开关一致）。

**凭据**：`make verify` **551 PASS / 0 FAIL** + reconcile **63/0**；`test_u6` **51/0**；客户端 `verify.py` **8/8**、dotnet **183 项**、`--e2e` 9/9（headless 46 PASS）、Unity batchmode **0 error**；字体重建 218408B/935 字符。

**本批抓到并修掉的四个真问题**（详见 `U6_M3_DEVLOG.md` §5）：测试服务漏 `skynet.dispatch/start` 导致 call 静默挂死；用了不存在的 `skynet.kill`；errand 货币类奖励用旧状态起算覆盖了固定奖励（对账抓到 1300→1000）；`claimed/bought` 这类数字键 map 的 JSON 形状随数据在数组/对象间漂移。

**未做（保持边界）**：抽卡演出、家园摆件/寻路、办差计时加速、rank 自动上报（仍走进入页面时懒提交）。发布验证继续延后。

## 21. U7 表现打磨 — 落地摘要（2026-11-22）

**做了什么**：把"能看"变成"像上线产品"——统一卡片层级、字段分组、克制的语义色，并让关键界面的结论一眼可读。**不引美术资源、不引图集、不引 TMP/Animator、不做 prefab**（prefab 一旦引入，界面就再也进不了 `dotnet test`）。

**主题 v2**（`Game/Render/Theme.cs`，换皮唯一入口）：11 个颜色 token + 4 档字号 + 5 个尺寸 token；`Theme.Rounded` 首次访问时**运行时生成** 9-slice 圆角贴图（逐像素按圆角距离算 alpha，1px 过渡当抗锯齿），生成失败自动退回纯色块；`Theme.AccentOf("ok"|"warn"|"rare"|"fail")` 把语义映射成颜色。

**五原语改版**：
- `Ui` 新增 `Panel`（圆角/降级）、`Divider`、`Badge`、配色 `Button`（ColorBlock 反馈）。
- `List`：行从"空格拼接的日志行"改成行卡片（首列主标题 + 弱色副标题 + 右侧"进入"）。
- `Detail`：三段式（卡片头 / 字段块：Surface 底 + 1px 分隔 + 标签弱值强 / 动作区：主按钮暖金、关闭改次按钮）。
- `Dialog`：顶部 6px 语义色条 + 标题随语义上色 → 抽卡"稀有紫 / 重复金 / 失败红"一眼可辨。

**语义色的位置**：Core 只产出语义字符串（`DialogModel.Accent`、`GachaView.Accent`、`HomeView.Accent`），颜色留在表现层。这样"稀有要高亮"这条规则能被 `dotnet test` 断言，换皮也不用改 Core。

**凭据**：客户端 `verify.py` **8/8**、dotnet **185 项**（+2 组语义色/对话框）、Unity batchmode **0 error**（首轮抓到 `GameClient.BuildDialog` 包装层未透传 `accent`）、字体 230044B/980 字符；服务端零改动，551/0 不回退。

**明确延后**：人眼/真机视觉验收、安全区适配、抽卡演出、有美术资源后的真实图集与 prefab 化（详见 `U7_PRESENTATION_DEVLOG.md` §7）。
