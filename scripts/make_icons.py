# -*- coding: utf-8 -*-
"""
从原始 LOGO.png 生成鸿蒙分层图标。

鸿蒙的应用图标是分层的：background + foreground，系统会给整体套一个
圆角遮罩（squircle），并在某些场景下做视差。所以：

  - background 必须满幅，不能有自己的圆角（否则会出现"圆角套圆角"）
  - foreground 只放主体图形，且要留安全边距，否则会被遮罩切掉

原图是一张完整图标（深色圆角方块 + CH 标识），需要把这两层拆开：
背景色从原图采样重建，前景用亮度抠图提取。

用法：python scripts/make_icons.py
"""

from PIL import Image
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# 源图随仓库一起提交，保证图标可复现
SRC = os.path.join(ROOT, "assets", "logo.png")

# 鸿蒙分层图标画布尺寸
CANVAS = 1024
# 背景放大倍数：把原图自带的圆角高光边挤出画面外
BACKGROUND_ZOOM = 1.12
# 启动图标（startWindowIcon）尺寸
START_ICON = 512


def luminance(px):
    r, g, b = px[0], px[1], px[2]
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def build_background(src):
    """
    背景层 = 整张原图，铺满画布。

    一开始试过"背景只放底色、前景抠出 logo"的常规分层做法，但原图是
    一张已经设计好的成品图标，抠不干净：左上角暖色渐变亮度高达 73，
    阈值定低了会把圆角方块边框留下来；定高了蓝色 H 的暗部又会破洞。
    亮度抠图在这种带渐变的素材上没有能同时满足两边的阈值。

    改成整张当背景、前景留空。系统本来就会给图标套圆角遮罩，
    效果正好还原原图，还省掉了抠图带来的所有瑕疵。

    原图自己的圆角是透明的，直接合成到深色底上会留下一圈高光边框，
    所以先放大再中心裁切，把那圈边挤出画面外。
    """
    w, h = src.size
    base = src.getpixel((int(w * 0.88), int(h * 0.88)))[:3]
    print(f"  底色采样={base}")

    # 放大到刚好让原图的圆角边缘落到画布之外
    side = int(CANVAS * BACKGROUND_ZOOM)
    scaled = src.resize((side, side), Image.LANCZOS)

    canvas = Image.new("RGBA", (side, side), base + (255,))
    canvas.alpha_composite(scaled)

    off = (side - CANVAS) // 2
    return canvas.crop((off, off, off + CANVAS, off + CANVAS))


def build_foreground():
    """
    前景层留空。

    图形已经全部烘焙在背景层里（见 build_background 的说明）。
    前景层在系统里主要用于视差效果，留空不影响图标正常显示。
    """
    return Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))


def build_start_icon(src):
    """启动图标是单张完整图，直接用原图缩放即可，保留它自己的圆角"""
    return src.convert("RGBA").resize((START_ICON, START_ICON), Image.LANCZOS)


def main():
    print(f"读取 {SRC}")
    src = Image.open(SRC).convert("RGBA")
    print(f"  原图 {src.size}")

    print("生成背景层…")
    bg = build_background(src)
    print("生成前景层…")
    fg = build_foreground()
    print("生成启动图标…")
    start = build_start_icon(src)

    # entry 模块和 AppScope 两处都要放，前者是 Ability 图标，后者是应用图标
    targets = [
        os.path.join(ROOT, "entry", "src", "main", "resources", "base", "media"),
        os.path.join(ROOT, "AppScope", "resources", "base", "media"),
    ]
    for d in targets:
        os.makedirs(d, exist_ok=True)
        bg.convert("RGB").save(os.path.join(d, "background.png"), optimize=True)
        fg.save(os.path.join(d, "foreground.png"), optimize=True)
        print(f"  已写入 {d}")

    # startIcon 只有 entry 模块用
    start.save(
        os.path.join(ROOT, "entry", "src", "main", "resources", "base", "media", "startIcon.png"),
        optimize=True,
    )

    # 生成一张合成预览，方便肉眼确认分层效果对不对
    preview = Image.alpha_composite(bg, fg)
    preview.save(os.path.join(ROOT, "scripts", "icon-preview.png"))
    print("  预览图 scripts/icon-preview.png")
    print("完成")


if __name__ == "__main__":
    main()
