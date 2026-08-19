#!/usr/bin/env python3
"""Builds the app icon from the artwork in gen10.py.

    python3 Tools/icon/make.py

Writes two things into Resources/, and they are not the same picture:

  AppIcon.icns        the flat bitmap, every size macOS asks for, used on any
                      system that does not draw a layered icon
  Bloom.icon/         the layered document macOS 26 draws instead, where the
                      system supplies the material, the shadow and the specular
                      and generates the dark and tinted variants itself

The design is `tongue`, round ten's fifth direction, at a margin of 150. A near
white Foam ground fills the canvas, a Deep panel is inset within it, two lanes
arrive and a pale Shallow bar crosses. The white is a margin we draw, not a gap
where the artwork stopped short, and the bar lies across it so that the margin
reads as a surface something sits on rather than as a frame.

THE PANEL GROWS A SPUR ALONG THE BAR'S OWN PATH, AND THAT IS THE WHOLE DESIGN.
Shallow #9BE9DC against Foam #E9F7F4 measures 1.26, well under the 1.60 two
layers need, so a pale bar lying on a near white margin is very nearly
invisible. Instead of recolouring a settled mark, the panel itself runs out to
the edge along the bar, 26 units proud of it on each side, so what crosses the
white is Deep at 14.4 against Foam with the Shallow bar riding inside it. Every
other way of solving this needs a drawn side or a shadow to hold the bar up and
loses it below about 48 points. Do not simplify the spur away; without it the
crossing disappears and the margin goes back to being the border the owner
reported as a bug.

Three rules worth knowing before editing this file.

THE LAYERED ARTWORK CARRIES NO TILE OF ITS OWN, AND THE FLAT ARTWORK DOES.

On macOS 26 the 1024 canvas IS the tile: the system takes the whole canvas,
masks it and lights it. An earlier version drew its own 824 tile inside that, so
it sat at 80.5 percent of the system's, and the ring of bare material left over
was the white border the owner reported. Not a specular, not a rim: 100 units
per side of the system's own tile showing past ours.

That rule is easy to misread now that the ground is white. The margin this
design draws is NOT that ring. The Ground layer still covers the whole canvas
and then some, so the system's mask cuts Foam rather than bare material, and the
panel inside it is a shape we drew at a measured inset. The test is whether the
white ends at the squircle's own edge, which it does, and whether the spur is
cut by that edge rather than stopping short of it, which it is.

The flat `.icns` is the opposite case. The app runs on macOS 15 too, where
nothing draws a tile for us, so there the figure keeps the Big Sur template: the
same composite, margin and all, scaled to 824 inside 1024 and clipped to the old
body.

THE 16 AND 32 POINT BITMAPS COME FROM SEPARATE ARTWORK, AND HERE THEY DROP THE
FRAME ENTIRELY. At 16 points a 150 margin is two pixels of white and the panel
is twelve pixels across, inside which three bands still have to read; the figure
closes into a texture and the crossing, which is the entire reason for the
frame, is the first thing to go. So below 64 the `.icns` swaps in
`gen10.unframed()`, which is the full bleed figure with the lanes opened up, and
that is legitimate because an `.icns` already carries different geometry at
different sizes.

`icon.json` has no such mechanism. One set of artwork serves every size, so on
macOS 26 the framed drawing is what appears at 16 in Finder list view and in
Spotlight. That is a known and accepted cost of a drawn margin, not a bug: at
that size the spur reaching the tile edge is the clearest thing left.

THE LAYERED DOCUMENT GETS LESS BAKED DEPTH THAN THE FLAT ONE. The system draws
its own shadow and specular over the layers, so the contact shadows that make
the flat icon read would be drawn twice. `gen10.render()` returns the layers and
the flat body separately for exactly this reason: take what it gives you rather
than flattening one into the other.
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
import gen10  # noqa: E402

DESIGN = gen10.tongue

# Where the frame stops being affordable. Below this the `.icns` draws the
# unframed figure instead, which is round nine's `corner` with the lanes opened
# up. 32 rather than 64 because 32 still carries the panel and the crossing;
# 16 does not.
SMALL_UP_TO = 32


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
    # THE THIRD RETURN VALUE, not the second. `render` gives back the layers,
    # the full bleed composite, and the same composite drawn at the Big Sur
    # template with the figure at 824 inside 1024. The `.icns` wants the third.
    #
    # Measured on macOS 26: a full canvas opaque icns is mapped onto the system
    # tile, a classic 824-in-1024 squircle is passed straight through at the
    # same size a layered icon lands at, and anything else gets the grey jail.
    # The app runs on macOS 15 as well, where nothing draws a tile for us, so
    # the flat icon has to carry its own. Only the layered document goes full
    # bleed.
    _, _, full = gen10.render(DESIGN)
    # `unframed` returns two, not three: the full bleed composite and the
    # legacy one. The legacy one again.
    _, small = gen10.unframed(small=True)

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
        art = small if size <= SMALL_UP_TO else full
        first = os.path.join(iconset, names[0])
        render(art, size, first)
        for extra in names[1:]:
            shutil.copyfile(first, os.path.join(iconset, extra))

    out = os.path.join(RESOURCES, "AppIcon.icns")
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", out], check=True)
    return out


def layered():
    """The four pieces the system composites, back to front: the Foam ground,
    the Deep panel with its spur, the two arriving lanes clipped to it, and the
    bar. Written with the app's own contact shadows left out, because the
    system seats the layers itself.

    The Assets directory is emptied first. A layer that stops being drawn would
    otherwise stay on disk and go on being compiled into the catalogue.
    """
    layers, _, _ = gen10.render(DESIGN)
    bundle = os.path.join(RESOURCES, "Bloom.icon")
    assets = os.path.join(bundle, "Assets")
    shutil.rmtree(assets, ignore_errors=True)
    os.makedirs(assets)

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
