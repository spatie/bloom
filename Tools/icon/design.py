#!/usr/bin/env python3
"""THE SHIPPED DRAWING. make.py builds `Resources/` from this file and from
nothing else.

It is `gen10.tongue` at a margin of 150, the design round ten settled on, with
round eleven's three decisions applied to it. Read make.py's docstring for what
the design IS and why the spur cannot be simplified away; this file is only
what changed after it.

  THE GRADE. `shine.py`'s `02-piece`, the row the owner chose. Every piece is
  graded across ITS OWN height rather than across the tile: the ground, the
  panel with its spur, each lane separately, and the bar. Lighter at the
  piece's own top by 0.14 and deeper at its own bottom by 0.11, so the average
  tone of every piece is still the palette entry it started as and the palette
  is not being changed by the back door. This is Numbers' move and Apple's
  `orientation` key is the only reason it is expressible at all.

  THE GRADE IS A KEY IN THE LAYERED DOCUMENT AND PAINT ONLY IN THE FLAT ONE.
  make.py's third rule. On macOS 26 each layer carries a two stop
  `linear-gradient` fill with an `orientation` and the system draws it; the
  artwork under it is a silhouette whose own colours are thrown away. The flat
  `.icns` says the same two stops over the same two canvas coordinates as an
  SVG gradient, because nothing on macOS 15 will do it for us. Neither output
  gets a second layer, a blur or a baked gloss: `shine.py` found that a
  duplicate silhouette carrying an alpha ramp comes back lifted and grey
  because the system lights every layer separately, and that CoreSVG drops
  `feGaussianBlur` silently.

  A GRADED GROUP BECOMES SEVERAL LAYERS. One fill key replaces a whole layer's
  colours, so a group holding two colours cannot be one layer any more: Bleed
  is now Spatie and Current, one gradient each. Splitting a group is not a
  change to the drawing and the geometry is identical either way.

  THE LANES ARE CLIPPED TO THE PLAIN SQUIRCLE. `gen10.figure` clipped them to
  the panel AFTER the spur had been unioned onto it, so at the leaving edge a
  lane that happened to lie inside the spur followed it out over the Foam and
  what crossed the white was mid teal, dark, pale bar, dark, mid teal. The left
  edge showed what was intended. They are cut at the plain panel now; the bar
  and the spur are untouched by this.

  THE SPUR IS CONCENTRIC WITH THE BAR, AND 17 UNITS PROUD RATHER THAN 26.
  `trim.py`'s `02-match`. Two things were wrong at the leaving edge. The spur
  was drawn `bar height + 52`, exactly 26 units proud on each side, but its
  band was ENDED SOMEWHERE ELSE THAN THE BAR'S: the bar runs to 1304 in the
  panel's frame and the spur ran to `outof(1200)`, which is 1485. A band's
  centre line is a cubic whose two control points are fixed, so stretching the
  end point reparametrises the curve and at any given x the longer band has not
  travelled as far down its own descent. Across the margin the spur's centre
  line therefore sat about 7 canvas units ABOVE the bar's, and a symmetric
  skirt was drawn as 22 above and 11 below. Ending it where the bar ends makes
  the two concentric again; 17 units proud then measures 11 canvas units on
  both sides, which is what the lower edge, the side nobody complained about,
  already measured.

  SOME DARK MUST STAY. Shallow #9BE9DC on Foam #E9F7F4 measures 1.26, well
  under the 1.60 two layers need, so the bar cannot be seen on the margin on
  its own and the spur is the whole reason this design is `tongue` rather than
  `flush`. 17 is a trim. Do not take it to zero.

THE SMALL ARTWORK IS NOT GRADED AND DOES NOT COME FROM HERE. Below 64 the
`.icns` draws `gen10.unframed()` instead, flat, for the reason make.py gives:
at 16 a 150 margin is two pixels of white. A grade of a tenth of a tone over
twelve pixels is not a grade, and the tone it costs at the bottom of a piece is
real, so the small artwork keeps its palette colours.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import gen10  # noqa: E402
import lib  # noqa: E402
import lib9  # noqa: E402
from gen10 import (BAND_X1, CY, END, H, HS, M, YA, YB, band_in, into, kof,  # noqa: E402
                   squircle_panel)
from lib import sh_group  # noqa: E402
from lib9 import clipped, fullbleed, sh_squircle, sheen, wrap_flat, wrap_layer, wrap_legacy  # noqa: E402

# How far the spur is proud of the bar, above and below, in the panel's own
# units, and where its band ends. The end point is the bar's own and must stay
# the bar's own: see the docstring.
SPUR_UP = 17.0
SPUR_DOWN = 17.0
SPUR_X1 = BAND_X1

# The grade, as a fraction of each colour's own value. Up at the piece's top,
# down at its bottom.
UP = 0.14
DOWN = 0.11


# ----------------------------------------------------------- colour, twice
#
# Every stop has to be sayable as an icon.json fill and as an SVG gradient, and
# both come from lib.shade, so the two outputs cannot drift by getting a number
# slightly wrong in one of them.
def tone(colour, t):
    """The palette colour nudged toward white (t > 0) or black (t < 0).

    NOT a palette change. Every gradient here is centred on the colour it
    grades, so a piece's average tone is the entry it started as.
    """
    return lib.shade(colour, t)


def key(colour, t=0.0, a=1.0):
    """One stop of an icon.json fill: `srgb:r,g,b,a`, components 0 to 1.

    The part before the colon names the space. Anything the document does not
    recognise compiles to a nil CGColor and actool dies inside CoreFoundation
    without saying why, so this encoding is not a preference.
    """
    r, g, b = lib._hex(tone(colour, t))
    return "srgb:%.4f,%.4f,%.4f,%.3f" % (r / 255.0, g / 255.0, b / 255.0, a)


def fill(colour, up, down, y0=None, y1=None, a=1.0, b=None):
    """A layer's fill key: a two stop vertical gradient, lighter at the top.

    y0 and y1 are canvas coordinates, converted here to the 0 to 1 the document
    wants. Left out, the ramp runs the whole canvas, which is the document's
    default. Given a piece's own top and bottom it is confined to that piece,
    and that is the whole of `02-piece`.
    """
    g = {"linear-gradient": [key(colour, up, a),
                             key(colour, -down, b if b is not None else a)]}
    if y0 is not None:
        g["orientation"] = {"start": {"x": 0.5, "y": y0 / 1024.0},
                            "stop": {"x": 0.5, "y": y1 / 1024.0}}
    return g


def paint(colour, up, down, y0, y1, a=1.0, b=None):
    """The same gradient as an SVG paint, for the flat `.icns`.

    userSpaceOnUse and canvas coordinates, so the same two numbers describe the
    ramp in both outputs.
    """
    fid = "vg%d" % len(lib._defs)
    lib._defs.append(
        '<linearGradient id="%s" gradientUnits="userSpaceOnUse" x1="512" y1="%.1f" '
        'x2="512" y2="%.1f"><stop offset="0" stop-color="%s" stop-opacity="%.3f"/>'
        '<stop offset="1" stop-color="%s" stop-opacity="%.3f"/></linearGradient>'
        % (fid, y0, y1, tone(colour, up), a, tone(colour, -down),
           b if b is not None else a))
    return "url(#%s)" % fid


# --------------------------------------------------------------- the shapes
def shapes(small=False, m=M):
    """`tongue` in pieces, with the spur stated rather than assumed.

    `plain` and `panel` are two different windows on purpose. `panel` is what
    is PAINTED Deep, plain plus the spur. `plain` is what the lanes are CUT to,
    and keeping them apart is the whole of the leaving edge correction.
    """
    h = HS if small else H
    barh = h * 1.04
    plain = squircle_panel(m)
    # Symmetric today, so the shift is zero. It is written out because the two
    # sides are separate numbers and an asymmetric spur has to move the band's
    # centre line rather than only its height.
    shift = (SPUR_DOWN - SPUR_UP) / 2.0
    spur = band_in(CY - 40 + shift, END + shift, barh + SPUR_UP + SPUR_DOWN, m,
                   x1=SPUR_X1)
    panel = sh_group(plain, spur)
    a = band_in(YA, END - h * 1.02, h * 0.92, m)
    b = band_in(YB + 26, END + h * 1.02, h * 0.92, m)
    c = band_in(CY - 40, END, barh, m)
    return dict(h=h, m=m, plain=plain, spur=spur, panel=panel, a=a, b=b, c=c,
                tile=sh_squircle(), bar=lib.sh_clip(c, panel))


# ------------------------------------------------------- where a piece lives
#
# A ramp confined to a piece needs that piece's top and bottom on the canvas,
# and a number typed in here by hand would go stale the first time the margin
# moved. Every band is a cubic whose control points sit at its own two end
# heights, so the curve never leaves the strip between them and the extent is
# exact rather than sampled.
def extent(y0, y1, h, m=M):
    half = h / 2.0
    return into(min(y0, y1) - half, m), into(max(y0, y1) + half, m)


def where(small=False, m=M):
    """Top and bottom, on the canvas, of every piece that carries a ramp."""
    h = HS if small else H
    lanes = (extent(YA, END - h * 1.02, h * 0.92, m),
             extent(YB + 26, END + h * 1.02, h * 0.92, m))
    return dict(
        ground=(0.0, 1024.0),
        panel=(m, 1024.0 - m),
        bar=extent(CY - 40, END, h * 1.04, m),
        # A lane is cut at the panel, so what is lit is the part inside it.
        a=(max(m, lanes[0][0]), min(1024.0 - m, lanes[0][1])),
        b=(max(m, lanes[1][0]), min(1024.0 - m, lanes[1][1])))


# ------------------------------------------------------------- the document
GROUNDKEYS = {}
BLEEDKEYS = gen10.BLEEDKEYS
PANELKEYS = gen10.PANELKEYS
MARKKEYS = gen10.MARKKEYS


def groups(small=False):
    """The four groups, back to front, each a list of layers.

    A layer is a dict the way icon.json wants one: a silhouette and a fill.
    Bleed carries two because it carries two colours.
    """
    sp, w = shapes(small), where(small)
    p = sp["plain"]
    return [
        ("Mark", [{"name": "Mark", "body": sp["bar"]("#000"),
                   "fill": fill("shallow", UP, DOWN, *w["bar"])}], MARKKEYS),
        ("Bleed", [{"name": "Current",
                    "body": clipped(sp["b"](sheen("current")), p),
                    "fill": fill("current", UP, DOWN, *w["b"])},
                   {"name": "Spatie",
                    "body": clipped(sp["a"](sheen("spatie")), p),
                    "fill": fill("spatie", UP, DOWN, *w["a"])}], BLEEDKEYS),
        ("Panel", [{"name": "Panel", "body": sp["panel"]("#000"),
                    "fill": fill("deep", UP, DOWN, *w["panel"])}], PANELKEYS),
        ("Ground", [{"name": "Ground", "body": fullbleed("#000"),
                     "fill": fill("foam", UP, DOWN, *w["ground"])}], GROUNDKEYS),
    ]


# ------------------------------------------------------------- the flat body
def body(small=False):
    """gen10.figure's own composite for `tongue`, graded, with the contact
    shadows the flat file needs and the layered one must not have.

    The order is the order it is painted in: ground, the panel seated on the
    margin, the panel, the lanes cut at the plain panel, the bar seated on each
    lane and on the panel, the bar. It is `depth.base_flat`'s composition,
    which is the one every shine row and every trim row was judged as.

    TWO THINGS gen10.figure DRAWS HERE AND THIS DOES NOT, and both are the same
    argument. `outside(side(c), p)` lays a Current thickness under the bar
    wherever the bar is on the margin without one, and
    `outside(contact(c, tile), p)` drops the bar's own shadow onto the Foam.
    Neither has a job left. The spur is what the bar lies in now, so the face
    on the margin already has a step against the ground, and the panel's own
    seat shadow already seats the spur. Drawn anyway, the side puts about 14
    canvas units of Current below the spur, which is the dark the trim was
    asked to take away, only on the other side.
    """
    sp, w = shapes(small), where(small)
    S = lib9.S
    p, plain, c = sp["panel"], sp["plain"], sp["bar"]
    lanes = (sp["a"](paint("spatie", UP, DOWN, *w["a"]))
             + sp["b"](paint("current", UP, DOWN, *w["b"])))
    return "".join([
        fullbleed(paint("foam", UP, DOWN, *w["ground"])),
        lib9.contact(p, sp["tile"], d=(0, 16 * S), blur=20 * S, alpha=0.22),
        p(paint("deep", UP, DOWN, *w["panel"])),
        clipped(lanes, plain),
        lib9.contact(c, sp["a"], d=(0, 26 * S), blur=13 * S, alpha=0.34),
        lib9.contact(c, sp["b"], d=(0, -26 * S), blur=13 * S, alpha=0.34),
        lib9.contact(c, p, d=(0, 26 * S), blur=15 * S, alpha=0.30),
        c(paint("shallow", UP, DOWN, *w["bar"])),
    ])


def render(small=False):
    """The groups, the full bleed composite, and the composite at the Big Sur
    template. Same contract and same order as gen10.render, with groups in
    place of layers.

    The two halves are built against separate def tables on purpose. Every
    wrapper embeds the whole of `lib.defs()`, so building the flat body first
    would put its gradients into every layer file as dead weight.
    """
    lib.SMALL = small
    lib.reset()
    gs = [(name, [dict(l, body=wrap_layer(l["body"])) for l in layers], keys)
          for name, layers, keys in groups(small)]
    lib.reset()
    b = body(small)
    return gs, wrap_flat(b), wrap_legacy(b)
