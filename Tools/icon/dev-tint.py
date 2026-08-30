#!/usr/bin/env python3
"""Recolours a copy of the layered icon document so the dev build is unmistakable.

    python3 Tools/icon/dev-tint.py <path to a copy of Bloom.icon>/icon.json [turn]

`turn` is the fraction of the colour wheel to rotate by, and it defaults to half.
A third identity wants a different one: two builds a quarter turn apart are told
apart at a glance, two that both took the half turn are the same icon twice.

Rewrites that file in place. It is only ever pointed at the detached worktree
Tools/dev-build.sh builds from, never at Resources/Bloom.icon in the tree.

WHY THIS AND NOT A SECOND DRAWING. The icon is a layered Icon Composer document
now: `icon.json` names the artwork and the fill for each layer, and the system
supplies the material, the shadow and the specular at draw time. Every colour in
the design therefore lives in exactly one file, as a handful of "srgb:r,g,b,a"
strings inside gradients. Rotating those is a dozen lines and stays correct when
the artwork changes; drawing a second icon by hand would be a second design to
keep in step with the first, and it would be out of date by the next round.

The rotation is half a turn, so the design's teal reads as orange and its deep
navy panel reads as deep brown. That is the largest possible move on the colour
wheel, which is what a mark meant to be told apart at 32 points in the Dock
wants; anything smaller reads as the same icon in a different light. Saturation
is lifted by a third as well, because the whole point is that a glance decides,
and value is left alone so the light and dark parts of the drawing keep their
relationship and the figure still reads.

The near white ground barely moves, and that is correct: it has almost no
saturation to rotate, so the dev icon keeps the same white plate and the same
silhouette. Only what was coloured changes colour. The two icons are recognisably
the same app, which is the point, and no two of their pixels are the same hue.
"""

import colorsys
import json
import sys

# Half a turn. See the docstring: the biggest available difference, deliberately.
# Overridable, because there is more than one second identity now.
HUE_TURN = float(sys.argv[2]) if len(sys.argv) > 2 else 0.5

# Enough to carry the rotated hue at Dock size without posterising the gradients.
SATURATION_GAIN = 1.35


def tint(value: str) -> str:
    """One "srgb:r,g,b,a" string, rotated. Anything else is returned untouched."""
    if not value.startswith("srgb:"):
        return value

    parts = [float(component) for component in value[len("srgb:"):].split(",")]
    red, green, blue, alpha = parts

    hue, saturation, brightness = colorsys.rgb_to_hsv(red, green, blue)
    hue = (hue + HUE_TURN) % 1.0
    saturation = min(1.0, saturation * SATURATION_GAIN)
    red, green, blue = colorsys.hsv_to_rgb(hue, saturation, brightness)

    # The same four decimal places Icon Composer writes, so a diff between the two
    # documents is the colours and nothing else.
    return "srgb:%.4f,%.4f,%.4f,%.4f" % (red, green, blue, alpha)


def walk(node):
    if isinstance(node, dict):
        return {key: walk(value) for key, value in node.items()}
    if isinstance(node, list):
        return [walk(item) for item in node]
    if isinstance(node, str):
        return tint(node)
    return node


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
        return 2

    path = sys.argv[1]
    with open(path) as handle:
        document = json.load(handle)

    tinted = walk(document)

    # Nothing above proves a colour was found. An icon.json that had stopped
    # naming its fills the way this expects would produce a dev build wearing the
    # real icon, which is the one failure this file exists to prevent, so it is
    # an error rather than a silent no-op.
    if tinted == document:
        print("dev-tint: no srgb: fills in %s, so nothing was recoloured" % path, file=sys.stderr)
        return 1

    with open(path, "w") as handle:
        json.dump(tinted, handle, indent=1)
        handle.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
