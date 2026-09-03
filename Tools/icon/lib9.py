"""Geometry and drawing for round nine.

Round nine changes one thing about the world the icon is drawn into, and it is
the reason this round exists.

THE TILE IS NOW THE WHOLE CANVAS.

Rounds one to eight drew the measured Big Sur template: a 1024 canvas with an
824 body inset by 100 and a corner radius of 185.4. That template is dead on
macOS 26. The system now takes the whole 1024 and masks it to its own shape,
and it does that to a layered `.icon` document and to a flat `.icns` alike.
Artwork that draws its own 824 tile is therefore drawn at 80.5% inside the
system's tile, and what shows in the 100 units left over on every side is the
system's own pale material. That pale ring is the border Freek is looking at.

So every piece of artwork in this round fills the 1024 canvas edge to edge and
lets the system cut it. `SYSTILE` below is the system's shape, traced out of a
real render rather than guessed, and it is used only to PREVIEW a flat SVG. It
is never drawn into a layered asset.

Everything else from round seven holds and is imported from the app's own
generator so the two cannot drift apart: the palette, the sheen, thickness,
contact shadows, the tonal steps. Depth is never lighting. Blur appears only
inside contact(), on black, at low alpha, inside a clip.
"""
import json
import math
import os
import sys

# lib.py is the app's own drawing library and is VENDORED beside this file, so
# a round of icon work cannot be broken by somebody editing the app while it is
# in progress and so this folder still builds after the app has moved on.
#
# There was a second entry on this path, pointing at the same folder inside a
# checkout called Baton, which is what this app was called before it was
# renamed. It was a fallback for a copy that has not existed under that name for
# a long time, on one person's machine, and it would have shipped an absolute
# path to somebody else's home directory into a public repository.
HERE_FIRST = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE_FIRST)
import lib  # noqa: E402
from lib import (C, contact, flat, sh_circle, sh_group, sh_move, sh_path,  # noqa: F401
                 sh_poly, sh_rect, shade, sheen, step, thick)  # noqa: F401

HERE = HERE_FIRST

CANVAS = 1024
CX = CY = 512.0

# The Big Sur body was 824 wide inside a 1024 canvas. The system's body is now
# 1024 wide inside a 1024 canvas, so every measurement from the chosen design
# is multiplied by this to keep the composition identical relative to the tile.
S = 1024.0 / 824.0

HEAD = ('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" '
        'viewBox="0 0 1024 1024">')


# ------------------------------------------------------------- system shape
def _quadrant():
    with open(os.path.join(HERE, "systile-quadrant.json")) as f:
        return [(x, y) for x, y in json.load(f)]


def squircle(x, y, w, h):
    """The system's icon shape, scaled into the box (x, y, w, h).

    The point list is the upper left quadrant of a real macOS 26 render of a
    single solid layer, found by marching a ray out from the centre to the
    alpha half crossing at 49 angles. The other three quadrants are mirrors of
    it. This is measured, not modelled: no superellipse exponent is assumed.
    """
    q = _quadrant()                                    # (0,512) round to (512,0)
    n = float(CANVAS)
    tl = q
    tr = [(n - px, py) for px, py in reversed(q)]      # (512,0) round to (1024,512)
    br = [(n - px, n - py) for px, py in q]            # (1024,512) round to (512,1024)
    bl = [(px, n - py) for px, py in reversed(q)]      # (512,1024) round to (0,512)
    pts, last = [], None
    for px, py in tl + tr + br + bl:
        p = (x + px * w / n, y + py * h / n)
        if last is None or abs(p[0] - last[0]) > 1e-6 or abs(p[1] - last[1]) > 1e-6:
            pts.append(p)
            last = p
    return "M%.2f,%.2f" % pts[0] + "".join("L%.2f,%.2f" % p for p in pts[1:]) + "Z"


SYSTILE = squircle(0, 0, CANVAS, CANVAS)


def sh_squircle(x=0, y=0, w=CANVAS, h=CANVAS):
    return sh_path(squircle(x, y, w, h))


# ------------------------------------------------------------------- output
def wrap_flat(body):
    """A flat SVG for the contact sheets and for the `.icns`.

    Clipped to the system's shape, because on macOS 26 that is what will
    happen to it anyway and a preview that does not show the cut is lying.
    """
    return (HEAD + "<defs>" + lib.defs()
            + '<clipPath id="t"><path d="%s"/></clipPath>' % SYSTILE
            + "</defs>" + '<g clip-path="url(#t)">' + body + "</g></svg>")


def wrap_layer(body):
    """One layer of a layered document. NOT clipped and NOT given a tile: the
    system owns the shape. Anything drawn past the edge is cut by the system,
    which is the only reason a piece can meet the edge cleanly."""
    return HEAD + "<defs>" + lib.defs() + "</defs>" + body + "</svg>"


# The Big Sur template. NOTHING BLOOM SHIPS IS DRAWN TO IT ANY MORE. macOS 26
# masks a layered icon and a flat .icns alike, but macOS 15 did not: there the
# .icns was drawn as it is, and it had to carry the old 824 body inside a 1024
# canvas or it landed in the dock a fifth too big. Bloom's floor is macOS 26 and
# it ships no .icns, so `design.py` stopped calling this.
#
# It stays because gen9, gen10, depth and shine still draw contact sheets that
# put the old template beside the new one, and those sheets are the record of
# how the current design was chosen. Do not wire it back into design.py.
LEGACY_INSET = 100.0
LEGACY_BODY = 824.0
LEGACY_TILE = lib.TILE


def wrap_legacy(body):
    """The flat fallback for anything that does not draw a layered icon.

    The whole composition is scaled down about the centre by 824/1024 and
    clipped to the Big Sur tile, so what fills the canvas in the layered
    document fills the old body here and the two are the same picture at two
    scales rather than two drawings.
    """
    k = LEGACY_BODY / CANVAS
    return (HEAD + "<defs>" + lib.defs()
            + '<clipPath id="l"><path d="%s"/></clipPath>' % LEGACY_TILE
            + "</defs>"
            + '<g clip-path="url(#l)">'
            + '<g transform="translate(%.4f %.4f) scale(%.6f)">' % (CX * (1 - k),
                                                                   CY * (1 - k), k)
            + body + "</g></g></svg>")


def wrap(body):
    """Deliberately not a function. There are two wraps in this round and they
    are not interchangeable: a layered asset must NOT be masked, because the
    system masks it and Apple's guidance says a pre-masked layer damages the
    specular, and a flat file must be. Ask for the one you mean, or use
    gen9.render, which hands back both already wrapped."""
    raise TypeError(
        "lib9 has no single wrap. Use wrap_layer(body) for a layered asset, "
        "wrap_flat(body) for a full canvas flat file, wrap_legacy(body) for "
        "the pre macOS 26 .icns, or gen9.render(fn, small) for all of them.")


def fullbleed(colour):
    """A ground that covers the canvas and then some, so no rounding error can
    leave a hairline of system material along an edge."""
    return ('<rect x="-64" y="-64" width="1152" height="1152" fill="%s"/>'
            % colour)


# ------------------------------------------------------------------- shapes
def band(y0, y1, h, x0=-280.0, x1=1304.0):
    """A lane of height h crossing the whole canvas, entering at y0 on the left
    and leaving at y1 on the right, easing between the two.

    This is round seven's `band` with every x multiplied by S about the centre,
    so the curve is the same curve, only now measured against a tile that is
    the whole canvas.
    """
    c0, c1 = CX + (300 - 512) * S, CX + (560 - 512) * S
    return sh_path(
        "M%.1f,%.1f C%.1f,%.1f %.1f,%.1f %.1f,%.1f L%.1f,%.1f C%.1f,%.1f "
        "%.1f,%.1f %.1f,%.1f Z"
        % (x0, y0 - h / 2, c0, y0 - h / 2, c1, y1 - h / 2, x1, y1 - h / 2,
           x1, y1 + h / 2, c1, y1 + h / 2, c0, y0 + h / 2, x0, y0 + h / 2))


def capped(y0, y1, h, x0, x1):
    """The same lane, ending inside the tile with a round cap rather than
    running off it.

    The lane itself is never reshaped: the full band is drawn and then shown
    only between x0 and x1, and a disc of radius h/2 is set at each end on the
    lane's own centre line. So a capped lane and an uncapped one are the same
    curve, which is the whole reason the ends can be moved without the design
    changing underneath them.
    """
    def make(f):
        cid = "p%d" % len(lib._defs)
        lib._defs.append('<clipPath id="%s"><rect x="%.1f" y="-500" width="%.1f" '
                         'height="2024"/></clipPath>' % (cid, x0 + h / 2, x1 - x0 - h))
        return ('<g clip-path="url(#%s)">%s</g>' % (cid, band(y0, y1, h)(f))
                + sh_circle(x0 + h / 2, yat(y0, y1, x0 + h / 2), h / 2)(f)
                + sh_circle(x1 - h / 2, yat(y0, y1, x1 - h / 2), h / 2)(f))
    return make


def _bez(p, t):
    u = 1 - t
    return (u * u * u * p[0] + 3 * u * u * t * p[1]
            + 3 * u * t * t * p[2] + t * t * t * p[3])


def yat(y0, y1, x, x0=-280.0, x1=1304.0):
    """Where the centre line of band(y0, y1) is at x, by inverting the cubic
    rather than approximating it, so a cap lands on the lane and not near it."""
    xs = (x0, CX + (300 - 512) * S, CX + (560 - 512) * S, x1)
    ys = (y0, y0, y1, y1)
    lo, hi = 0.0, 1.0
    for _ in range(40):
        mid = (lo + hi) / 2
        if _bez(xs, mid) < x:
            lo = mid
        else:
            hi = mid
    return _bez(ys, (lo + hi) / 2)


def clipped(body, window):
    """A finished piece of drawing showing only inside window."""
    cid = "w%d" % len(lib._defs)
    lib._defs.append('<clipPath id="%s">%s</clipPath>' % (cid, window("#000")))
    return '<g clip-path="url(#%s)">%s</g>' % (cid, body)


def outside(body, window):
    """A finished piece of drawing showing only OUTSIDE window. The only way to
    say `this thread has left the plate` in one shape."""
    mid = "o%d" % len(lib._defs)
    lib._defs.append('<mask id="%s"><rect x="-200" y="-200" width="1424" '
                     'height="1424" fill="#fff"/>%s</mask>'
                     % (mid, window("#000")))
    return '<g mask="url(#%s)">%s</g>' % (mid, body)
