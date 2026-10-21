"""Render the README preview images (docs/images/*.png) from the addon's own layout numbers.

They mirror Bar.lua (standard / one row / vertical layouts at the default size), Ammo.lua's
colour bands, Vendors.lua's pins and tooltip, and the settings window as Options.lua lays it
out. Text uses the bundled Barlow Condensed; in game the default font is the client's 2002 Bold.

Usage: python -I tools/render_previews.py   (needs Pillow)
"""
import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "docs" / "images"
FONT = str(ROOT / "Media" / "Fonts" / "BarlowCondensed-SemiBold.ttf")
FONT_BOLD = str(ROOT / "Media" / "Fonts" / "BarlowCondensed-Bold.ttf")
UI_FONT = str(ROOT / "Media" / "Fonts" / "TitilliumWeb-Bold.ttf")
S = 3  # pixels per UI unit

# Colours from Config.lua / Bar.lua / Ammo.lua / Vendors.lua
MOVE = (0.36, 0.82, 0.47)
STAND = (0.96, 0.40, 0.29)
ZONE = (0.42, 0.11, 0.08)
TRACK = (0.07, 0.07, 0.08)
TEXT = (0.95, 0.95, 0.95)
MUTED = (0.62, 0.64, 0.67)
MELEE = (1.00, 0.78, 0.30)
RANGE = {"in": ("In range", (0.36, 0.82, 0.47)), "close": ("Too close", (1.00, 0.66, 0.20)),
         "far": ("Out of range", (0.96, 0.40, 0.29))}
BANDS = [(70, "40d860"), (50, "a6d96a"), (30, "ffc04d"), (15, "ff8c2e"), (0, "f23a3a")]
FACTION = {"A": ("Alliance", (0.27, 0.55, 1)), "H": ("Horde", (0.92, 0.22, 0.2)), "N": ("Neutral", (1, 0.82, 0.25))}
BG = (24, 28, 24)
WIDTH, THICK, FONT_SIZE, SMALL, GAP = 220, 10, 12, 10, 4
WINDOW = 0.55  # 0.5 s stand-still + 50 ms ping
STAND_H = max(3, int(THICK * 0.4 + 0.5))  # the stand-still bar under the main one (Bar.lua)
STAND_EXTRA = STAND_H + 3


def stand_bar(img, x, y, length, value, vertical=False, colour=None):
    """The slim stand-still bar: track, 1 px border, fill (green: move, red: stand)."""
    d = ImageDraw.Draw(img)
    colour = colour or STAND
    if vertical:
        rect(d, x - 1, y - 1, x + STAND_H + 1, y + length + 1, (0, 0, 0, 255))
        rect(d, x, y, x + STAND_H, y + length, rgb(TRACK))
        if value > 0:
            rect(d, x, y + length * (1 - value), x + STAND_H, y + length, rgb(colour))
    else:
        rect(d, x - 1, y - 1, x + length + 1, y + STAND_H + 1, (0, 0, 0, 255))
        rect(d, x, y, x + length, y + STAND_H, rgb(TRACK))
        if value > 0:
            rect(d, x, y, x + length * value, y + STAND_H, rgb(colour))


def stand_value(value, speed, window):
    """The stand-still bar at this point of the swing (standing still): (fill, colour)."""
    if window <= 0:
        return 0, STAND
    move_for = speed - window
    if value * speed < move_for:
        return 1.0, MOVE
    return max(0.0, min(1.0, (value * speed - move_for) / window)), STAND


def rgb(c, a=255):
    return tuple(int(round(v * 255)) for v in c[:3]) + (a,)


def hexrgb(h):
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4)) + (255,)


def font(size, path=FONT):
    return ImageFont.truetype(path, int(size * S))


def text(d, x, y, s, size, colour, anchor="la", path=FONT, shadow=True, alpha=1.0):
    f = font(size, path)
    if alpha < 1:
        # Draw on a layer and blend it, so a faded text mixes with what is under it.
        if alpha <= 0.01:
            return
        layer = Image.new("RGBA", d._image.size, (0, 0, 0, 0))
        text(ImageDraw.Draw(layer), x, y, s, size, colour, anchor, path, shadow)
        layer.putalpha(layer.getchannel("A").point(lambda v: int(v * alpha)))
        d._image.alpha_composite(layer)
        return
    if shadow:
        d.text((x * S + S, y * S + S), s, font=f, fill=(0, 0, 0, 220), anchor=anchor)
    d.text((x * S, y * S), s, font=f, fill=colour, anchor=anchor)


def rect(d, x0, y0, x1, y1, colour):
    d.rectangle([x0 * S, y0 * S, x1 * S - 1, y1 * S - 1], fill=colour)


def gradient(img, x0, y0, x1, y1, c0, c1, vertical=False):
    d = ImageDraw.Draw(img)
    n = int((y1 - y0) * S) if vertical else int((x1 - x0) * S)
    for i in range(max(1, n)):
        t = i / max(1, n - 1)
        c = tuple(int(c0[k] + (c1[k] - c0[k]) * t) for k in range(3)) + (255,)
        if vertical:
            yy = int(y1 * S) - 1 - i
            d.line([(x0 * S, yy), (x1 * S - 1, yy)], fill=c)
        else:
            xx = int(x0 * S) + i
            d.line([(xx, y0 * S), (xx, y1 * S - 1)], fill=c)


def arrow_icon(d, x, y, size, colour=(200, 170, 110, 255)):
    """A small arrow glyph standing in for the ammo icon."""
    s = size * S
    x0, y0 = x * S, y * S
    d.rectangle([x0, y0, x0 + s - 1, y0 + s - 1], fill=(52, 40, 28, 255), outline=(20, 14, 8, 255))
    d.line([(x0 + s * 0.2, y0 + s * 0.8), (x0 + s * 0.8, y0 + s * 0.2)], fill=colour, width=max(2, S))
    d.polygon([(x0 + s * 0.85, y0 + s * 0.15), (x0 + s * 0.55, y0 + s * 0.22), (x0 + s * 0.78, y0 + s * 0.45)], fill=(220, 220, 225, 255))
    d.line([(x0 + s * 0.2, y0 + s * 0.8), (x0 + s * 0.1, y0 + s * 0.62)], fill=(230, 80, 60, 255), width=max(2, S))
    d.line([(x0 + s * 0.2, y0 + s * 0.8), (x0 + s * 0.38, y0 + s * 0.9)], fill=(230, 80, 60, 255), width=max(2, S))


def bullet_icon(d, x, y, size):
    s = size * S
    x0, y0 = x * S, y * S
    d.rectangle([x0, y0, x0 + s - 1, y0 + s - 1], fill=(40, 40, 46, 255), outline=(12, 12, 14, 255))
    d.rounded_rectangle([x0 + s * 0.3, y0 + s * 0.18, x0 + s * 0.7, y0 + s * 0.85], radius=s * 0.18, fill=(200, 160, 70, 255))
    d.rectangle([x0 + s * 0.3, y0 + s * 0.55, x0 + s * 0.7, y0 + s * 0.85], fill=(170, 120, 50, 255))


def bar(img, x, y, length, thick, value, colour, speed=2.09, vertical=False, window=WINDOW):
    """StatusBar with track, stand-still zone, gradient fill, divider, sheen, border, spark."""
    d = ImageDraw.Draw(img)
    zone = length * min(window, speed) / speed
    if vertical:
        rect(d, x - 1, y - 1, x + thick + 1, y + length + 1, (0, 0, 0, 255))
        rect(d, x, y, x + thick, y + length, rgb(TRACK))
        rect(d, x, y, x + thick, y + zone, rgb(ZONE))
        fill = length * value
        if fill > 0:
            gradient(img, x, y + length - fill, x + thick, y + length, rgb([c * 0.72 for c in colour]), rgb(colour), vertical=True)
        d.line([(x * S, (y + zone) * S), ((x + thick) * S - 1, (y + zone) * S)], fill=(255, 255, 255, 140), width=1)
        spark_at = (x + thick / 2, y + length - fill)
    else:
        rect(d, x - 1, y - 1, x + length + 1, y + thick + 1, (0, 0, 0, 255))
        rect(d, x, y, x + length, y + thick, rgb(TRACK))
        if zone >= 0.5:
            rect(d, x + length - zone, y, x + length, y + thick, rgb(ZONE))
        fill = length * value
        if fill > 0:
            gradient(img, x, y, x + fill, y + thick, rgb([c * 0.72 for c in colour]), rgb(colour))
        if zone >= 0.5:
            d.line([((x + length - zone) * S, y * S), ((x + length - zone) * S, (y + thick) * S - 1)], fill=(255, 255, 255, 140), width=1)
        d.line([(x * S, y * S), ((x + length) * S - 1, y * S)], fill=(255, 255, 255, 30), width=1)
        spark_at = (x + fill, y + thick / 2)
    if 0 < value < 1:
        glow = Image.new("RGBA", img.size, (0, 0, 0, 0))
        g = ImageDraw.Draw(glow)
        cx, cy = spark_at[0] * S, spark_at[1] * S
        if vertical:
            g.ellipse([cx - thick * 1.2 * S, cy - 3 * S, cx + thick * 1.2 * S, cy + 3 * S], fill=(255, 255, 230, 200))
        else:
            g.ellipse([cx - 3 * S, cy - thick * 1.2 * S, cx + 3 * S, cy + thick * 1.2 * S], fill=(255, 255, 230, 200))
        img.alpha_composite(glow.filter(ImageFilter.GaussianBlur(2.2 * S)))
        d.line([(cx, (spark_at[1] - thick * 0.6) * S), (cx, (spark_at[1] + thick * 0.6) * S)] if not vertical else
               [((spark_at[0] - thick * 0.6) * S, cy), ((spark_at[0] + thick * 0.6) * S, cy)], fill=(255, 255, 240, 255), width=S)


def ammo(d, x, y, pct):
    colour = next(hexrgb(c) for lo, c in BANDS if pct >= lo)
    arrow_icon(d, x, y - SMALL + 1, SMALL)
    text(d, x + SMALL + 3, y, f"{pct}%", SMALL, colour, anchor="ls")


def range_text(d, right_x, y, state, distance, align="right"):
    label, c = RANGE[state]
    s = f"{label}  {distance}"
    w = font(SMALL).getlength(s) / S
    dot = max(4, SMALL // 2)
    x0 = right_x - w if align == "right" else right_x + dot + 4
    dx = x0 - 4 - dot
    rect(d, dx, y - SMALL * 0.5 - dot / 2 - 1, dx + dot, y - SMALL * 0.5 + dot / 2 - 1, rgb(c))
    text(d, x0, y, s, SMALL, rgb(c), anchor="ls")


def standard(img, ox, oy, status, scolour, countdown, value, pct, state, distance, info="2.09s   ~4 shots", window=WINDOW, speed=2.09, text_alpha=1.0, stand=None):
    d = ImageDraw.Draw(img)
    top = max(FONT_SIZE, SMALL) + GAP
    base = oy + top - GAP
    text(d, ox, base, status, FONT_SIZE, rgb(scolour), anchor="ls", path=FONT_BOLD, alpha=text_alpha)
    count_w = math.ceil(FONT_SIZE * 2.2)
    count_slot = count_w + 8
    ammo_w = SMALL + 3 + math.ceil(SMALL * 2.6)
    if countdown:
        text(d, ox + WIDTH, base, countdown, FONT_SIZE, rgb(TEXT), anchor="rs", path=FONT_BOLD, alpha=text_alpha)
    ammo(d, ox + WIDTH - count_slot - ammo_w, base, pct)
    bar(img, ox, oy + top, WIDTH, THICK, value, scolour, speed=speed, window=window)
    sv, sc = stand_value(value, speed, window) if stand is None else (stand, STAND)
    stand_bar(img, ox, oy + top + THICK + 3, WIDTH, sv, colour=sc)
    below = oy + top + THICK + STAND_EXTRA + GAP + SMALL
    text(d, ox, below, info, SMALL, rgb(MUTED), anchor="ls", alpha=text_alpha)
    range_text(d, ox + WIDTH, below, state, distance)


def canvas(w, h):
    img = Image.new("RGBA", (int(w * S), int(h * S)), BG + (255,))
    # Soft vignette so the bar reads like it sits over the game world.
    v = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ImageDraw.Draw(v).ellipse([-w * S * 0.2, -h * S * 0.4, w * S * 1.2, h * S * 1.4], fill=(46, 58, 42, 255))
    img.alpha_composite(v.filter(ImageFilter.GaussianBlur(40 * S)))
    return img


def caption(img, x, y, s):
    text(ImageDraw.Draw(img), x, y, s, 9, (170, 176, 170, 255), anchor="ls", path=UI_FONT, shadow=False)


def render_phases():
    img = canvas(520, 82)
    x, y = 24, 22
    standard(img, x, y, "MOVE", MOVE, "0.9", 0.29, 62, "in", "25-30 yd")
    caption(img, x, 14, "1  Free to move")
    x = 272
    standard(img, x, y, "STAND STILL", STAND, "0.29", 0.86, 62, "in", "25-30 yd")
    caption(img, x, 14, "2  Stand still, the shot is coming")
    img.save(OUT / "bar-phases.png")

    img = canvas(520, 82)
    x = 24
    standard(img, x, y, "TOO CLOSE", STAND, "", 1.0, 18, "close", "5-8 yd", info="2.09s")
    caption(img, x, 14, "Shot held up: inside the dead zone")
    x = 272
    standard(img, x, y, "OUT OF RANGE", STAND, "", 1.0, 9, "far", "40-45 yd", info="2.09s")
    caption(img, x, 14, "Shot held up: target too far away")
    img.save(OUT / "bar-blocked.png")


def render_melee():
    img = canvas(520, 82)
    x, y = 24, 22
    standard(img, x, y, "MELEE", MELEE, "0.7", 0.61, 62, "close", "5-8 yd", info="1.80s melee", window=0, speed=1.8)
    caption(img, x, 14, "Swinging in melee: time to your next swing")
    x = 272
    standard(img, x, y, "TOO CLOSE", STAND, "", 0.0, 62, "close", "5-8 yd", info="2.09s   ~4 shots", stand=0)
    caption(img, x, 14, "In combat, too close, not swinging")
    img.save(OUT / "bar-melee.png")


def render_layouts():
    img = canvas(560, 272)
    d = ImageDraw.Draw(img)
    caption(img, 24, 20, "Horizontal, text above (default)")
    standard(img, 24, 28, "MOVE", MOVE, "0.9", 0.29, 62, "in", "25-30 yd")

    caption(img, 24, 106, "Horizontal, one row")
    status_w = math.ceil(FONT_SIZE * 6)
    count_w = math.ceil(FONT_SIZE * 2.2)
    row_h = max(THICK, FONT_SIZE + 2)
    oy = 114
    left = 24 + status_w + 6
    by = oy + (row_h - THICK) / 2
    text(d, left - 6, by + THICK / 2, "STAND STILL", FONT_SIZE, rgb(STAND), anchor="rm", path=FONT_BOLD)
    bar(img, left, by, WIDTH, THICK, 0.86, STAND)
    text(d, left + WIDTH + 6, by + THICK / 2, "0.29", FONT_SIZE, rgb(TEXT), anchor="lm", path=FONT_BOLD)
    sv, sc = stand_value(0.86, 2.09, WINDOW)
    stand_bar(img, left, by + THICK + 3, WIDTH, sv, colour=sc)
    ax = left + WIDTH + 6 + count_w + 6
    arrow_icon(d, ax, by + THICK / 2 - SMALL / 2, SMALL)
    text(d, ax + SMALL + 3, by + THICK / 2, "62%", SMALL, hexrgb("a6d96a"), anchor="lm")
    below = oy + row_h + STAND_EXTRA + GAP + SMALL
    text(d, left, below, "2.09s   ~4 shots", SMALL, rgb(MUTED), anchor="ls")
    range_text(d, left + WIDTH, below, "in", "25-30 yd")

    caption(img, 420, 20, "Vertical")
    vx, vy = 420, 28
    length = 210
    bar(img, vx, vy, length, THICK, 0.45, MOVE, vertical=True)
    sv, sc = stand_value(0.45, 2.09, WINDOW)
    stand_bar(img, vx + THICK + 3, vy, length, sv, vertical=True, colour=sc)
    tx = vx + THICK + 6 + STAND_EXTRA
    text(d, tx, vy + FONT_SIZE, "MOVE", FONT_SIZE, rgb(MOVE), anchor="ls", path=FONT_BOLD)
    text(d, tx, vy + 2 * FONT_SIZE + 3, "0.6", FONT_SIZE, rgb(TEXT), anchor="ls", path=FONT_BOLD)
    ammo(d, tx, vy + 2 * FONT_SIZE + 6 + SMALL, 62)
    range_text(d, tx, vy + 2 * FONT_SIZE + 9 + 2 * SMALL, "in", "25-30 yd", align="left")
    text(d, tx, vy + length, "2.09s   ~4 shots", SMALL, rgb(MUTED), anchor="ls")
    img.save(OUT / "layouts.png")


def render_ammo():
    img = canvas(520, 58)
    d = ImageDraw.Draw(img)
    samples = [(85, "70-100%"), (60, "50-69%"), (40, "30-49%"), (20, "15-29%"), (8, "0-14%")]
    for i, (pct, label) in enumerate(samples):
        x = 24 + i * 100
        ammo(d, x, 28, pct)
        caption(img, x, 46, label)
    img.save(OUT / "ammo-colours.png")


def pin(d, img, x, y, faction, kind="arrow", size=18, count=None):
    c = rgb(FACTION[faction][1])
    rect(d, x - size / 2, y - size / 2, x + size / 2, y + size / 2, c)
    inner = size - 4
    (arrow_icon if kind == "arrow" else bullet_icon)(d, x - inner / 2, y - inner / 2, inner)
    if count:
        text(d, x + size / 2 + 3, y + size / 2 + 2, str(count), 9, (255, 210, 0, 255), anchor="rs", path=FONT_BOLD)


def render_vendors():
    w, h = 520, 220
    img = Image.new("RGBA", (w * S, h * S), (0, 0, 0, 255))
    # Parchment-like map backdrop with a few faint "roads".
    paper = Image.new("RGBA", img.size, (182, 160, 118, 255))
    pd = ImageDraw.Draw(paper)
    for i in range(9):
        pd.ellipse([(30 + i * 57) * S, (20 + (i * 37) % 160) * S, (130 + i * 57) * S, (90 + (i * 37) % 160) * S], fill=(168, 146, 104, 255))
    pd.line([(0, 150 * S), (180 * S, 120 * S), (300 * S, 140 * S), (520 * S, 90 * S)], fill=(140, 116, 80, 255), width=4 * S)
    img.alpha_composite(paper.filter(ImageFilter.GaussianBlur(6 * S)))
    d = ImageDraw.Draw(img)
    pin(d, img, 70, 70, "A")
    pin(d, img, 128, 150, "A", count=4)
    pin(d, img, 200, 92, "N", kind="bullet")
    pin(d, img, 64, 182, "N")
    pin(d, img, 236, 176, "A", kind="bullet", size=13)
    # Tooltip for the hovered pin (Vendors.lua OnMouseEnter, one vendor).
    tx, ty, tw = 262, 18, 236
    lines = [("Brog Hamfist", (255, 255, 255, 255), None),
             ("Alliance", rgb(FACTION["A"][1]), None),
             ("Rough Arrow", (230, 230, 230, 255), "level 1"),
             ("Light Shot", (230, 230, 230, 255), "level 1"),
             ("Elwynn Forest  44.0, 65.9", (153, 153, 153, 255), None),
             ("Click: set a waypoint", (128, 204, 255, 255), None)]
    th = 12 + len(lines) * 15
    d.rounded_rectangle([tx * S, ty * S, (tx + tw) * S, (ty + th) * S], radius=4 * S, fill=(8, 10, 22, 236), outline=(120, 120, 130, 255), width=S)
    for i, (s, c, right) in enumerate(lines):
        yy = ty + 18 + i * 15
        text(d, tx + 9, yy, s, 11 if i else 12.5, c, anchor="ls", path=UI_FONT if i == 0 else FONT, shadow=False)
        if right:
            text(d, tx + tw - 9, yy, right, 11, (153, 153, 153, 255), anchor="rs", shadow=False)
    d.line([(70 * S, 70 * S), (tx * S, (ty + 10) * S)], fill=(255, 255, 255, 60), width=S)
    # Legend
    legend_y = 206
    for i, (f, (name, _)) in enumerate(FACTION.items()):
        lx = 270 + i * 82
        rect(d, lx, legend_y - 9, lx + 10, legend_y + 1, rgb(FACTION[f][1]))
        text(d, lx + 15, legend_y, name, 10, (30, 26, 20, 255), anchor="ls", path=UI_FONT, shadow=False)
    img.save(OUT / "vendor-pins.png")


def render_settings():
    """The /hst window, placed as Options.lua places it (890 x 540)."""
    W, H, COL = 890, 540, 270
    LEFT, MID, RIGHT = 16, 310, 604
    s = 1.6
    img = Image.new("RGBA", (int(W * s * S / 3 * 3), int(H * s * S / 3 * 3)), (0, 0, 0, 0))
    scale = s

    def X(v):
        return v * scale

    d = ImageDraw.Draw(img)
    gold, white, grey = (255, 209, 0, 255), (240, 240, 240, 255), (200, 200, 200, 255)
    d.rounded_rectangle([0, 0, X(W) * S - 1, X(H) * S - 1], radius=6 * S, fill=(18, 18, 20, 250), outline=(90, 90, 96, 255), width=2 * S)
    d.rectangle([2 * S, 2 * S, X(W) * S - 3, X(24) * S], fill=(32, 32, 36, 255))

    def t(x, y, s_, size=11, c=grey, anchor="la", path=UI_FONT):
        f = ImageFont.truetype(path, int(size * scale * S))
        d.text((X(x) * S, X(y) * S), s_, font=f, fill=c, anchor=anchor)

    t(W / 2, 5, "Hunter Shot Timer", 12, gold, "ma")
    t(W - 14, 4, "x", 12, (200, 60, 50, 255), "ra")

    def heading(x, y, s_):
        t(x, -y, s_, 12, gold)
        d.line([(X(x) * S, X(-y + 16) * S), (X(x + COL) * S, X(-y + 16) * S)], fill=(255, 209, 0, 64), width=S)

    def checkbox(x, y, s_, on=True):
        bx, by = X(x + 3) * S, X(-y + 3) * S
        bs = X(18) * S
        d.rounded_rectangle([bx, by, bx + bs, by + bs], radius=2 * S, fill=(10, 10, 12, 255), outline=(150, 150, 150, 255), width=S)
        if on:
            d.line([(bx + bs * 0.2, by + bs * 0.55), (bx + bs * 0.42, by + bs * 0.78), (bx + bs * 0.82, by + bs * 0.2)], fill=gold, width=3 * S)
        t(x + 27, -y + 5, s_, 11, white)

    def slider(x, y, s_, value, frac):
        t(x, -y, s_, 10, grey)
        sy = -y + 22
        d.line([(X(x + 14) * S, X(sy) * S), (X(x + COL - 70) * S, X(sy) * S)], fill=(90, 90, 96, 255), width=3 * S)
        kx = X(x + 14 + (COL - 84) * frac) * S
        d.ellipse([kx - 5 * S, X(sy) * S - 5 * S, kx + 5 * S, X(sy) * S + 5 * S], fill=gold)
        t(x + 2, sy - 7, "<", 10, gold)
        t(x + COL - 62, sy - 7, ">", 10, gold)
        t(x + COL - 50, sy - 7, value, 10, white)

    def choice(x, y, s_, value):
        t(x, -y, s_, 10, grey)
        bx, by = X(x) * S, X(-y + 16) * S
        d.rounded_rectangle([bx, by, bx + X(COL - 10) * S, by + X(22) * S], radius=3 * S, fill=(26, 26, 30, 255), outline=(110, 110, 116, 255), width=S)
        t(x + 8, -y + 20, value, 10, white)
        t(x + COL - 22, -y + 19, "v", 10, gold)

    def swatch(x, y, s_, c):
        d.rectangle([X(x) * S, X(-y) * S, X(x + 18) * S, X(-y + 18) * S], fill=c, outline=(150, 150, 150, 255), width=S)
        t(x + 24, -y + 2, s_, 11, white)

    y = -34
    heading(LEFT, y, "Layout & size"); y -= 26
    choice(LEFT, y, "Layout", "Horizontal, text above"); y -= 48
    slider(LEFT, y, "Length", "220", (220 - 100) / 400); y -= 42
    slider(LEFT, y, "Thickness", "10", (10 - 4) / 36); y -= 42
    slider(LEFT, y, "Opacity", "100%", 1); y -= 42
    slider(LEFT, y, "Stand-still window adjust", "0 ms", 200 / 500); y -= 46
    heading(LEFT, y, "Timing"); y -= 22
    checkbox(LEFT, y, "Add my ping to the window"); y -= 34
    heading(LEFT, y, "Ammo vendors on the map"); y -= 22
    checkbox(LEFT, y, "World map"); checkbox(LEFT + COL / 2, y, "Minimap"); y -= 24
    checkbox(LEFT, y, "Continent maps"); checkbox(LEFT + COL / 2, y, "Neutral"); y -= 24
    checkbox(LEFT, y, "Other faction", False); y -= 30
    choice(LEFT, y, "Vendors that sell", "Match my weapon")

    y = -34
    heading(MID, y, "Text"); y -= 26
    choice(MID, y, "Font", "2002 Bold"); y -= 48
    choice(MID, y, "Text style", "Shadow"); y -= 48
    slider(MID, y, "Font size", "12", (12 - 8) / 20); y -= 42
    slider(MID, y, "Small font size (info, range)", "10", (10 - 6) / 14); y -= 46
    heading(MID, y, "Colors"); y -= 24
    swatch(MID, y, "Move", rgb(MOVE)); swatch(MID + COL / 2, y, "Stand still", rgb(STAND)); y -= 24
    swatch(MID, y, "Window", rgb(ZONE)); swatch(MID + COL / 2, y, "Background", rgb(TRACK)); y -= 24
    swatch(MID, y, "Countdown", rgb(TEXT)); swatch(MID + COL / 2, y, "Melee", rgb(MELEE)); y -= 30
    choice(MID, y, "Bar texture", "Flat")

    y = -34
    heading(RIGHT, y, "Show"); y -= 22
    checkbox(RIGHT, y, "Status text"); checkbox(RIGHT + COL / 2, y, "Countdown"); y -= 24
    checkbox(RIGHT, y, "Weapon speed"); checkbox(RIGHT + COL / 2, y, "Shots to kill"); y -= 24
    checkbox(RIGHT, y, "Spark"); checkbox(RIGHT + COL / 2, y, "Flash on shot"); y -= 24
    checkbox(RIGHT, y, "Border"); checkbox(RIGHT + COL / 2, y, "Gradient fill"); y -= 24
    checkbox(RIGHT, y, "Melee & too close"); checkbox(RIGHT + COL / 2, y, "Stand-still bar"); y -= 30
    choice(RIGHT, y, "Ammo left", "Percent (62%)"); y -= 52
    heading(RIGHT, y, "Range check"); y -= 22
    checkbox(RIGHT, y, "Enabled"); checkbox(RIGHT + COL / 2, y, "Show text"); y -= 24
    checkbox(RIGHT, y, "Only in combat", False); checkbox(RIGHT + COL / 2, y, "When not shooting"); y -= 30
    choice(RIGHT, y, "Position (horizontal layouts)", "Below, right"); y -= 48
    choice(RIGHT, y, "Distance to target", "Range (20-25 yd)")

    def button(x, w, label, right=False):
        bx = X(W - 16 - w) if right else X(x)
        by = X(H - 14 - 22)
        d.rounded_rectangle([bx * S, by * S, (bx + X(w)) * S, (by + X(22)) * S], radius=3 * S, fill=(120, 18, 14, 255), outline=(60, 10, 8, 255), width=S)
        f = ImageFont.truetype(UI_FONT, int(10 * scale * S))
        d.text(((bx + X(w) / 2) * S, (by + X(11)) * S), label, font=f, fill=gold, anchor="mm")

    button(16, 120, "Reset position")
    button(144, 140, "Reset all settings")
    button(0, 90, "Done", right=True)
    t(W / 2, H - 42 - 12, "Drag the bar to move it while this window is open.", 10, (128, 128, 128, 255), "ma")
    img = img.resize((img.width * 2 // 3, img.height * 2 // 3), Image.LANCZOS)
    img.save(OUT / "settings.png")


def smooth(t):
    return t * t * (3 - 2 * t)  # as Bar.lua


def render_switch():
    """MELEE to the shot bar as Bar.lua glides it: over BLEND_TIME the fill, colour and window
    ease to their new place, and the texts fade out and come back with the new words."""
    blend_time, speed = 0.2, 2.09
    frames = [0, 0.25, 0.5, 0.75, 1]
    row = 52 + STAND_EXTRA
    img = canvas(330, 14 + row * len(frames))
    d = ImageDraw.Draw(img)
    from_value = 0.61
    for i, b in enumerate(frames):
        e = smooth(b)
        y = 12 + row * i
        since_shot = b * blend_time  # you stepped back and shot; the switch starts with the shot
        value = from_value + (since_shot / speed - from_value) * e
        colour = tuple(MELEE[k] + (MOVE[k] - MELEE[k]) * e for k in range(3))
        swapped = b >= 0.5
        alpha = 1.0 if b >= 1 else abs(1 - 2 * b)
        left = speed - since_shot - WINDOW
        standard(img, 84, y, "MOVE" if swapped else "MELEE", colour, f"{left:.1f}" if swapped else "0.7",
                 value, 62, "in", "8-10 yd", info="2.09s   ~4 shots" if swapped else "1.80s melee",
                 window=WINDOW * e, speed=speed, text_alpha=alpha)
        text(d, 24, y + 23, f"{int(round(since_shot * 1000))} ms", 11, (170, 176, 170, 255),
             anchor="ls", path=UI_FONT, shadow=False)
    img.save(OUT / "bar-switch.png")


def render_timing():
    """What /hst timing prints, from Timer.lua's own ns.TimingReport() (needs lupa)."""
    import lupa.lua51 as lupa
    lua = lupa.LuaRuntime()
    lua.execute("issecret = function() return false end")
    ns = lua.eval("{}")
    lua.eval("function(s) return assert(loadstring(s, 'Timer.lua')) end")(
        (ROOT / "Timer.lua").read_text(encoding="utf-8"))("HunterShotTimer", ns)
    lua.execute("function fillGaps(ns, list) ns.gaps = {} for i, g in ipairs(list) do ns.gaps[i] = { gap = g, speed = 2.09 } end end")
    lua.globals().fillGaps(ns, lua.table(2.11, 2.08, 2.10, 2.12, 4.30, 2.09, 2.10))
    lua.execute("function fillCalib(ns) ns.DEFAULTS = { windowExtra = 0, addPing = true } "
                "ns.calib = { stand = { 0.61, 0.63, 0.62, 0.62 }, early = { 0.02, 0.01, 0.03 }, missed = { 0.51, 0.5, 0.52 } } end")
    lua.globals().fillCalib(ns)
    lines = list(ns.TimingReport().values())

    size, lh = 11, 15
    f = font(size, FONT)
    w = 20 + max(f.getlength(l) for l in lines) / S + 20
    prefix = "Hunter Shot Timer "
    out = [(prefix, "Auto Shot timing (stand still and shoot first):")]
    for line in lines:
        cur = "  "
        for word in line.split(" "):
            trial = cur + word if cur.strip() == "" else cur + " " + word
            if f.getlength(trial) / S > w - 20 and cur.strip():
                out.append(("", cur))
                cur = "    " + word
            else:
                cur = trial
        out.append(("", cur))
    h = 14 + lh * len(out)
    img = canvas(w + 48, h + 28)
    d = ImageDraw.Draw(img)
    rect(d, 24, 14, 24 + w, 14 + h, (10, 12, 10, 255))  # the chat frame's dark background
    y = 14 + 7 + size
    for pre, body in out:
        x = 34
        if pre:
            text(d, x, y, pre, size, (171, 212, 115, 255), anchor="ls")
            x += f.getlength(pre) / S
        colour = (170, 170, 170, 255) if "left out" in body else (255, 255, 255, 255)
        text(d, x, y, body, size, colour, anchor="ls")
        y += lh
    img.save(OUT / "timing.png")


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    render_phases()
    render_melee()
    render_switch()
    render_timing()
    render_layouts()
    render_ammo()
    render_vendors()
    render_settings()
    print("rendered:", ", ".join(sorted(p.name for p in OUT.glob("*.png"))))
