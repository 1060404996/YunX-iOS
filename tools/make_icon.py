"""生成 YunX iOS App 图标（1024x1024，不透明方形，圆角由 iOS 自动裁）。

设计：品牌蓝对角渐变底 + 白色云朵 + 云下白色下载箭头。
4x 超采样后 LANCZOS 缩小，保证边缘平滑。
"""
import os
from PIL import Image, ImageDraw

S = 1024
SS = 4
W = S * SS


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def gradient(size, top, bottom):
    img = Image.new("RGB", (size, size))
    d = ImageDraw.Draw(img)
    for y in range(size):
        t = y / (size - 1)
        d.line([(0, y), (size, y)], fill=lerp(top, bottom, t))
    return img


def rounded_rect_mask(size, box, radius):
    m = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle(box, radius=radius, fill=255)
    return m


def circle_mask(size, cx, cy, r):
    m = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(m)
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=255)
    return m


def union(*masks):
    out = masks[0].copy()
    for m in masks[1:]:
        out = Image.fromarray(
            __import__("numpy").maximum(
                __import__("numpy").array(out), __import__("numpy").array(m)
            )
        )
    return out


def build():
    import numpy as np
    from PIL import ImageFilter

    # 背景：上浅下深的品牌蓝
    base = gradient(W, (0x5C, 0x8E, 0xF0), (0x25, 0x4B, 0xC2)).convert("RGBA")

    # 柔和高光：大椭圆 + 高斯模糊，避免硬边界
    glow = Image.new("L", (W, W), 0)
    gd = ImageDraw.Draw(glow)
    gd.ellipse([-W * 0.45, -W * 0.75, W * 1.05, W * 0.45], fill=255)
    glow = glow.filter(ImageFilter.GaussianBlur(W * 0.10))
    white = Image.new("RGBA", (W, W), (255, 255, 255, 255))
    base = Image.composite(white, base, glow.point(lambda v: int(v * 0.16)))

    k = SS
    # 云朵：左中右三圆 + 圆角底座
    circle_l = np.array(circle_mask(W, 348 * k, 398 * k, 132 * k))
    circle_m = np.array(circle_mask(W, 512 * k, 338 * k, 172 * k))
    circle_r = np.array(circle_mask(W, 686 * k, 394 * k, 138 * k))
    body = np.array(rounded_rect_mask(W, [318 * k, 366 * k, 716 * k, 522 * k], 84 * k))
    cloud_mask = Image.fromarray(np.maximum.reduce([circle_l, circle_m, circle_r, body]))

    # 箭头：与云留出呼吸间隙，杆顶做圆角
    arrow = Image.new("L", (W, W), 0)
    ad = ImageDraw.Draw(arrow)
    ad.rounded_rectangle([474 * k, 566 * k, 550 * k, 690 * k], radius=16 * k, fill=255)
    ad.polygon([(392 * k, 668 * k), (632 * k, 668 * k), (512 * k, 818 * k)], fill=255)

    solid_white = Image.new("RGBA", (W, W), (255, 255, 255, 255))
    base = Image.composite(solid_white, base, cloud_mask)

    arrow_layer = Image.new("RGBA", (W, W), (255, 255, 255, 235))
    base = Image.composite(arrow_layer, base, arrow)

    return base.convert("RGB").resize((S, S), Image.LANCZOS)


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    icon_dir = os.path.join(root, "YunX", "Resources", "Assets.xcassets", "AppIcon.appiconset")
    os.makedirs(icon_dir, exist_ok=True)
    img = build()
    path = os.path.join(icon_dir, "AppIcon-1024.png")
    img.save(path, "PNG")
    print("written:", path, img.size)


if __name__ == "__main__":
    main()
