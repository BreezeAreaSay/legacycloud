#!/usr/bin/env python3
"""Draws iOS 6 style icons: a glossy rounded square with a white glyph and a soft shadow.

  repo/CydiaIcon.png        the repo icon (the same infinity sign as the Skeuo4Ever item in Settings)
  icons/<package>.png       package icons for Cydia and the package pages

Drawn 8 times larger and scaled down, so the edges are antialiased.
Usage: scripts/make-icons.py
"""

import math
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
SIZE = 64
K = 8
S = SIZE * K
U = S / 29  # one unit is a point of a 29×29 icon, as in S4ESettings.m
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


# Glyphs are drawn in white on a mask, in 29×29 coordinates

def glyph_infinity(d):
    # Skeuomorphism forever: a lemniscate of Bernoulli, the same curve as in S4ESettings.m
    cx = cy = 14.5
    a = 10.5
    points = []
    for i in range(193):
        t = 2 * math.pi * i / 192
        sine, cosine = math.sin(t), math.cos(t)
        dd = 1 + sine * sine
        points.append(p(cx + a * cosine / dd, cy + a * 1.15 * sine * cosine / dd))
    d.line(points, fill=WHITE, width=round(2.6 * U), joint="curve")


def text(d, string, size, dy=0):
    font = bold_font(round(size * U))
    left, top, right, bottom = d.textbbox((0, 0), string, font=font)
    d.text((S / 2 - (left + right) / 2, S / 2 - (top + bottom) / 2 + dy * U), string, font=font, fill=WHITE)


def glyph_back(d):
    # A back arrow: head and shaft
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
    # An app icon with the "New" sash across its upper right corner
    d.rounded_rectangle([p(4.5, 4.5), p(24.5, 24.5)], radius=4 * U, outline=WHITE, width=round(1.8 * U))
    # A gap around the sash so it reads over the frame
    d.polygon([p(9.5, 2), p(17.5, 2), p(27, 11.5), p(27, 19.5)], fill=0)
    d.polygon([p(11.5, 3), p(16.5, 3), p(26, 12.5), p(26, 17.5)], fill=WHITE)


def glyph_bold(d):
    text(d, "A", 20, dy=0.5)


def glyph_monitor(d):
    d.rounded_rectangle([p(4.5, 6), p(24.5, 19)], radius=1.8 * U, outline=WHITE, width=round(2 * U))
    d.rectangle([p(12.5, 19), p(16.5, 22)], fill=WHITE)
    d.rounded_rectangle([p(9, 22), p(20, 24)], radius=1 * U, fill=WHITE)


def glyph_controls(d):
    # Two sliders, as in Control Center
    for y, knob in ((9, 16), (17, 9)):
        d.rounded_rectangle([p(4, y - 1.2), p(25, y + 1.2)], radius=1.2 * U, fill=WHITE)
        d.ellipse([p(knob - 3.2, y - 3.2), p(knob + 3.2, y + 3.2)], fill=WHITE)


def glyph_cursor(d):
    # A text cursor with arrows on both sides
    d.rectangle([p(13.6, 5), p(15.4, 24)], fill=WHITE)
    d.rectangle([p(11, 4), p(18, 5.6)], fill=WHITE)
    d.rectangle([p(11, 23.4), p(18, 25)], fill=WHITE)
    d.polygon([p(3, 14.5), p(9, 10), p(9, 19)], fill=WHITE)
    d.polygon([p(26, 14.5), p(20, 10), p(20, 19)], fill=WHITE)


def glyph_markup(d):
    # Screenshot frame corners and a pencil across them
    w = round(1.8 * U)
    for x0, y0, dx, dy in ((5, 5, 1, 1), (24, 5, -1, 1), (5, 24, 1, -1), (24, 24, -1, -1)):
        d.line([p(x0, y0), p(x0 + 5 * dx, y0)], fill=WHITE, width=w)
        d.line([p(x0, y0), p(x0, y0 + 5 * dy)], fill=WHITE, width=w)
    d.polygon([p(10.5, 17), p(17, 10.5), p(19, 12.5), p(12.5, 19)], fill=WHITE)
    d.polygon([p(10, 17.5), p(12, 19.5), p(8.5, 21)], fill=WHITE)


def glyph_stopwatch(d):
    # A stopwatch: dial, crown and hand
    d.ellipse([p(5.5, 7), p(23.5, 25)], outline=WHITE, width=round(2.2 * U))
    d.rounded_rectangle([p(11.5, 2.5), p(17.5, 5.5)], radius=1 * U, fill=WHITE)
    d.line([p(14.5, 16), p(14.5, 10.5)], fill=WHITE, width=round(2 * U))
    d.line([p(14.5, 16), p(18.5, 18)], fill=WHITE, width=round(2 * U))
    d.ellipse([p(13.2, 14.7), p(15.8, 17.3)], fill=WHITE)


def glyph_magnifier(d):
    # A magnifying glass: a ring and a handle
    d.ellipse([p(4.5, 4.5), p(19.5, 19.5)], outline=WHITE, width=round(2.6 * U))
    d.line([p(17.2, 17.2), p(24, 24)], fill=WHITE, width=round(3.6 * U))
    d.ellipse([p(22.2, 22.2), p(25.8, 25.8)], fill=WHITE)


def glyph_appearance(d):
    # The iOS 13 appearance sign: a ring with its right half filled
    d.ellipse([p(5, 5), p(24, 24)], outline=WHITE, width=round(2.2 * U))
    d.pieslice([p(5, 5), p(24, 24)], start=-90, end=90, fill=WHITE)


ICONS = {
    "repo/CydiaIcon.png": ((115, 199, 252), (26, 112, 214), glyph_infinity),
    "icons/com.skeuo4ever.core.png": ((115, 199, 252), (26, 112, 214), glyph_infinity),
    "icons/com.skeuo4ever.swipeback.png": ((150, 168, 196), (78, 99, 135), glyph_back),
    "icons/com.skeuo4ever.battery.png": ((255, 222, 92), (238, 160, 0), glyph_battery),
    "icons/com.skeuo4ever.nightshift.png": ((72, 92, 160), (18, 26, 66), glyph_moon),
    "icons/com.skeuo4ever.newsash.png": ((110, 181, 255), (33, 99, 214), glyph_new_app),
    "icons/com.skeuo4ever.boldtext.png": ((166, 173, 183), (90, 99, 112), glyph_bold),
    "icons/com.skeuo4ever.desktopsite.png": ((100, 205, 250), (24, 116, 222), glyph_monitor),
    "icons/com.skeuo4ever.controlcenter.png": ((118, 124, 133), (40, 43, 48), glyph_controls),
    "icons/com.skeuo4ever.keyboardcursor.png": ((150, 158, 172), (82, 90, 104), glyph_cursor),
    "icons/com.skeuo4ever.screenshot.png": ((196, 150, 245), (112, 62, 190), glyph_markup),
    "icons/com.skeuo4ever.cameratimer.png": ((132, 141, 156), (52, 58, 70), glyph_stopwatch),
    "icons/com.skeuo4ever.darkmode.png": ((92, 97, 110), (20, 22, 28), glyph_appearance),
    "icons/com.skeuo4ever.settingssearch.png": ((176, 182, 192), (98, 105, 118), glyph_magnifier),
    "icons/com.skeuo4ever.png": ((255, 176, 70), (232, 98, 18), glyph_infinity),
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

    # Gloss: a light oval on top
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
