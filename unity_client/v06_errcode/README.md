# v06_errcode · 错误码一致性 lint

**对应篇目**：V06《登录链路五条失败分支》｜**档位**：A 档

## 解决什么

服务端 `ch4_login/shared/error_code.lua` 与契约 `Msg_Common.proto` 各有一套错误码。
**1~6 六个数值相同、含义完全不同**（台账 C-27）：

| 值 | 服务端 | 契约 |
|---|---|---|
| 1 | ERR_UNKNOWN_ACCOUNT | ERR_TICKET_INVALID |
| 2 | ERR_WRONG_PASSWORD | ERR_TICKET_EXPIRED |
| 3 | ERR_ALREADY_LOGGED_IN | ERR_TICKET_REPLAY |
| 4 | ERR_TOKEN_EXPIRED | ERR_SERVER_FULL |
| 5 | ERR_INVALID_TOKEN | ERR_ROLE_NOT_FOUND |
| 6 | ERR_LOGIN_QUEUE_FULL | ERR_DB_TIMEOUT |

编译能过、单测能过，联调时提示语系统性错配 —— 因为客户端拿到 4 会显示"服务器已满"，
而服务端说的是"票据过期"。

## 文件

| 文件 | 作用 |
|---|---|
| `errcode_lint.py` | 解析两侧、抓撞车与漂移、校验语义映射表是否过期 |
| `test_errcode.py` | 23 条断言：撞车正好 6 处、0 值同义被豁免、映射有效 |

## 跑

```bash
python unity_client/v06_errcode/errcode_lint.py           # 报告
python unity_client/v06_errcode/errcode_lint.py --strict  # 有不一致 rc=1
```

## 两个设计细节

1. **`OK` 与 `ERR_OK` 不算撞车**：`normalize()` 去掉 `ERR_` 前缀后比较，两者同义。
   但 `ERR_TOKEN_EXPIRED` 与 `ERR_TICKET_EXPIRED` 去掉前缀后仍不同（token ≠ ticket），必须报。
2. **语义映射是人工裁决的交付物**：`SEMANTIC_MAP` 写死两组同义映射，lint 只校验
   "映射两端的名字在两侧都还存在"。映射过期比撞车更危险——它会静默失效。

## 证据边界

本工具只做静态比对，不改变任何一侧的定义。收敛动作（改哪一侧、改哪个值）
需要产品与两端一起定，代码不做决定。
