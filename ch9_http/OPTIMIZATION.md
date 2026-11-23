# ch9_http 设计取舍

> 依据：design.md Phase 6 —— HTTP 管理接口（GM 命令、健康检查）

---

## 0. 一句话结论

管理接口的价值不在"能发 HTTP"，而在**职责边界**：
只暴露只读指标 + 受控动作，**不做进程管理**（拉起/杀进程在节点外部）。

以及一条工程约束：**跨服务只能传值**。这两个设计决定引出了本文大部分经验。

---

## 1. 为什么不做 appmgr

design.md 写明"不实现 appmgr 管理进程，管理逻辑在节点外部"。

理由：

| 维度 | 节点内 appmgr | 节点外管理（本方案） |
|---|---|---|
| 进程崩溃后 | appmgr 也挂了，无法自救 | 外部系统独立存活 |
| 权限 | 进程能杀自己，权限边界模糊 | 边界清晰 |
| 复杂度 | 需要实现守护、重启、日志收集 | 交给 k8s / systemd |

本服务只提供：
- **只读**：`/health`（指标聚合）
- **受控动作**：`/gm`（需要 token，且只执行已注册的命令白名单）

---

## 2. 指标聚合：开闭原则

`/health` 不自己产生业务指标，而是调用注册上来的 provider：

```lua
providers[name] = function()
    local r = table.pack(skynet.call(provider_addr, "lua", cmd or "metrics"))
    if r[1] == error_code.ERR_INTERNAL then
        error(tostring(r[2] or "provider error"))
    end
    return table.unpack(r, 1, r.n)
end
```

好处：新增一个指标来源**不需要改 http_mgr**。
ch4 的登录 qps、ch7 的连接池状态、ch8 的组件消息数都可以直接挂上来。

### provider 失败要降级，不能崩溃

```lua
for name, fn in pairs(providers) do
    local ok, res = pcall(fn)
    if ok and type(res) == "table" then
        metrics[name] = res
    else
        failed[name] = ...
        n_failed = n_failed + 1     -- ⚠️ 不能用 #failed（hash 表恒为 0）
    end
end
```

一个 provider 挂掉 → `status: "degraded"` + `provider_errors` 带出原因，
其余 provider 的指标照常返回。**监控接口本身绝不能因为某个数据源异常而不可用。**

---

## 3. 安全边界

| 路由 | 鉴权 | 理由 |
|---|---|---|
| `/health` | 无 | 只读，供负载均衡探活；加鉴权会让探活配置复杂化 |
| `/gm` | Bearer token | 能修改状态 |
| `/callback` | secret | 内部系统回调，防止外部伪造 |

token 支持两种传递：`Authorization: Bearer <token>` 头，或 `?token=` 查询参数
（后者便于浏览器/curl 调试，但会进日志，生产建议只用头）。

未配置 token 时不鉴权（开发模式），但 `stats()` 会如实报告 `gm_token_set`。

---

## 4. 跨服务只能传值

这是本章最大的工程教训，踩了两次：

| 原设计 | 问题 | 新设计 |
|---|---|---|
| `register_metrics(name, fn)` | 函数无法序列化 | `register_metrics(name, addr, cmd)` |
| `register_gm(name, fn)` | 同上 | `register_gm(name, module_path)` |

失败表现是返回 `-1`（`ERR_INTERNAL`），**没有任何有用信息**——
因为序列化失败被骨架捕获成了统一错误码。

> **规则：设计跨服务 API 时，参数必须可序列化。**
> 需要"传行为"时，传**引用**（地址 + 命令名，或模块路径），由服务端自己解析。

附带收益：GM 命令以模块形式提供后，模块可以被热更替换（ch12 的基础）。

---

## 5. 性能相关

- **backlog 显式设 128**：`socket.listen` 默认 32，
  负载均衡高频探活会丢弃 SYN（与 ch4 完全相同的坑）
- **每个请求一个协程**：skynet 的 socket.start 回调天然并发，
  H13 验证 10 个并发 `/health` 全部成功
- **`Connection: close`**：管理接口不需要长连接，省去 keepalive 状态管理

---

## 6. 没有做的事

- ❌ **HTTPS**：管理接口通常部署在内网，TLS 交给网关层
- ❌ **keepalive / 连接池**：管理请求低频，不值得引入状态复杂度
- ❌ **请求限流**：当前由部署层（网关 / k8s）负责
- ❌ **进程管理**：见 §1

---

## 7. 验证

```bash
wsl -d Ubuntu make -C ch9_http test    # 35 断言
```
