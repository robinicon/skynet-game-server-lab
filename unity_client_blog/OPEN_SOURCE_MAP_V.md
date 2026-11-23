# V 系列（Unity 客户端 16 篇）开源代码映射

按纪律"客户端仅开源代码与部分截图、不开源美术资源"整理，规则与 skynet 服务端各章**完全一致**：
一章一目录、每目录可独立运行验证、片段掠过、非强制。

配套台账：[ISSUES.md](./ISSUES.md)。

## 一、判定口径

| 问题 | 判据 |
|---|---|
| 能开源吗 | 能脱离 Unity 编辑器独立跑起来（脚本 + 断言），且不依赖美术资产 |
| 开什么 | 校验器、编解码、状态机、契约定义、manifest 规则 |
| 不开什么 | 图片/模型/动画/prefab/场景/字体；蓝本源码；片段；硬编码本机路径的脚本 |
| 怎么算"验证过" | `python unity_client/run_tests.py` 全绿，断言数写进本表 |

**没有一条代码是为了凑数写的**：每条都对应正文里一个具体结论或台账里一个具体编号。

## 二、逐篇映射

| 篇 | 标题 | 档 | 开源处置 | 目录 | 断言 |
|---|---|---|---|---|---|
| V01 | 66MB 的客户端仓库，业务代码只有 1 个脚本 | A | **掠过** | — | — |
| V02 | 三个场景字节完全相同：空场景 + prefab 的取舍 | A | **掠过** | — | — |
| V03 | 四套信封收敛 | A | **开源** | `unity_client/v03_frame/` | 32 |
| V04 | opcode 单一来源与只增不改 | A | **开源**（既有） | `unity_client/protocol/` `tools/` | 1 |
| V05 | 契约覆盖度矩阵 | A | **开源** | `unity_client/v05_contract/` | 26 |
| V06 | 登录链路五条失败分支 | A | **开源**（错误码部分） | `unity_client/v06_errcode/` | 23 |
| V07 | 选角与创角补齐契约 | B | **开源**（表结构部分） | `unity_client/v07_role_schema/` | 23 |
| V08 | 进服与属性同步 | B | **开源** | `unity_client/v08_props/` | 29 |
| V09 | 断线不是接着玩 | B | **开源** | `unity_client/v09_reconnect/` | 26 |
| V10 | 跨节点跳转窗口期 | B | **开源** | `unity_client/v10_jump/` | 31 |
| V11 | 编辑器 AI 助手 | C | **掠过** | — | — |
| V12 | 美术资源 AI 化边界 | B | **开源**（规则与校验器，不含图片） | `unity_client/v12_art_pipeline/` | 24 |
| V13 | Android 出包三条硬约束 | A | **开源** | `unity_client/v13_build/` | 13 |
| V14 | iOS 出包与热更红线 | A | **开源** | `unity_client/v13_build/` | 12 |
| V15 | 微信小游戏 WSS 与首包 | A | **开源** | `unity_client/v13_build/` | 14 |
| V16 | 联调验收与灰度回滚 | A | **开源** | `unity_client/v16_gate/` | 22 |

（v13 目录的 39 条断言由 V13/V14/V15 三篇共用，按篇拆分如上；`run_tests.py` 按目录汇总。）

### 掠过的三篇，为什么掠过

**V01**：正文是 `curl` GitHub API 读外部仓库的统计命令 —— 那些命令在文章里，不在本仓库。
硬做成脚本只会是"把 curl 包一层"，不构成可复用代码。

**V02**：讲的是 9 个 prefab 的职责与三个空场景的 sha 相同。prefab/场景属美术资产，
引用文件名已是极限（纪律 1）。再往下就是索引美术资源，越线。

**V11**：C 档方法笔记，编辑器助手的目录约定 + 环境变量。没有工程、没有实测，
做成代码就是"看起来能跑、实际没跑过"，违反"不编"。

## 三、每条代码对应哪个结论

| 代码 | 证明的结论 | 可复现的证据 |
|---|---|---|
| `v03_frame/frame.py` + `frame_ref.lua` | 三端可以用同一份字节定义 | 4 组向量逐字节一致（跨语言） |
| `v03_frame/sniff_legacy_naive()` | C-21：首字节判别必然失效 | 新帧 len=6 时首字节 `0x00`，与旧 sproto 小包不可分 |
| `v05_contract/coverage.py` | C-04：缺 `role_list`/`role_create` 四条 | CLI 通道 0x0001~0x000E 占满，缺口 3 个界面 |
| `v06_errcode/errcode_lint.py` | C-27：1~6 六处数值撞车 | 撞车表逐行输出，`OK`/`ERR_OK` 被正确豁免 |
| `v07_role_schema/check_schema.py` | C-28：`roles` 表没有 `name` | v1 体检 4 个缺列，v2 通过 |
| `v08_props/props.py` | **C-46（新增）**：示例槽位表 3100 重叠 | `check_slot_conflicts()` 输出 `(3100, quest.done, quest.progress(qid=100))` |
| `v09_reconnect/reconnect.py` | C-14：20s 才发现 vs 1s 窗口 | `late_by_s=19.0`，`fallback_to_reload=True` |
| `v10_jump/jump.py` | C-15 / C-32：重放重复执行、无超时无上限 | 重放顺序断言、超时回滚、溢出丢最旧、去重 256 |
| `v12_art_pipeline/manifest_lint.py` | AI 出图必须可复现 | `seed=random` 被拒、缺时区被拒 |
| `v13_build/check_android.py` | C-38/39/40 | 参考工程实跑：4 项不通过 |
| `v13_build/check_ios.py` | C-18：不做代码热更可被执行证明 | 热更痕迹扫描为 0 才算合规 |
| `v13_build/check_minigame.py` | V15：首包预算与只能 WSS | 空清单拒绝估算、`ws://` 被拦 |
| `v16_gate/gate.py` | C-44：空 token 放行 | 假服务端复现"只对空 token 放行"，两关都抓 |

## 四、运行

```bash
python unity_client/run_tests.py            # 276 条断言，全绿
```

## 五、提交建议（与 skynet 一致：一章一提交）

```
feat: 开源 v03_frame 信封层（黄金实现 + Lua 参考，32 断言）
feat: 开源 v05_contract 契约覆盖度矩阵（26 断言）
feat: 开源 v06_errcode 错误码 lint（撞车 6 处，23 断言）
feat: 开源 v07_role_schema roles 表结构检查（23 断言）
feat: 开源 v08_props 泳道编解码（检出槽位 3100 冲突，29 断言）
feat: 开源 v09_reconnect 退避与状态机（26 断言）
feat: 开源 v10_jump 跳转窗口期（31 断言）
feat: 开源 v12_art_pipeline manifest 与图片质检（24 断言）
feat: 开源 v13_build 三端出包检查（39 断言）
feat: 开源 v16_gate 联调验收门禁（22 断言）
```

`unity_client/protocol` 与 `tools` 已在暂存区（13 文件），可单独作为一次提交先行落地。

## 六、红线复核

- [x] 无任何美术资源（图片/模型/动画/prefab/场景/字体）
- [x] 未复制蓝本源码，只引用文件名与结构
- [x] 无硬编码本机绝对路径（`project_settings.DEFAULT_PATH` 有 `--file` 覆盖）
- [x] 无编造数据（检查器读真实文件；测试数据由代码构造并注明）
- [x] 每条断言可复现，不依赖 Unity 编辑器
- [x] 掠过项均有理由，未强行开源片段
