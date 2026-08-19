"""The ten of round nine.

One design, one complaint, ten answers. The design is `merge`: a dark tile, two
lanes arriving from the left and the right, and a broad pale bar leaving to the
right. Its geometry and its colours are settled and nothing here argues with
them. The complaint is the pale border macOS 26 draws around it, and the wish
attached to the complaint is one thread going off the tile.

Five answers to the border and five to the thread.

  A. WITHOUT A BORDER
  01 flush    the chosen design, full bleed. The whole fix, and nothing else
  02 inset    every piece pulled in off the edge, nothing left to catch a rim
  03 stop     ground to the edge, the bar stopping short with a round cap
  04 plate    a Fathom plate on an Abyss ground: our own margin, not the system's
  05 quiet    01 with the system's specular and shadow switched off in icon.json

  B. A THREAD GOING OFF THE BORDER
  06 breach   the two lanes held inside, the bar alone running off the tile
  07 corner   the bar leaves through the lower right corner, cut on the curve
  08 lift     the bar raised on its own layer, wider than the tile, passing over
  09 pierce   the plate entered on the left and left on the right, twice broken
  10 tab      the bar breaks the plate and stops in the margin, an actual tab

Every one of them fills the 1024 canvas. None of them draws a tile of its own
except where a plate is the point, and a plate is never the outermost thing.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lib9
import lib  # noqa: E402  reached through lib9's sys.path
from lib9 import (CX, CY, S, band, capped, clipped, contact, flat, fullbleed,
                  outside, sh_circle, sh_group, sh_squircle, sheen, squircle,
                  wrap_flat, wrap_layer, wrap_legacy)

D = lib9.D

H = 150 * S            # the settled lane height, against the new tile
HS = 168 * S           # the same lane opened up for 16 and 32
YA = CY - 362 * S      # where the upper lane arrives on the left
YB = CY + 362 * S      # where the lower lane arrives on the right

PLATE = 68.0           # how far a plate sits in from the tile edge


def _bands(small):
    h = HS if small else H
    return (band(YA, CY - h * 0.98, h),
            band(YB, CY + h * 0.98, h),
            band(CY, CY, h), h)


def _plate():
    return sh_squircle(PLATE, PLATE, 1024 - 2 * PLATE, 1024 - 2 * PLATE)


# Each direction returns (layers, flat).
#
#   layers  front to back, the way icon.json wants them: a list of
#           (group name, svg body, group keys). No contact shadows: the system
#           draws those, and drawing them here would seat every piece twice.
#   flat    one composite body with the contact shadows baked in, for the
#           `.icns`, the sheets and the web.


def flush(small=False):
    """The chosen design, unchanged, filling the canvas.

    Nothing is redrawn. The only difference from what ships today is that the
    artwork no longer carries a tile of its own, so the system's tile is the
    only tile and there is nothing left over to show as a border."""
    a, b, c, h = _bands(small)
    layers = [
        ("Mark", c(sheen("shallow")), MARKKEYS),
        ("Bleed", a(sheen("spatie")) + b(sheen("current")), BLEEDKEYS),
        ("Ground", fullbleed(flat("deep")), {}),
    ]
    body = "".join([
        fullbleed(flat("deep")), a(sheen("spatie")), b(sheen("current")),
        contact(c, a, d=(0, 26 * S), blur=13 * S, alpha=0.34),
        contact(c, b, d=(0, -26 * S), blur=13 * S, alpha=0.34),
        c(sheen("shallow")),
    ])
    return layers, body


def inset(small=False):
    """Every moving piece pulled in off the edge.

    If the border is a rim caught along the edge of a layer, this is the
    version that cannot have one: no piece of the figure is within 70 units of
    the tile, so the only thing meeting the boundary is flat ground."""
    m = 70.0
    h = HS if small else H
    a = capped(YA, CY - h * 0.98, h, m, 1024 - m)
    b = capped(YB, CY + h * 0.98, h, m, 1024 - m)
    c = capped(CY, CY, h, m, 1024 - m)
    layers = [
        ("Mark", c(sheen("shallow")), MARKKEYS),
        ("Bleed", a(sheen("spatie")) + b(sheen("current")), BLEEDKEYS),
        ("Ground", fullbleed(flat("deep")), {}),
    ]
    body = "".join([
        fullbleed(flat("deep")), a(sheen("spatie")), b(sheen("current")),
        contact(c, a, d=(0, 26 * S), blur=13 * S, alpha=0.34),
        contact(c, b, d=(0, -26 * S), blur=13 * S, alpha=0.34),
        c(sheen("shallow")),
    ])
    return layers, body


def stop(small=False):
    """Ground to the edge, lanes to the edge, the bar stopping short.

    The half of his sentence that says a ground can reach the boundary as long
    as the moving pieces do not. The bar still arrives from off the left, it
    just ends inside the tile, and ending is a different statement from being
    cut: this is the one direction where the merge finishes."""
    a, b, _, h = _bands(small)
    c = capped(CY, CY, h, -280, 1024 - 96)
    layers = [
        ("Mark", c(sheen("shallow")), MARKKEYS),
        ("Bleed", a(sheen("spatie")) + b(sheen("current")), BLEEDKEYS),
        ("Ground", fullbleed(flat("deep")), {}),
    ]
    body = "".join([
        fullbleed(flat("deep")), a(sheen("spatie")), b(sheen("current")),
        contact(c, a, d=(0, 26 * S), blur=13 * S, alpha=0.34),
        contact(c, b, d=(0, -26 * S), blur=13 * S, alpha=0.34),
        c(sheen("shallow")),
    ])
    return layers, body


def plate(small=False):
    """A Fathom plate on an Abyss ground, with the figure on the plate.

    He does not want the system's border. This gives him a border of his own
    instead: same width, our colour, and a piece of the drawing rather than a
    leftover. The plate carries the system's shadow so the margin reads as
    depth. It is the only direction here that keeps a frame on purpose."""
    a, b, c, h = _bands(small)
    p = _plate()
    fig = a(sheen("spatie")) + b(sheen("current"))
    layers = [
        ("Mark", clipped(c(sheen("shallow")), p), MARKKEYS),
        ("Bleed", clipped(fig, p), BLEEDKEYS),
        ("Plate", p(flat("fathom")), PLATEKEYS),
        ("Ground", fullbleed(flat("deep")), {}),
    ]
    body = "".join([
        fullbleed(flat("deep")),
        contact(p, sh_squircle(), d=(0, 22 * S), blur=18 * S, alpha=0.45),
        p(flat("fathom")),
        clipped("".join([
            a(sheen("spatie")), b(sheen("current")),
            contact(c, a, d=(0, 26 * S), blur=13 * S, alpha=0.34),
            contact(c, b, d=(0, -26 * S), blur=13 * S, alpha=0.34),
            c(sheen("shallow")),
        ]), p),
    ])
    return layers, body


def quiet(small=False):
    """01 with the system's specular and shadow switched off.

    The same pixels as 01. The only difference is in icon.json, where the Mark
    group asks for no specular and no shadow, so nothing the system adds can
    trace an edge. It is in the set because it is the one variation that tests
    the manifest rather than the artwork, and if the border had been a specular
    this is the one that would have fixed it."""
    layers, body = flush(small)
    layers = [(n, b, {} if n == "Ground" else QUIETKEYS) for n, b, _ in layers]
    return layers, body


# ------------------------------------------------ B. a thread off the border
def breach(small=False):
    """The two lanes held inside the tile, the bar alone running off it.

    The wish, without drawing a frame to break. The lanes stop and cap 120 in
    from the edge, so they are unmistakably contained, and the pale bar is then
    the only piece that reaches the boundary at all. One thread leaves and the
    rest of the figure stays: that is the whole reading, and it costs nothing
    because there is no margin of bare ground anywhere for the system to light.
    """
    a, b, c, h = _bands(small)
    m = 120.0
    a = capped(YA, CY - h * 0.98, h, m, 1024 - m)
    b = capped(YB, CY + h * 0.98, h, m, 1024 - m)
    layers = [
        ("Mark", c(sheen("shallow")), MARKKEYS),
        ("Bleed", a(sheen("spatie")) + b(sheen("current")), BLEEDKEYS),
        ("Ground", fullbleed(flat("deep")), {}),
    ]
    body = "".join([
        fullbleed(flat("deep")), a(sheen("spatie")), b(sheen("current")),
        contact(c, a, d=(0, 26 * S), blur=13 * S, alpha=0.34),
        contact(c, b, d=(0, -26 * S), blur=13 * S, alpha=0.34),
        c(sheen("shallow")),
    ])
    return layers, body


def corner(small=False):
    """The bar leaves through the lower right corner.

    A shape cut by a straight edge looks cut. A shape cut by a curve looks like
    it went round something. The bar is tipped so it exits where the tile is
    turning, and the mask takes it on the diagonal."""
    h = HS if small else H
    end = CY + 196
    c = band(CY - 40, end, h * 1.04)
    a = band(YA, end - h * 1.02, h * 0.92)
    b = band(YB + 26, end + h * 1.02, h * 0.92)
    layers = [
        ("Mark", c(sheen("shallow")), MARKKEYS),
        ("Bleed", a(sheen("spatie")) + b(sheen("current")), BLEEDKEYS),
        ("Ground", fullbleed(flat("deep")), {}),
    ]
    body = "".join([
        fullbleed(flat("deep")), a(sheen("spatie")), b(sheen("current")),
        contact(c, a, d=(0, 26 * S), blur=13 * S, alpha=0.34),
        contact(c, b, d=(0, -26 * S), blur=13 * S, alpha=0.34),
        c(sheen("shallow")),
    ])
    return layers, body


def lift(small=False):
    """The bar raised off the tile, wider than the tile, passing over it.

    Nothing is cropped to a plate here and no margin is drawn. The bar is on
    its own group with the system's shadow under it, a fifth again as thick as
    the lanes, and it is the only piece that touches the edge. It does not
    break the silhouette. It reads as having been laid across it."""
    h = (HS if small else H) * 1.24
    a, b, _, _ = _bands(small)
    c = band(CY - 26, CY - 26, h)
    layers = [
        ("Mark", c(sheen("foam")), LIFTKEYS),
        ("Bleed", a(sheen("spatie")) + b(sheen("current")), BLEEDKEYS),
        ("Ground", fullbleed(flat("deep")), {}),
    ]
    body = "".join([
        fullbleed(flat("deep")), a(sheen("spatie")), b(sheen("current")),
        contact(c, a, d=(0, 34 * S), blur=20 * S, alpha=0.40),
        contact(c, b, d=(0, -34 * S), blur=20 * S, alpha=0.40),
        contact(c, sh_squircle(), d=(0, 34 * S), blur=20 * S, alpha=0.34),
        c(sheen("foam")),
    ])
    return layers, body


def pierce(small=False):
    """The plate entered on the left and left on the right.

    06 breaks the plate once. This breaks it twice, so the bar is unambiguously
    one continuous thread that the plate happens to be sitting under rather
    than a shape that starts at the plate's edge. The upper lane comes in over
    the margin too, which is what stops the pair reading as a plus sign."""
    a, b, c, h = _bands(small)
    p = _plate()
    layers = [
        ("Mark", c(sheen("shallow")), MARKKEYS),
        ("Bleed", clipped(b(sheen("current")), p) + a(sheen("spatie")), BLEEDKEYS),
        ("Plate", p(flat("fathom")), PLATEKEYS),
        ("Ground", fullbleed(flat("deep")), {}),
    ]
    body = "".join([
        fullbleed(flat("deep")),
        contact(p, sh_squircle(), d=(0, 22 * S), blur=18 * S, alpha=0.45),
        p(flat("fathom")),
        clipped(b(sheen("current")), p),
        a(sheen("spatie")),
        contact(a, p, d=(0, 22 * S), blur=15 * S, alpha=0.26),
        contact(c, a, d=(0, 26 * S), blur=13 * S, alpha=0.34),
        contact(c, b, d=(0, -26 * S), blur=13 * S, alpha=0.34),
        contact(c, p, d=(0, 26 * S), blur=15 * S, alpha=0.30),
        c(sheen("shallow")),
    ])
    return layers, body


def tab(small=False):
    """The bar breaks the plate and stops in the margin.

    The most literal reading of what he asked for. The thread leaves the tile
    the drawing establishes, gets clear of it, and ends in the open with a
    round cap, so there is a piece of the figure standing outside the body with
    air on three sides of it. The system still cuts anything past the real
    edge, so the cap is placed to land inside it."""
    a, b, _, h = _bands(small)
    c = capped(CY, CY, h, -280, 1024 - 26)
    p = _plate()
    layers = [
        ("Mark", c(sheen("shallow")), MARKKEYS),
        ("Bleed", clipped(a(sheen("spatie")) + b(sheen("current")), p), BLEEDKEYS),
        ("Plate", p(flat("fathom")), PLATEKEYS),
        ("Ground", fullbleed(flat("deep")), {}),
    ]
    body = "".join([
        fullbleed(flat("deep")),
        contact(p, sh_squircle(), d=(0, 22 * S), blur=18 * S, alpha=0.45),
        p(flat("fathom")),
        clipped("".join([
            a(sheen("spatie")), b(sheen("current")),
            contact(c, a, d=(0, 26 * S), blur=13 * S, alpha=0.34),
            contact(c, b, d=(0, -26 * S), blur=13 * S, alpha=0.34),
        ]), p),
        contact(c, p, d=(0, 26 * S), blur=15 * S, alpha=0.30),
        outside(contact(c, sh_squircle(), d=(0, 26 * S), blur=16 * S, alpha=0.34), p),
        c(sheen("shallow")),
    ])
    return layers, body


# ------------------------------------------------------------- icon.json keys
#
# What the keys do, measured on this machine rather than assumed.
#
#   specular      the system's own edge light. It traces the upper edge of a
#                 layer's silhouette. It is real and it is visible, but it is
#                 not the border: the border survives specular being off.
#   shadow        the system's shadow under a group, so the app does not have
#                 to bake one. kind is "neutral". This is why the layered
#                 assets drop contact().
#   translucency  lets the material behind show through a layer. Off for every
#                 layer here, because the design is opaque paper.
#   fill          the document's background where no layer covers it. Left
#                 "automatic", which on macOS 26 is a pale material. Every
#                 direction below covers the whole canvas so it never shows.
MARKKEYS = {"shadow": {"kind": "neutral", "opacity": 0.5}, "specular": True,
            "translucency": {"enabled": False, "value": 0.5}}
BLEEDKEYS = {"translucency": {"enabled": False, "value": 0.5}}
PLATEKEYS = {"shadow": {"kind": "neutral", "opacity": 0.6},
             "translucency": {"enabled": False, "value": 0.5}}
LIFTKEYS = {"shadow": {"kind": "neutral", "opacity": 0.75}, "specular": True,
            "translucency": {"enabled": False, "value": 0.5}}
QUIETKEYS = {"specular": False,
             "translucency": {"enabled": False, "value": 0.5}}


ICONS = [
    ("01-flush", flush), ("02-inset", inset), ("03-stop", stop),
    ("04-plate", plate), ("05-quiet", quiet),
    ("06-breach", breach), ("07-corner", corner), ("08-lift", lift),
    ("09-pierce", pierce), ("10-tab", tab),
]

GROUP = {"01-flush": "A", "02-inset": "A", "03-stop": "A", "04-plate": "A",
         "05-quiet": "A", "06-breach": "B", "07-corner": "B", "08-lift": "B",
         "09-pierce": "B", "10-tab": "B"}

BLURB = {
    "01-flush": "the chosen design, full bleed. the whole fix",
    "02-inset": "every piece off the edge, nothing to catch a rim",
    "03-stop": "ground to the edge, the bar stopping short",
    "04-plate": "our own margin instead of the system's",
    "05-quiet": "specular and shadow off in icon.json",
    "06-breach": "the lanes held in, the bar alone leaving",
    "07-corner": "cut on the curve of the lower right corner",
    "08-lift": "raised, wider than the tile, laid across it",
    "09-pierce": "the plate broken on both sides by one thread",
    "10-tab": "the thread leaves the body, ends in the open",
}


def render(fn, small=False):
    """One direction, both ways round.

    Returns three things.

      layers  the layered document's groups, front to back, each already a
              whole SVG and none of them masked
      flat    the composite filling the canvas, clipped to the system's shape.
              For the sheets, for the web, and for anything on macOS 26
      legacy  the same composite at the Big Sur template, 824 inside 1024, for
              the `.icns` that macOS 15 will draw as it is

    lib keeps its gradients and clip paths in a module level list, so the list
    is reset once, the direction is drawn once, and every file written out
    carries the same set of defs. Unused defs in a layer cost bytes and nothing
    else.
    """
    lib.SMALL = small
    lib.reset()
    layers, body = fn(small)
    out = [(name, wrap_layer(b), keys) for name, b, keys in layers]
    return out, wrap_flat(body), wrap_legacy(body)
