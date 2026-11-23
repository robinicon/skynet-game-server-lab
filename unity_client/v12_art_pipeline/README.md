# v12_art_pipeline · 美术 manifest 与图片质检

**对应篇目**：V12《美术资源 AI 化边界》｜**档位**：B 档

## 边界先写在最前

**美术资源一律不开源。** 本目录不含任何项目图片、prefab、贴图，只有"怎么管这些资源"的规则与校验器。
测试图由 PIL 现场生成到临时目录，跑完即删。

## 解决什么

AI 出图最大的隐患不是画得不好，是**复现不了**：seed 写成 `random`、底座模型没记版本、
生成时间没时区 —— 三个月后想重出同一张图，无从下手。manifest 是唯一凭据。

## 文件

| 文件 | 作用 |
|---|---|
| `manifest_lint.py` | 11 个必填字段、命名前缀、seed 必须为整数、size 2 的幂、时区 |
| `qa_check.py` | 尺寸/模式质检：icon 要 alpha、tex 不要 alpha、尺寸上限、2 的幂、与 manifest 声明比对 |
| `test_pipeline.py` | 24 条断言：字段缺失、坏命名、alpha 规则、尺寸上限、文件缺失 |

## 跑

```bash
python unity_client/v12_art_pipeline/manifest_lint.py your_manifest.json
python unity_client/v12_art_pipeline/qa_check.py path/to/assets
python unity_client/v12_art_pipeline/test_pipeline.py
```

## 命名前缀决定入库规则

| 前缀 | alpha | 尺寸上限 | 说明 |
|---|---|---|---|
| `icon_` | 必须 | 1024 | UI 图标，透明底 |
| `ui_` | 必须 | 1024 | 界面图集元素 |
| `tex_` | 禁止 | 2048 | 场景贴图，带 alpha 会白边 + 多占显存 |
| `char_` | 必须 | 2048 | 角色立绘 |
| `vfx_` | 必须 | 1024 | 特效贴图 |

前缀不可识别 → 直接拦在入库前，不给"先放进去再说"的机会。

## 证据边界

manifest 字段表来自 AI 出图的实际产出参数（ComfyUI 的 checkpoint / seed / sampler / steps / cfg），
非本项目实测数据。CPU 推理耗时、云端成本等数字引自参考工程的 ComfyUI 攻略文档，
**属方法笔记，不是本项目的性能结论**。
