# v09_reconnect · 重连退避与状态机

**对应篇目**：V09《断线不是接着玩》｜**档位**：B 档

## 解决什么

服务端把连接标 `offline`、等新 fd `rebind`；客户端以为"网卡了一下"。两边对"断线"的定义不同，
就会出现回档。这个目录把两端参数放在一起算，让"来不及"这件事变成一道可断言的不等式。

## 文件

| 文件 | 作用 |
|---|---|
| `reconnect.py` | 退避序列（±20% 抖动）、预算、判定函数、五状态状态机 |
| `test_reconnect.py` | 26 条断言：序列、抖动范围、C-14 不等式、状态机路径 |

## 跑

```bash
python unity_client/v09_reconnect/test_reconnect.py
```

## C-14：这条不等式就是回档的根因

```
客户端发现断线 = 心跳 5s + 超时 15s = 20s
服务端窗口     = CH12_OFFLINE_TIMEOUT = 100cs = 1s
→ 晚了 19s，重连到达时服务端已 save_and_exit，只能重新读档
```

`reconnect_verdict()` 会把这三个数算出来并给出 `fallback_to_reload`。把窗口放到 30s
就变成 `False` —— 参数必须两端一起定。

## 退避：别用固定间隔

`1s→2s→4s→8s→15s`，累计 `1/3/7/15/30s`。固定 1 秒重试的问题是服务端重启时十万客户端
每秒一次重连，等于自己打自己。上限 15s 保证累计仍落在 60s 的产品预算内。

## 状态机不变量

`InGame → Reconnecting →(连上) Reauth →(验票) Resync →(全量校准) InGame`；
预算耗尽或票据失效 → `Login`。**重连成功必须先 Resync 再回 InGame** —— 直接续玩就是回档（C-16）。

## 证据边界

心跳 5s / 超时 15s / 退避 1-2-4-8-15s 是**经验起点，未做弱网实测**。真实值需按网络质量
分布标定。服务端侧 `OFFLINE_TIMEOUT_CS = 100` 引自 `ch12_disconnect` 实际代码。
