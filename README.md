# skynet-game-server-lab

基于 [cloudwu/skynet](https://github.com/cloudwu/skynet) 的游戏服务器架构逐章实现与优化笔记。

## 当前状态

本仓库目前只包含**第 4 章 `ch4_login`（端到端登录优化）**的代码与文档。其余章节（ch5–ch12）与配套技术博客将在后续提交中陆续发布，目前**不在本仓库中**。

- **运行时**：Skynet（Lua 5.4 + C），以 `git submodule` 挂在 `skynet/` 路径，锁定上游 commit `64391f732e76507ea6615f312cb71be1fd7bfbdd`
- **平台**：Linux / WSL（Skynet 是 ELF，Windows 下需经 WSL 运行）
- **测试**：`ch4_login` 自带 Skynet 测试服务，`make test` 跑完 18 个断言，失败非零退出

## 快速开始

```bash
git clone --recursive https://github.com/robinicon/skynet-game-server-lab.git
cd skynet-game-server-lab

# 若已 clone 但未拉子模块：
# git submodule update --init --recursive

# 首次需编译 skynet
make -C skynet linux

# 跑第 4 章测试（Windows 上经 WSL 执行）
cd ch4_login
make test
```

预期结果：`=== TOTAL: 18 PASS, 0 FAIL ===`

## 目录

```
skynet-game-server-lab/
├── ch4_login/        # 第4章 账号登录与验证（当前唯一已发布章节）
│   ├── conf/         # skynet 配置
│   ├── service/      # center / login / gate 服务
│   ├── gateway/      # 网关入口与 gated
│   ├── shared/       # token / service / utils 等公共模块
│   ├── proto/        # 协议定义
│   ├── test/         # 单元测试与 1000 并发压测
│   ├── README.md        # 设计与运行说明
│   ├── OPTIMIZATION.md  # 优化过程与实测数据
│   ├── 修复.md          # 实现中踩过的真实坑
│   └── Makefile         # test / run / clean
├── skynet/           # Skynet 依赖（git submodule，仅作依赖，不纳入本仓库源码）
├── .gitmodules       # submodule 定义
└── LICENSE           # MIT
```

## 许可证

[MIT](LICENSE)
