#!/usr/bin/env python3
"""Render the Mac Mop disk-image window background.

Usage: python3 scripts/render-dmg-background.py [out-dir]   (default: assets/dmg)

Writes background.png (1x), background@2x.png and the multi-resolution
background.tiff that scripts/make-dmg.py puts in the image's hidden
.background folder. Needs Pillow; the TIFF is committed so release builds
do not need Pillow. Re-run after changing the layout constants below (they
must match make-dmg.py: window 660x420, icons at (170,200) and (490,200)).

Design: Tahoe-style soft blue gradient matching the app icon, light streaks
and frosted glass shapes, a hand-drawn arrow from the app slot to the
Applications slot, the wordmark and a bilingual caption. The image is taller
than the window (480 pt) so a Finder title bar of any height never uncovers
a white strip; everything that matters sits in the top 400 pt.
"""
import math
import os
import random
import subprocess
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

W, H = 660, 480                    # points; the window shows the top ~420
APP_SLOT = (170, 200)              # icon centres (Finder Iloc), keep in sync
APPS_SLOT = (490, 200)
FONT = "/System/Library/Fonts/SFNS.ttf"
ROUNDED = "/System/Library/Fonts/SFNSRounded.ttf"


def lerp(a, b, t):
    return a + (b - a) * t


def mix(c1, c2, t):
    return tuple(int(round(lerp(x, y, t))) for x, y in zip(c1, c2))


def font(path, size, weight):
    f = ImageFont.truetype(path, size)
    try:
        axes = f.get_variation_axes()
        values = []
        for axis in axes:
            name = axis["name"]
            if name in (b"Weight", "Weight"):
                values.append(weight)
            elif name in (b"Optical Size", "Optical Size"):
                values.append(max(axis["minimum"], min(axis["maximum"], size / 2)))
            else:
                values.append(axis["default"])
        f.set_variation_by_axes(values)
    except Exception:
        pass
    return f


def vertical_gradient(w, h, stops):
    """stops: [(y_fraction, rgb)], returns RGB image."""
    col = Image.new("RGB", (1, h))
    px = col.load()
    for y in range(h):
        f = y / (h - 1)
        for (f0, c0), (f1, c1) in zip(stops, stops[1:]):
            if f0 <= f <= f1:
                t = (f - f0) / (f1 - f0) if f1 > f0 else 0
                t = t * t * (3 - 2 * t)        # smoothstep between stops
                px[0, y] = mix(c0, c1, t)
                break
    return col.resize((w, h))


def radial_glow(size, center, radius, rgb, alpha):
    """RGBA layer with a soft radial blob."""
    layer = Image.new("RGBA", size, rgb + (0,))
    mask = Image.new("L", size, 0)
    d = ImageDraw.Draw(mask)
    cx, cy = center
    d.ellipse((cx - radius, cy - radius, cx + radius, cy + radius), fill=int(255 * alpha))
    mask = mask.filter(ImageFilter.GaussianBlur(radius * 0.55))
    layer.putalpha(mask)
    return layer


def streak(size, p0, p1, width, alpha, blur):
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).line([p0, p1], fill=int(255 * alpha), width=int(width))
    mask = mask.filter(ImageFilter.GaussianBlur(blur))
    layer = Image.new("RGBA", size, (255, 255, 255, 0))
    layer.putalpha(mask)
    return layer


def glass_disc(size, box, s):
    """Frosted glass lens: faint fill, bright rim on the upper left."""
    layer = Image.new("RGBA", size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    d.ellipse(box, fill=(255, 255, 255, 22))
    rim = Image.new("RGBA", size, (0, 0, 0, 0))
    ImageDraw.Draw(rim).ellipse(box, outline=(255, 255, 255, 120), width=max(1, int(1.5 * s)))
    # Fade the rim towards the lower right so it reads as a lit edge.
    x0, y0, x1, y1 = box
    fade = Image.new("L", size, 0)
    fd = ImageDraw.Draw(fade)
    steps = 24
    for i in range(steps):
        t = i / steps
        fd.ellipse((x0 - (x1 - x0) * 0.2 + t * 0, y0 - (y1 - y0) * 0.2, x1 - (x1 - x0) * (0.25 + 0.5 * t),
                    y1 - (y1 - y0) * (0.25 + 0.5 * t)), fill=int(255 * (1 - t) ** 0.7))
    fade = fade.filter(ImageFilter.GaussianBlur(14 * s))
    rim.putalpha(ImageChops.multiply(rim.getchannel("A"), fade))
    layer = Image.alpha_composite(layer, rim.filter(ImageFilter.GaussianBlur(0.6 * s)))
    return layer


def bezier(p0, p1, p2, p3, t):
    u = 1 - t
    return (u ** 3 * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t ** 3 * p3[0],
            u ** 3 * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t ** 3 * p3[1])


def hand_arrow(size, s, rng):
    """Tapered, slightly wobbly hand-drawn arrow between the two slots."""
    mask = Image.new("L", size, 0)
    d = ImageDraw.Draw(mask)
    p0 = ((APP_SLOT[0] + 84) * s, (APP_SLOT[1] - 6) * s)
    p3 = ((APPS_SLOT[0] - 86) * s, (APPS_SLOT[1] - 14) * s)
    p1 = ((APP_SLOT[0] + 120) * s, (APP_SLOT[1] - 70) * s)
    p2 = ((APPS_SLOT[0] - 128) * s, (APPS_SLOT[1] - 78) * s)
    n = 260
    pts = []
    for i in range(n + 1):
        t = i / n
        x, y = bezier(p0, p1, p2, p3, t)
        wob = math.sin(t * 9.0 + 0.7) * 0.9 * s + math.sin(t * 23.0) * 0.35 * s
        pts.append((x, y + wob))
    for i, (x, y) in enumerate(pts):
        t = i / n
        r = (1.4 + 2.6 * math.sin(math.pi * min(1, t * 1.05)) ** 0.8) * s   # taper both ends
        d.ellipse((x - r, y - r, x + r, y + r), fill=255)
    # Arrow head: two strokes swept back from the tip along the tangent.
    tip = pts[-1]
    back = pts[-14]
    ang = math.atan2(tip[1] - back[1], tip[0] - back[0])
    for side, length in ((1, 19), (-1, 17)):
        a = ang + math.pi - side * 0.62
        end = (tip[0] + math.cos(a) * length * s, tip[1] + math.sin(a) * length * s)
        m = 40
        for i in range(m + 1):
            t = i / m
            x = lerp(tip[0], end[0], t) + math.sin(t * 3.1) * 0.8 * s * side
            y = lerp(tip[1], end[1], t)
            r = lerp(3.3, 1.3, t) * s
            d.ellipse((x - r, y - r, x + r, y + r), fill=255)
    return mask


def sparkle(draw, c, r, alpha, s):
    """Four-point star."""
    x, y = c
    k = r * 0.22
    pts = [(x, y - r), (x + k, y - k), (x + r, y), (x + k, y + k), (x, y + r), (x - k, y + k), (x - r, y), (x - k, y - k)]
    draw.polygon(pts, fill=(255, 255, 255, int(255 * alpha)))


def text_center(layer, y, text, f, fill, shadow=None, s=1):
    d = ImageDraw.Draw(layer)
    box = d.textbbox((0, 0), text, font=f)
    w = box[2] - box[0]
    x = (layer.width - w) / 2 - box[0]
    if shadow:
        sh = Image.new("RGBA", layer.size, (0, 0, 0, 0))
        ImageDraw.Draw(sh).text((x, y + shadow[1] * s), text, font=f, fill=shadow[0])
        sh = sh.filter(ImageFilter.GaussianBlur(shadow[2] * s))
        layer.alpha_composite(sh)
    d.text((x, y), text, font=f, fill=fill)


def render(scale):
    s = scale
    size = (W * s, H * s)
    rng = random.Random(7)

    # 1. Base gradient: light sky at the top to azure under the icons, so the
    #    Finder labels (black in Light, white in Dark mode) both stay legible.
    base = vertical_gradient(size[0], size[1], [
        (0.00, (222, 237, 255)),
        (0.24, (160, 198, 252)),
        (0.50, (78, 126, 222)),
        (0.78, (50, 96, 208)),
        (1.00, (30, 68, 178)),
    ]).convert("RGBA")

    # 2. Aurora glows.
    for center, radius, rgb, alpha in [
        ((90, 40), 260, (255, 255, 255), 0.55),
        ((610, 110), 220, (120, 220, 255), 0.35),
        ((560, 470), 260, (110, 90, 230), 0.30),
        ((60, 440), 200, (60, 170, 255), 0.30),
        ((APP_SLOT[0], APP_SLOT[1] - 14), 92, (255, 255, 255), 0.24),
        ((APPS_SLOT[0], APPS_SLOT[1] - 14), 92, (255, 255, 255), 0.24),
    ]:
        base.alpha_composite(radial_glow(size, (center[0] * s, center[1] * s), radius * s, rgb, alpha))

    # 3. Light streaks (diagonal glass glints).
    for (x0, y0, x1, y1, wdt, a, b) in [
        (-40, 300, 360, -40, 46, 0.10, 18),
        (60, 420, 520, -60, 14, 0.12, 6),
        (300, 520, 760, 80, 70, 0.07, 26),
        (420, 520, 820, 170, 10, 0.12, 4),
    ]:
        base.alpha_composite(streak(size, (x0 * s, y0 * s), (x1 * s, y1 * s), wdt * s, a, b * s))

    # 4. Frosted glass lenses in the corners.
    for box in [(-70, 250, 150, 470), (520, -90, 760, 150), (560, 330, 700, 470)]:
        base.alpha_composite(glass_disc(size, tuple(v * s for v in box), s))

    # 5. Soft "shelf" under each icon slot: a lit ellipse the icon sits on.
    for cx, cy in (APP_SLOT, APPS_SLOT):
        shelf = Image.new("L", size, 0)
        ImageDraw.Draw(shelf).ellipse(((cx - 74) * s, (cy + 50) * s, (cx + 74) * s, (cy + 96) * s), fill=120)
        shelf = shelf.filter(ImageFilter.GaussianBlur(12 * s))
        layer = Image.new("RGBA", size, (14, 40, 120, 0))
        layer.putalpha(shelf)
        base.alpha_composite(layer)

    # 6. Arrow with a soft glow and a faint drop shadow.
    mask = hand_arrow(size, s, rng)
    shadow = Image.new("RGBA", size, (10, 30, 90, 0))
    shadow.putalpha(mask.filter(ImageFilter.GaussianBlur(4 * s)).point(lambda v: int(v * 0.35)))
    base.alpha_composite(shadow, (0, int(2 * s)))
    glow = Image.new("RGBA", size, (200, 235, 255, 0))
    glow.putalpha(mask.filter(ImageFilter.GaussianBlur(7 * s)).point(lambda v: int(v * 0.8)))
    base.alpha_composite(glow)
    white = Image.new("RGBA", size, (255, 255, 255, 0))
    white.putalpha(mask)
    base.alpha_composite(white)

    # 7. Sparkles: a few near the arrow and the wordmark.
    sp = Image.new("RGBA", size, (0, 0, 0, 0))
    d = ImageDraw.Draw(sp)
    for (x, y, r, a) in [(332, 112, 7, 0.95), (352, 98, 3.5, 0.8), (312, 100, 2.5, 0.7),
                         (402, 124, 3, 0.6), (250, 128, 2.2, 0.55),
                         (418, 40, 5, 0.85), (431, 30, 2.4, 0.7), (238, 58, 3, 0.6)]:
        sparkle(d, (x * s, y * s), r * s, a, s)
    glow = sp.filter(ImageFilter.GaussianBlur(3 * s))
    base.alpha_composite(glow)
    base.alpha_composite(sp)

    # 8. Wordmark + caption.
    txt = Image.new("RGBA", size, (0, 0, 0, 0))
    text_center(txt, 26 * s, "Mac Mop", font(ROUNDED, 34 * s, 760), (18, 52, 128, 255),
                shadow=((255, 255, 255, 170), 1, 1.5), s=s)
    text_center(txt, 330 * s, "Trascina Mac Mop nella cartella Applicazioni",
                font(FONT, 17 * s, 620), (255, 255, 255, 255), shadow=((8, 28, 90, 150), 1, 3), s=s)
    text_center(txt, 356 * s, "Drag Mac Mop to the Applications folder",
                font(FONT, 12 * s, 480), (232, 241, 255, 215), shadow=((8, 28, 90, 120), 1, 2), s=s)
    base.alpha_composite(txt)

    # 9. Dither: a whisper of noise so the gradient never bands.
    noise = Image.effect_noise(size, 6).convert("L")
    noise = Image.merge("RGBA", (noise, noise, noise, Image.new("L", size, 7)))
    base = Image.alpha_composite(base, noise)
    return base.convert("RGB")


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "assets", "dmg")
    os.makedirs(out, exist_ok=True)
    big = render(2)
    big.save(os.path.join(out, "background@2x.png"), dpi=(144, 144))
    small = render(1)
    small.save(os.path.join(out, "background.png"), dpi=(72, 72))
    subprocess.run(["tiffutil", "-cathidpicheck", os.path.join(out, "background.png"),
                    os.path.join(out, "background@2x.png"), "-out", os.path.join(out, "background.tiff")],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(os.path.join(out, "background.tiff"))


if __name__ == "__main__":
    main()
