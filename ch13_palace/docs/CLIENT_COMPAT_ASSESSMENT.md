# Lovely 客户端 × ch13_palace(skynet) 兼容性评估

> 评估对象：`C:\workspaces\Lovely`（Cocos Creator 3.5.2 / TypeScript，1398 个 TS 文件）
> 对照对象：`C:\workspaces\bookskynet\ch13_palace`（skynet / Lua）
> 结论日期：2026-11-22

---

## 0. 结论摘要

**能不能还原：能，但不是"接上就能跑"，而是"要补一层兼容实现"。**

当前 ch13_palace 与 Lovely 客户端在**四个层面同时不兼容**，任何一个都会导致登录失败：

| 层 | 客户端要求 | ch13 现状 | 严重度 |
|---|---|---|---|
| 传输 | WebSocket 二进制帧，内容为 `deflate(JSON)` | 裸 TCP + `netpack`(2 字节长度) + 4 字节 session | 致命 |
| 登录 | HTTP `/lovelylogin/api/account/*` 换 ticket，WS 只验 ticket | 无 HTTP 服；WS 内用 `md5(密码+salt)` 验密码 | 致命 |
| 信封 | `{id,type:0\|1,op,params:[...],error:0,header}` | `type:"r"/"p"`，`error:200` 表示成功，`params` 是对象 | 致命 |
| 数据 | 原 Java VO 形状（AvatarVO 62 字段、item/hero 的 add/update/delete 列表） | 分区 fid blob + `{mask,values}` 增量 | 致命 |

**覆盖度**：客户端实际引用 **281 个请求 op**、注册 **56 个推送 op**；ch13 已实现 15 个动作，与客户端真正交集 **8 个**（且响应形状均不匹配）。覆盖率约 **2.8%**。

**技术可行性**：没有死点。WebSocket 服务端、sha1/base64、zlib 三条路都有现成解法（见 §4），所以这是**工程量问题，不是可行性问题**。

**分档工作量**（1 名熟悉 skynet + 熟悉该客户端的工程师）：

| 档位 | 交付标准 | 人日 | 累计 |
|---|---|---:|---:|
| A | 启动 → 登录 → 进主城 → 角色/货币/将星列表可见 | 12~17 | 12~17 |
| B | 核心循环：将星养成 / 背包 / 任务 / 家园建筑 / 商店 | 23~33 | 35~50 |
| C | 完整体验：经营 / 社交聊天 / 活动 / 排行 / 跨服 / 战斗 | 41~57 | 76~107 |

不含：战斗引擎重写（原服逐帧模拟 + 30 余个效果控制器）、支付渠道、热更。

---

## 1. 客户端事实（从代码读出，非推测）

### 1.1 技术栈与规模

- Cocos Creator 3.5.2，TypeScript，`assets/Scripts`(框架/模型) + `assets/Script`(业务/协议)
- 协议层集中在 `assets/Script/Net/`：`Server/NetSvc.ts`、`Net/Socket/ClientToServer/ClientNetConst.ts`、`Net/Socket/ServerToClient/ServerNetConst.ts`
- 客户端自有配表 **319 张 JSON**（`assets/Data/*.json`），例如 `HeroData.json`(27 模板)、`ItemData.json`(1568 条)
- 默认渠道：`GameVar.TARGET_SDK = 0`(CC_SDK_TEST)、`TARGET_OPR = "test"`、`TARGET_PUBLIC_SERVER = 0`
- 默认登录服：`http://192.168.0.200:9090/lovelylogin`；默认游戏服 `127.0.0.1:9101`

> 注：`ServerConfig.ts:8-9` 的 `SERVER_IP=127.0.0.1, SERVER_PROT=9101` 与原 Java 版 GAS 端口一致，说明这套客户端就是针对原服写的。

### 1.2 传输层：WebSocket + zlib

```ts
// NetSvc.ts:37
let url = StringUtil.Format("ws://{0}:{1}", ip, port);
// NetSvc.ts:185  发送：JSON → UTF-8 → zlib deflate → 二进制帧
let data4 = Zlib.deflateSync(new Uint8Array(data3));
this._ws.send(data4);
// NetSvc.ts:90   接收：二进制 → zlib inflate → JSON
let data2 = Zlib.inflateSync(new Uint8Array(data));
```

- 帧内容**永远是 zlib 格式（RFC1950，带 2 字节头 + adler32）**，不是 raw deflate
- 心跳：`{header:0, type:0, timestamp}`（`PACKET_TYPE_HEARTBEAT = "0"`），客户端 15 秒一次；服务端须回 `{header:0, type:1, timestamp:<服务器时间>}`
- 若 15 秒内没收到 pong，客户端弹重连窗（`NetSvc.readyShowReconnectBox`）

### 1.3 信封与分发

```ts
// NetSvc.ts:190
let nmsg = { id: this._rpcCounter, type: type, op: op, params: params, scope: 0, error: false, header: 1 };
```

客户端接收分支（`NetSvc.ts:94-121`）：

| 条件 | 行为 |
|---|---|
| `header == "0"` | 心跳：`type=0` 回 pong，`type=1` 校时 |
| `type == 1` | 请求响应：按 `id` 找回调；`if (dataObj.error)` 为真 → 视为失败 |
| `type == 0` | 服务端推送：按 `op` 查 `ServerNetConst.commandList` |

**两个硬约束**：
1. `error` 必须是 **0** 表示成功（JS 真值判断，`200` 会被当成失败）
2. `type` 必须是**数字** 0/1（`"r"`/`"p"` 无法命中任何分支）

### 1.4 HTTP 登录链路

`ServerConfig.ts:50-70` 定义全部端点（基址 `<LOGIN_URL>/lovelylogin`）：

| 端点 | 参数 | 用途 |
|---|---|---|
| `/api/account/list` | `name,group,version,extra` | 返回服务器列表 |
| `/api/account/create` | `name,pass,group,version,extra` | 注册 |
| `/api/account/reqTicket` | `name,pass,group,version,extra` | 换票 |
| `/api/account/reqTicketByToken` | `token,group,version,extra` | token 换票 |
| `/api/account/checkTicket` | `name,ticket,group,version,extra` | 校验票 |
| `/api/account/loginByTicket` | `name,ticket,serverId,group,version,extra` | 进服换票 |

- 密码在客户端先做一次 `Md5.init(pass)`（`HttpService.ts:49`），服务端做二次加盐
- `/account/list` 响应必须是：
  ```json
  { "accout": "...", "allSrv": [{"serverId":1,"serverName":"...","ip":"127.0.0.1","port":9101,"isPush":1,"newSrv":false}],
    "lastLoginSrv": [], "loginRoles": {}, "thirdPayOpenState": false }
  ```
  字段名 `accout` 是客户端拼写，不能改成 `account`；`allSrv` 为空则客户端无法进入游戏（`ILoginSystem.DefaultServer` 直接返回 null）

### 1.5 WS 登录与推送序列

```ts
// ClientProxy.ts:37
this.mSocket.send("u.login", account, password/*ticket*/, role, appVersion, resVersion, extra, callback);
```

即 `u.login` 是 **6 个位置参数**：`(account, ticket, role, appVersion, resVersion, extraJson)`。

登录后客户端依赖的推送（按原服顺序，`palace-game/.../UserService.java:165-215`）：

| 顺序 | op | 客户端用途 | 是否必须 |
|---:|---|---|---|
| 1 | `u.on_login_pre_guidance_info` | 引导 | 可省（无引导则跳过） |
| 2 | `u.on_login_pre` (`itemList`) | `ItemService.onChange(list)` | 必须 |
| 3 | `u.on_login_pre` (`heroList`) | `HeroService.onChange(list)` | 必须 |
| 4 | `u.on_login_pre` (`buildingList`) | `BuildService.initBuildList` | 必须（家园） |
| 5 | `u.resOpenedActivities` | 活动服务 | 建议 |
| 6 | `u.avatar_info`（槽位 1/3/4/5/10/11/12/14） | 分模块模型 | 必须 |
| 7 | `u.on_login` | **payload 被忽略**，仅触发进主城 | 必须 |
| 8 | `u.homeland_change` / `u.building_change` | 家园 | 家园必须 |
| 9 | `u.clientserverTime` | 定时校时 | 建议 |

### 1.6 客户端侧一个必须注意的缺陷

```ts
// ServerCommand.ts:54-58  —— u.on_login 的数据被完全丢弃
public userLogin(data: any) {
    UserService.getInstance().setUserLogin(true)
    GameEvent.getInstance().emit(EventConst.EVENT_USER_LOGIN);
}
```

而 `_avatarModel` **只在** `UserService.onChangeAvatar()`（`UserService.ts:81`，由 `u.avatar_change` 触发）里赋值。原 Java 服登录时并不推 `u.avatar_change`。

后果：若服务端照原服顺序推送，`UserService.avatarModel` 会是 **null**，而全工程有 **249 处**引用它；一开背包/将星/家园窗口就抛 `Cannot read property 'currencys' of null`。

两条修复路径（都便宜）：
- **服务端侧（推荐，不改客户端）**：登录时在 `u.on_login` 之后补推一条完整 `u.avatar_change`
- 客户端侧：`userLogin` 里恢复 `onChangeAvatar(data[0])`

### 1.7 客户端期望的数据形状（原 Java VO）

- `u.avatar_change` → `data[0]` 为 AvatarVO：`AvatarModel.ts:275-350` 读取 **62 个字段**（`id/gbId/lv/zhanli/currencys/CurrentGuanKa/formationList/bagModelList/valueMap/stringValueMap/marriedModel/...`），其中 `currencys[8]` 被当作繁荣度（`UserService.ts:112`）
- `u.item_change` → `data[0] = {addList, updateList, deleteList}`（`ItemService.ts:35`）
- `u.hero_change` → `data[0] = {addList, updateList, deleteList}`（`HeroService.ts:29`），英雄必须有 `uid`、`id`(模板 id)
- 动作响应 → `params` 是**位置数组**，惯例是 `[bool, payload]`：
  - `itemUse` 回调读 `data[0][0]` / `data[0][1]`（`BagUseCommand.ts:26`）
  - `missionClaimReward` 读 `data[0][1].dropItemMap`（`ChaptInfoItem.ts:464`）
  - `heroUpdateLvAuto` 读 `data[0]` 为布尔（`XianshiShengjiWnd.ts:449`）

---

## 2. 与 ch13_palace 的逐层对照

| 项 | Lovely | ch13_palace | 差异性质 |
|---|---|---|---|
| 接入方式 | `ws://ip:port` | `snax.gateserver` + `netpack`（TCP，2 字节长度 + 4 字节 session） | 需重写网关 |
| 压缩 | `deflate/inflate`(zlib) | 无 | 需新增 C 模块 |
| 心跳 | `header=0` 独立帧，15s | 无（PING 信封未接网关） | 需新增 |
| 成功码 | `error: 0` | `errors.OK = 200` | 改配置即可，但影响全局 |
| 响应类型 | `type: 1`（数字） | `type: "r"`（字符串） | 需改 `message.to_legacy` |
| 推送类型 | `type: 0`（数字） | `type: "p"` | 同上 |
| 返回值 | `params: [bool, payload]` | `params: {ok=true, rev=...}` | 需改 handler 契约 |
| 登录参数 | 6 个位置参数，第 2 是 ticket | 3 个：`account,password,token` | 需改 schema + 鉴权 |
| 鉴权 | HTTP 换票，WS 只验票 | WS 内 `md5(md5+salt)` | 需新增 HTTP 服 |
| 角色数据 | AvatarVO 62 字段 | 分区 fid（13 字段） | 需建 VO 映射层 |
| 变更推送 | add/update/delete 列表 | `{mask, values}` | 需改推送构造 |
| 动作数 | 281 被引用 | 15（交集 8） | 需补 273 |

### 2.1 覆盖度明细

| 功能域 | 客户端 op 数 | ch13 已实现 | 缺口 |
|---|---:|---:|---:|
| 登录/角色 | 21 | 2 | 19 |
| 将星/养成 | 20 | 5 | 15 |
| 任务/剧情 | 7 | 1 | 6 |
| 家园/建筑 | 15 | 0 | 15 |
| 经营(manage) | 39 | 0 | 39 |
| 商店/充值 | 14 | 0 | 14 |
| 活动/运营 | 17 | 0 | 17 |
| 社交/聊天 | 38 | 0 | 38 |
| 战斗/排行 | 12 | 0 | 12 |
| 其他（散装） | 98 | 0 | 98 |
| **合计** | **281** | **8** | **273** |

### 2.2 内容表缺口

| 项 | 客户端 | ch13 `conf/gamedata.xlsx` |
|---|---|---|
| 表数量 | 319 张 JSON | 6 张 sheet |
| 英雄模板 | 27 | 4 |
| 道具 | 1568 | 7 |
| 其他 | 活动/商店/任务/建筑/公式/语言… 全在客户端 | 无 |

**含义**：客户端自己带全套配表，服务端必须用**同一份 ID 与同一套数值语义**，否则客户端会显示"未知道具"或数值对不上。正确做法是把客户端 `assets/Data/*.json`（或原工程 Excel）作为服务端配表的上游，而不是继续维护 `gamedata.xlsx` 里那 4 个英雄。

---

## 3. 能不能"完整还原修复"的判断

### 3.1 可以还原的部分

- **登录进主城**：完全可行，且不需要改客户端一字节（服务端补推 `u.avatar_change` 即可绕过 §1.6）
- **角色/货币/将星/背包/任务/家园/商店**：可行，属于"照着原 Java 业务重写一遍"，规则可由客户端代码与配表反向确认
- **纯展示型功能**（排行、活动面板）：可行，数据可由服务端算或直接下发配置

### 3.2 难以"完整"的部分

- **战斗**：客户端要 `u.fightres.test` / `u.ranking_fight_result` 的战报结构，且原服是服务端逐帧模拟 + 30 余个效果控制器。要"看起来一样"必须有战报生成器；要"结果一样"必须复刻随机与公式。这是最重的一块，且无法从客户端反推全部规则
- **聊天**：客户端有独立 `ChatNetSvc`，连另一个端口，需独立 chat 服（原服是 3 个进程）
- **经营（manage，39 op）**：差事/货架/产出/加速，状态机复杂，是原工程里最容易出对账差异的模块
- **跨服/世界 boss**：依赖 Redis 与跨进程协调，原服有独立 global 进程

### 3.3 不可行的部分

- **支付/渠道**：客户端按 `TARGET_SDK` 走 13 个渠道 SDK，服务端不可能"还原"，只能按目标渠道单独接
- **热更**：客户端有 `HotUpdateBundle`，服务端无关

---

## 4. 技术可行性验证（关键依赖已实测）

| 依赖 | 现状 | 解法 | 成本 |
|---|---|---|---|
| WebSocket 服务端 | skynet 自带 `lualib/http/websocket.lua`（576 行），支持 server 模式、掩码、分片、ping/pong，`examples/simplewebsocket.lua` 就是服务端示例 | 直接复用 | 0.5 人日接入 |
| sha1 / base64 | `websocket.lua` 依赖 `skynet.crypt`；本仓库 `luaclib/` **没有 crypt.so** | 用 `skynet/lualib-src/lua-crypt.c + lsha1.c` 编译（系统已装 openssl 头与 libcrypto） | 0.5 人日 |
| zlib | skynet 无；系统有 `/usr/include/zlib.h` + `libz.so` | 仿 `clib/mysql.c` 写 `clib/zlib.c`（inflate/deflate，windowBits=15） | 1 人日 |
| HTTP 服务端 | skynet 自带 `lualib/http/httpd.lua` | 复用，5 个路由 | 2~3 人日 |
| MySQL | 已通（阶段 2 完成，`clib/mysql.c`） | 直接复用 | 0 |

**结论**：所有阻塞项都有明确解法，且都能在现有工程结构内完成（`clib/` 放 C 模块、`service/` 放服务），不需要改 skynet 子模块。

---

## 5. 建议路径

### 第一步：兼容层（不改客户端，12~17 人日）

1. `clib/zlib.c` + 编译进 `clib/`；`clib/crypt`（或 `luaclib/crypt.so`）
2. `service/ws_gate.lua`：基于 `http.websocket` 的 WS 网关，处理 `inflate → JSON → 归一化`、`JSON → deflate → 二进制帧`、心跳回包
3. `service/http_login.lua`：`/lovelylogin/api/account/*` 五个接口（复用现有 `login` 服的账号表与 ticket）
4. `message.to_legacy` 改为客户端信封：`type` 数字、`error=0`、`params` 数组
5. `service/handler/avatar.lua`：构造 AvatarVO（62 字段）+ `u.avatar_change` 补推
6. 登录推送序列编排：`on_login_pre×3 → avatar_info → on_login → avatar_change → homeland/simple`
7. 端到端验收：真客户端（Cocos 预览）能进主城、看到角色、货币、将星列表

**验收标准**：客户端控制台无 `null` 报错；`u.avatar_change` 后主城 HUD 显示正确等级/战力/货币。

### 第二步：核心循环（23~33 人日）

按 B 档顺序：将星(20) → 背包/道具 → 任务/剧情(7) → 家园建筑(15) → 商店(14)。每批沿用现有 `service/handler/<domain>.lua` 注册制 + `docs/samples/*.json` 对账，但**样本改为从客户端抓包**（因为客户端才是唯一权威）。

### 第三步：完整体验（41~57 人日）

经营(39) → 社交/聊天(38，含独立 chat 服) → 活动(17) → 排行/跨服/战斗(12，战斗引擎另计)。

---

## 6. 风险清单

| 风险 | 影响 | 缓解 |
|---|---|---|
| 客户端"被修改过"但无 git 历史 | 无法 diff 出哪些是改动、哪些是原样 | 以 `ClientNetConst` + `ServerCommand` 为契约唯一来源；行为不一致时以客户端为准 |
| 客户端配表与服务端配表不同源 | 道具/英雄显示错乱 | 服务端配表改为从 `assets/Data/*.json` 导出 |
| 战斗规则无法从客户端反推 | 战报/结果不可还原 | 先做"战报转发客户端预演"；结果类功能延后 |
| `error=200` 改 `0` 影响现有 229 个断言 | 全量回归失败 | 在兼容层做映射（内部仍 200，出站转 0），不动既有语义 |
| 现有 8 个动作返回形状不符 | 即使 op 匹配客户端也判失败 | 在 handler 契约加 `client_params` 适配层，不改业务逻辑 |

---

## 7. 一句话回答

**能还原，但要先补一层"客户端兼容层"（WS+zlib+HTTP 票+信封+VO 映射），约 12~17 人日才能进主城；完整还原到"能玩"是 76~107 人日量级。技术上没有死点，难点不在协议而在 273 个动作的业务规则与战斗引擎。**
