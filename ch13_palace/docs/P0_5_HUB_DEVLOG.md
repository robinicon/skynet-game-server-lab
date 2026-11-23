# P0.5 跨服 hub 最小可运行 —— 开发记录

日期：2026-11-22。依据 `docs/CROSS_SERVER.md` §4 与 `docs/CLIENT_V2_DESIGN.md` §8.1。
纪律：只动 `bookskynet/ch13_palace`（skynet 新版），不动 `palaceserver/trunk` 与 `Lovely`。

## 1. 目标与边界

落地"排行这一条最短链路"，只做最小可运行：

- `service/hub.lua`：排行提交/查询、`(sid, seq)` 幂等、三级开关、snapshot 落盘。
- `service/handler/cross.lua`：`u.crossSubmit` / `u.crossRank` 两个动作。
- `conf/schema.xlsx`：新增 aid 16/17（handler=`cross`），由 `make gen` 生成物。
- `test/test_cross.lua`：4 条断言（合并 / 幂等 / 乱序丢弃 / 开关独立生效）。
- `make test-cross`：独立门禁目标，并并入 `TARGET` 默认集。

**明确不做**：跨服战 `settle`、世界 Boss、公会战、跨服邮件/喇叭、hub 多实例、Redis 后端。
`settle` 只留接口注释与 `error("not implemented")`，不写半成品。

## 2. 改造前基线（实测，2026-11-22 16:26 CST）

| 项 | 结果 |
|---|---|
| `make test`（test 段） | **394 PASS / 0 FAIL** |
| `make reconcile` | 偶发失败：Python `subprocess.run(stdout=PIPE)` 捕获 skynet 输出时 rc=-9（SIGKILL），日志停在 login 启动后；**同一命令重跑得 23 cases / 0 failed**。手动重定向到文件必成功（rc=0）。 |
| 结论 | reconcile 抖动是 WSL + subprocess 管道的既有环境噪声，**非本次改动引入**。门禁以"重跑可得稳定全绿"为准，每步记录重跑次数。 |

## 3. 子任务表

| # | 子任务 | 验收凭据 | 状态 |
|---|---|---|---|
| S1-0 | 记录基线与本文档 | 本文档 | ✅ |
| S1-1 | 导表加 aid 16/17 + `VALID_HANDLERS` 加 cross | `make gen`/`check-schema` 全过；17 actions，生成物含 16/17 | ✅ |
| S1-2 | `service/hub.lua` 最小实现 | 提交/查询/幂等/乱序/三级开关/快照；T1~T4 全过 | ✅ |
| S1-3 | agent 跨服务通道 + `handler/cross.lua` | `ctx.call_hub`/`ctx.uid` 注入；端到端 E2E 全过 | ✅ |
| S1-4 | `test/test_cross.lua` + `make test-cross` | `make test-cross` → **30 PASS / 0 FAIL**，无 error 噪声 | ✅ |
| S1-5 | 全量回归 + 文档更新 | `make verify` → **427 PASS / 0 FAIL** + reconcile 23/0；本文档收尾、记忆落盘 | ✅ |

## 4. 问题归档（现象 / 根因 / 方案 / 预防）

### P1 reconcile 偶发 rc=-9
- **现象**：`make reconcile`/`make verify` 中 `compare_with_java.py` 的 replay 子进程偶发 `rc=-9`，日志仅到 login 启动；同一命令重跑全过。
- **根因**：WSL 下 Python `subprocess.run(stdout=PIPE, stderr=STDOUT)` 捕获 skynet 大量 stdout 时的管道竞态/信号，非产品逻辑。手动 `> file` 重定向从不复现。
- **方案**：不改产品代码；门禁以重跑稳定结果为准，文档如实记录。
- **预防**：后续若要把 reconcile 接入 CI，先给 `run_replay` 增加"重试一次"或改文件重定向；本次属既有噪声，不在 P0.5 范围。

### P2 test_schema 硬编码 action 数导致回归
- **现象**：加入 aid 16/17 后 `make test` 报 `[test_schema] FAIL: action count (got 17, want 15)`，总断言 393/1 FAIL。
- **根因**：`test_schema.lua` 把 `na == 15` 写死；导表加 action 是本次预期改动，测试契约必须同步。
- **方案**：改为 `na >= 15` 并显式断言 `op_of(15/16/17)`，既兼容后续加表又锁定本次新增动作。
- **预防**：测试对"数量"的断言一律用下界 + 关键项具名校验，不用精确等号。

### P3 submit 死变量 / cross me 取值 / settle 日志噪声
- **现象**：三处自查发现：①hub.submit 里 `enabled` 判定后未使用（死代码）；②cross.rank 补 me 时用 `select(2, ctx.call_hub(...))`，而 call_hub 成功只返回 1 值 → 取到空；③hub.settle 用 `error()` 占位，测试主动调用时向 skynet 日志写 error 噪声。
- **根因**：均为实现细节疏漏，非架构问题。
- **方案**：①submit 返回带 `enabled/switch_reason` 字段，让 T4 可断言"关着也能写"；②改为直接取 call_hub 返回值的 `.rows`；③settle 改返回 `{ ok=false, reason="not_implemented", need="U4 fight handler" }`，保留接口占位语义但不 throw。
- **预防**：新写跨服务调用先确认返回值的元数（单值 vs 双值）；占位接口用结构化返回而非 error，避免 actor 崩溃传播。

## 5. 最终验收凭据（2026-11-22）

```
make test-cross          → 30 PASS / 0 FAIL（T1~T4 + 端到端，无 error 噪声）
make verify              → 427 PASS / 0 FAIL
  └─ reconcile           → 23 cases / 0 failed（hero 11 / item 6 / mission 6）
make check-schema        → 13 fields, 17 actions, 7 errors, xlsx ↔ 3 生成物 + mirror 同步
```

断言数变化：基线 394 → 427（+33 = test_schema 净 +3、test_cross +30）。既有测试无回退。

## 6. 交付文件清单

| 文件 | 改动 |
|---|---|
| `service/hub.lua` | **新增**：排行提交/查询、`(sid,seq)` 幂等、乱序丢弃、三级开关、JSON 快照落盘/恢复、settle 占位 |
| `service/handler/cross.lua` | **新增**：`u.crossSubmit`/`u.crossRank` 两个动作 |
| `test/test_cross.lua` | **新增**：30 断言（4 核心 + 端到端 + 边界） |
| `service/agent.lua` | `ctx.uid()` / `ctx.call_hub()` / `CMD.set_hub` |
| `service/gated.lua` / `service/ws_gate.lua` | 透传 hub 地址给新建 agent（`CMD.set_hub`） |
| `main.lua` | 启动并命名 `HUB`，注入两网关，测试 run 追加第 5 参 |
| `runtime.lua` | `hub_snapshot_path` 配置 + `CH13_HUB_SNAPSHOT` 覆盖 |
| `tools/gen_schema.py` | `VALID_HANDLERS` 加 `cross` |
| `conf/schema.xlsx` / `conf/schema.json` / `generated/*` | 加 aid 16/17 并重生成 |
| `test/test_schema.lua` | action 数断言改下界 + 具名校验 |
| `Makefile` | `test-cross` 目标并入 `TARGET`；test/test-one 注入 hub 快照路径 |

## 7. 里程碑与决策

- 决策 D1：hub 作为**独立 skynet 服务**，`main.lua` 起服务并命名 `HUB`；agent 经 `CMD.set_hub` 拿到地址，`ctx` 暴露 `call_hub` 给 cross handler。理由：handler 既有契约禁止直接碰 db/state，跨服务必须走显式注入，不破坏分层。
- 决策 D2：`(gid, sid)` 中 gid 本次固定为 1（单机单组），sid 用提交方 zone 标识；`seq` 由 `(sid, seq)` 唯一确定幂等键。理由：CROSS_SERVER §3.4 的整数二元组，单机验收无需多 gid。
