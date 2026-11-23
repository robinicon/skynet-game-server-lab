# skynet-game-server-lab

基于 [cloudwu/skynet](https://github.com/cloudwu/skynet) 的游戏服务器架构逐章实现与优化笔记，配套 `[Unity 手记]` 客户端系列。

## 当前状态（2026-11-23）

本仓库按章节逐篇发布。**已发布 4 篇，待发布 5 篇**：

- 已发布：第 4–7 章，远端提交依次为 `821ea83` → `7fc9886` → `2fa9fac` → `872580d`
- 待发布：第 8–12 章，代码与文章已成稿，按周发布
- 实验章：`ch13_palace`（327 断言）未列入九章系列，无配套博客，不参与版本标签
- 配套客户端：`[Unity 手记]` V01–V16 已成稿，2027-01-05 起发布；代码在 `unity_client/`，**美术资源不开源**

发布排期、逐篇门禁与完成定义见 [PUBLISH_SCHEDULE.md](PUBLISH_SCHEDULE.md)，发布状态单一来源见 [STATUS.md](STATUS.md)。

- **运行时**：Skynet（Lua 5.4 + C），以 `git submodule` 挂在 `skynet/` 路径，锁定上游 commit `64391f732e76507ea6615f312cb71be1fd7bfbdd`
- **平台**：Linux / WSL（Skynet 是 ELF，Windows 下需经 WSL 运行）
- **测试**：九章合计 290 断言；已发布的第 4–7 章共 155 断言，逐章 `make test`，失败非零退出

## 快速开始

```bash
git clone --recursive https://github.com/robinicon/skynet-game-server-lab.git
cd skynet-game-server-lab

# 若已 clone 但未拉子模块：
# git submodule update --init --recursive

# 首次需编译 skynet
make -C skynet linux

# 跑已发布的四章测试（Windows 上经 WSL 执行）
for d in ch4_login ch5_perf ch6_ecs ch7_db; do make -C $d test; done
```

预期四章合计 `155 PASS, 0 FAIL`。ch7 默认使用 memory 驱动；要走真实 MySQL，需先启用 `mysql_native_password=ON`（MySQL 8.4 默认禁用）并建专用账号，详见 `ch7_db/README.md`。

客户端代码自测（本地 Python，不依赖 WSL）：

```bash
python unity_client/run_tests.py    # 期望 276 PASS, 0 FAIL
```

## 章节索引

| 篇 | 目录 | 主题 | 断言 | 状态 |
|---|---|---|---|---|
| 01 | `ch4_login/` | 端到端登录优化 | 18 | 已发布 |
| 02 | `ch5_perf/` | 对象池收益边界 | 59 | 已发布 |
| 03 | `ch6_ecs/` | 双语言 ECS 设计 | 41 | 已发布 |
| 04 | `ch7_db/` | 并发存盘安全 | 37 | 已发布 |
| 05 | `ch8_components/` | 组件式 Agent | 30 | 待发布（2026-11-24） |
| 06 | `ch9_http/` | 管理接口设计 | 35 | 待发布（2026-12-01） |
| 07 | `ch10_distributed/` | 分布式登录与跨节点容错 | 36 | 待发布（2026-12-08） |
| 08 | `ch11_jump/` | 分布式跳转 | 18 | 待发布（2026-12-15） |
| 09 | `ch12_disconnect/` | 断线重连与热更新 | 16 | 待发布（2026-12-22） |
| — | `ch13_palace/` | 宫殿大厅（实验章） | 327 | 未列入系列 |

## 目录

```
skynet-game-server-lab/
├── ch4_login/            # 第1篇 端到端登录优化
├── ch5_perf/             # 第2篇 对象池收益边界
├── ch6_ecs/              # 第3篇 双语言 ECS
├── ch7_db/               # 第4篇 并发存盘安全（memory / mysql 双驱动）
├── ch8_components/       # 第5篇 组件式 Agent（待发布）
├── ch9_http/             # 第6篇 管理接口（待发布）
├── ch10_distributed/     # 第7篇 分布式登录（待发布）
├── ch11_jump/            # 第8篇 分布式跳转（待发布）
├── ch12_disconnect/      # 第9篇 断线重连与热更（待发布）
├── ch13_palace/          # 实验章，未列入系列
├── unity_client/         # 客户端侧可复现代码子集（契约 + opcode 生成器 + 校验器 + 发布门禁，MIT）
├── docs/blog/            # 已发布文章；未发布稿留在本地
├── skynet/               # Skynet 依赖（git submodule，仅作依赖，不纳入本仓库源码）
├── PUBLISH_SCHEDULE.md   # 剩余篇目排期与门禁
├── STATUS.md             # 发布状态单一来源
├── .gitmodules           # submodule 定义
└── LICENSE               # MIT
```

每个已发布章节目录统一包含 `README.md`（设计与运行）、`OPTIMIZATION.md`（优化过程与实测数据）、`修复.md`（真实踩坑）、`Makefile`（test / run / clean）。

## 许可证

[MIT](LICENSE)
