# v03_frame · 信封层

**对应篇目**：V03《四套信封收敛》｜**档位**：A 档（四处结构均给文件与行号）

## 这个目录解决什么

客户端按 `[opcode:u32][protobuf]` 组包，skynet 网关按 `[len:u16][sproto][session:u32]` 收。
两边都能编译、都能单测，接上就是不通。这里给出**一份可执行的字节定义**，三端对齐它：

```
[len:u32 BE][ver:u8][opcode:u32 BE][payload]
```

`len` 不含自身 4 字节；`opcode = channel << 16 | id`；`ver` 为 `0x02`（新）/ `0x01`（过渡期旧帧）。

## 文件

| 文件 | 作用 |
|---|---|
| `frame.py` | 黄金实现：编解码、粘包切分、版本判别、可读转储 |
| `frame_ref.lua` | 服务端侧参考实现（Lua 5.3，无依赖），嵌入 `gated.lua` 只需替换头与尾 |
| `frame_dump.lua` | 生成测试向量，供 Python 侧逐字节比对 |
| `test_frame.py` | 32 条断言：向量、边界、粘包、C-21 复现、跨语言等价 |

## 跑

```bash
python unity_client/v03_frame/test_frame.py
```

跨语言等价需要 WSL 里有 `lua`（`/home/dev/bin/lua`，走 `bash -lc` 才能进 PATH）。没有就跳过该项并明确报"环境缺失"，不静默通过。

## 证据边界

- **这是契约的可执行定义，不是客户端运行时**。客户端侧按本目录的字节序列实现，语言不限（C#/TS 均可）。
- `frame_ref.lua` 是参考实现，未接入 `ch4_login` 分支——接入属于 V03 迁移步骤 ③，尚未执行。
- C-21（首字节判别失效）在本目录被**复现**而非修复：`sniff_legacy_naive()` 保留错误做法用于回归，`sniff()` 是修复形态（固定偏移 4）。
