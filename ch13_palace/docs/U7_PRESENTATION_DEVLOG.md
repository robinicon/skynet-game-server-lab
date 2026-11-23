# U7 表现打磨 — 开发记录

> 阶段：U7（主题 / 图集 / 关键界面）　日期：2026-11-22　纪律：只动新版 `palaceclient`（服务端零改动），不碰原版 trunk/Lovely。发布验证继续延后。

## 1. 目标与边界

**目标**：让五个原语（Form / Hud / List / Detail / Dialog）从"能看"到"像一款上线产品"——统一的卡片层级、清晰的字段分组、克制的语义色；**关键界面**（战斗结算 / 抽卡结果）的结论要一眼可读。

**边界**（本次明确不做）：
- **不引入美术资源与图集**：工程里没有 UI 图，硬做图集只会多一堆占位图。圆角用运行时生成的 9-slice 贴图替代（零资源、零图集成本，WebGL 下也不增加包体）。
- **不引 TMP / Animator**：小游戏端少一层依赖；按钮反馈走 `ColorBlock`。
- **不做 prefab**：界面仍由 `render(model)` 从数据重建（与 U1~U6 同一条纪律），拖拽引用一旦引入，`dotnet test` 就再也断言不了界面。
- **视觉验收延后**：本次交付"可编译、可断言的表现规则"，人眼验收与真机截图需要设备与美术定稿，按用户要求一并延后。

## 2. 主题 v2（`Game/Render/Theme.cs`）

| 类别 | Token | 值 / 说明 |
|---|---|---|
| 底色 | `Background` | `#12141C` 全屏底（非圆角，避免四角露边） |
| 卡片 | `Card` | `#212631` 弹层卡片 |
| 行块 | `Surface` | `#2B303D` 卡片内的字段块/列表行 |
| 分隔 | `Line` | 白色 8% alpha，1px |
| 文字 | `Text` / `Muted` | `#EDEFF5` / `#99A3B3` |
| 强调 | `Accent` / `AccentSoft` | 暖金 `#EDBA4F` / 16% alpha |
| 语义 | `Success` / `Danger` / `Rare` | 绿 / 红 / 紫（稀有） |
| 字号 | `FontSmall` 18 / `FontBody` 22 / `FontTitle` 30 / `FontHero` 38 | 按 1080 宽基准 |
| 尺寸 | `Gap` 12 / `Padding` 24 / `Radius` 10 / `RowHeight` 56 / `ButtonHeight` 52 | — |

**圆角贴图**：`Theme.Rounded` 首次访问时生成 `2r+2` 的 RGBA32 小图，逐像素按"到最近角圆心的距离"算 alpha（边缘 1px 线性过渡当抗锯齿），`Sprite.Create(..., border: r)` 后以 `Image.Type.Sliced` 使用。失败时返回 null → `Ui.Panel` 自动退回纯色块，**不会崩**。

**语义色**：`Theme.AccentOf("ok"|"warn"|"rare"|"fail")`。Core 只产出语义（`DialogModel.Accent`、`GachaView.Accent`、`HomeView.Accent`），色值全部留在表现层——换皮不碰 Core，Core 也能被 `dotnet test` 断言。

## 3. 原语改造（`Game/Render/*`）

| 原语 | 改造点 |
|---|---|
| `Ui` | 新增 `Panel`（圆角/纯色自动降级）、`Divider`（1px 线）、`Badge`（小标签）、`Button(配色重载)`（ColorBlock 反馈、`ButtonHeight`） |
| `Form` | 卡片改圆角、标题用强调色；输入框沿用圆角 Card |
| `Hud` | 顶部状态条改圆角卡片 |
| `List` | 行从"空格拼接的日志行"改成**行卡片**：首列主标题、其余列弱色副标题、右侧"进入"按钮；表头合并进卡片标题 + 关闭键 |
| `Detail` | 三段式：卡片头（标题 + 关闭）/ 字段块（Surface 底 + 行间 1px 分隔 + 标签弱/值强）/ 动作区（主按钮暖金，关闭改次按钮） |
| `Dialog` | 顶部 6px 语义色条 + 标题随语义上色 + 正文 + 动作；抽卡"稀有紫 / 重复金 / 失败红"一眼可辨 |

## 4. 关键界面

- **抽卡结果**：`GachaView.Message` 给结论（"【稀有】获得 太子（保底触发）· 第 10 抽，金币 900"），`Accent` 给语义（rare/warn/ok/fail）→ Dialog 顶部色条与标题同步。
- **家园升级**：`HomeView.UpgradeMessage`（"家园升到 Lv.3，花费 200 金币，收取 小还丹 x2"）+ `Accent`（ok/fail）。
- **战斗结算**：沿用 U4 的 `fight.result` Dialog，改版后自动获得语义色（`CallAction` 统一按 `result.Ok` 传 ok/fail）。
- **办差领取**：确认页字段块用配表文案（U6 的 `OfTableKey`），领取后弹窗 + 刷新列表。

## 5. 验收

| 项 | 结果 |
|---|---|
| 客户端 `verify.py` | **8/8** |
| dotnet 测试 | **185 项**（183 + 2 组语义色/对话框） |
| Unity 2021.3 batchmode | **0 error**（两次：首轮抓到 `GameClient.BuildDialog` 仍是 3 参重载，已补） |
| 中文字体 | 重建 230044 B / **980 字符**（新增"进入/关闭/已满级/—"等文案） |
| 服务端 | 零改动，`make verify` 551/0 不回退 |

## 6. 问题归档

### P1 表现层改完了，门禁全绿，但 Unity 编译报 4 参重载不存在
- **现象**：`dotnet test`、`verify.py` 全过；Unity batchmode 报 `Main.cs(356): error CS1501: no overload for BuildDialog takes 4 arguments`。
- **根因**：`Main` 走的是 `GameClient.BuildDialog`（3 参包装），我只给 `PanelBuilder.BuildDialog` 加了可选 `accent`，包装层没跟着加。`PalaceCore` 编不到 `Game/Main.cs`（它在 Unity 工程里），所以 dotnet 侧完全看不到。
- **方案**：`GameClient.BuildDialog(panelId, key, message, accent = null)` 透传。
- **预防**：**改 Core 公开签名时，必须同时 grep 包装层与 Game 层调用点**；`Game/` 下的代码只有 Unity batchmode 能验，改一次跑一次（U4/U5 已各踩一次，这次是第三次，已写入记忆）。

### P2 圆角底板忘了铺满
- **现象（自查发现，未进构建）**：`Ui.Panel(_root, "bg", ...)` 返回的 Image 默认 sizeDelta=0，直接挂上去等于没有底板。
- **方案**：所有底板统一 `Ui.Fill(...rectTransform)`；`Ui.Root` 的全屏底也改成 `Fill`，并显式关闭圆角（否则四角露黑边）。
- **预防**："程序化 UGUI 里，凡是靠锚点铺满的节点都要显式 Fill"，不能指望布局组。

## 7. 后续（等资源/设备）

1. 美术定稿后把 `Theme.Rounded` 换成真实九宫格图，`Theme` 的 token 不用改。
2. 抽卡/战斗结算接演出（序列帧或 DOTween），本次只保证"结论可读、语义对"。
3. 真机截图与安全区适配（刘海屏），需微信开发者工具与真机。
4. 图集策略：等有图后按 1024×1024 分页，`Theme` 加 `SpriteRef` 解析，避免散图进主包。
