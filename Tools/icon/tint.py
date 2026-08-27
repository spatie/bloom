#!/usr/bin/env python3
"""Recolours a copy of the layered icon document so a side build is unmistakable.

    python3 Tools/icon/tint.py <turn> <path to a copy of Bloom.icon>/icon.json

Rewrites that file in place. It is only ever pointed at the detached worktree
Tools/dev-build.sh builds from, never at Resources/Bloom.icon in the tree.

WHY THIS AND NOT A SECOND DRAWING. The icon is a layered Icon Composer document
now: `icon.json` names the artwork and the fill for each layer, and the system
supplies the material, the shadow and the specular at draw time. Every colour in
the design therefore lives in exactly one file, as a handful of "srgb:r,g,b,a"
strings inside gradients. Rotating those is a dozen lines and stays correct when
the artwork changes; drawing a second icon by hand would be a second design to
keep in step with the first, and it would be out of date by the next round.

WHY THE TURN IS AN ARGUMENT. It was the constant 0.5, because there were two
icons to tell apart and half a turn is the largest possible move on the colour
wheel, which is what a mark meant to be read at 32 points in the Dock wants;
anything smaller reads as the same icon in a different light. Then a third
identity arrived, the largest move was taken, and the choice was between copying
this file with one number changed and passing the number in. A copy would have
been two scripts agreeing about the saturation gain, the four decimal places and
the did-anything-change check by coincidence, which is how the second one starts
being subtly wrong.

WHICH TURNS, AND WHY NOT THIRDS. Three marks at a third of a turn apart is the
arrangement that puts the most colour between each pair, and it is the right
answer for three icons being designed at once. These are not: the real icon is
at 0 and cannot move, and the dev icon at 0.5 has been in the owner's Dock long
enough that moving it costs him the one thing an icon is for. So the third mark
goes as far from both as what is left allows, which is a quarter turn, equally
distant from teal at 0 and from rust at 0.5. That is 90 degrees of separation
instead of the 120 thirds would give, bought without relearning an icon in daily
use.

Forward a quarter rather than back a quarter, and that is measured rather than
preferred. Back is 0.75 and takes the design's teal to #5BBE1F, a leaf green two
steps round from where it started, which at 32 points in a Dock is the same icon
under a different lamp. Forward is 0.25 and takes it to #811FBE, a violet no part
of either existing icon is anywhere near. So: teal and navy for the real copy,
rust and orange for the dev copy, violet over aubergine for the SSH copy.

Saturation is lifted by a third whatever the turn, because the whole point is
that a glance decides, and value is left alone so the light and dark parts of the
drawing keep their relationship and the figure still reads.

The near white ground barely moves, and that is correct: it has almost no
saturation to rotate, so a tinted icon keeps the same white plate and the same
silhouette. Only what was coloured changes colour. The icons are recognisably the
same app, which is the point, and no two of them share a hue.
"""

import colorsys
import json
import sys

# Enough to carry the rotated hue at Dock size without posterising the gradients.
SATURATION_GAIN = 1.35


def tint(value: str, turn: float) -> str:
    """One "srgb:r,g,b,a" string, rotated. Anything else is returned untouched."""
    if not value.startswith("srgb:"):
        return value

    parts = [float(component) for component in value[len("srgb:"):].split(",")]
    red, green, blue, alpha = parts

    hue, saturation, brightness = colorsys.rgb_to_hsv(red, green, blue)
    hue = (hue + turn) % 1.0
    saturation = min(1.0, saturation * SATURATION_GAIN)
    red, green, blue = colorsys.hsv_to_rgb(hue, saturation, brightness)

    # The same four decimal places Icon Composer writes, so a diff between two
    # documents is the colours and nothing else.
    return "srgb:%.4f,%.4f,%.4f,%.4f" % (red, green, blue, alpha)


def walk(node, turn: float):
    if isinstance(node, dict):
        return {key: walk(value, turn) for key, value in node.items()}
    if isinstance(node, list):
        return [walk(item, turn) for item in node]
    if isinstance(node, str):
        return tint(node, turn)
    return node


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
        return 2

    try:
        turn = float(sys.argv[1])
    except ValueError:
        print("tint: %s is not a rotation" % sys.argv[1], file=sys.stderr)
        return 2

    # A turn of nothing is the real app's icon, and a build asking for it has
    # lost its identity somewhere between Tools/guard.sh and here. The failure it
    # would otherwise produce is a side build wearing the real icon, which is the
    # one this file exists to prevent, so it is refused rather than obeyed.
    if turn % 1.0 == 0.0:
        print("tint: a turn of %s leaves the icon exactly as it is" % sys.argv[1], file=sys.stderr)
        return 1

    path = sys.argv[2]
    with open(path) as handle:
        document = json.load(handle)

    tinted = walk(document, turn)

    # Nothing above proves a colour was found. An icon.json that had stopped
    # naming its fills the way this expects would produce a side build wearing
    # the real icon, which is the one failure this file exists to prevent, so it
    # is an error rather than a silent no-op.
    if tinted == document:
        print("tint: no srgb: fills in %s, so nothing was recoloured" % path, file=sys.stderr)
        return 1

    with open(path, "w") as handle:
        json.dump(tinted, handle, indent=1)
        handle.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
