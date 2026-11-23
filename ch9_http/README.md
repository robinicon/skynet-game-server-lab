# ch9_http — 服务器管理与 HTTP

> 《游戏服务器架构》第 9 章的 Skynet 实现。
> 独立 HTTP 管理服务：健康检查、GM 命令、内部回调。

---

## 快速开始

```bash
# 接口测试（35 断言）
wsl -d Ubuntu make -C ch9_http test

# 常驻模式（手动 curl 调试）
wsl -d Ubuntu make -C ch9_http run
curl http://127.0.0.1:8899/health
curl -X POST -H "Authorization: Bearer dev-token" \
     -d "command=test&echo=hi" http://127.0.0.1:8899/gm
```

---

## 目录

| 路径 | 说明 |
|---|---|
| `service/http_mgr.lua` | **核心**：路由、鉴权、指标聚合、GM 命令表 |
| `service/metrics_demo.lua` | 指标提供者示例（含故意失败的命令） |
| `shared/json.lua` | 极简 JSON 编码器（skynet 不自带） |
| `shared/gm_double.lua` | GM 命令模块示例 |
| `test/http_client.lua` | 极简 HTTP 客户端（Connection: close） |
| `test/test_http.lua` | 35 断言 |

---

## 路由与安全边界

| 路由 | 方法 | 鉴权 | 说明 |
|---|---|---|---|
| `/health` | GET | 公开 | 聚合各服务指标，供负载均衡探活 |
| `/gm` | GET / POST | **Bearer token** | 执行 GM 命令 |
| `/callback` | POST | **secret** | 内部回调 |

**design.md 明确要求：不实现 appmgr 管理进程。**
管理逻辑在节点外部，本服务只暴露只读指标和受控动作，
**不做拉起/杀掉进程这类操作**。

---

## 指标聚合设计

`/health` 不自己产生业务指标，而是调用各业务服务注册的 provider：

```lua
-- 业务侧注册（跨服务只能传地址 + 命令名，不能传函数）
skynet.call(http_mgr, "lua", "register_metrics", "login", login_addr, "metrics")
```

输出：

```json
{
  "ok": true,
  "status": "healthy",
  "node": { "uptime_s": 12.34, "harbor": "0", "lua_mem_kb": 1234 },
  "metrics": {
    "demo_service": { "online": 42, "qps": 100, "pool_free": 3, "pool_total": 8 }
  }
}
```

**provider 失败时降级而非崩溃**：`status` 变为 `"degraded"`，
失败原因出现在 `provider_errors` 里，其余 provider 的指标照常返回。

---

## 内置 GM 命令

| 命令 | 说明 |
|---|---|
| `test` | 回显，用于连通性验证 |
| `online` | 返回在线数（从 login provider 取） |
| `reload` | 记录热更意图（真实实现见 ch12） |
| `gc` | 触发 `collectgarbage("collect")` 并返回释放量 |

扩展：`register_gm(name, module_path)`，模块需导出 `run(args) -> result`。

```lua
-- shared/gm_double.lua
local M = {}
function M.run(args) return { result = (tonumber(args.n) or 0) * 2 } end
return M
```

---

## 两条重要约束

**1. 跨服务只能传值，不能传函数**
`register_metrics` 收"地址 + 命令名"，`register_gm` 收"模块路径"——
都在服务端内部解析。传函数会在序列化阶段失败，且被骨架吞成 `ERR_INTERNAL(-1)`，极难排查。

**2. 不要用 `#` 数 hash 表**
`#` 只对连续整数键有效。统计字符串键的表必须用计数器。
（本系列第二次踩到，第一次是 ch4 的 gate。）

---

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `CH9_TEST_TARGET` | — | `test_http` |
| `CH9_GM_TOKEN` | dev-token | GM 接口令牌 |
| `CH9_CALLBACK_SECRET` | dev-secret | 内部回调密钥 |
| `CH9_HTTP_PORT` | 8899 | 监听端口 |

---

## 相关文档

- [`OPTIMIZATION.md`](OPTIMIZATION.md) — 设计取舍与安全边界
- [`修复.md`](修复.md) — 5 条记录（跨服务传函数踩了两次）
- 技术博客：[`docs/blog/06-ch9-http-管理接口设计.md`](../docs/blog/06-ch9-http-管理接口设计.md)
