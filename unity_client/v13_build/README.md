# v13_build · Android / iOS / 小游戏出包检查

**对应篇目**：V13《Android 出包三条硬约束》、V14《iOS 出包与热更红线》、V15《微信小游戏 WSS 与首包》｜**档位**：A 档（配置项均给文件与行号）

## 解决什么

"打出来了"不等于"可以发了"。参考工程的配置是**能出包但装不上/上不了架**的状态，
三个缺陷在 V13 正文里逐条给出，这里把它们变成 rc != 0 的检查器。

## 文件

| 文件 | 作用 |
|---|---|
| `project_settings.py` | Unity-YAML 极简解析（不依赖 PyYAML，它解析不了 `!u!129 &1`） |
| `check_android.py` | ARM64 / IL2CPP / 包名 / targetSdk / 版本号 |
| `check_ios.py` | IL2CPP / 包名 / 最低系统版本 + **热更痕迹扫描**（2.5.2 红线的可执行证明） |
| `check_minigame.py` | 首包与总包预算、只能 WSS、性能阈值 |
| `first_package.example.json` | 首包清单模板（**数值必须由构建产物填入**） |
| `test_build.py` | 39 条断言：坏配置能拦住、好配置能通过 |

## 跑

```bash
python unity_client/v13_build/check_android.py
python unity_client/v13_build/check_ios.py --scan C:/workspaces/Client/Assets
python unity_client/v13_build/check_minigame.py --endpoint wss://game.example.com/ws \
       --fps 30 --memory-mb 300 --drawcall 140
python unity_client/v13_build/test_build.py
```

## 在参考工程上的真实输出

```
Android: 4 项不通过
  ✗ AndroidTargetArchitectures=1（ARMv7）缺 ARM64
  ✗ scriptingBackend 未为 Android 显式设置（当前空）→ 默认落 Mono
  ✗ applicationIdentifier 未设置 → 包名落 com.DefaultCompany.*
  ✗ AndroidTargetSdkVersion=0（自动取最高）→ 应固定

iOS: 2 项不通过
  ✗ scriptingBackend 未为 iPhone 显式设置
  ✗ applicationIdentifier(iPhone) 未设置
```

对应台账 C-38 / C-39 / C-40。

## 三个容易忽略的判断

1. **`AndroidTargetArchitectures: 1` 是"仅 ARMv7"**，不是"架构版本 1"。位掩码：1=ARMv7、2=ARM64、4=x86。
2. **`scriptingBackend: {}` 不是"默认 IL2CPP"**，默认是 Mono。空 map 在评审时看起来"没配"，
   在构建时就是"没配"，会悄悄产出 Mono 包。
3. **小游戏首包数字必须来自构建产物**。`check_minigame.py` 对空清单直接报错而不是给估算值 ——
   用估算值算出来的"达标"是最贵的假绿。

## 证据边界

限额常量（4 MB 首包 / 20 MB 总包 / 30fps / 350 MB / 150 drawcall）引自参考工程的三端定案文档，
**属工程定案，非本项目实机验证**。平台限额以官方当年公告为准，代码里集中在 `LIMITS` 一处，改这里即可。
