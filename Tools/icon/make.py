#!/usr/bin/env python3
"""Builds the app icon from the artwork in gen.py.

    python3 Tools/icon/make.py

Writes two things into Resources/, and they are not the same picture:

  AppIcon.icns        the flat bitmap, every size macOS asks for, used on any
                      system that does not draw a layered icon
  Bloom.icon/         the layered document macOS 26 draws instead, where the
                      system supplies the material, the shadow and the specular
                      and generates the dark and tinted variants itself

The design is `merge` from the eighth round of icon work: a dark tile, two lanes
arriving from the left and right, and a pale bar leaving to the right. It reads
as a B without being one, which is why it was chosen, so nothing here should
change its geometry.

Two rules worth keeping in mind before editing this file.

The 16 and 32 point bitmaps are drawn from SEPARATE ARTWORK with the lanes
opened up. At that size the three bands are a few pixels each and they close
into a texture, so the small version trades fidelity for still being three
things. `gen.merge(small=True)` is that version.

The layered document gets LESS baked depth than the flat one, not the same. The
system draws its own shadow and specular over the layers, so the contact
shadows that make the flat icon read would be drawn twice. The layers here are
the three pieces of the figure with the app's own shadows left out.
"""

import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
RESOURCES = os.path.join(ROOT, "Resources")

sys.path.insert(0, HERE)
import gen  # noqa: E402
import lib  # noqa: E402


def render(svg, size, out):
    """rsvg-convert rather than sips, because sips rasterises an SVG at one
    size and scales, which loses the small artwork's whole point."""
    path = os.path.join(HERE, ".build", "tmp.svg")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(svg)
    subprocess.run(
        ["rsvg-convert", "-w", str(size), "-h", str(size), path, "-o", out],
        check=True,
    )


def icns():
    """The flat icon. Apple asks for each size twice, once at 1x and once at
    2x, and the 2x of one size is the same pixels as the 1x of the next, so the
    set is rendered once per pixel size and linked into both names."""
    full, small = gen.merge(), gen.merge(small=True)
    iconset = os.path.join(HERE, ".build", "AppIcon.iconset")
    shutil.rmtree(iconset, ignore_errors=True)
    os.makedirs(iconset)

    # (pixels, [names]). Below 64 the opened-up artwork is used.
    plan = [
        (16, ["icon_16x16.png"]),
        (32, ["icon_16x16@2x.png", "icon_32x32.png"]),
        (64, ["icon_32x32@2x.png"]),
        (128, ["icon_128x128.png"]),
        (256, ["icon_128x128@2x.png", "icon_256x256.png"]),
        (512, ["icon_256x256@2x.png", "icon_512x512.png"]),
        (1024, ["icon_512x512@2x.png"]),
    ]
    for size, names in plan:
        art = small if size <= 32 else full
        first = os.path.join(iconset, names[0])
        render(art, size, first)
        for extra in names[1:]:
            shutil.copyfile(first, os.path.join(iconset, extra))

    out = os.path.join(RESOURCES, "AppIcon.icns")
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", out], check=True)
    return out


def layers():
    """The layered document, back to front: the tile, the two arriving lanes,
    the leaving bar.

    The pieces are taken from `gen.merge` rather than redrawn, so the two icons
    cannot drift apart. What is deliberately dropped is `contact()`: those
    shadows exist to seat one piece on another, and the system draws that for us
    here. Leaving them in would seat every piece twice.
    """
    h = 150
    a = gen.band(150, 512 - h * 0.98, h)
    b = gen.band(874, 512 + h * 0.98, h)
    c = gen.band(512, 512, h)

    pieces = {
        "ground": lib.ground(lib.flat("deep")),
        "bleed": a(lib.sheen("spatie")) + b(lib.sheen("current")),
        "mark": c(lib.sheen("shallow")),
    }

    assets = os.path.join(RESOURCES, "Bloom.icon", "Assets")
    os.makedirs(assets, exist_ok=True)
    for name, body in pieces.items():
        with open(os.path.join(assets, name + ".svg"), "w") as f:
            f.write(lib.wrap(body))
    return assets


if __name__ == "__main__":
    print("==>", icns())
    print("==>", layers())
