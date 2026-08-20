#!/usr/bin/env python3
"""Ten depth studies on the shipped icon, `gen10.tongue` at margin 150.

    python3 Tools/icon/depth.py [outdir]

Nothing here ships. The design is not changed: same Foam ground, same Deep
panel with its spur, same two lanes, same pale Shallow bar. What changes is
where the depth comes from, which is the one question this file is asking.

READ make.py's DOCSTRING FIRST. Its three rules bound everything below.

Rule three is the crux. On macOS 26 the system draws its own shadow and its own
specular over the layered document's groups, so any depth baked into the
artwork is drawn twice and reads muddy rather than deep. The flat `.icns` has
the opposite problem: nothing is drawn for it at all, so everything it has to
say about depth has to be in the paint. Each variation below therefore declares
where its depth LIVES, and the two outputs are built from that declaration
rather than from one drawing flattened two ways:

  system   the artwork stays flat and the depth is expressed as separation
           between layer groups, tuned through the icon.json shadow keys. Only
           the layered document can do this
  baked    the depth is painted into the artwork. The `.icns` needs this; the
           layered document gets a reduced dose of the same paint so the
           system's own pass has something left to add
  split    the two outputs want genuinely different drawings

Rule one still holds: the layered assets carry no tile, the flat one carries
the Big Sur body at 824 inside 1024. Rule two is not exercised here, because
the point of the sheet is to watch the framed artwork lose its depth as it gets
small, and swapping in the unframed small artwork below 64 would hide exactly
that. The sheet says so on the page.

`sheet()` writes a self contained HTML page: each variation at 1024, then at
512, 256, 128, 64, 32 and 16 actual size, on a light ground and a dark one,
with the layered document and the flat `.icns` side by side for every one.
"""

import base64
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import gen10  # noqa: E402
import lib  # noqa: E402
import lib9  # noqa: E402
from gen10 import M, END, H, HS, YA, YB, band_in, outof, squircle_panel  # noqa: E402
from lib import sh_group, sh_move, sh_rect, shade, sheen, flat  # noqa: E402
from lib9 import (CX, CY, S, clipped, contact, fullbleed, outside,  # noqa: E402
                  sh_squircle, wrap_flat, wrap_layer, wrap_legacy)


# --------------------------------------------------------------- new paint
#
# Everything in lib.py is a flat piece of paper, a thickness or a contact
# shadow, and that is deliberate: round five was thrown away for lighting.
# These four helpers are the smallest additions that let a variation say
# `glow`, `inner shadow`, `travelling` and `translucent` at all. They are here
# and not in lib.py because none of them has earned a place in the app's own
# drawing language yet.
def inner(shape, d, blur, alpha, colour="#000000"):
    """An inner shadow, or an inner light when the colour is white.

    The shape's own complement, blurred and nudged, showing only INSIDE the
    shape. Where contact() says `this piece is lying on that one`, this says
    `this piece is a hole in that one` or, pointed the other way, `this edge
    is the crown of something round`.

    MIND THE SIGN. The complement is what moves, so a POSITIVE offset lands the
    band along the TOP and LEFT inner edges and a negative one along the bottom
    and right. The set lights from the upper left, so a positive offset in
    white is a crown and a positive offset in black is a recess. Getting this
    backwards lights the piece from below and looks subtly wrong rather than
    obviously wrong, which is worse."""
    if lib.SMALL:
        return ""
    dx, dy = d
    cid = "ic%d" % len(lib._defs)
    mid = "im%d" % len(lib._defs)
    lib._defs.append('<clipPath id="%s">%s</clipPath>' % (cid, shape("#000")))
    lib._defs.append('<mask id="%s"><rect x="-400" y="-400" width="1824" '
                     'height="1824" fill="#fff"/>%s</mask>'
                     % (mid, shape("#000")))
    fid = lib._blurfilter(blur)
    return ('<g clip-path="url(#%s)"><g opacity="%.2f" filter="url(#%s)" '
            'transform="translate(%.1f %.1f)"><g mask="url(#%s)">'
            '<rect x="-400" y="-400" width="1824" height="1824" fill="%s"/>'
            '</g></g></g>' % (cid, alpha, fid, dx, dy, mid, colour))


def haze(shape, colour, blur, alpha, window=None):
    """A glow: the shape's own silhouette in a light colour, blurred wide, at
    low alpha, laid UNDER the piece it belongs to so only the spill shows.

    This is the one thing round seven forbade outright, and it is forbidden for
    a good reason: a glow that is not attached to a piece is atmosphere. Every
    call here is attached, and most are clipped to the panel so the spill
    cannot wander onto the margin."""
    if lib.SMALL:
        return ""
    fid = lib._blurfilter(blur)
    body = ('<g opacity="%.2f" filter="url(#%s)">%s</g>'
            % (alpha, fid, shape(lib.C.get(colour, colour))))
    return clipped(body, window) if window else body


def axial(colour, x0, y0, x1, y1, t0, t1):
    """A fill that runs along an axis the caller chooses, rather than along the
    set's shared sheen axis. Used only to make a lane read as travelling: dark
    where it enters at the back, full colour where it leaves at the front."""
    fid = "ax%d" % len(lib._defs)
    lib._defs.append('<linearGradient id="%s" gradientUnits="userSpaceOnUse" '
                     'x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f">'
                     '<stop offset="0" stop-color="%s"/>'
                     '<stop offset="1" stop-color="%s"/></linearGradient>'
                     % (fid, x0, y0, x1, y1, shade(colour, t0), shade(colour, t1)))
    return "url(#%s)" % fid


def bloomdisc(cx, cy, r, colour, alpha):
    """A soft round spill, for the light that leaks out of a crossing."""
    if lib.SMALL:
        return ""
    fid = "rg%d" % len(lib._defs)
    c = lib.C.get(colour, colour)
    lib._defs.append('<radialGradient id="%s" gradientUnits="userSpaceOnUse" '
                     'cx="%.1f" cy="%.1f" r="%.1f">'
                     '<stop offset="0" stop-color="%s" stop-opacity="%.2f"/>'
                     '<stop offset="0.45" stop-color="%s" stop-opacity="%.2f"/>'
                     '<stop offset="1" stop-color="%s" stop-opacity="0"/>'
                     '</radialGradient>' % (fid, cx, cy, r, c, alpha, c,
                                            alpha * 0.38, c))
    return ('<circle cx="%.1f" cy="%.1f" r="%.1f" fill="url(#%s)"/>'
            % (cx, cy, r, fid))


# ------------------------------------------------------------ the geometry
#
# `tongue` in pieces, so a variation can put its depth between any two of them
# without redrawing the design. Every number is gen10.figure's own.
def shapes(small=False, m=M):
    h = HS if small else H
    plain = squircle_panel(m)
    spur = band_in(CY - 40, END, h * 1.04 + 52, m, x1=outof(1200, m))
    panel = sh_group(plain, spur)
    a = band_in(YA, END - h * 1.02, h * 0.92, m)
    b = band_in(YB + 26, END + h * 1.02, h * 0.92, m)
    c = band_in(CY - 40, END, h * 1.04, m)
    return dict(h=h, m=m, plain=plain, spur=spur, panel=panel, a=a, b=b, c=c,
                tile=sh_squircle(), bar=lib.sh_clip(c, panel))


# Where the bar crosses each lane, in canvas coordinates, found by walking the
# bar's centre line against each lane's. Used by the two glow variations, which
# have to put their light exactly on a crossing or it reads as a smudge.
def crossings(sp):
    m = sp["m"]
    out = []
    for lane, y0, y1 in ((sp["a"], YA, END - sp["h"] * 1.02),
                         (sp["b"], YB + 26, END + sp["h"] * 1.02)):
        best, bx = 1e9, 0.0
        for i in range(200):
            x = 120.0 + i * 4.0
            u = gen10.outof(x, m)
            d = abs(lib9.yat(y0, y1, u) - lib9.yat(CY - 40, END, u))
            if d < best:
                best, bx = d, x
        out.append((bx, gen10.into(lib9.yat(CY - 40, END, gen10.outof(bx, m)), m)))
    return out


PANELKEYS = gen10.PANELKEYS
BLEEDKEYS = gen10.BLEEDKEYS
MARKKEYS = gen10.MARKKEYS


def keys(shadow=None, translucency=False, specular=None):
    """One icon.json group's keys. `shadow` is the opacity the system draws the
    group's own shadow at, and it is the only handle a layered icon has on
    depth that the system will not draw twice."""
    k = {}
    if shadow is not None:
        k["shadow"] = {"kind": "neutral", "opacity": shadow}
    if specular is not None:
        k["specular"] = specular
    k["translucency"] = {"enabled": bool(translucency),
                         "value": translucency if translucency else 0.5}
    return k


# --------------------------------------------------------------- the base
#
# The shipped drawing, as layers and as a flat body, so a variation can say
# what it adds rather than restating the whole picture.
def base_layers(sp, mark_extra="", bleed_extra="", panel_extra="",
                ground_extra="", markkeys=None, bleedkeys=None,
                panelkeys=None, groundkeys=None, bar=None, lanes=None):
    bar = bar if bar is not None else sp["bar"](sheen("shallow"))
    if lanes is None:
        lanes = sp["a"](sheen("spatie")) + sp["b"](sheen("current"))
    return [
        ("Mark", bar + mark_extra, markkeys or MARKKEYS),
        ("Bleed", clipped(lanes, sp["panel"]) + bleed_extra,
         bleedkeys or BLEEDKEYS),
        ("Panel", sp["panel"](flat("deep")) + panel_extra,
         panelkeys or PANELKEYS),
        ("Ground", fullbleed(flat("foam")) + ground_extra, groundkeys or {}),
    ]


def base_flat(sp, seat=1.0, panel_seat=1.0, lanes=None, bar=None,
              after_panel="", after_lanes="", after_bar="", before_bar=""):
    """gen10.figure's own flat body for `tongue`, with four places to cut in.

    `seat` scales every contact shadow at the crossing at once, so a variation
    that says `the seating is the whole idea` and one that says `the seating
    gets out of the way` are the same call with a different number.
    `panel_seat` is the shadow under the panel, scaled on its own, because one
    variation removes it entirely and another leans on it."""
    p, c, a, b = sp["panel"], sp["bar"], sp["a"], sp["b"]
    lanes = lanes if lanes is not None else (a(sheen("spatie"))
                                             + b(sheen("current")))
    o = [fullbleed(flat("foam"))]
    if panel_seat:
        o.append(contact(p, sp["tile"], d=(0, 16 * S), blur=20 * S,
                         alpha=0.22 * panel_seat))
    o += [p(flat("deep")), after_panel, clipped(lanes, p), after_lanes]
    if seat:
        o += [contact(c, a, d=(0, 26 * S), blur=13 * S, alpha=0.34 * seat),
              contact(c, b, d=(0, -26 * S), blur=13 * S, alpha=0.34 * seat),
              contact(c, p, d=(0, 26 * S), blur=15 * S, alpha=0.30 * seat)]
    o += [before_bar, bar if bar is not None else c(sheen("shallow")), after_bar]
    return "".join(o)


# ------------------------------------------------------------------ the ten
#
# Each returns (layers, flat body). `small` is threaded through because every
# helper in lib.py answers to lib.SMALL, not because any of these is a small
# size drawing.
def v00_current(small=False):
    """The shipped icon, unchanged, so every other row has something to be
    compared against rather than remembered against."""
    return gen10.tongue(small)


def v01_float(small=False):
    """Layer separation only. Nothing is painted; the four groups are simply
    given different heights and the system's own shadow and specular do the
    lighting.

    The shipped keys give Panel 0.55 and Mark 0.50, which is very nearly flat:
    the bar hovers no higher than the panel it lies on. Here the ladder is
    real. Ground casts nothing, Panel sits on it at 0.42, Bleed gets a shadow
    of its own at 0.30 where it had none, and Mark rides at 0.85. On macOS 26
    that is four heights instead of two, and it costs nothing at any size
    because there is no paint to lose.

    The flat `.icns` cannot ask for any of that, so it says the same thing the
    only way it can: the same contacts, opened up.
    """
    sp = shapes(small)
    layers = base_layers(
        sp,
        markkeys=keys(shadow=0.85, specular=True),
        bleedkeys=keys(shadow=0.30),
        panelkeys=keys(shadow=0.42),
        groundkeys={})
    return layers, base_flat(sp, seat=1.45)


def v02_crown(small=False):
    """A specular highlight on the bar's crown.

    An inner light along the bar's upper edge and an inner shade along its
    lower one, both clipped to the bar, so the pale face stops being a strip of
    paper and becomes the top of something rounded. The light is on the set's
    own axis, up and to the left, so it agrees with every thickness and every
    contact shadow already drawn.

    Baked, and deliberately halved in the layered document: the system draws a
    specular of its own across the whole icon, and two speculars on one piece
    is the muddy result rule three warns about.
    """
    sp = shapes(small)
    c = sp["bar"]

    def crown(k):
        return (inner(c, (4, 15 * S), 8 * S, 0.48 * k, "#FFFFFF")
                + inner(c, (0, -21 * S), 15 * S, 0.40 * k, lib.C["fathom"]))
    return base_layers(sp, bar=c(sheen("shallow")) + crown(0.5)), \
        base_flat(sp, after_bar=crown(1.0))


def v03_extrude(small=False):
    """Thickness on the bar itself: a lit top face and a darker side.

    lib.thick's own move, which the shipped icon uses only on the scrap of bar
    that has left the panel. Here the bar has a side along its whole length,
    in Current, which measures 2.16 against Shallow and sits inside the 1.15 to
    2.30 a thickness band wants. The side is clipped to the panel with the bar,
    so it runs out along the spur and is cut by the tile with everything else.

    Baked, and identical in both outputs. A side is material and not lighting,
    so the system drawing a shadow over it does not double anything.
    """
    sp = shapes(small)
    dx, dy = lib.THICK_D
    side = ("" if small else
            lib.sh_clip(sh_move(sp["c"], dx * 0.9, dy * 0.9), sp["panel"])(
                flat("current")))
    bar = side + sp["bar"](sheen("shallow"))
    return base_layers(sp, bar=bar), base_flat(sp, seat=0.7, bar=bar)


def v04_spill(small=False):
    """Light spilling from where the lanes pass under the bar.

    Two soft Bloom discs, one on each crossing, drawn into the Bleed group so
    they sit under the bar and over the lanes. The bar reads as lit from
    beneath at exactly the two points where something passes below it, which is
    the only place in the drawing where one piece is demonstrably behind
    another.

    Baked into the Bleed group. On the layered document the system's Mark
    shadow lands on top of the spill and eats about a third of it, so the
    layered dose is raised rather than lowered: the one case in the set where
    rule three points the other way.
    """
    sp = shapes(small)
    xs = crossings(sp)

    def spill(k):
        return clipped("".join(
            bloomdisc(x, y, 210 * S, "bloom", 0.34 * k) for x, y in xs),
            sp["panel"])
    return base_layers(sp, bleed_extra=spill(1.25)), \
        base_flat(sp, after_lanes=spill(1.0))


def v05_filament(small=False):
    """The pale bar carries light along its whole length.

    A wide Bloom haze hugging the bar, clipped to the panel so the spill stays
    on the Deep field and never touches the Foam margin, plus a tighter, hotter
    one along the spur where the bar crosses out. The bar stops being the
    lightest piece of paper in the picture and becomes the source everything
    else is lit by.

    Baked into the Panel group so it lies under the Mark group and is not
    darkened by the Mark shadow the system draws. Halved for the layered
    document all the same, because the system's specular already brightens the
    bar's own face and a hot bar over a hot halo goes chalky.
    """
    sp = shapes(small)

    def glow(k):
        return (haze(sp["c"], "bloom", 34 * S, 0.42 * k, window=sp["panel"])
                + haze(sp["c"], "shallow", 12 * S, 0.34 * k, window=sp["panel"]))
    return base_layers(sp, panel_extra=glow(0.5)), \
        base_flat(sp, after_panel=glow(1.0))


def v06_recess(small=False):
    """An inner shadow on the panel, so it reads as a well cut into the Foam
    rather than a card stuck on it.

    The panel's own complement, blurred and nudged down and right, showing only
    inside the panel, which puts the dark band along the top and left inner
    edges where a real recess has one. The contact shadow the shipped icon
    draws under the panel is removed in the same breath: a hole does not cast
    onto the surface it is cut into, and drawing both at once is the surest way
    to make a shape look like neither.

    Split, and this is the sharpest split in the set. The system's group shadow
    lifts the Panel group off the Ground group, which is the exact opposite of
    what this variation is claiming, so the layered document sets Panel's
    shadow to 0.05 and lets the paint do all of it.
    """
    sp = shapes(small)

    def well(k):
        return (inner(sp["panel"], (0, 22 * S), 20 * S, 0.55 * k, lib.C["abyss"])
                + inner(sp["panel"], (0, -18 * S), 16 * S, 0.16 * k, "#FFFFFF"))
    layers = base_layers(sp, panel_extra=well(1.0),
                         panelkeys=keys(shadow=0.05))
    return layers, base_flat(sp, panel_seat=0, after_panel=well(1.0))


def v07_seat(small=False):
    """Contact shadow at the crossing, and nowhere else.

    The shipped icon already casts the bar onto both lanes and onto the panel.
    This tightens all three, halves the blur and darkens them, and adds the one
    the shipped icon does not draw: an occlusion where the spur meets the Foam,
    so the tongue reads as a step down onto the margin rather than a shape
    painted on it. No glow, no bevel, nothing that is not a shadow.

    Baked, and kept in the layered document at two thirds. The system's shadow
    is drawn per group, behind the whole group, so it can never produce the
    dark line where the bar meets the panel that is the entire point of this
    one.
    """
    sp = shapes(small)
    p, c, a, b = sp["panel"], sp["bar"], sp["a"], sp["b"]

    def seats(k):
        return "".join([
            contact(c, a, d=(0, 20 * S), blur=7 * S, alpha=0.46 * k),
            contact(c, b, d=(0, -20 * S), blur=7 * S, alpha=0.46 * k),
            contact(c, p, d=(2 * S, 18 * S), blur=8 * S, alpha=0.42 * k),
        ])
    lip = (lambda k: outside(contact(p, sp["tile"], d=(0, 14 * S),
                                     blur=13 * S, alpha=0.30 * k), p))
    return base_layers(sp, bleed_extra=seats(0.66), ground_extra=lip(0.66)), \
        base_flat(sp, seat=0, panel_seat=0, before_bar=seats(1.0),
                  after_panel=lip(1.0))


def v08_travel(small=False):
    """A gradient along each lane, so the lanes read as arriving from depth.

    Every fill in the set runs on one shared 62 degree axis, which is what
    makes the pieces read as flat paper. These two run along their own length
    instead: dark where the lane enters at the left, full colour where it
    leaves at the right. The lanes stop being two stripes and become two
    things travelling toward the crossing.

    Baked, identical in both outputs, and the only variation in the set that
    costs nothing at 16 points, because a gradient does not have a smallest
    legible size the way a highlight or a shadow does.
    """
    sp = shapes(small)
    lanes = (sp["a"](axial("spatie", 120, 0, 900, 0, -0.34, 0.10))
             + sp["b"](axial("current", 120, 0, 900, 0, -0.30, 0.08)))
    return base_layers(sp, lanes=lanes), base_flat(sp, lanes=lanes)


def v09_glass(small=False):
    """The bar is slightly translucent, so the panel and the lanes show through
    it.

    Split, and the two outputs do it by completely different means. The flat
    `.icns` paints it: the bar at 0.86 alpha over what is already drawn, with a
    solid bright leading edge along the top so the transparency reads as glass
    and not as a printing fault. The layered document paints nothing and turns
    the system's own translucency key on for the Mark group instead, which
    makes the bar take the material behind it and, unlike a baked alpha, still
    works when the system recolours the icon for a dark or tinted variant.

    This is the only variation whose layered artwork is byte for byte the
    shipped drawing. Everything it does is in icon.json.
    """
    sp = shapes(small)
    lip = inner(sp["bar"], (3, 13 * S), 6 * S, 0.62, "#FFFFFF")
    glass = ('<g opacity="0.86">%s</g>%s'
             % (sp["bar"](sheen("shallow")), lip))
    return base_layers(sp, markkeys=keys(shadow=0.5, specular=True,
                                         translucency=0.42)), \
        base_flat(sp, bar=glass)


def v10_stack(small=False):
    """Separation, crown and seating together, at the dose each one survives.

    v01's ladder of group heights, v02's crown at half strength, v07's tighter
    seating at two thirds, and v08's travelling lanes, which are free. Nothing
    from the two glow variations, because a glow is the first thing that turns
    to fog at 64 and the second thing that fights the system's specular.

    Split by dose rather than by drawing: the layered document takes the
    separation and a third of the paint, the `.icns` takes all of the paint and
    none of the separation, because it has no groups to separate.
    """
    sp = shapes(small)
    p, c, a, b = sp["panel"], sp["bar"], sp["a"], sp["b"]
    lanes = (a(axial("spatie", 120, 0, 900, 0, -0.30, 0.08))
             + b(axial("current", 120, 0, 900, 0, -0.26, 0.06)))

    def crown(k):
        return (inner(c, (4, 15 * S), 8 * S, 0.42 * k, "#FFFFFF")
                + inner(c, (0, -21 * S), 15 * S, 0.34 * k, lib.C["fathom"]))

    def seats(k):
        return "".join([
            contact(c, a, d=(0, 20 * S), blur=8 * S, alpha=0.42 * k),
            contact(c, b, d=(0, -20 * S), blur=8 * S, alpha=0.42 * k),
            contact(c, p, d=(2 * S, 18 * S), blur=9 * S, alpha=0.38 * k),
        ])
    layers = [
        ("Mark", c(sheen("shallow")) + crown(0.35), keys(shadow=0.85,
                                                         specular=True)),
        ("Bleed", clipped(lanes, p) + seats(0.5), keys(shadow=0.30)),
        ("Panel", p(flat("deep")), keys(shadow=0.42)),
        ("Ground", fullbleed(flat("foam")), {}),
    ]
    body = base_flat(sp, seat=0, panel_seat=1.35, lanes=lanes,
                     before_bar=seats(1.0), after_bar=crown(1.0))
    return layers, body


VARIANTS = [
    ("00-current", "the shipped icon, for comparison", "shipped",
     v00_current),
    ("01-float", "four group heights, no paint at all", "system", v01_float),
    ("02-crown", "a specular along the bar's upper edge", "baked", v02_crown),
    ("03-extrude", "the bar given a side along its whole length", "baked",
     v03_extrude),
    ("04-spill", "Bloom light leaking from the two crossings", "baked",
     v04_spill),
    ("05-filament", "the bar as the source the panel is lit by", "baked",
     v05_filament),
    ("06-recess", "the panel sunk into the Foam, not stuck on it", "split",
     v06_recess),
    ("07-seat", "the crossing seated hard, nothing else touched", "baked",
     v07_seat),
    ("08-travel", "the lanes graded along their own length", "baked",
     v08_travel),
    ("09-glass", "the bar translucent over the panel", "split", v09_glass),
    ("10-stack", "separation, crown, seating and travel together", "split",
     v10_stack),
]


def render(fn, small=False):
    """Same contract as gen10.render: the layered groups, the full bleed
    composite, and the composite at the Big Sur template for the `.icns`."""
    lib.SMALL = small
    lib.reset()
    layers, body = fn(small)
    return ([(n, wrap_layer(b), k) for n, b, k in layers],
            wrap_flat(body), wrap_legacy(body))


# ------------------------------------------------------- the system's pass
#
# What macOS 26 adds on top of a layered document, near enough to judge a
# variation by: a shadow behind each group at the opacity its keys ask for, and
# one specular along the tile's own upper edge. It is an approximation and the
# page says so. It exists because half the variations here are ABOUT what the
# system adds, and comparing them on the raw layers would be comparing the half
# of each drawing that was deliberately left out.
def simulate(layers):
    parts = []
    for name, body, k in reversed(layers):
        # Translucency is a material key, not a shadow one, and the only way to
        # show it here is to let the group take some of what is behind it.
        tr = k.get("translucency") or {}
        if tr.get("enabled"):
            body = '<g opacity="%.2f">%s</g>' % (1.0 - 0.40 * tr["value"], body)
        sh = (k.get("shadow") or {}).get("opacity")
        if not sh:
            parts.append(body)
            continue
        # The system's shadow grows with the group's height, and the opacity
        # key is the only thing we know about that height, so it drives both.
        dy = 3 + 30 * sh
        blur = 3 + 24 * sh
        fid = "sys%d" % len(parts)
        lib._defs.append(
            '<filter id="%s" x="-40%%" y="-40%%" width="180%%" height="180%%" '
            'color-interpolation-filters="sRGB"><feDropShadow dx="0" dy="%.1f" '
            'stdDeviation="%.1f" flood-color="#000814" flood-opacity="%.2f"/>'
            '</filter>' % (fid, dy, blur, min(0.55, 0.30 + 0.28 * sh)))
        parts.append('<g filter="url(#%s)">%s</g>' % (fid, body))
    tile = sh_squircle()
    parts.append(inner(tile, (0, 9), 7, 0.42, "#FFFFFF"))
    parts.append(inner(tile, (0, -11), 9, 0.13, "#001018"))
    return wrap_flat("".join(parts))


def outputs(fn):
    """The two pictures a variation has to be judged on: the layered document
    as the system will composite it, and the flat `.icns` as it is."""
    lib.SMALL = False
    lib.reset()
    layers, body = fn(False)
    raw = [(n, b, k) for n, b, k in layers]
    layered = simulate(raw)
    return layered, wrap_legacy(body)



# ------------------------------------------------- the small size comparison
#
# The per variation cards answer `what does this one do`. They cannot answer
# `which of these is still doing it at 32`, because two cards are a thousand
# pixels apart and the eye cannot carry a two pixel difference that far. This
# grid puts every variation at ONE size in one row, so the claims in the
# verdict can be checked rather than taken on trust.
#
# Each picture is shown twice: once at actual size, which is the truth, and
# once scaled up with image-rendering: pixelated, which is the same pixels
# magnified rather than a bigger render. The magnified one is a reading aid and
# says so on the page; nothing is judged on it that the actual size pair does
# not also show.
GRID_SIZES = [128, 64, 32, 16]
GRID_ZOOM = {128: 2, 64: 4, 32: 8, 16: 16}


def grids(seen):
    out = []
    for key, label in (("L", "layered document"), ("F", "flat .icns")):
        rows = []
        for size in GRID_SIZES:
            z = GRID_ZOOM[size] * size
            cells = []
            for name, _, _, _ in VARIANTS:
                c = seen[(name, key, size)]
                cells.append(
                    '<div class="gc"><i class="%s" style="width:%dpx;'
                    'height:%dpx"></i>'
                    '<i class="%s px" style="width:%dpx;height:%dpx"></i>'
                    '<span>%s</span></div>'
                    % (c, size, size, c, z, z, name.split("-", 1)[1]))
            rows.append(
                '<div class="grow"><h4>%d point, actual size above, the same '
                'pixels at %dx below</h4><div class="gr">%s</div></div>'
                % (size, GRID_ZOOM[size], "".join(cells)))
        out.append('<div class="gblock"><h3>%s</h3>%s</div>'
                   % (label, "".join(rows)))
    return ('<section class="card grid"><div class="hd">'
            '<h2>All eleven at the sizes that decide it</h2></div>'
            '<p class="note">Depth is the first thing to go when an icon '
            'shrinks, so this is where the set is actually judged. Each row is '
            'one size, every variation in the same order as above, actual size '
            'on top and the same pixels magnified underneath. If two cells in a '
            'row look the same, that variation is not buying anything at that '
            'size.</p>%s</section>') % "".join(out)


# ------------------------------------------------------------------- sheet
SIZES = [1024, 512, 256, 128, 64, 32, 16]


def png(svg, size, path):
    tmp = path + ".svg"
    with open(tmp, "w") as f:
        f.write(svg)
    subprocess.run(["rsvg-convert", "-w", str(size), "-h", str(size), tmp,
                    "-o", path], check=True)
    os.remove(tmp)
    with open(path, "rb") as f:
        return "data:image/png;base64," + base64.b64encode(f.read()).decode()


NOTE = {
    "00-current": ("Foam ground, Deep panel with its spur, two lanes, the pale "
                   "bar riding inside the spur. Depth: baked contact shadows in "
                   "the flat file, the system's own shadow in the layered one."),
    "01-float": ("No paint at all. Ground 0, Panel 0.42, Bleed 0.30, Mark 0.85, "
                 "so the system lifts four things to four heights. Depth lives "
                 "in the layer separation."),
    "02-crown": ("An inner light along the bar's top edge and an inner shade "
                 "along its bottom. Depth lives in the paint, halved in the "
                 "layered document because the system draws a specular too."),
    "03-extrude": ("A Current side under the bar along its whole length, "
                   "clipped to the panel so it follows the spur out. Depth "
                   "lives in the paint and is the same in both, because a side "
                   "is material and not lighting."),
    "04-spill": ("Two Bloom discs on the crossings, in the Bleed group under "
                 "the bar. Depth lives in the paint; the layered dose is raised "
                 "because the system's Mark shadow eats a third of it."),
    "05-filament": ("A wide Bloom haze on the bar, clipped to the panel, with a "
                    "tighter one along the spur. Depth lives in the paint, "
                    "halved in the layered document."),
    "06-recess": ("An inner shadow inside the panel and no contact under it. "
                  "Depth lives in the paint, and the layered document turns the "
                  "Panel group's system shadow down to 0.05 so the system does "
                  "not lift what the paint sank."),
    "07-seat": ("The three contacts at the crossing tightened and darkened, "
                "plus an occlusion where the spur steps down onto the Foam. "
                "Depth lives in the paint, at two thirds in the layered "
                "document, because a per group shadow cannot draw a line at a "
                "crossing."),
    "08-travel": ("Each lane graded along its own length, dark at the entry and "
                  "full colour at the exit. Depth lives in the paint and is "
                  "identical in both outputs."),
    "09-glass": ("The bar reads through to the panel. Depth lives in two "
                 "different places: a baked 0.86 alpha with a solid bright lip "
                 "in the flat file, the system's own translucency key in the "
                 "layered one, whose artwork is the shipped drawing untouched."),
    "10-stack": ("01's separation, 02's crown at a third, 07's seating at two "
                 "thirds, 08's lanes. Depth lives in both places at once, which "
                 "is what the current pipeline already assumes."),
}

CSS = """
:root { color-scheme: light dark; }
* { box-sizing: border-box; }
body { margin: 0; background: #16181C; color: #E8EDF0;
  font: 15px/1.6 ui-sans-serif, -apple-system, "SF Pro Text", system-ui, sans-serif; }
header { padding: 48px 40px 24px; max-width: 1180px; }
h1 { font-size: 30px; margin: 0 0 12px; letter-spacing: -0.01em; }
header p { color: #9AA7B0; max-width: 74ch; margin: 0 0 10px; }
code { font: 13px/1.5 ui-monospace, "SF Mono", Menlo, monospace; color: #9BE9DC; }
.card { border-top: 1px solid #262B31; padding: 34px 40px 40px; }
.hd { display: flex; align-items: baseline; gap: 14px; flex-wrap: wrap;
  margin-bottom: 6px; }
.hd h2 { font-size: 21px; margin: 0; letter-spacing: -0.01em; }
.blurb { color: #7E8B94; }
.num { color: #4A5560; font: 13px ui-monospace, Menlo, monospace; }
.tag { font-size: 11px; letter-spacing: 0.08em; text-transform: uppercase;
  padding: 3px 9px; border-radius: 999px; border: 1px solid #2AA3B4;
  color: #9BE9DC; }
.tag.system { border-color: #4FD8C4; color: #4FD8C4; }
.tag.split { border-color: #E0A85C; color: #E9C48E; }
.tag.baked { border-color: #3E7A8C; color: #8FC7D4; }
.tag.shipped { border-color: #4A5560; color: #8E9AA3; }
.note { color: #9AA7B0; max-width: 92ch; margin: 6px 0 22px; }
.cols { display: flex; flex-direction: column; gap: 30px; }
.col { min-width: 0; }
.col h3 { font-size: 12px; letter-spacing: 0.09em; text-transform: uppercase;
  color: #6E7C86; margin: 0 0 12px; font-weight: 600; }
.card { max-width: 1240px; }
.bigs { display: flex; gap: 16px; margin-bottom: 18px; }
.big { padding: 20px; border-radius: 16px; }
.big i { display: block; width: 400px; height: 400px; }
.strip { display: flex; align-items: flex-end; gap: 14px; padding: 16px;
  border-radius: 12px; margin-bottom: 10px; overflow-x: auto; width: max-content;
  max-width: 100%; }
.strips { display: flex; gap: 16px; flex-wrap: wrap; }
i { display: inline-block; background-size: 100% 100%;
  background-repeat: no-repeat; }
.light { background: #EDEDED; }
.dark { background: #1C1C1E; }
.sz { text-align: center; }
.sz span { display: block; font: 10px ui-monospace, Menlo, monospace;
  margin-top: 5px; }
.light .sz span { color: #8A8A8A; }
.dark .sz span { color: #7A8088; }
.grid { max-width: 1240px; }
.gblock { margin-bottom: 34px; }
.gblock h3 { font-size: 12px; letter-spacing: 0.09em; text-transform: uppercase;
  color: #6E7C86; margin: 0 0 14px; font-weight: 600; }
.grow { margin-bottom: 22px; }
.grow h4 { font-size: 11px; letter-spacing: 0.06em; color: #5C6872;
  margin: 0 0 8px; font-weight: 500; text-transform: uppercase; }
.gr { display: flex; gap: 10px; flex-wrap: wrap; }
.gc { background: #EDEDED; border-radius: 8px; padding: 10px 10px 6px;
  display: flex; flex-direction: column; align-items: center; gap: 8px; }
.gc span { font: 10px ui-monospace, Menlo, monospace; color: #8A8A8A;
  max-width: 100%; }
.px { image-rendering: pixelated; image-rendering: crisp-edges; }

.verdict { border-top: 1px solid #262B31; padding: 40px; }
.verdict h2 { font-size: 22px; margin: 0 0 14px; }
.verdict p { color: #C2CBD2; max-width: 82ch; }
.verdict strong { color: #9BE9DC; font-weight: 600; }
.verdict ul { color: #9AA7B0; max-width: 82ch; }
"""


def sheet(outdir):
    """The page. Every picture is embedded as one CSS rule and used by class,
    because each of them appears twice, on the light ground and on the dark
    one, and a data URI written into the file twice doubles an eleven megabyte
    page for nothing."""
    os.makedirs(outdir, exist_ok=True)
    pngs = os.path.join(outdir, "png")
    os.makedirs(pngs, exist_ok=True)

    rules, cards = [], []
    # (name, key, size) -> class, kept so that grids() can lay every
    # variation out at ONE size next to every other one. The cards can
    # only be read one at a time, and a claim like `05 is a smudge at 32`
    # cannot be checked that way.
    seen = {}
    for name, blurb, where, fn in VARIANTS:
        layered, flatsvg = outputs(fn)
        cols = []
        for label, svg, key in (("layered document, macOS 26, system pass "
                                 "simulated", layered, "L"),
                                ("flat .icns, the Big Sur body at 824 in 1024",
                                 flatsvg, "F")):
            cls = {}
            for size in SIZES:
                p = os.path.join(pngs, "%s-%s-%d.png" % (name, key, size))
                c = "i%s%s%d" % (name.split("-")[0], key, size)
                rules.append(".%s{background-image:url(%s)}"
                             % (c, png(svg, size, p)))
                cls[size] = c
                seen[(name, key, size)] = c
            small = "".join(
                '<div class="sz"><i class="%s" style="width:%dpx;height:%dpx">'
                '</i><span>%d</span></div>' % (cls[s], s, s, s)
                for s in sorted(SIZES[1:]))
            cols.append(
                '<div class="col"><h3>%s</h3>'
                '<div class="bigs">'
                '<div class="big light"><i class="%s"></i></div>'
                '<div class="big dark"><i class="%s"></i></div></div>'
                '<div class="strip light">%s</div>'
                '<div class="strip dark">%s</div></div>'
                % (label, cls[1024], cls[1024], small, small))
        cards.append(
            '<section class="card"><div class="hd"><span class="num">%s</span>'
            '<h2>%s</h2><span class="tag %s">depth: %s</span>'
            '<span class="blurb">%s</span></div>'
            '<p class="note">%s</p><div class="cols">%s</div></section>'
            % (name.split("-")[0], name.split("-", 1)[1], where, where, blurb,
               NOTE[name], "".join(cols)))

    grid = grids(seen)

    html = ("<!doctype html><meta charset=utf-8><title>Bloom icon, ten depth "
            "studies</title><style>%s\n%s</style>"
            "<header><h1>Bloom, ten depth studies</h1>"
            "<p>The design does not change. Foam ground, Deep panel with its "
            "spur, two lanes, the pale bar riding inside the spur. What changes "
            "in each row is where the depth comes from, and every row says "
            "where its depth lives.</p>"
            "<p>Both outputs are shown, because they are not the same picture. "
            "On the left the layered document as macOS 26 will composite it: "
            "the system draws a shadow behind each group and a specular over "
            "the lot, and that pass is simulated here rather than measured, so "
            "read it as close and not as exact. On the right the flat "
            "<code>.icns</code>, which nothing helps, drawn to the Big Sur "
            "template at 824 inside 1024 because the app still runs on macOS "
            "15. That is why the right hand icon sits smaller in its square.</p>"
            "<p>The big pair is the 1024 render on a light ground and a dark "
            "one. The two strips under it are ACTUAL SIZE at 16, 32, 64, 128, "
            "256 and 512, smallest first so that the sizes the set is really "
            "judged at sit at the same place in every row. All of it comes from "
            "the same framed artwork at every size, which is what the layered "
            "document really does. The shipped <code>.icns</code> swaps in the "
            "unframed drawing below 64; that swap is deliberately left out "
            "here, so each row shows what its depth alone is worth as it "
            "shrinks.</p>"
            "<p>After the eleven there is a grid putting all of them at 128, "
            "64, 32 and 16 side by side, which is the only way to see which "
            "ones stop paying for themselves. Read the verdict at the bottom "
            "against that grid and not against the 1024s.</p>"
            "</header>%s%s%s") % (CSS, "".join(rules), "".join(cards),
                                 grid, VERDICT)

    out = os.path.join(outdir, "depth.html")
    with open(out, "w") as f:
        f.write(html)
    return out


VERDICT = """
<section class="verdict"><h2>What I would ship</h2>
<p><strong>10-stack</strong>, and if only one thing may change,
<strong>01-float</strong> on its own. 01 is free: it is four numbers in
<code>icon.json</code>, it survives every size because there is no paint to
lose, and it is the one kind of depth macOS 26 is asking to be given. The
shipped keys put Panel at 0.55 and Mark at 0.50, which tells the system the bar
is no higher than the panel it lies on, and that is not what the drawing means.
10 adds the two painted effects that hold up when the icon shrinks, the crown
and the tighter seating, at a dose that leaves the system's own pass something
to do.</p>
<p><strong>Runners up.</strong> 07-seat is the most honest single effect in the
set: it draws the one thing a per group shadow can never draw, the dark line
where the bar meets the panel, and it is the only variation that looks CRISPER
at 32 than the shipped icon rather than softer. 08-travel costs nothing, reads
at 32, and is the cheapest way to make the lanes look like they are going
somewhere. 09-glass is worth a look on the layered side alone, where the
artwork is the shipped drawing untouched and the whole effect is one key.</p>
<p><strong>Honest about the small sizes.</strong> Judge these on the 64, 32 and
16 strips, not on the 1024.</p>
<ul>
<li><strong>05-filament fails.</strong> Below 128 the haze stops being a halo
and becomes a general lightening of the panel; at 32 the panel looks washed
rather than lit, and the Deep field loses the weight that pays for the white
margin. Beautiful at 1024, a smudge at 32.</li>
<li><strong>04-spill fails.</strong> The discs are 210 units across, which is
six pixels at 32 and three at 16. By 64 it is indistinguishable from the
shipped icon, so it is paying a cost at 1024 for nothing at the sizes the icon
is actually used at.</li>
<li><strong>06-recess fails, twice.</strong> The inner shadow is gone by 32,
and at every size it fights the system, which wants to lift the Panel group.
Worse, a sunk panel makes the Foam read as a frame again, which is the bug
round nine was fixing. Included because it was asked for, and it is the one I
would argue hardest against.</li>
<li><strong>09-glass costs contrast.</strong> It reads at every size, which is
the surprise, but at 32 the bar goes dull and grey and the crossing, the whole
point of the design, loses its punch. Its layered half is still the most
interesting thing here, because it costs one key and survives the system's dark
and tinted variants, which a baked alpha does not.</li>
<li><strong>02-crown survives further than expected</strong> but changes
meaning on the way down. At 64 the bar reads rounded; at 32 the shade band is
two pixels of the bar's six and it reads as a thinner, darker bar rather than a
crowned one. Keep it at the reduced dose 10-stack uses, not at full.</li>
<li><strong>03-extrude</strong> holds to about 48 and then thickens the bar by
a pixel of Current, so at 32 the bar looks fatter rather than deeper. It is
also the only variation that changes the bar's silhouette, which makes it the
riskiest thing here for a mark that also has to work at 15 points in the menu
bar.</li>
</ul>
<p><strong>Nothing here changes the shipped icon.</strong> Every variation is a
function in <code>Tools/icon/depth.py</code>. Shipping one is pointing
<code>make.py</code>'s <code>DESIGN</code> at it and taking the keys it asks
for, which is one line and one dictionary.</p>
</section>
"""


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, ".build",
                                                             "depth")
    print("==>", sheet(out))
