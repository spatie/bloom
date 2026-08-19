#!/usr/bin/env python3
"""Builds the app icon from the artwork in gen9.py.

    python3 Tools/icon/make.py

Writes two things into Resources/, and they are not the same picture:

  AppIcon.icns        the flat bitmap, every size macOS asks for, used on any
                      system that does not draw a layered icon
  Bloom.icon/         the layered document macOS 26 draws instead, where the
                      system supplies the material, the shadow and the specular
                      and generates the dark and tinted variants itself

The design is `flush`: a dark ground, two lanes arriving from the left and
right, and a pale bar leaving to the right. It reads as a B without being one,
which is why it was chosen out of nine rounds, so nothing here should change its
geometry.

Three rules worth knowing before editing this file.

THE ARTWORK CARRIES NO TILE OF ITS OWN. An earlier version drew the rounded
rectangle itself and then let the system draw its tile over it, and the sliver
of ours that showed past theirs was the white border the owner reported. The
system's tile is the only tile. That is the whole difference between `flush` and
what shipped before it.

THE 16 AND 32 POINT BITMAPS COME FROM SEPARATE ARTWORK with the lanes opened
up. At that size the three bands are a few pixels each and they close into a
texture, so the small version trades fidelity for still being three things.
`gen9.flush(small=True)` is that version.

THE LAYERED DOCUMENT GETS LESS BAKED DEPTH THAN THE FLAT ONE. The system draws
its own shadow and specular over the layers, so the contact shadows that make
the flat icon read would be drawn twice. `flush()` returns the layers and the
flat body separately for exactly this reason: take what it gives you rather than
flattening one into the other.
"""

import json
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
RESOURCES = os.path.join(ROOT, "Resources")

sys.path.insert(0, HERE)
import gen9  # noqa: E402


def render(svg, size, out):
    """rsvg-convert rather than sips, because sips rasterises an SVG once and
    scales, which loses the small artwork's whole point."""
    tmp = os.path.join(HERE, ".build", "tmp.svg")
    os.makedirs(os.path.dirname(tmp), exist_ok=True)
    with open(tmp, "w") as f:
        f.write(svg)
    subprocess.run(
        ["rsvg-convert", "-w", str(size), "-h", str(size), tmp, "-o", out],
        check=True,
    )


def icns():
    """Apple asks for each size twice, at 1x and 2x, and the 2x of one size is
    the same pixels as the 1x of the next, so each pixel size is rendered once
    and copied into both names."""
    # `gen9.render` is what turns a design into SVG documents. Calling
    # `flush()` directly returns raw bodies with no defs and no header, and it
    # also skips the reset that stops gradient ids leaking between the full and
    # the small artwork.
    _, full = gen9.render(gen9.flush)
    _, small = gen9.render(gen9.flush, small=True)

    iconset = os.path.join(HERE, ".build", "AppIcon.iconset")
    shutil.rmtree(iconset, ignore_errors=True)
    os.makedirs(iconset)

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


def layered():
    """The three pieces the system composites, back to front: the ground, the
    two arriving lanes, the leaving bar. Written with the app's own contact
    shadows left out, because the system seats the layers itself."""
    layers, _ = gen9.render(gen9.flush)
    bundle = os.path.join(RESOURCES, "Bloom.icon")
    assets = os.path.join(bundle, "Assets")
    os.makedirs(assets, exist_ok=True)

    groups = []
    for name, body, keys in layers:
        with open(os.path.join(assets, name.lower() + ".svg"), "w") as f:
            f.write(body)
        group = {"layers": [{"image-name": name.lower() + ".svg", "name": name}]}
        group.update(keys)
        groups.append(group)

    with open(os.path.join(bundle, "icon.json"), "w") as f:
        json.dump({"fill": "automatic", "groups": groups}, f, indent=1)
    return bundle


if __name__ == "__main__":
    print("==>", icns())
    print("==>", layered())
