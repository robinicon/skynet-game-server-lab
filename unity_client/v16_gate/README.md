# v16_gate · 联调验收门禁

**对应篇目**：V16《联调验收与灰度回滚》｜**档位**：A 档

## 解决什么

发版前必须过的三关，加上第四关（空 token）：`/health` 要 `ok=true`、旧版本要被拦住、
管理面不带 token 要 401。第四关专抓台账 C-44 —— `ch9_http` 的 `check_token` 对空 token
直接 `return true`，不设 `CH9_GM_TOKEN` 时管理面全开放。

## 文件

| 文件 | 作用 |
|---|---|
| `gate.py` | 四关检查 + 回滚清单静态检查；传输层可注入 |
| `test_gate.py` | 22 条断言：正常服务端、裸奔服务端、门禁失效、服务不可达、回滚清单 |

## 跑

```bash
python unity_client/v16_gate/test_gate.py                      # 离线自测
python unity_client/v16_gate/gate.py --base http://127.0.0.1:8080 \
       --token "$CH9_GM_TOKEN" --rollback-dir unity_client/v16_gate/rollback
```

## 为什么传输层要可注入

真实服务在 CI 里不一定起得来。把 `Transport` 做成协议，测试就能用假服务端精确构造
"裸奔""只对空 token 放行"这些形态 —— 否则这类缺陷只能靠运气在联调现场撞见。

## C-44 的判定为什么不能只看状态码

`check_unauthorized()` 只看"不带 token 是否 200"，能抓"完全不校验"；
但"只对空 token 放行"这种实现，不带 token 时可能仍然 401。
所以额外加了 `check_empty_token()`：显式发 `Authorization: Bearer `（空值），
它必须被拒。两关都过，才算真的鉴权。

## 回滚清单

`check_rollback_dir()` 校验四项是否齐全（配置回滚 / Lua 热修 / 客户端下架 / 事故模板）。
缺一项就等于出事时现场编流程。本目录暂未放这四份文档 —— 它们是运营交付物，
需要配合真实的发布通道填写，放在这里只会变成假的"已完成"。

## 证据边界

检查器**未对真实 `ch9_http` 服务执行过**（需要起 skynet 节点 + 设 `CH9_GM_TOKEN`）。
判定逻辑用可注入传输验证，真实链路的跑通属于 V16 的验收动作，尚未执行。
