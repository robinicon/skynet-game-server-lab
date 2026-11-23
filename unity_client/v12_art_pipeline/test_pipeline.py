"""V12 管线自测：manifest 字段完整性 + 图片质检规则。

测试图由 PIL 现场生成到临时目录，不含任何项目美术资源（美术资源不开源）。
"""

from __future__ import annotations

import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)

from PIL import Image  # noqa: E402

import _selftest as T  # noqa: E402
import manifest_lint as M  # noqa: E402
import qa_check as Q  # noqa: E402
from _selftest import check, section  # noqa: E402


def good() -> dict:
    return {
        "file": "icon_shop_gold.png",
        "workflow": "A",
        "checkpoint": "sd15_base_v1.5",
        "prompt": "gold coin icon, flat, clean edge",
        "negative": "blurry, text, watermark",
        "seed": 1234567,
        "steps": 24,
        "cfg": 6.5,
        "sampler": "dpmpp_2m",
        "size": "512x512",
        "generated_at": "2026-11-22T20:30:00+08:00",
    }


def test_manifest_ok():
    section("manifest：完整凭据通过")
    check("完整 manifest 无问题", M.lint_manifest(good()) == [], M.lint_manifest(good()))
    check("icon_ 前缀要求 alpha", M.alpha_requirement("icon_x.png")["alpha"] is True)
    check("tex_ 前缀禁止 alpha", M.alpha_requirement("tex_ground.png")["alpha"] is False)
    check("前缀不识别返回 None", M.alpha_requirement("weird.png") is None)


def test_manifest_errors():
    section("manifest：复现凭据缺一不可")
    m = good()
    del m["seed"]
    check("缺 seed 报错", any("seed" in p for p in M.lint_manifest(m)))

    m = good()
    m["seed"] = "random"
    check("seed=random 视为放弃复现", any("复现" in p or "随机" in p or "整数" in p
                                       for p in M.lint_manifest(m)))

    m = good()
    m["size"] = "500x500"
    check("非 2 的幂报错", any("2 的幂" in p for p in M.lint_manifest(m)))

    m = good()
    m["size"] = "512*512"
    check("size 格式错误报错", any("WxH" in p for p in M.lint_manifest(m)))

    m = good()
    m["generated_at"] = "2026-11-22 20:30:00"
    check("缺时区报错", any("时区" in p for p in M.lint_manifest(m)))

    m = good()
    m["file"] = "GoldCoin.PNG"
    probs = M.lint_manifest(m)
    check("大写/无前缀文件名报错", any("前缀规范" in p for p in probs), probs)

    m = good()
    m["file"] = "icon_shop_gold.bmp"
    check("非常见位图格式报错", any("位图格式" in p for p in M.lint_manifest(m)))

    check("空 manifest 全字段报错", len(M.lint_manifest({})) >= len(M.REQUIRED))


def test_batch():
    section("批量：重复文件名会互相覆盖")
    a, b = good(), good()
    b["seed"] = 999
    check("同名两条被检出", any("出现 2 次" in p for p in M.lint_files([a, b])))
    b["file"] = "icon_shop_gem.png"
    check("改名后无重复", not any("出现 2 次" in p for p in M.lint_files([a, b])))


def test_images():
    section("图片质检：用 PIL 现场生成，验证 alpha / 2 的幂 / 尺寸上限")
    with tempfile.TemporaryDirectory() as tmp:
        def make(name: str, size: tuple[int, int], mode: str) -> str:
            p = os.path.join(tmp, name)
            Image.new(mode, size, (200, 120, 60) if mode == "RGB" else (200, 120, 60, 255)).save(p)
            return p

        p_ok = make("icon_shop_gold.png", (512, 512), "RGBA")
        check("合规 icon（512 RGBA）无问题", Q.check_image(p_ok) == [], Q.check_image(p_ok))

        p_noalpha = make("icon_bad.png", (512, 512), "RGB")
        check("icon 缺 alpha 被检出", any("需要 alpha" in x for x in Q.check_image(p_noalpha)))

        p_tex = make("tex_ground.png", (1024, 1024), "RGB")
        check("tex 无 alpha 合规", Q.check_image(p_tex) == [])

        p_tex_a = make("tex_alpha.png", (1024, 1024), "RGBA")
        check("tex 带 alpha 被检出", any("不应带 alpha" in x for x in Q.check_image(p_tex_a)))

        p_np2 = make("ui_odd.png", (300, 300), "RGBA")
        check("非 2 的幂被检出", any("2 的幂" in x for x in Q.check_image(p_np2)))

        p_big = make("tex_huge.png", (4096, 4096), "RGB")
        check("超上限被检出", any("超过上限" in x for x in Q.check_image(p_big)))

        p_unknown = make("weird.png", (256, 256), "RGBA")
        check("前缀不可识别被检出", any("无匹配前缀" in x for x in Q.check_image(p_unknown)))

        p_mismatch = make("icon_size.png", (256, 256), "RGBA")
        probs = Q.check_image(p_mismatch, size_rule=(512, 512))
        check("与 manifest 声明尺寸不符被检出", any("不符" in x for x in probs), probs)

        missed = Q.check_manifest_pair({"file": "icon_missing.png", "size": "512x512"}, tmp)
        check("文件缺失被检出", any("不存在" in x for x in missed))

        paired = Q.check_manifest_pair({"file": "icon_shop_gold.png", "size": "512x512"}, tmp)
        check("manifest 与产物一致时无问题", paired == [], paired)


def main():
    test_manifest_ok()
    test_manifest_errors()
    test_batch()
    test_images()
    return T.summary("V12 art_pipeline")


if __name__ == "__main__":
    sys.exit(T.guard(main, "V12 art_pipeline"))
