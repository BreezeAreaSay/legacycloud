#!/usr/bin/env python3
"""Рисует иконки в стиле iOS 6: глянцевый скруглённый квадрат и белый знак с мягкой тенью.

  repo/CydiaIcon.png        — иконка источника (та же «6», что у пункта iOS6Revive в Настройках)
  icons/<пакет>.png         — иконки пакетов для Cydia и страниц пакетов

Рисуем в 8 раз крупнее и уменьшаем, чтобы края были сглаженными.
Использование: scripts/make-icons.py
"""

import math
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
SIZE = 64
K = 8
S = SIZE * K
U = S / 29  # единица — пункт иконки 29×29, как в IRSettings.m
WHITE = 255


def bold_font(size):
    for name in ("DejaVuSans-Bold.ttf", "Arial Bold.ttf", "LiberationSans-Bold.ttf"):
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            continue
    return ImageFont.load_default()


def p(x, y):
    return (x * U, y * U)


# Знаки рисуются белым на маске в координатах 29×29

def glyph_revive(d):
    cx = cy = 14.5
    radius, width = 10, 2.2
    start, end = -90 + math.degrees(0.5), -90 - math.degrees(0.25) + 360
    d.arc([p(cx - radius, cy - radius), p(cx + radius, cy + radius)], start=start, end=end, fill=WHITE, width=round(width * U))
    a = math.radians(end)
    tip = (cx + radius * math.cos(a), cy + radius * math.sin(a))
    t, n = (-math.sin(a), math.cos(a)), (math.cos(a), math.sin(a))
    d.polygon([p(tip[0] + t[0] * 3.6, tip[1] + t[1] * 3.6), p(tip[0] + n[0] * 3.2, tip[1] + n[1] * 3.2),
               p(tip[0] - n[0] * 3.2, tip[1] - n[1] * 3.2)], fill=WHITE)
    text(d, "6", 14)


def text(d, string, size, dy=0):
    font = bold_font(round(size * U))
    left, top, right, bottom = d.textbbox((0, 0), string, font=font)
    d.text((S / 2 - (left + right) / 2, S / 2 - (top + bottom) / 2 + dy * U), string, font=font, fill=WHITE)


def glyph_back(d):
    # Стрелка «назад»: наконечник и древко
    d.polygon([p(5.5, 14.5), p(13.5, 7), p(13.5, 11.5), p(23, 11.5), p(23, 17.5), p(13.5, 17.5), p(13.5, 22)], fill=WHITE)


def glyph_battery(d):
    d.rounded_rectangle([p(4.5, 9.5), p(22.5, 19.5)], radius=2.2 * U, outline=WHITE, width=round(1.8 * U))
    d.rounded_rectangle([p(22.5, 12.5), p(25, 16.5)], radius=0.8 * U, fill=WHITE)
    d.rectangle([p(7, 12), p(15, 17)], fill=WHITE)


def glyph_moon(d):
    d.ellipse([p(6, 6), p(23, 23)], fill=WHITE)
    d.ellipse([p(11, 3), p(28, 20)], fill=0)
    d.polygon([p(22, 17), p(22.8, 19.2), p(25, 20), p(22.8, 20.8), p(22, 23), p(21.2, 20.8), p(19, 20), p(21.2, 19.2)], fill=WHITE)


def glyph_new_app(d):
    # Мини-иконка программы и подпись с точкой слева
    d.rounded_rectangle([p(9, 4.5), p(20, 15.5)], radius=2.5 * U, fill=WHITE)
    d.ellipse([p(5, 19), p(9, 23)], fill=WHITE)
    d.rounded_rectangle([p(11, 19.8), p(24, 22.2)], radius=1.2 * U, fill=WHITE)


def glyph_bold(d):
    text(d, "A", 20, dy=0.5)


def glyph_monitor(d):
    d.rounded_rectangle([p(4.5, 6), p(24.5, 19)], radius=1.8 * U, outline=WHITE, width=round(2 * U))
    d.rectangle([p(12.5, 19), p(16.5, 22)], fill=WHITE)
    d.rounded_rectangle([p(9, 22), p(20, 24)], radius=1 * U, fill=WHITE)


def glyph_controls(d):
    # Два ползунка, как в Пункте управления
    for y, knob in ((9, 16), (17, 9)):
        d.rounded_rectangle([p(4, y - 1.2), p(25, y + 1.2)], radius=1.2 * U, fill=WHITE)
        d.ellipse([p(knob - 3.2, y - 3.2), p(knob + 3.2, y + 3.2)], fill=WHITE)


def glyph_bolt(d):
    d.polygon([p(16.5, 3.5), p(7.5, 16), p(13.5, 16), p(11.5, 25.5), p(21.5, 12.5), p(15.5, 12.5)], fill=WHITE)


ICONS = {
    "repo/CydiaIcon.png": ((115, 199, 252), (26, 112, 214), glyph_revive),
    "icons/com.ios6revive.core.png": ((115, 199, 252), (26, 112, 214), glyph_revive),
    "icons/com.ios6revive.swipeback.png": ((150, 168, 196), (78, 99, 135), glyph_back),
    "icons/com.ios6revive.battery.png": ((255, 222, 92), (238, 160, 0), glyph_battery),
    "icons/com.ios6revive.nightshift.png": ((72, 92, 160), (18, 26, 66), glyph_moon),
    "icons/com.ios6revive.newappdot.png": ((110, 181, 255), (33, 99, 214), glyph_new_app),
    "icons/com.ios6revive.boldtext.png": ((166, 173, 183), (90, 99, 112), glyph_bold),
    "icons/com.ios6revive.desktopsite.png": ((100, 205, 250), (24, 116, 222), glyph_monitor),
    "icons/com.ios6revive.controlcenter.png": ((118, 124, 133), (40, 43, 48), glyph_controls),
    "icons/com.ios6revive.quickwins.png": ((255, 176, 70), (232, 98, 18), glyph_bolt),
}


def gradient(top, bottom):
    image = Image.new("RGBA", (S, S))
    draw = ImageDraw.Draw(image)
    for y in range(S):
        t = y / (S - 1)
        draw.line([(0, y), (S, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)) + (255,))
    return image


def render(top, bottom, glyph):
    icon = gradient(top, bottom)

    mask = Image.new("L", (S, S), 0)
    glyph(ImageDraw.Draw(mask))
    shadow = ImageChops.offset(mask.filter(ImageFilter.GaussianBlur(1.5 * U)).point(lambda v: v * 0.35), 0, round(U))
    icon = Image.composite(Image.new("RGBA", (S, S), (0, 0, 0, 255)), icon, shadow)
    icon = Image.composite(Image.new("RGBA", (S, S), (255, 255, 255, 255)), icon, mask)

    # Глянец: светлый овал сверху
    gloss = Image.new("L", (S, S), 0)
    ImageDraw.Draw(gloss).ellipse([-0.5 * S, -0.75 * S, 1.5 * S, 0.5 * S], fill=255)
    fade = Image.new("L", (S, S), 0)
    fade_draw = ImageDraw.Draw(fade)
    for y in range(S // 2):
        fade_draw.line([(0, y), (S, y)], fill=round(255 * (0.45 - 0.37 * y / (S / 2))))
    icon = Image.composite(Image.new("RGBA", (S, S), (255, 255, 255, 255)), icon, ImageChops.multiply(gloss, fade))

    rounded = Image.new("L", (S, S), 0)
    ImageDraw.Draw(rounded).rounded_rectangle([0, 0, S - 1, S - 1], radius=5.5 * U, fill=255)
    icon.putalpha(rounded)
    return icon.resize((SIZE, SIZE), Image.LANCZOS)


def main():
    for path, (top, bottom, glyph) in ICONS.items():
        target = ROOT / path
        target.parent.mkdir(exist_ok=True)
        render(top, bottom, glyph).save(target)
        print(target.relative_to(ROOT))


if __name__ == "__main__":
    main()
