#!/usr/bin/env python3
"""Рисует repo/CydiaIcon.png — ту же глянцевую иконку, что и пункт iOS6Revive в Настройках.

Рисуем в 8 раз крупнее и уменьшаем: так края получаются сглаженными.
Использование: scripts/make-icon.py [размер, по умолчанию 64]
"""

import math
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

SIZE = int(sys.argv[1]) if len(sys.argv) > 1 else 64
K = 8
S = SIZE * K
OUT = Path(__file__).resolve().parent.parent / "repo" / "CydiaIcon.png"


def vertical_gradient(top, bottom):
    image = Image.new("RGBA", (S, S))
    draw = ImageDraw.Draw(image)
    for y in range(S):
        t = y / (S - 1)
        draw.line([(0, y), (S, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)))
    return image


def bold_font(size):
    for name in ("DejaVuSans-Bold.ttf", "Arial Bold.ttf", "LiberationSans-Bold.ttf"):
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            continue
    return ImageFont.load_default()


def main():
    unit = S / 29  # координаты те же, что у иконки 29 pt в IRSettings.m

    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, S - 1, S - 1], radius=5.5 * unit, fill=255)

    icon = vertical_gradient((115, 199, 252, 255), (26, 112, 214, 255))

    # Белая «6» в круговой стрелке
    glyph = Image.new("L", (S, S), 0)
    draw = ImageDraw.Draw(glyph)
    cx = cy = S / 2
    radius, width = 10 * unit, 2.2 * unit
    start, end = -90 + math.degrees(0.5), -90 - math.degrees(0.25) + 360
    box = [cx - radius, cy - radius, cx + radius, cy + radius]
    draw.arc(box, start=start, end=end, fill=255, width=round(width))
    angle = math.radians(end)
    tip = (cx + radius * math.cos(angle), cy + radius * math.sin(angle))
    tangent = (-math.sin(angle), math.cos(angle))
    normal = (math.cos(angle), math.sin(angle))
    draw.polygon([
        (tip[0] + tangent[0] * 3.6 * unit, tip[1] + tangent[1] * 3.6 * unit),
        (tip[0] + normal[0] * 3.2 * unit, tip[1] + normal[1] * 3.2 * unit),
        (tip[0] - normal[0] * 3.2 * unit, tip[1] - normal[1] * 3.2 * unit),
    ], fill=255)
    font = bold_font(round(14 * unit))
    left, top, right, bottom = draw.textbbox((0, 0), "6", font=font)
    draw.text((cx - (left + right) / 2, cy - (top + bottom) / 2), "6", font=font, fill=255)

    # Мягкая тень под знаком, как у иконок iOS 6
    shadow = glyph.filter(ImageFilter.GaussianBlur(1.5 * unit)).point(lambda v: v * 0.35)
    shadow = ImageChops.offset(shadow, 0, round(unit))
    icon = Image.composite(Image.new("RGBA", (S, S), (0, 0, 0, 255)), icon, shadow)
    icon = Image.composite(Image.new("RGBA", (S, S), (255, 255, 255, 255)), icon, glyph)

    # Глянец: светлый овал сверху
    gloss_mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(gloss_mask).ellipse([-0.5 * S, -0.75 * S, 1.5 * S, 0.5 * S], fill=255)
    fade = Image.new("L", (S, S), 0)
    fade_draw = ImageDraw.Draw(fade)
    for y in range(S // 2):
        fade_draw.line([(0, y), (S, y)], fill=round(255 * (0.45 - 0.37 * y / (S / 2))))
    gloss = ImageChops.multiply(gloss_mask, fade)
    icon = Image.composite(Image.new("RGBA", (S, S), (255, 255, 255, 255)), icon, gloss)

    icon.putalpha(mask)
    icon.resize((SIZE, SIZE), Image.LANCZOS).save(OUT)
    print(f"{OUT} ({SIZE}×{SIZE})")


if __name__ == "__main__":
    main()
