# -*- coding: utf-8 -*-
"""
生成电源模式托盘图标（多分辨率 ICO）。

设计：圆角方形渐变徽章 + 白色闪电 + 顶部高光；暂停态叠加禁止斜杠。
四态配色：节能=绿、平衡=蓝、高性能=橙红、暂停/未知=灰。

要点：
1. 每个尺寸都以 8 倍超采样独立渲染后 LANCZOS 缩回；
2. 小尺寸（<=24px）走「加粗放大」分支，对抗 16px 下的细节坍缩；
3. **手工组装 ICO 容器**——Pillow 的 ICO save 会用同一张大图去缩放所有层，
   会导致上面的逐尺寸优化全部失效。自己写才能让每层都用独立渲染结果。
"""
import io
import os
import struct
from PIL import Image, ImageDraw, ImageChops, ImageOps

SS = 8                      # 超采样倍数
OUT = r"C:\Users\Administrator\WorkBuddy\2026-10-05-17-32-35\_icons_out"

# ---- 配色：(顶部亮色, 底部深色) ----
STATES = {
    "saver":    ((0x5C, 0xC0, 0x62), (0x1B, 0x5E, 0x20)),   # 节能 · 绿
    "balanced": ((0x4F, 0xAC, 0xF7), (0x0D, 0x47, 0xA1)),   # 平衡 · 蓝
    "high":     ((0xFF, 0x8A, 0x50), (0xB7, 0x1C, 0x1C)),   # 高性能 · 橙红
    "unknown":  ((0x9A, 0xA4, 0xAE), (0x37, 0x41, 0x4A)),   # 未知 · 冷灰
}
PAUSED_COLORS = ((0xC4, 0xC9, 0xCE), (0x5A, 0x63, 0x6B))    # 暂停 · 灰

# ---- 闪电多边形（归一化坐标） ----
BOLT = [
    (0.588, 0.128),
    (0.250, 0.562),
    (0.444, 0.562),
    (0.398, 0.874),
    (0.752, 0.438),
    (0.556, 0.438),
]

SIZES = [16, 20, 24, 32, 40, 48, 64, 128, 256]


# ============================================================
#  绘制
# ============================================================
def build(size, colors, paused=False):
    """渲染单个尺寸的图标（RGBA）。"""
    S = size * SS
    c_top, c_bot = colors
    small = size <= 24

    # --- 底板：圆角方形 ---
    margin = S * (0.026 if small else 0.045)
    radius = S * (0.195 if small else 0.255)
    plate = Image.new("L", (S, S), 0)
    ImageDraw.Draw(plate).rounded_rectangle(
        [margin, margin, S - 1 - margin, S - 1 - margin], radius=radius, fill=255
    )

    # --- 渐变填充 ---
    grad = Image.linear_gradient("L").resize((S, S), Image.LANCZOS)
    body = ImageOps.colorize(grad, c_top, c_bot).convert("RGBA")
    body.putalpha(plate)

    # --- 外描边：极细深色轮廓，浅色任务栏上也清晰 ---
    edge_w = max(1.0, S * (0.036 if small else 0.022))
    edge = Image.new("L", (S, S), 0)
    ImageDraw.Draw(edge).rounded_rectangle(
        [margin + edge_w / 2, margin + edge_w / 2,
         S - 1 - margin - edge_w / 2, S - 1 - margin - edge_w / 2],
        radius=radius, outline=255, width=int(round(edge_w)),
    )
    body = Image.composite(
        Image.new("RGBA", (S, S), (0, 0, 0, 46)), body, ImageChops.multiply(edge, plate)
    )

    # --- 顶部高光 ---
    hl = Image.linear_gradient("L").resize((S, S), Image.LANCZOS)
    hl = hl.point(lambda v: int(58 * (1.0 - (v / 255.0) ** 0.75)))
    hl = ImageChops.multiply(hl, plate)
    body = Image.alpha_composite(
        body, Image.merge("RGBA", [Image.new("L", (S, S), 255)] * 3 + [hl])
    )

    # --- 闪电 ---
    bs = 1.17 if small else 1.0
    pts = [((0.5 + (x - 0.5) * bs) * S, (0.5 + (y - 0.5) * bs) * S) for (x, y) in BOLT]
    bolt = Image.new("L", (S, S), 0)
    bd = ImageDraw.Draw(bolt)
    bd.polygon(pts, fill=255)
    bd.line(pts + [pts[0]], fill=255, width=max(1, int(S * (0.075 if small else 0.055))),
            joint="curve")   # 软化尖角

    # 闪电投影：小尺寸下省略，否则糊成一团
    if not small:
        off = max(1, int(S * 0.014))
        sh = bolt.transform((S, S), Image.AFFINE, (1, 0, -off, 0, 1, -off),
                            resample=Image.BILINEAR).point(lambda v: int(v * 0.34))
        body = Image.alpha_composite(
            body, Image.merge("RGBA", [Image.new("L", (S, S), 0)] * 3 + [sh])
        )

    white = Image.new("L", (S, S), 255)
    body = Image.alpha_composite(body, Image.merge("RGBA", [white, white, white, bolt]))

    # --- 暂停：禁止斜杠（白线 + 深色描边，压在闪电之上） ---
    if paused:
        a = S * (0.215 if small else 0.235)
        b = S * (0.785 if small else 0.765)
        stroke = Image.new("L", (S, S), 0)
        ImageDraw.Draw(stroke).line([(a, a), (b, b)], fill=255,
                                    width=int(S * (0.185 if small else 0.135)))
        stroke = ImageChops.multiply(stroke, plate)

        core = Image.new("L", (S, S), 0)
        ImageDraw.Draw(core).line([(a, a), (b, b)], fill=255,
                                  width=int(S * (0.125 if small else 0.082)))
        core = ImageChops.multiply(core, plate)

        dark = Image.new("L", (S, S), 0)
        body = Image.alpha_composite(body, Image.merge("RGBA", [dark, dark, dark, stroke]))
        body = Image.alpha_composite(body, Image.merge("RGBA", [white, white, white, core]))

    return body.resize((size, size), Image.LANCZOS)


# ============================================================
#  手工组装 ICO
# ============================================================
def _dib(img):
    """32bpp BGRA 自下而上的 DIB（ICO 内的小尺寸用）。"""
    w, h = img.size
    px = img.tobytes()          # RGBA 自上而下
    flip = bytearray()
    stride = w * 4
    for y in range(h - 1, -1, -1):
        row = px[y * stride:(y + 1) * stride]
        # RGBA -> BGRA
        flip += bytes(b for i in range(0, stride, 4)
                      for b in (row[i + 2], row[i + 1], row[i], row[i + 3]))
    and_stride = ((w + 31) // 32) * 4
    andmask = b"\x00" * (and_stride * h)
    header = struct.pack("<IiiHHIIiiII", 40, w, h * 2, 1, 32, 0, len(flip), 0, 0, 0, 0)
    return header + bytes(flip) + andmask


def _png(img):
    buf = io.BytesIO()
    img.save(buf, format="PNG", optimize=True)
    return buf.getvalue()


def write_ico(levels, path):
    """levels: [(size, RGBA Image), ...]，按尺寸升序。256 层用 PNG（放最后，兼容老解析器）。"""
    blobs = []
    for sz, im in levels:
        blobs.append((sz, _png(im) if sz >= 256 else _dib(im)))

    out = bytearray()
    out += struct.pack("<HHH", 0, 1, len(blobs))
    offset = 6 + 16 * len(blobs)
    for sz, data in blobs:
        dim = 0 if sz >= 256 else sz
        out += struct.pack("<BBBBHHII", dim, dim, 0, 0, 1, 32, len(data), offset)
        offset += len(data)
    for _, data in blobs:
        out += data
    with open(path, "wb") as f:
        f.write(bytes(out))
    return len(out)


# ============================================================
def main():
    os.makedirs(OUT, exist_ok=True)

    def render(colors, paused=False):
        return [(s, build(s, colors, paused=paused)) for s in SIZES]

    jobs = [
        ("icon-saver.ico",    STATES["saver"],    False),
        ("icon-balanced.ico", STATES["balanced"], False),
        ("icon-high.ico",     STATES["high"],     False),
        ("icon-unknown.ico",  STATES["unknown"],  False),
        ("icon-paused.ico",   PAUSED_COLORS,      True),
        ("PowerSwitch.ico",   STATES["balanced"], False),   # exe 主图标
    ]
    for fname, colors, paused in jobs:
        levels = render(colors, paused)
        n = write_ico(levels, os.path.join(OUT, fname))
        print("%-22s %8d bytes  (%d layers)" % (fname, n, len(levels)))

    # 预览拼图
    for tag, bgcol, fname in (("light", (245, 246, 248), "preview_sheet.png"),
                              ("dark",  (32, 34, 38),    "preview_sheet_dark.png")):
        shows = [16, 24, 32, 48, 128]
        order = [("saver", STATES["saver"], False), ("balanced", STATES["balanced"], False),
                 ("high", STATES["high"], False), ("paused", PAUSED_COLORS, True)]
        cell = 150
        sheet = Image.new("RGB", (cell * len(shows), cell * len(order)), bgcol)
        for row, (_, colors, paused) in enumerate(order):
            for col, s in enumerate(shows):
                im = build(s, colors, paused=paused)
                bg = Image.new("RGBA", (cell, cell), bgcol + (255,))
                bg.alpha_composite(im, ((cell - s) // 2, (cell - s) // 2))
                sheet.paste(bg.convert("RGB"), (col * cell, row * cell))
        sheet.save(os.path.join(OUT, fname))

    print("OUT:", OUT)


if __name__ == "__main__":
    main()
