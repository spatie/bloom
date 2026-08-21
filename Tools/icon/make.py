#!/usr/bin/env python3
"""Builds the app icon from the artwork in design.py.

    python3 Tools/icon/make.py

Writes two things into Resources/:

  Bloom.icon/         the layered document macOS 26 draws, where the system
                      supplies the material, the shadow and the specular and
                      generates the dark and tinted variants itself
  BloomMenuBar.pdf    the menu bar mark, drawn by menubar.py from the same lane
                      this icon is built from. Fifteen points is too small for
                      the above, so it is a reduction rather than a scaling, and
                      menubar.py's docstring says what it keeps and what it
                      gives up. It is built here so that one command leaves
                      nothing in the tree older than the design

THERE IS NO FLAT `.icns` ANY MORE, AND PUTTING ONE BACK WOULD CHANGE NOTHING.
This file used to write `Resources/AppIcon.icns` as well, on the Big Sur
template, because the app ran on macOS 15 where nothing draws a tile for us. At
a floor of macOS 26 the system finds `Bloom.icon` through CFBundleIconName and
`Assets.car`, and the flat bitmap is never asked for. Measured before it was
deleted, on three copies of the bundle: one carrying both, one carrying only the
layered document, one carrying only the `.icns`. Through
`NSWorkspace.icon(forFile:)`, which is Finder's answer, and through
`NSRunningApplication.icon`, which is what the Dock tile and the Cmd-Tab
switcher draw, the first two agree to within three of 255 on one channel at 16
and 32 points and are identical from 64 up. The third differs on 43 to 55
percent of its pixels at every size. The flat artwork was not being drawn.

The design is `tongue`, round ten's fifth direction, at a margin of 150. A near
white Foam ground fills the canvas, a Deep panel is inset within it, two lanes
arrive and a pale Shallow bar crosses. The white is a margin we draw, not a gap
where the artwork stopped short, and the bar lies across it so that the margin
reads as a surface something sits on rather than as a frame.

THE DRAWING IS design.py's, NOT gen10.tongue. gen10 holds round ten's ten
directions and `tongue` is the one that was chosen, but three things have been
decided about it since: every piece is graded across its own height, the lanes
are cut at the plain panel rather than at the panel plus its spur, and the spur
is concentric with the bar and 17 units proud of it rather than 26. design.py's
docstring says why each. Read this file for what the outputs are and that one
for what is in them.

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

THE ARTWORK CARRIES NO TILE OF ITS OWN.

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

ONE SET OF ARTWORK SERVES EVERY SIZE, AND THE SMALL ONES PAY FOR IT. At 16
points a 150 margin is two pixels of white and the panel is twelve pixels
across, inside which three bands still have to read; the figure closes into a
texture and the crossing, which is the entire reason for the frame, is the
first thing to go. `icon.json` has no mechanism for saying something else at a
small size, so the framed drawing is what appears at 16 in Finder list view and
in Spotlight. That is a known and accepted cost of a drawn margin, not a bug: at
that size the spur reaching the tile edge is the clearest thing left.

An `.icns` did have that mechanism, and while there was one it swapped in
`gen10.unframed()` below 64, the full bleed figure with the lanes opened up.
That swap was never what macOS 26 drew, so removing the `.icns` did not remove
it from anything a user sees. `site.py` still draws the website's favicon from
the same unframed artwork, for the same reason and at the same sizes.

THE LAYERED DOCUMENT GETS LESS BAKED DEPTH THAN A FLAT COMPOSITE. The system
draws its own shadow and specular over the layers, so the contact shadows that
make a flat drawing read would be drawn twice. `design.render()` returns the
layers and the flat body separately for exactly this reason: take what it gives
you rather than flattening one into the other. The flat body is not dead with
the `.icns` gone; it is what the contact sheets and `site.py` draw.
"""

import json
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
RESOURCES = os.path.join(ROOT, "Resources")

sys.path.insert(0, HERE)
import design  # noqa: E402
import menubar  # noqa: E402

def layered():
    """The four groups the system composites, back to front: the Foam ground,
    the Deep panel with its spur, the two arriving lanes cut at the plain
    panel, and the bar. Written with the app's own contact shadows left out,
    because the system seats the layers itself.

    A GROUP IS NOT A LAYER. Bleed holds two, one per lane, because each carries
    its own gradient and one fill key cannot say Spatie and Current at once.
    Anything that walks this list has to walk the layers inside a group rather
    than assume one each.

    The Assets directory is emptied first. A layer that stops being drawn would
    otherwise stay on disk and go on being compiled into the catalogue.
    """
    built, _ = design.render()
    bundle = os.path.join(RESOURCES, "Bloom.icon")
    assets = os.path.join(bundle, "Assets")
    shutil.rmtree(assets, ignore_errors=True)
    os.makedirs(assets)

    groups = []
    for _, layers, keys in built:
        group = {"layers": []}
        for layer in layers:
            asset = layer["name"].lower() + ".svg"
            with open(os.path.join(assets, asset), "w") as f:
                f.write(layer["body"])
            item = {"image-name": asset, "name": layer["name"]}
            # A layer's fill REPLACES the artwork's own colours, so the SVG
            # under it is a silhouette. Anything the document cannot parse
            # compiles to a nil CGColor and actool dies inside CoreFoundation
            # without saying which layer it was.
            for k in ("fill", "opacity", "blend-mode", "specular"):
                if k in layer:
                    item[k] = layer[k]
            group["layers"].append(item)
        group.update(keys)
        groups.append(group)

    with open(os.path.join(bundle, "icon.json"), "w") as f:
        json.dump({"fill": "automatic", "groups": groups}, f, indent=1)
    return bundle


if __name__ == "__main__":
    print("==>", layered())
    print("==>", menubar.asset())
