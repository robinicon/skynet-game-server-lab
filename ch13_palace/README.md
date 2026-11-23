# ch13_palace — 抽象数据 + 抽象消息最小服务端

在既有 skynet 书籍工程中新建的独立章节目录，**不改动 ch4~ch12 任何代码**。
目标：用最少的表和最少的消息种类，跑通「test 渠道登录 → 角色加载 → 快照 → 动作增量」这条关键链路。

## 当前状态

- `make test`：**551 PASS / 0 FAIL**（默认 memory 驱动；14 个测试服务）
- `make test-mysql`：**35 PASS / 0 FAIL**（MySQL 往返 + 重启持久化）
- `make reconcile`：**23 cases / 0 failed**；`make reconcile-mysql` 同样 **23 / 0**（换驱动不改语义）
- 已实现：schema 生成与校验、分区脏写与 rev、7 种统一信封、legacy 协议归一化、test 渠道登录、动作 delta、**TCP 网关**、**双存储驱动（memory / mysql，上层零改动）**、**会话完整化（断线挂起 / token 重连 / 顶号 / 超时落盘）**、**wire 分级协议**、**处理器注册制 + Excel 内容配表 + 回放对账（hero / item / mission 三批 6 个动作）**
- 未实现：其余 522 个原工程 handler、客户端移植（Unity 侧 client_state + wire=2）、灰度开关

## 快速开始

WSL 内：

```bash
cd /mnt/c/workspaces/bookskynet
make -C ch13_palace test
```

Windows Git Bash 调用 WSL：

```bash
MSYS_NO_PATHCONV=1 wsl.exe -e bash -lc \
  'cd /mnt/c/workspaces/bookskynet && make -C ch13_palace test'
```

单测 / 常驻 / 重新生成 schema：

```bash
make -C ch13_palace test-one T=test_schema
make -C ch13_palace test-one T=test_gate      # 只跑 TCP 网关端到端
make -C ch13_palace test-one T=test_reconnect # 只跑会话完整化（断线/重连/顶号/超时）
make -C ch13_palace test-one T=test_delta_wire # 只跑 wire 分级协议（过滤/订阅/增量）
make -C ch13_palace test-one T=test_action_hero   # 只跑将星养成批次
make -C ch13_palace test-mysql             # MySQL 驱动往返（需 mysqld 运行）
make -C ch13_palace reconcile              # 批次对账（docs/samples 回放比对）
make -C ch13_palace reconcile-mysql        # 同一批样本在 MySQL 下重跑
make -C ch13_palace verify                 # 门禁：test + reconcile
make -C ch13_palace run
make -C ch13_palace gen             # 从两份 Excel 导表生成 Lua（schema + gamedata）
make -C ch13_palace check-schema    # 校验 Excel 与生成物同步
make -C ch13_palace xlsx-preview    # 预览 schema 四张表
make -C ch13_palace gamedata-preview # 预览游戏内容表（英雄/道具/任务等）
```

网关监听 `127.0.0.1:9813`（`CH13_GATE_PORT` / `CH13_GATE_ADDRESS` 可覆盖）。
帧格式：`2 字节大端长度 + JSON + 4 字节大端 session`；首包必须是 `u.login` / `u.create`。

`u.login` params 第三位是 `token`（可选，老客户端只传账号密码仍兼容）：重连时带上它可精确找回挂起会话。
首包信封顶层带 `wire=2` 启用新协议（策略过滤快照 + 分区订阅 + 独立 `u.delta`）；不带则是 wire=1 全量兼容。
客户端需移植 `shared/client_state.lua` 的 `base_rev` 校验才能用 wire=2，未移植前保持缺省即可零改动运行。
断线重连窗口默认 3 秒，`CH13_SESSION_GRACE`（0.01s 单位）可覆盖；超时会把脏分区落盘并释放会话。
存储后端通过 `CH13_DB_DRIVER=memory|mysql` 切换（默认 memory）；MySQL 连接参数 `CH13_DB_HOST/PORT/USER/PASSWORD/NAME`
可覆盖，默认 `dev/dev123@127.0.0.1:3306/ch13_palace`。换后端无需改任何业务代码，会话语义一致。

预期输出末尾：

```
gamedata check: hero=4 exp=79 surmount=16 week=16 item=7 mission=3, lua + mirror in sync
schema check: 13 fields, 15 actions, 7 errors, xlsx in sync with 3 generated files + mirror
=== TOTAL: 551 PASS, 0 FAIL ===
```

## 目录

```
ch13_palace/
├── conf/schema.xlsx        # 事实源①：载体定义（fields/actions/errors/meta）
├── conf/gamedata.xlsx      # 事实源②：游戏内容（hero/hero_exp/hero_surmount/hero_week/item/mission）
├── conf/schema.json        # 导表生成的可读镜像（不参与运行）
├── conf/gamedata.json      # 内容表镜像（不参与运行）
├── conf/ddl.sql            # 阶段 2：MySQL 6 张表 DDL
├── conf/skynet.conf        # skynet 启动配置（测试目标、网关端口、DB 参数经环境变量注入）
├── clib/mysql.c            # 阶段 2：同步 MySQL C 扩展（产物 clib/mysql.so）
├── generated/              # 由 schema 生成的 Lua 表（勿手改）
├── shared/
│   ├── schema.lua          # schema 访问层：字段名 ↔ fid
│   ├── message.lua         # 7 种信封、归一化、delta
│   ├── json.lua            # 最小 JSON 编解码（skynet 不自带）
│   ├── db_driver_memory.lua # 内存驱动（对照基线）
│   ├── db_driver_mysql.lua  # MySQL 驱动（6 张表 + 脏分区 upsert）
│   ├── client_state.lua    # wire2 客户端参考实现（apply_snapshot/apply_delta + base_rev 校验）
│   ├── gamedata.lua        # 内容配置访问层（英雄/经验曲线/门槛/道具/任务）
│   ├── bag.lua             # 背包纯函数（数字键规范化、批量增减扣）
│   └── testutil.lua        # 断言计数器
├── service/
│   ├── db.lua              # 存储服务：驱动分发的薄层（memory / mysql）
│   ├── login.lua           # test 渠道账号与 session
│   ├── agent.lua           # 会话 + 处理器注册表分发 + suspend/resume/expire/shutdown
│   ├── gated.lua           # TCP 网关 + 会话状态机（挂起/重连/顶号/超时落盘）
│   ├── replay.lua          # 对账用离线回放器（不参与线上链路）
│   └── handler/            # 按领域注册的业务处理器
│       ├── hero.lua        # 将星升级/加官/进爵
│       ├── item.lua        # 道具使用/出售
│       ├── mission.lua     # 任务领奖
│       ├── view.lua        # 纯读动作
│       └── dev.lua         # 测试脚手架（u.dev.*，不计入迁移数量）
├── test/                   # 10 个测试服务（协议/存储/会话/wire/三个动作批次 + gateclient.lua）
├── docs/samples/           # 对账样本（hero/item/mission，含 Java 出处与推导）
├── tools/                  # 导表与对账工具链
│   ├── gen_schema.py / check_schema.py / make_xlsx.py
│   ├── gen_gamedata.py / make_gamedata_xlsx.py
│   ├── compare_with_java.py  # 回放结果比对，批次门禁
│   └── XLSX_PIPELINE.md    # 导表工具设计与表结构规范
├── ARCHITECTURE.md         # 整体架构设计
└── PLAN.md                 # 逐一落地计划与验收标准
```

## 设计要点

1. **数据无意义**：实体只存 fid，字段名/类型/分区/持久化策略来自 Excel 导出的 `fields_generated.lua`。
2. **消息无意义**：老协议 `{op,params}` 由 Excel `actions` 表路由为 `{kind,aid,params}`；一帧一 op 收敛到 7 种信封。
3. **Excel 单一事实源**：编辑 `conf/schema.xlsx` 后 `make gen` 生成 Lua，`check-schema` 防止漂移；工具链零外部依赖，详见 `tools/XLSX_PIPELINE.md`。
4. **只写脏分区**：字段变更标脏所在分区，rev 递增；避免原工程 99 列 + 6 个 6.25MB 大列全量重写。
5. **TCP 网关零改动接入**：首包 `u.login`/`u.create`，登录回包保持老 op；信封顶层 `wire=2` 才启用新协议，缺省 wire=1 全量兼容（delta 嵌回包）。
6. **双存储驱动**：memory 与 mysql 实现同一方法契约，`db.lua` 按 `CH13_DB_DRIVER` 选择；MySQL 用 6 张表 + 脏分区 upsert + 索引列分离，换后端业务代码零改动。
7. **会话状态机**：断线挂起 agent 不销毁，grace 窗口内带 token 换 fd 可恢复；同 uid 新登录顶号旧连接；grace 到期落盘脏分区并退出。状态全在 gated 单服务内，`gen` 递增使旧定时器失效，无锁且无竞态。
8. **wire 分级协议**：wire=2 时快照按 `fields.replicate` 策略过滤（on_demand 订阅后才推、none 永不推），delta 独立成 `u.delta` 包，`u.snapshot`/`u.delta` 支持主动拉取与 base_rev 追帧；客户端移植 `shared/client_state.lua` 后可兑现省流量收益，未移植保持 wire=1。
9. **处理器注册制**：schema 的 `handler` 列决定 `require("handler.<name>")`，`agent.lua` 不再有 if 链；新增一批动作 = 加一个 handler 文件 + 导表加 action。handler 只能通过 ctx 读写，统一由 agent 打 delta。
10. **内容与载体分离**：`schema.xlsx` 管 fid 含义与复制策略，`gamedata.xlsx` 管英雄/经验/消耗/道具/任务数值；handler 不硬编码数值。
11. **批次对账**：每批附 `docs/samples/<batch>.json`（带 Java 出处与手算推导）与 `test_action_<batch>.lua`，`make reconcile` 在干净实体上回放比对；同一批样本必须在 memory/mysql 下都通过。
12. **边界**：抽象载体，不抽象行为；抽卡/战斗等多步事务仍写在 handler 里。

详细论证见 `ARCHITECTURE.md`，分阶段实施见 `PLAN.md`。
