#!/usr/bin/env python3
"""Generate the plugin icons (an original mark: equaliser bars + a skip chevron).

  <name>.svg      24x24 monochrome glyph, all #000: Material Skin swaps it in
                  for <name>_svg.png and recolours it per theme
  <name>_svg.png  512x512 full-bleed colour tile for other skins/apps

Deliberately not YouTube's logo (no red rounded rectangle, no play button).
The tile is full-bleed: clients round or crop it themselves. PNG rendering
uses macOS QuickLook.

LMS and browsers cache resized icons by path, so bump NAME when the art
changes (and update install.xml).

Menu icons: MTL_icon_<name>.png for each Material Design icon in MENU_ICONS.
Material Skin sees "MTL_icon_<name>" in the path and draws its own icon of
that name (themed); other skins show the PNG: the same glyph, white on the
logo's tile. Glyphs are Google's Material Icons (Apache-2.0), fetched from
the npm CDN when this script runs.
"""

import os
import re
import shutil
import subprocess
import tempfile
import urllib.request

NAME = "youtube-direct-1"
OUT = os.path.join(os.path.dirname(__file__), "..", "src", "YouTubeDirect",
                   "HTML", "EN", "plugins", "YouTubeDirect", "html", "images")

# in a 512 box: three equaliser bars (centre x, height), then a chevron
BARS = [(92, 150), (148, 250), (204, 190)]
BAR_W, BAR_CY = 34, 256
CHEVRONS = [272, 344]          # left x of each chevron
CHEV_W, CHEV_H, CHEV_T = 92, 230, 40   # width, height, stroke thickness


def f(v):
    return f"{v:.2f}".rstrip("0").rstrip(".")


def bar_paths():
    r = BAR_W / 2
    out = []
    for cx, h in BARS:
        x0, x1 = cx - r, cx + r
        top, bot = BAR_CY - h / 2 + r, BAR_CY + h / 2 - r
        out.append(f"M{f(x0)} {f(top)}A{f(r)} {f(r)} 0 0 1 {f(x1)} {f(top)}V{f(bot)}"
                   f"A{f(r)} {f(r)} 0 0 1 {f(x0)} {f(bot)}Z")
    return "".join(out)


def chevron_paths():
    out = []
    for x in CHEVRONS:
        top, mid, bot = BAR_CY - CHEV_H / 2, BAR_CY, BAR_CY + CHEV_H / 2
        # a ">" outlined as a filled polygon of thickness CHEV_T
        out.append(
            f"M{f(x)} {f(top)}L{f(x + CHEV_T)} {f(top)}L{f(x + CHEV_W)} {f(mid)}"
            f"L{f(x + CHEV_T)} {f(bot)}L{f(x)} {f(bot)}L{f(x + CHEV_W - CHEV_T)} {f(mid)}Z")
    return "".join(out)


MARK = bar_paths() + chevron_paths()
LEFT = BARS[0][0] - BAR_W / 2
RIGHT = CHEVRONS[-1] + CHEV_W
TOP = BAR_CY - max(CHEV_H, max(h for _, h in BARS)) / 2

TILE = f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512">
<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
<stop offset="0" stop-color="#12b3a1"/><stop offset="1" stop-color="#0b3b5c"/></linearGradient></defs>
<rect width="512" height="512" fill="url(#g)"/>
<path fill="#ffffff" d="{MARK}"/>
</svg>
"""

# 24x24 with the mark scaled into a 20x20 area (2 px margin), centred
scale = 20 / (RIGHT - LEFT)
GLYPH = f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="24" height="24">
<path fill="#000" transform="translate(2 {f(12 - BAR_CY * scale)}) scale({scale:.5f}) translate({f(-LEFT)} 0)" d="{MARK}"/>
</svg>
"""

MENU_ICONS = ["search", "star", "link", "queue_music", "playlist_play",
              "more_horiz", "person_add", "person_remove", "new_releases"]
GLYPH_URL = "https://cdn.jsdelivr.net/npm/@material-design-icons/svg@0.14.13/filled/{}.svg"


def menu_tile(name):
    with urllib.request.urlopen(GLYPH_URL.format(name), timeout=30) as r:
        svg = r.read().decode()
    paths = "".join(re.findall(r"<path[^>]*/>", svg))
    background = TILE.split("<path")[0].split(">", 1)[1]
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512">'
            f'{background}<g fill="#ffffff" transform="translate(124 124) scale(11)">{paths}</g></svg>')


def render(svgs):
    """{filename.png: svg text} -> PNGs in OUT, via QuickLook"""
    tmp = tempfile.mkdtemp()
    sources = []
    for png, svg in svgs.items():
        src = os.path.join(tmp, png[:-4] + ".svg")
        with open(src, "w") as fh:
            fh.write(svg)
        sources.append(src)
    subprocess.run(["qlmanage", "-t", "-s", "512", "-o", tmp] + sources,
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for png in svgs:
        shutil.copy(os.path.join(tmp, png[:-4] + ".svg.png"), os.path.join(OUT, png))


def main():
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, NAME + ".svg"), "w") as fh:
        fh.write(GLYPH)

    svgs = {NAME + "_svg.png": TILE}
    svgs.update({f"MTL_icon_{n}.png": menu_tile(n) for n in MENU_ICONS})
    render(svgs)
    print("wrote", NAME + ".svg", ", ".join(svgs))


if __name__ == "__main__":
    main()
