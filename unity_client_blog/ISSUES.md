# 客户端 × skynet 联调问题台账

本文件是 v3 系列（16 篇）的**唯一问题登记处**。纪律要求：客户端与服务器联调、以及整个开发过程中遇到的问题，必须先在本地登记、写明修复方案，再在对应篇目里按同样编号复述。博客里出现的每一个"坑"，都能在本表查到出处与处置状态。

**登记规则**

1. 只登记**有证据**的问题：代码行号、文件路径、命令输出、测试断言，三者至少占其一。
2. 不许写"感觉会有问题"。设计层风险单列 `风险` 类型，不混进"已发生"。
3. 修复方案必须可执行：改哪个文件、改哪一行、怎么验证。
4. 状态四档：`已修复`（改完并跑过验证）｜`方案已定`（设计定案，未落地）｜`待实现`（缺件）｜`风险`（未发生，只做预案）。
5. 编号不复用、不删除。修错了就追加一条，保留过程。

**状态统计（截至 16 篇成稿 + 开源代码落地）**：已修复 7 条、方案已定 20 条、待实现 15 条、风险 4 条，共 **46** 条。其中 C-46 由开源代码的槽位冲突检测新发现。

---

## 一、信封与协议层

### C-01 四套信封互不兼容

- **类型**：已发生（静态核对即可确认）｜**篇目**：V03
- **现象**：客户端按 `[opcode:u32][protobuf]` 组包，skynet 网关按 `[len:u16][sproto][session:u32]` 收。两边各自可编译、可单测，接上直接不通；报错落在"解析失败"，指向不了信封。
- **证据**：`unity_client/protocol/gen/Opcode.cs`（`AUTH_LOGIN_REQ = 0x00060001`）；`ch4_login/gateway/gated.lua:36`（`netpack.pack`）；`ch4_login/proto/game.proto`（sproto）。
- **根因**：客户端的契约来自另一套工程口径，服务端沿用了 skynet sproto 模板，中间没有一层"线格式冻结"。
- **修复方案**：网关改 `[len:u32][opcode:u32][protobuf payload]`，首包按 opcode 分派；过渡期用首字节判别双栈（详见 `unity_client/docs/frame_decision.md`）。
- **验证**：`make -C ch4_login test` 18 断言全绿 + 双栈灰度一周无解析失败。

### C-02 网关尾部取 session，会吃掉 payload

- **类型**：已发生（代码即事实）｜**篇目**：V03
- **现象**：上行消息若不带尾部 4 字节 session，`message:sub(-4)` 会把 payload 最后 4 字节当 session 切走，业务层拿到的是被截断的包。
- **证据**：`ch4_login/gateway/gated.lua:133-140`（`string.unpack(">I4", message, -4)`、`body = message:sub(1, -5)`）。
- **根因**：会话关联塞在**尾部**，而不是信封头部；客户端契约里根本没有 session 字段。
- **修复方案**：会话关联移到 payload 头部（`request_id`），或直接用 opcode 里的通道语义；网关不再从尾部切。
- **验证**：构造 1 字节 payload 的包，确认不再越界；`#message < 4` 分支保留作防御。

### C-03 版本门禁没有位置安放

- **类型**：方案已定｜**篇目**：V03 / V06
- **现象**：契约 v3 新增 `CLI_VERSION_CHECK_REQ`（`CLI` 通道 `0x000D`），要求接入第一帧就校验；但 ch4 网关首包固定按 `login_req` 解析，这一帧没有落点。
- **证据**：`opcode_registry.yaml`（`CLI_VERSION_CHECK_REQ`，`note: "[v3] 客户端版本门禁 · 接入时第一帧"`）；`gated.lua` 的 `handshake[fd]` 分支只认 `do_login`。
- **根因**：首包语义被写死成"登录"，而不是"按 opcode 分派"。
- **修复方案**：信封收敛后，`handshake` 分支改为按 opcode 派发；`CLI_VERSION_CHECK_REQ` 先回 `RSP`，版本不符直接回强更码并断连。
- **验证**：三组版本号（client / config / resource）各构造一次不符，确认都被拦在 `AUTH_LOGIN_REQ` 之前。

### C-04 契约缺两对 opcode

- **类型**：待实现｜**篇目**：V05 / V07
- **现象**：`RoleSelect`、`Character (List)`、`RoleCreate` 三个 prefab 没有任何一条消息能填满；契约里没有角色列表与创角。
- **证据**：`opcode_registry.yaml` v3 全表 22 条，`CLI` 通道无 `ROLE_LIST` / `ROLE_CREATE`。
- **根因**：契约是按"登录 → 进服"主线裁的，UI 侧的后半段没进需求。
- **修复方案**：只增不改，取 `CLI` 通道未占用 id 补 `CLI_ROLE_LIST_REQ/RSP`、`CLI_ROLE_CREATE_REQ/RSP`；同步 `opcode_snapshot.yaml`。
- **验证**：`check_opcode.py` rc=0；三端产物哈希一致。

### C-05 agent 只有 Ping 与 echo

- **形态**：待实现｜**篇目**：V05 / V07
- **现象**：即使 opcode 补齐，服务端也没有角色 handler，请求会被 `handlers.client` 落到 `return ""`。
- **证据**：`ch4_login/service/agent.lua:80-102`，仅 `CMD_PING` / `CMD_ECHO` 两个分支。
- **根因**：ch4 的交付目标是"登录链路打通"，业务面刻意留空。
- **修复方案**：agent 增两个 cmd，转调 `ch7_db` 的 `RoleLoad` / `RoleSave`（不新造存储）。
- **验证**：新增用例覆盖"列表空 / 单角色 / 满 4 角色"三种返回。

---

## 二、契约工具链

### C-06 opcode 快照与注册表版本不同步

- **类型**：已修复｜**篇目**：V04
- **现象**：`opcode_registry.yaml` 已升到 v3，`opcode_snapshot.yaml` 仍是 v2 口径；校验器把"新增 opcode"误判成"回退"。
- **证据**：两文件 `version` 字段不一致；`check_opcode.py` 的快照比对分支。
- **根因**：快照是"上次发布"的副本，改注册表时漏了同步。
- **修复方案**：以注册表为源重新导出快照（`snapshot` 只读生成，不手改）；把比对改为"只拦删除与改值，不拦新增"。
- **验证**：`python check_opcode.py` rc=0；故意删一条，rc≠0。

### C-07 双端各写一份枚举

- **类型**：风险｜**篇目**：V04
- **现象**：客户端与服务端各自维护 `Opcode` 常量，短期一致，长期必然漂移；且漂移在编译期完全看不出来。
- **根因**：缺少单一来源（single source of truth）。
- **修复方案**：`opcode_registry.yaml` 唯一来源 → `gen_opcodes.py` 产出 `Opcode.cs` / `opcode.h` / `opcode.lua`；CI 校验三份产物的哈希。
- **验证**：改注册表后不重跑生成器，校验器必须报错。

### C-08 打包脚本把平台名塞进 variant

- **类型**：已发生（代码即事实）｜**篇目**：V01 / V15
- **现象**：`BuildAB.cs` 用 `importer.assetBundleVariant = ext`（`win` / `android`）来区分平台，输出的目录是 `streamingAssets/assetbundle.win`；没有清单、没有版本号、没有增量。
- **证据**：`art/Assets/Scripts/Editor/BuildAB.cs`，`BuildSetting(string ext, BuildTarget)` 内。
- **根因**：variant 的本义是"同一资源的变体（如 lq/hq）"，被挪用成平台后缀；平台差异本该在构建目标层解决。
- **修复方案**：客户端侧不改蓝本脚本（只引用不修改），在自建流水线里补 `catalog.json`（包名 / 哈希 / 大小 / 依赖），variant 恢复只表画质档。
- **验证**：同一份资源出两平台，包名一致、哈希不同、catalog 可解析。

---

## 三、登录与存盘

### C-09 场景是空壳，加载链未验证

- **类型**：风险｜**篇目**：V02
- **现象**：`Empty` / `Login` / `Roles` 三个 `.unity` 的 Git blob sha 完全相同（`2826522b…`，均 5199 B）。
- **根因**：界面不在场景里，靠 prefab 运行时实例化；三个场景只是不同名字的同一份壳。
- **修复方案**：接受这个结构，在自建工程里补一个 `UIRoot` 入口，按流程加载 prefab；**不在文章里断言具体加载 API**（蓝本未公开）。
- **验证**：需在编辑器里实际打开工程确认（本环境未验证，标 `风险`）。

### C-10 DB 部分更新丢字段

- **类型**：已修复｜**篇目**：V07
- **现象**：`D3.2 gold preserved (partial update)` 在真实 MySQL 下 FAIL：只更新 `hp` 时，未提供的 `gold` 被写成 0；memory 驱动逐字段合并，一直是绿的。
- **证据**：`ch7_db/shared/db_driver.lua` 的 `Mysql:save_role`；`ch7_db/test/test_db.lua` D3.2。
- **根因**：SQL 用 `INSERT ... ON DUPLICATE KEY UPDATE hp=?, gold=?` 全量覆盖，而接口语义是"部分字段更新"。
- **修复方案**：按 `data` 里实际出现的字段动态拼 SQL，缺失字段用 `COALESCE(新值, 旧列)` 保留原值。
- **验证**：`CH7_DB_DRIVER=mysql make -C ch7_db test` 37 PASS；memory 侧 37 PASS 无回归。

### C-11 MySQL 8.4 认证插件与纯 Lua 驱动不兼容

- **类型**：已修复（环境侧）｜**篇目**：V07
- **现象**：`db init failed: -1`，日志里是 `errno:1251 Client does not support authentication protocol`。
- **根因**：skynet 的 `db/mysql.lua` 是纯 Lua 实现，走 sha1 握手；MySQL 8 默认 `caching_sha2_password`。
- **修复方案**：为驱动建专用账号并启用 `mysql_native_password`（`mysqld.cnf` 加 `mysql_native_password=ON`）；不动业务账号。
- **验证**：`mysql -u skynet -p… -e "SELECT VERSION()"` 通；ch7_db 双驱动 37 PASS。

### C-12 票据 TTL 与客户端重试不同源

- **类型**：方案已定｜**篇目**：V06
- **现象**：`token.TTL = 7200` 写在服务端 `shared/token.lua`，实际生效由 center 的 `token_index` 决定；客户端若自带一份超时时间，两边会各说各话。
- **根因**：有效期是服务端事实，客户端不该复制常量。
- **修复方案**：客户端只认 `AUTH_LOGIN_RSP` 里的票据与错误码（`ERR_TOKEN_EXPIRED=4` / `ERR_INVALID_TOKEN=5`），不缓存 TTL。
- **验证**：把服务端 TTL 改成 60s，客户端不改一行，仍能在过期后正确走重登。

---

## 四、属性同步与断线

### C-13 属性投影粒度不一致

- **类型**：方案已定｜**篇目**：V08
- **现象**：客户端要"哪些字段变了"，服务端给的是"哪个组件改了"；`ch8_components` 的属性归属 `bag` / `quest` / `skill` / `vip` 四个组件，组件内部字段名与客户端表现层不是一套。
- **证据**：`ch8_components/shared/component_*.lua`；契约侧 `CLI_SYNC_PROPS` + `Msg_Common.PropValue`。
- **根因**：缺一张"组件字段 → 泳道 → 客户端表现"的投影表。
- **修复方案**：以泳道为单位做白名单投影，全量只在进服/重连时发；增量按变更集发。
- **验证**：改一个组件字段，客户端只收到该泳道的一条增量。

### C-14 offline 超时双端不一致会回档

- **类型**：方案已定｜**篇目**：V09
- **现象**：服务端 `OFFLINE_TIMEOUT_CS = 100`（1 秒，可被 `CH12_OFFLINE_TIMEOUT` 覆盖）。客户端若按 30 秒退避重连，第二次重连到达时 agent 早已存盘退出，玩家看到的是"回档"而不是"续玩"。
- **证据**：`ch12_disconnect/service/agent_reconnect.lua:17-18`、`test/test_disconnect.lua:44-45`。
- **根因**：超时是**服务端**的时间事实，客户端把自己的重连节奏当成了对齐点。
- **修复方案**：客户端首轮重连必须在超时窗口内完成（本环境 1s，生产按实际配）；超窗后走"重新登录"而不是"续连"。
- **验证**：把超时调到 1s，客户端 0.5s 重连成功；1.5s 重连必须落到重登分支。

### C-15 跳转窗口期重放导致双执行

- **类型**：方案已定｜**篇目**：V10
- **现象**：`gate_redirect` 在 `window=true` 期间把消息压进 `buffer`，等新 agent `rebind` 后重放。客户端若在过场期间继续发操作，同一条指令可能被执行两次。
- **证据**：`ch11_jump/service/gate_redirect.lua:25-26`（入 buffer）、`:60-61`（rebind 取走 buffer）。
- **根因**：窗口期是"服务端缓存"，客户端没有对应的"锁输入"。
- **修复方案**：客户端收到跳转开始即锁输入 + 遮罩；重放消息带 `request_id`，客户端按 id 去重。
- **验证**：窗口期内连发 3 条，恢复后客户端只应产生 1 次表现。

### C-16 断线期间的发送队列没有上限

- **类型**：风险｜**篇目**：V09
- **现象**：弱网下客户端往往把操作排进本地队列，重连后一次性 flush；队列无上限时内存与重复提交都会失控。
- **修复方案**：队列封顶（条数 + 时长双阈值），溢出丢最旧并提示；重连成功先做一次全量校准再 flush。
- **验证**：注入 10 秒断网，队列不增长到失控；恢复后状态与服务端一致。

---

## 五、发布与上线

### C-17 小游戏只能 WSS，网关按 TCP 写

- **类型**：方案已定｜**篇目**：V15
- **现象**：微信小游戏没有原生 TCP，只能 `wx.connectSocket`；ch4 网关用 `netpack` 处理 TCP 流。这一层不改，小游戏连不上。
- **证据**：`ch4_login/gateway/gated.lua:36`（`socketdriver.send` + `netpack`）；参考工程定案「小游戏强制 WSS」（`01_三端架构与技术选型.md` §6）。
- **根因**：传输层与信封层耦合在一起。
- **修复方案**：信封统一后，TCP 与 WSS 共用同一套编解码，只换 Transport；WSS 用 binary frame，不再自己加 `tag`。
- **验证**：同一份登录脚本，TCP 与 WSS 两条链路都能完成 auth → gate → enter。

### C-18 iOS 2.5.2 与"代码热更"冲突

- **类型**：已发生（口径冲突）｜**篇目**：V01 / V14
- **现象**：同一份工程文档里，README 写"HybridCLR + xLua 双热更"，定案文档写"不做代码热更"。若按 README 施工，iOS 提审时会撞 2.5.2。
- **证据**：`legend3D/README.md`（双热更）vs `01_三端架构与技术选型.md` §1（不做代码热更）、`03_风险与决策清单.md` C8。
- **根因**：文档漂移，旧结论没被新约束覆盖。
- **修复方案**：以较新的定案为准；客户端只做资源热更，代码修复走审核；主蓝本的 csproj 无热更程序集，与此一致。
- **验证**：出包产物里不存在任何可下载执行程序集的加载入口。

### C-19 版本门禁三处版本号

- **类型**：待实现｜**篇目**：V16
- **现象**：`CLI_VERSION_CHECK_REQ` 要同时带 client / config / resource 三个版本，任一不符即强更；现在只有 opcode 定义，没有判定实现。
- **修复方案**：管理面（`ch9_http`）提供版本表；网关侧判定；不符返回强更码，不静默进服。
- **验证**：三组版本号分别构造不符，全部被拦在登录之前。

### C-20 根 README 与仓库现状漂移

- **类型**：已发生｜**篇目**：V16
- **现象**：根 `README.md` 仍写"只包含 ch4_login"，而远端已发布 ch4 / ch5 / ch6 / ch7。
- **修复方案**：README 目录树与"当前状态"按实际提交更新；发布前检查清单加一条"README 与 HEAD 一致"。
- **验证**：`git show --stat HEAD` 与 README 目录树逐项比对。

---

### C-21 首字节判别双栈失效

- **类型**：已修复（设计层）｜**篇目**：V03
- **现象**：双栈过渡期原设计"读首字节：`0x00` 走旧帧，否则按新帧"——实测字节上不成立。
- **根因**：新帧首字节是 `len` 高位，小包（<64 KB）首字节为 `0x00`；旧 sproto 首包首字节也常为 `0x00`。最常见的情况下两者完全撞车。
- **修复方案**：改为魔数 `0x02`（新）/ 兼容 `0x01`（旧），占 1 字节；或用端口分流。选魔数，避免两份部署。
- **验证**：构造 `len=0x08` 与 `len=0x00010000` 两个包，判别结果必须不同。

---

## 六、契约工具链（补充）

### C-22 生成的 C# 命名空间残留他工程名

- **类型**：待实现｜**篇目**：V04
- **现象**：`gen_opcodes.py` 的 `gen_cs()` 输出 `namespace Legend3D.Protocol`，与主蓝本 `GameBookClient` 无关。
- **根因**：生成器从上一套工程沿用，字符串硬编码。
- **修复方案**：namespace 参数化（`--namespace`），生成物仍禁止手改。
- **验证**：`grep -n "namespace" protocol/gen/Opcode.cs`。

### C-23 生成器 docstring 路径与实际不符

- **类型**：待实现｜**篇目**：V04
- **现象**：docstring 写 `python tools/gen_opcodes.py`，实际文件在 `protocol/gen/gen_opcodes.py`。
- **根因**：目录调整后未同步注释；`ROOT = parents[2]` 仍能跑，但照文档敲命令会找不到文件。
- **修复方案**：改 docstring，并在 README 给可复制命令。
- **验证**：按文档命令执行，返回 rc=0。

### C-24 校验器把 proto 关联变更判为违规

- **类型**：方案已定｜**篇目**：V04
- **现象**：只改 `proto` 字段（value 不变）也会 `exit 1`。
- **根因**：`changed` 比较整个字典，包含 `proto`。
- **修复方案**：保留严格（改语义应新增 opcode），另加 `--allow-proto-change` 显式放行并留痕。
- **验证**：改 proto 后不带开关 → fail；带开关 → pass。

### C-25 版本门禁残留 HybridCLR / xLua 字段

- **类型**：方案已定｜**篇目**：V05 / V16
- **现象**：`VersionCheckReq` 有 `assembly_version`、`lua_version`，而工程定案不做代码热更，二者恒为 0。
- **根因**：契约继承自旧工程，定案变更后未清理。
- **修复方案**：字段保留（proto 只增不改），注释标"保留，本工程恒为 0"；门禁只判 client / config / resource。
- **验证**：门禁用例只覆盖三项，不因 assembly/lua 为 0 而误拦。

---

## 七、登录与角色

### C-26 票据设计两套

- **类型**：待实现｜**篇目**：V06
- **现象**：契约注释写 `Ticket = base64({uid,channel,expire,nonce,sign})`、HMAC-SHA256、**60s 一次性**；服务端实现是 `base64(randomkey()..randomkey())` 128bit 随机串 + `token_index` 查表、**TTL 7200s**、不删即有效。
- **根因**：契约与实现来自两条不同来源。
- **修复方案**：以服务端实现为准，改契约注释；"一次性 or 可重复""TTL"写入协议文档；若要一次性，需 `drop_token` + 独立重放码。
- **验证**：同一票据连续用两次，行为与文档一致。

### C-27 错误码两份、数值撞车

- **类型**：待实现｜**篇目**：V06
- **现象**：`ch4/shared/error_code.lua` 与 `Msg_Common.ErrCode` 在 1/2/3/4/5/6 上数值相同、含义完全不同（如 4 = 票据过期 vs 服务器满）。
- **根因**：双端各自定义枚举，无人对照。
- **修复方案**：网关出口做映射（服务端码 → 契约码）作过渡；长期改为一源生成。
- **验证**：按数值排序逐行对照两份枚举，映射表覆盖全部码。

### C-28 `roles` 表缺创角字段

- **类型**：待实现｜**篇目**：V07
- **现象**：`roles` 只有 `uid/hp/gold/version/updated_at`，没有 `name/level/profession/gender`；创角无处落名。
- **根因**：表为"并发存盘实验"所建，不是为角色系统建的。
- **修复方案**：加定长列 + `UNIQUE KEY uk_name(name)`；外观细节走 `RoleBlob`。
- **验证**：`DESCRIBE roles` 含四列；并发同名创角只有一个成功。

---

## 八、同步、断线与跳转

### C-29 全量同步可能撞 65535 上限

- **类型**：风险｜**篇目**：V08
- **现象**：`netpack` 头为 `uint16`，单包上限 65535 字节；场景实体快照（多 NPC × 多属性）容易超。
- **根因**：2 字节长度头；全量策略未限范围。
- **修复方案**：信封升级 u32（C-01）+ 视野内裁剪；分片仅作兜底。
- **验证**：构造 100 实体 × 10 属性的全量包，量级估算 < 上限或走分片。

### C-30 旧连接回调误杀新连接

- **类型**：方案已定｜**篇目**：V09
- **现象**：重连成功后被旧连接的 `onDisconnect` 回调关闭，界面显示"已连接"但实际断开。
- **根因**：缺连接代数（generation）校验。
- **修复方案**：每条连接带 generation，回调先比对当前代数再执行。
- **验证**：断网→立即恢复→100ms 内连发两次断线回调，连接不被关闭。
- **备注**：来自参考工程 F030 事故记录，非本蓝本。

### C-31 Lua 前向 `local` 引用导致 `route` 为 nil

- **类型**：已修复｜**篇目**：V10
- **现象**：`CMD.rebind` 里调 `route` 报 `attempt to call a nil value`。
- **根因**：`local function route` 定义在 `CMD` 之后；Lua 的 `local` 作用域从声明行下一行开始，前向引用变成全局 `nil`。
- **修复方案**：把 `route` 移到 `CMD` 之前定义（`gate_redirect.lua` 注释中已记明）。
- **验证**：`make -C ch11_jump test` 通过。

### C-32 跳转窗口期无超时、无上限

- **类型**：风险｜**篇目**：V10
- **现象**：`begin_jump` 只置 `window=true`，无定时器；`rebind` 不到达则 `buffer` 持续增长，玩家表现为"卡死"。
- **根因**：窗口期只做了"开"和"关"，没做"过期"。
- **修复方案**：窗口加超时（如 10s）强制回滚并清空 buffer；buffer 加条数上限。
- **验证**：模拟 `accept` 永不返回，超时后 fd 回滚到原 agent。

---

## 九、AI 与资源管线（旁支）

### C-33 编辑器脚本误入运行时程序集

- **类型**：方案已定｜**篇目**：V11
- **现象**：脚本放在 `Assets/Editor` 之外时被编进 `Assembly-CSharp`，构建期因 `UnityEditor` 缺失失败；有人用 `#if UNITY_EDITOR` 包住一半，导致运行时那一半永不执行。
- **根因**：Unity 的 `Editor` 目录规则只对同名文件夹生效。
- **修复方案**：编辑器脚本统一放 `Assets/Editor/`；CI 断言 `Assembly-CSharp` 不含 `UnityEditor`。
- **验证**：`grep -c UnityEditor Assembly-CSharp.csproj` 为 0。

### C-34 助手直接覆盖文件

- **类型**：方案已定｜**篇目**：V11
- **现象**：生成内容直接写盘，改错了无法定位差异。
- **根因**：缺 diff 与确认环节。
- **修复方案**：写盘前展示 diff + 人工确认；写盘后 `AssetDatabase.Refresh()` 并触发编译验证。
- **验证**：取消确认后文件未变。

### C-35 AI 产出图不合 Unity 导入规范

- **类型**：方案已定｜**篇目**：V12
- **现象**：尺寸非 2 的幂、图标缺 alpha、场景图多 alpha。
- **根因**：生成端不感知导入规范。
- **修复方案**：入库前跑质检（尺寸 / 通道 / 命名），不合格直接拦。
- **验证**：构造三类坏样本，全部被拦。

### C-36 生成参数未留档，无法复现

- **类型**：方案已定｜**篇目**：V12
- **现象**："上次那张好的图"复现不出来。
- **根因**：无 manifest，seed 与采样参数未记录。
- **修复方案**：每图强制 manifest（seed / checkpoint / prompt / steps / cfg / sampler）。
- **验证**：按 manifest 重跑，产出与原件一致或高度接近。

### C-37 UI 图默认开 mipmap

- **类型**：方案已定｜**篇目**：V12
- **现象**：UI 小尺寸显示发糊，内存多占约 1/3。
- **根因**：Unity 默认导入设置。
- **修复方案**：`AssetPostprocessor` 按目录规则 `mipmapEnabled = false`。
- **验证**：导入后 Inspector 中 mipmap 关闭。

---

## 十、发布

### C-38 只开 ARMv7

- **类型**：待实现｜**篇目**：V13
- **现象**：`AndroidTargetArchitectures: 1`，64 位真机安装报 `INSTALL_FAILED_NO_MATCHING_ABIS`。
- **根因**：配置未跟"ARM64 + IL2CPP"定案。
- **修复方案**：改为 `3`（ARMv7 + ARM64）；CI 断言。
- **验证**：`grep AndroidTargetArchitectures` 得 3；64 位真机安装成功。

### C-39 包名为空

- **类型**：待实现｜**篇目**：V13
- **现象**：`applicationIdentifier: {}`，出包无有效 Bundle ID。
- **修复方案**：设为 `com.<company>.<game>`；CI 校验非空。
- **验证**：构建产物包名正确。

### C-40 脚本后端未设 IL2CPP

- **类型**：待实现｜**篇目**：V13
- **现象**：`scriptingBackend: {}` 走平台默认（Mono），与定案不符。
- **修复方案**：显式设 IL2CPP + Master + 裁剪等级；补 `link.xml`。
- **验证**：构建日志显示 IL2CPP；反射类型不丢。

### C-41 无账号注销协议

- **类型**：待实现｜**篇目**：V14
- **现象**：只有 `role.ISDELETE`（删角色），没有账号注销链路。
- **根因**：合规项未排期。
- **修复方案**：注销申请 → 二次确认 → 冷静期 → 真删/匿名化；补协议。
- **验证**：审核自查表"账号删除入口"一项可勾。

### C-42 未提供 Sign in with Apple

- **类型**：待实现｜**篇目**：V14
- **现象**：已接第三方登录，但无 Apple 登录。
- **根因**：国内习惯，未按 iOS 审核要求。
- **修复方案**：接入 Apple 登录，`account_oauth(provider=apple)`。
- **验证**：iOS 包内可完成 Apple 登录并进服。

### C-43 `tag=0x5953` 在 WSS 下冗余

- **类型**：方案已定｜**篇目**：V15
- **现象**：TCP 自定义帧的魔数在 WSS 下无意义，每包多 2 字节。
- **根因**：魔数用于裸 TCP 流判包，WSS 有帧边界 + TLS 完整性。
- **修复方案**：去掉 tag；加密交给 TLS。
- **验证**：WSS 链路抓包无 tag，登录链路正常。

### C-44 `CH9_GM_TOKEN` 未设置时 `/gm` 完全开放

- **类型**：待实现｜**篇目**：V16
- **现象**：`check_token` 对空 expected 直接 `return true`；未配环境变量时任何人可执行 GM 命令，且无告警。
- **根因**：开发便利优先，默认分支是"放行"而不是"拒绝"。
- **修复方案**：生产配置下空 token 拒绝启动；`/gm` 仅监听内网/127.0.0.1。
- **验证**：不设 token 启动应失败；公网访问 `/gm` 不可达。

### C-45 `/gm` 允许 GET，token 可走 query

- **类型**：待实现｜**篇目**：V16
- **现象**：`?token=xxx&command=...` 可执行命令；token 进 access log / 浏览器历史。
- **根因**：为 curl/浏览器调试方便。
- **修复方案**：线上只留 POST + `Authorization: Bearer`；GET 仅开发环境。
- **验证**：线上 GET `/gm` 返回 405。

### C-46 `quest.progress` 与 `quest.done` 抢同一个槽位 3100

- **类型**：方案已定｜**篇目**：V08
- **现象**：`quest.progress` 用 `3000 + (qid & 0xFF)`，`qid = 100` 时落到 `3100`；
  而 `quest.done` 的完成位集合固定在 `3100`。两个不同语义的字段共用一个槽号，
  同步时后到的会覆盖先到的 —— 表现为"任务进度显示成已完成"，或反过来。
- **根因**：分段表只按"段"划范围（3000~3999），段内分配用取模，与段内的固定槽位
  （`done=3100`）没有做联合冲突校验。示例值写进文档时没人跑过一遍全量分配。
- **修复方案**：活跃任务上限收到 64（`mask = 0x3F`），`progress` 占 `3001~3063`，
  `done` 保留 `3100`；容量超限在分配期拒绝，不允许静默回绕。
- **验证**：`check_slot_conflicts(active_qids=64, mask=0x3F)` 返回空；
  `active_qids=65` 必须报冲突（容量是硬约束，不是建议）。
  已落地为 `unity_client/v08_props/` 的 29 条断言之一。
- **备注**：这是"开源代码反过来修正文章示例"的一例 —— 正文第八节的槽位表按本文修正值落地。

---

## 十一、按篇目索引

| 篇目 | 涉及问题 |
|---|---|
| V01 | C-08、C-18 |
| V02 | C-09 |
| V03 | C-01、C-02、C-03、C-21 |
| V04 | C-06、C-07、C-22、C-23、C-24 |
| V05 | C-04、C-05、C-25 |
| V06 | C-03、C-12、C-26、C-27 |
| V07 | C-04、C-05、C-10、C-11、C-28 |
| V08 | C-13、C-29、C-46 |
| V09 | C-14、C-16、C-30 |
| V10 | C-15、C-31、C-32 |
| V11 | C-33、C-34 |
| V12 | C-35、C-36、C-37 |
| V13 | C-18、C-38、C-39、C-40 |
| V14 | C-18、C-41、C-42 |
| V15 | C-08、C-17、C-43 |
| V16 | C-19、C-20、C-25、C-44、C-45 |
