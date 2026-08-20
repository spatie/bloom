#!/usr/bin/env python3
"""Ten shine studies on the shipped icon, `gen10.tongue` at margin 150.

    python3 Tools/icon/shine.py [outdir]

Nothing here ships. The design is not changed and neither is the palette: same
Foam ground, same Deep panel with its spur, same Spatie and Current lanes, same
pale Shallow bar, same silhouette, no border added anywhere. The only thing
that changes between the eleven rows is HOW LIGHT BEHAVES ON THE DRAWING.

READ make.py's DOCSTRING FIRST, and depth.py's after it. The rule that governs
this file is make.py's third one: on macOS 26 the system draws its own shadow
and its own specular over the layered document, so paint that says the same
thing is drawn twice and comes out muddy. Every row below therefore says where
its effect LIVES:

  system   the artwork is not painted at all. The effect is asked for through
           the layered document's own keys and the system produces it. Only
           `Bloom.icon` can do this, so the flat `.icns` gets the nearest thing
           paint can say
  baked    the effect is painted into the artwork. The `.icns` needs this; the
           layered document gets a reduced dose so the system's pass has
           something left to add
  split    the two outputs want genuinely different drawings

WHAT WAS MEASURED OFF APPLE'S OWN ICONS, and it is not what a screenshot shows.

`/System/Applications/*.app/Contents/Resources/Assets.car` carries the layered
documents themselves, and `assetutil --info` prints every key in them. Photos,
Maps, Home and Find My were read that way. Numbers was not: its icon is still a
flat `.icns` with no layered document at all, and everything glassy about it on
this machine is the system's material applied to a legacy bitmap. That alone is
worth knowing, because the icon the owner pointed at as the clearest case of a
graded shape has no gradient in it.

  1 A LAYER'S FILL IS A KEY, NOT PAINT. Apple's layers carry
    `LayerGradientColorName` pointing at a two stop Named Gradient, and the SVG
    under it is a silhouette whose own colours are thrown away. Verified here:
    give a layer a `fill` and the drawing becomes a mask.
  2 EVERY GRADIENT IN ALL FOUR IS VERTICAL. `0.500,0.000 - 0.500,1.000`, top to
    bottom, two stops, no exceptions. Not one diagonal, not one radial. The
    renderer says so itself: "radial gradients are not supported".
  3 THE RAMP OFTEN STOPS EARLY. `0.500,0.000 - 0.500,0.700` appears in Photos
    and in Find My: the grade completes at seven tenths of the way down and the
    rest of the shape is flat. That is what makes a gloss read as a lit crown
    rather than as a wash, and it is the single most useful thing in the file.
  4 THE SYSTEM'S OWN GROUND IS A GRADIENT. `system-light` is #FFFFFF to
    #ECECEC top to bottom, `system-dark` is 19.2 percent grey to 7.8 percent.
    A near white ground graded by about eight percent of its own value is
    exactly what the system would have drawn for us.
  5 TRANSLUCENCY IS IN THE COLOUR AND IN THE KEY, AND APPLE USES BOTH. Photos'
    petals are alpha 0.80 in the dark appearance, opaque in the light one. Find
    My's radar wedge ramps #61A6FF at alpha 0.40 down to #0087FF at alpha 0.84.
    Find My's back circle is `Multiply`. Where two shapes overlap, the overlap
    is a blend and never an occlusion.
  6 LIGHTING IS ON BY DEFAULT. `LayerHasLightingEffects` is true on every
    shape layer in all four, and false on the detail layers Maps draws on top
    of its own puck. It is a per layer switch and it is worth turning off.

TWO THINGS THIS FILE FOUND OUT BY BUILDING THE BUNDLES RATHER THAN BY READING
THEM, and both of them killed a variation before they were understood.

  7 THE LAYERED DOCUMENT'S RENDERER IGNORES SVG FILTERS. actool draws the layer
    art with CoreSVG, and `feGaussianBlur` is silently dropped: a `<g filter>`
    renders its contents unblurred. Clips and masks survive; blur does not.
    Every soft edge in `lib.py` and in `depth.py` is a blur inside a clip, so
    ALL OF IT DIES on the layered side, and worse, it does not die quietly. The
    first cut of rows 04 and 07 came back with the panel flooded pale, because
    an inner shadow whose softness has been removed is a hard slab. rsvg, which
    draws the flat `.icns`, blurs correctly, so a baked soft edge is now a flat
    file device only and the page marks every row that uses one as split.
  8 ONE PIECE GETS ONE GRADIENT, AND STACKING TWO IS NOT A WAY ROUND IT. A
    linear gradient has exactly two stops, so a piece cannot be given a lit
    crown and a seated base by one fill. The obvious answer, a second layer of
    the same silhouette carrying an alpha ramp, does not work: the system lights
    every layer separately, so the duplicate gets a specular of its own and the
    piece comes back lifted and grey rather than shaded. Tried with a plain
    alpha ramp and again with `Multiply`, and both lift it. Apple never does it
    either; not one of the four stacks two layers on one shape. The way to say
    crown and base at once is ONE ramp placed across the piece so that what is
    above the start clamps light and what is below the stop clamps deep, which
    is what row 09 does.

HOW THE LAYERED COLUMN ON THE PAGE IS PRODUCED, and why it can be trusted.

depth.py had to SIMULATE the system's pass, because it had no way to ask the
system what it would draw. This file does not simulate anything. Each variation
is written out as a real `.icon` bundle, compiled with `actool` exactly the way
`build.sh` compiles the shipped one, dropped into a throwaway `.app` in
`.build/`, and handed to Icon Services, which composites it and hands back the
pixels Finder would show. The left hand column of the page is a photograph of
macOS drawing the icon, not a guess at it. Nothing here writes outside
`Tools/icon/.build`.

The flat `.icns` column is rendered from the same artwork the way make.py
renders it, at the Big Sur template, because the app still runs on macOS 15.
"""

import base64
import json
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import depth  # noqa: E402
import gen10  # noqa: E402
import lib  # noqa: E402
import lib9  # noqa: E402
from depth import inner, shapes, base_flat  # noqa: E402
from gen10 import END, H, HS, M, YA, YB, into, kof  # noqa: E402
from lib import flat, sheen, shade  # noqa: E402
from lib9 import S, clipped, fullbleed, outside, wrap_flat, wrap_layer, wrap_legacy  # noqa: E402

BUILD = os.path.join(HERE, ".build", "shine")


# ------------------------------------------------------------ colour, twice
#
# Every effect below has to be sayable in two languages: as a stop in an
# icon.json fill, and as a stop in an SVG gradient. Both come from lib.shade,
# so a variation cannot drift between its two outputs by getting a number
# slightly wrong in one of them.
def tone(colour, t):
    """The palette colour nudged toward white (t > 0) or black (t < 0).

    THIS IS NOT A PALETTE CHANGE. Every gradient in this file is centred on the
    colour it grades: the top is lighter than the fill and the bottom is deeper
    by the same amount, so the piece's average tone is the palette entry it
    started as. That is what Apple does to a bar in Numbers and to a petal in
    Photos, and it is the difference between grading a colour and replacing it.
    """
    return lib.shade(colour, t)


def key(colour, t=0.0, a=1.0):
    """One stop of an icon.json fill: `srgb:r,g,b,a` with components 0 to 1.

    The encoding was found by reading IconComposerFoundation rather than
    guessed: a colour is a string, the part before the colon names the space
    (srgb, extended-srgb, display-p3, gray, extended-gray, named) and the part
    after it is the components. Anything else compiles to a nil CGColor and
    actool dies inside CoreFoundation without saying why.
    """
    r, g, b = lib._hex(tone(colour, t))
    return "srgb:%.4f,%.4f,%.4f,%.3f" % (r / 255.0, g / 255.0, b / 255.0, a)


def fill(colour, up, down, y0=None, y1=None, a=1.0, b=None):
    """A layer's fill key: a two stop vertical gradient, lighter at the top.

    y0 and y1 are canvas coordinates, converted here to the 0 to 1 the document
    wants. Left out, the ramp runs the whole canvas, which is what Apple's
    default `0.500,0.000 - 0.500,1.000` does and what makes the whole icon read
    as one lit sheet. Given a piece's own top and bottom, the ramp is confined
    to that piece and every piece is lit head to foot, which is Numbers.
    """
    g = {"linear-gradient": [key(colour, up, a), key(colour, -down, b if b is not None else a)]}
    if y0 is not None:
        g["orientation"] = {"start": {"x": 0.5, "y": y0 / 1024.0},
                            "stop": {"x": 0.5, "y": y1 / 1024.0}}
    return g


def paint(colour, up, down, y0, y1, a=1.0, b=None):
    """The same gradient as an SVG paint, for the flat `.icns`.

    userSpaceOnUse and canvas coordinates, so the same two numbers describe the
    ramp in both outputs and the two files cannot say different things.
    """
    fid = "vg%d" % len(lib._defs)
    lib._defs.append(
        '<linearGradient id="%s" gradientUnits="userSpaceOnUse" x1="512" y1="%.1f" '
        'x2="512" y2="%.1f"><stop offset="0" stop-color="%s" stop-opacity="%.3f"/>'
        '<stop offset="1" stop-color="%s" stop-opacity="%.3f"/></linearGradient>'
        % (fid, y0, y1, tone(colour, up), a, tone(colour, -down),
           b if b is not None else a))
    return "url(#%s)" % fid


# ------------------------------------------------------- where a piece lives
#
# A gradient confined to a piece needs that piece's top and bottom on the
# canvas, and a number typed in by hand here would go stale the first time the
# margin moved. Every band in the design is a cubic whose control points sit at
# its own two end heights, so the curve never leaves the strip between them and
# the extent is exact rather than sampled.
def extent(y0, y1, h, m=M, extra=0.0):
    half = (h + extra) / 2.0
    return into(min(y0, y1) - half, m), into(max(y0, y1) + half, m)


def where(small=False, m=M):
    """Top and bottom, on the canvas, of every piece the design has."""
    h = HS if small else H
    lanes = (extent(YA, END - h * 1.02, h * 0.92, m),
             extent(YB + 26, END + h * 1.02, h * 0.92, m))
    return dict(
        ground=(0.0, 1024.0),
        panel=(m, 1024.0 - m),
        bar=extent(gen10.CY - 40, END, h * 1.04, m),
        spur=extent(gen10.CY - 40, END, h * 1.04 + 52, m),
        # A lane is clipped to the panel, so what is lit is the part inside it.
        a=(max(m, lanes[0][0]), min(1024.0 - m, lanes[0][1])),
        b=(max(m, lanes[1][0]), min(1024.0 - m, lanes[1][1])))


def crest(y0, y1, at=0.14):
    """The same strip, with the ramp told to finish near the top.

    Apple's `0.500,0.000 - 0.500,0.700` in Photos and Find My. Pushed to a
    seventh rather than seven tenths it stops being a grade and becomes a lit
    crown: a bright band along the upper edge with flat colour under it.
    """
    return y0, y0 + (y1 - y0) * at


# ------------------------------------------------------------- the document
#
# The shipped icon.json has one layer per group because every group is one
# colour. A fill key replaces the artwork's colours outright, so the moment the
# Bleed group is graded its two lanes have to become two layers: one gradient
# cannot carry Spatie and Current at once. Splitting a group is not a change to
# the drawing, and the geometry is the same either way.
def groupkeys(shadow=None, specular=None, translucency=None):
    k = {}
    if shadow is not None:
        k["shadow"] = {"kind": "neutral", "opacity": shadow}
    if specular is not None:
        k["specular"] = specular
    k["translucency"] = ({"enabled": True, "value": translucency}
                         if translucency else {"enabled": False, "value": 0.5})
    return k


MARK = groupkeys(shadow=0.5, specular=True)
BLEED = groupkeys()
PANEL = groupkeys(shadow=0.55)
GROUND = {}


def layer(name, body, fill=None, opacity=None, blend=None, specular=None):
    d = {"name": name, "body": body}
    if fill is not None:
        d["fill"] = fill
    if opacity is not None:
        d["opacity"] = opacity
    if blend is not None:
        d["blend-mode"] = blend
    if specular is not None:
        d["specular"] = specular
    return d


# ------------------------------------------------------------------------
# ONLY THE PALE BAR LEAVES ON THE RIGHT, AND THAT IS A CORRECTION.
#
# `gen10.figure` clips the two lanes to the panel, and the panel it clips them to
# is the one that has already had the spur added to it: `clipped(lanes, p)` where
# `p` is `sh_group(squircle_panel(m), band_in(...))`. So wherever a lane happens
# to lie inside the spur it follows the spur out over the Foam margin, and at the
# leaving edge both lanes do lie inside it, because both are easing toward END
# exactly where the bar is. What crosses the white on the right is therefore mid
# teal, dark, pale bar, dark, mid teal, in five bands.
#
# That is not the spur carrying content; it is a lane that is not being cut at
# the panel boundary. The left edge shows what was intended: there the lanes are
# still far from the bar's height, nothing of them is inside the spur, and what
# crosses the margin is the dark spur with the pale bar inside it and nothing
# else.
#
# THE SPUR ITSELF STAYS. make.py's docstring is right that Shallow on Foam
# measures 1.26 and cannot be seen, and the dark spur is what holds the bar up
# across the white. The fix is one window, not one shape: the lanes are clipped
# to the PLAIN squircle and the bar and the spur are left exactly as they are.
# Every row below is drawn that way, the baseline included, and shipping it is
# the same one word change in `gen10.figure`.


def lanewindow(sp):
    """What a lane is cut by: the panel WITHOUT its spur.

    The one line the correction lives in. `sp["panel"]` is the squircle with
    the spur already unioned on, and clipping a lane to that is what lets it
    ride out over the margin.
    """
    return sp["plain"]


def document(sp, mark=None, lanes=None, panel=None, ground=None,
             markkeys=None, bleedkeys=None, panelkeys=None, groundkeys=None):
    """The four groups, back to front, each a list of layers.

    Defaults are the shipped drawing with the leaving edge corrected, so a
    variation states what it changes rather than restating the whole icon.
    """
    p = sp["panel"]
    mark = mark if mark is not None else [layer("Mark", sp["bar"](sheen("shallow")))]
    if lanes is None:
        lanes = [layer("Bleed", clipped(sp["a"](sheen("spatie"))
                                        + sp["b"](sheen("current")),
                                        lanewindow(sp)))]
    panel = panel if panel is not None else [layer("Panel", p(flat("deep")))]
    ground = ground if ground is not None else [layer("Ground", fullbleed(flat("foam")))]
    return [("Mark", mark, markkeys or MARK),
            ("Bleed", lanes, bleedkeys or BLEED),
            ("Panel", panel, panelkeys or PANEL),
            ("Ground", ground, groundkeys or GROUND)]


def split_lanes(sp, afill=None, bfill=None, aop=None, bop=None, blend=None):
    """The Bleed group as two layers, so each lane can be lit on its own."""
    p = lanewindow(sp)
    return [layer("Current", clipped(sp["b"](sheen("current")), p), bfill, bop, blend),
            layer("Spatie", clipped(sp["a"](sheen("spatie")), p), afill, aop, blend)]


def cut(sp, body):
    """A lane drawing, cut at the panel boundary, for the flat file.

    depth.base_flat clips whatever it is handed to the panel WITH the spur, so
    the correction is applied before it is handed over. Clipping twice to a
    shape and to a superset of it is the same as clipping once, so nothing else
    in that function has to know.
    """
    return clipped(body, lanewindow(sp))


# ------------------------------------------------------------------ the ten
#
# Each returns (groups, flat body). `small` is threaded through because every
# helper in lib.py answers to lib.SMALL.
def v00_current(small=False):
    """The shipped icon, unchanged, so every other row has something to be
    compared against rather than remembered against."""
    sp = shapes(small)
    return document(sp), base_flat(sp, lanes=cut(sp, sp["a"](sheen("spatie"))
                                               + sp["b"](sheen("current"))))


def v01_sheet(small=False):
    """One grade across the whole tile, every piece on the same axis.

    The system's own `system-light` ground is #FFFFFF at the top and #ECECEC at
    the bottom, a drop of about eight percent of its own value over the canvas.
    This is that, applied to all four of our colours at once: one ramp from top
    to bottom, no orientation given, which is the document's default and Apple's
    default. Every piece is lighter where it is high on the tile and deeper
    where it is low, so the icon reads as one sheet under one light rather than
    as five separately lit shapes.

    The effect is entirely in the keys. The layered document's artwork is the
    shipped silhouettes with their colours thrown away; the flat file gets the
    same two stops as an SVG gradient over the same canvas coordinates.
    """
    sp, w = shapes(small), where(small)
    up, dn = 0.085, 0.085
    lanes = split_lanes(sp, afill=fill("spatie", up, dn), bfill=fill("current", up, dn))
    groups = document(
        sp,
        mark=[layer("Mark", sp["bar"]("#000"), fill("shallow", up, dn))],
        lanes=lanes,
        panel=[layer("Panel", sp["panel"]("#000"), fill("deep", up, dn))],
        ground=[layer("Ground", fullbleed("#000"), fill("foam", up, dn))])
    g = lambda c: paint(c, up, dn, 0, 1024)  # noqa: E731
    body = base_flat(
        sp,
        lanes=cut(sp, sp["a"](g("spatie")) + sp["b"](g("current"))),
        bar=sp["bar"](g("shallow")),
        after_panel=sp["panel"](g("deep")))
    return groups, fullbleed(g("foam")) + body[len(fullbleed(flat("foam"))):]


def v02_piece(small=False):
    """Numbers' move: every piece graded across its own height.

    The ramp is confined to the piece rather than to the tile, so the bar is
    light at its own top edge and deep at its own bottom edge wherever it lies,
    and so is each lane, and so is the panel. Against 01 this is the difference
    between a sheet of paper held under a lamp and four solid objects each
    catching the same light.

    The layered document says it with one `orientation` per layer, which is the
    key Apple uses and the only reason a per piece grade is expressible at all;
    the flat file says it with the same two canvas coordinates.
    """
    sp, w = shapes(small), where(small)
    up, dn = 0.14, 0.11
    lanes = split_lanes(sp,
                        afill=fill("spatie", up, dn, *w["a"]),
                        bfill=fill("current", up, dn, *w["b"]))
    groups = document(
        sp,
        mark=[layer("Mark", sp["bar"]("#000"), fill("shallow", up, dn, *w["bar"]))],
        lanes=lanes,
        panel=[layer("Panel", sp["panel"]("#000"), fill("deep", up, dn, *w["panel"]))],
        ground=[layer("Ground", fullbleed("#000"), fill("foam", up, dn, *w["ground"]))])
    body = base_flat(
        sp,
        lanes=cut(sp, sp["a"](paint("spatie", up, dn, *w["a"]))
                  + sp["b"](paint("current", up, dn, *w["b"]))),
        bar=sp["bar"](paint("shallow", up, dn, *w["bar"])),
        after_panel=sp["panel"](paint("deep", up, dn, *w["panel"])))
    return groups, fullbleed(paint("foam", up, dn, *w["ground"])) + body[len(fullbleed(flat("foam"))):]


def v03_crest(small=False):
    """The grade compressed into the top seventh of each piece.

    Apple stops a ramp early twice in the four icons read here, at seven tenths
    of the shape. Pushed to a seventh it stops being a grade at all: what shows
    is a tight bright band along the upper edge with flat palette colour under
    it, which is the lit crown the reference icons actually have and which a
    full height wash never quite becomes.

    It also costs less contrast than 02, because the body of every piece stays
    at its palette value instead of being darkened toward the bottom, and that
    is what lets it survive at 32 where 02 starts to look merely paler.
    """
    sp, w = shapes(small), where(small)
    up = 0.30
    lanes = split_lanes(sp,
                        afill=fill("spatie", up, 0, *crest(*w["a"])),
                        bfill=fill("current", up, 0, *crest(*w["b"])))
    groups = document(
        sp,
        mark=[layer("Mark", sp["bar"]("#000"), fill("shallow", up, 0, *crest(*w["bar"])))],
        lanes=lanes,
        panel=[layer("Panel", sp["panel"]("#000"), fill("deep", up, 0, *crest(*w["panel"], at=0.09)))],
        ground=[layer("Ground", fullbleed("#000"), fill("foam", 0.05, 0.05))])
    body = base_flat(
        sp,
        lanes=cut(sp, sp["a"](paint("spatie", up, 0, *crest(*w["a"])))
                  + sp["b"](paint("current", up, 0, *crest(*w["b"])))),
        bar=sp["bar"](paint("shallow", up, 0, *crest(*w["bar"]))),
        after_panel=sp["panel"](paint("deep", up, 0, *crest(*w["panel"], at=0.09))))
    return groups, (fullbleed(paint("foam", 0.05, 0.05, 0, 1024))
                    + body[len(fullbleed(flat("foam"))):])


def v04_rim(small=False):
    """A rim light on the upper edge and a soft shade on the lower one.

    Thickness without an outline: a bright hairline inside the top of the panel
    and of the bar, and a soft dark band inside the bottom of each. Nothing is
    added around a shape, which is what would have been a border; both bands
    are clipped INSIDE the piece, so no silhouette changes by a pixel.

    Split, and finding 7 is the reason. A soft edge in this codebase is a
    Gaussian blur inside a clip, and the layered document's renderer throws
    blurs away, which turns the hairline into a slab and floods the panel. So
    the layered side says rim the only way it can be said in keys: a ramp
    across the top twentieth of each piece, which is finding 3 pushed as far as
    it will go, plus the system's own specular turned on for every group so the
    material draws the edge it is better at drawing than we are. The flat file,
    which rsvg blurs correctly, bakes the real thing.
    """
    sp, w = shapes(small), where(small)
    p, c = sp["panel"], sp["bar"]

    def rims(k):
        return (inner(p, (0, 13 * S), 5 * S, 0.50 * k, "#FFFFFF")
                + inner(p, (0, -20 * S), 18 * S, 0.34 * k, "#000814")
                + inner(c, (0, 11 * S), 4 * S, 0.62 * k, "#FFFFFF")
                + inner(c, (0, -17 * S), 14 * S, 0.30 * k, lib.C["fathom"]))
    lanes = split_lanes(sp,
                        afill=fill("spatie", 0.26, 0, *crest(*w["a"], at=0.06)),
                        bfill=fill("current", 0.26, 0, *crest(*w["b"], at=0.06)))
    groups = document(
        sp,
        mark=[layer("Mark", c("#000"), fill("shallow", 0.30, 0, *crest(*w["bar"], at=0.06)))],
        lanes=lanes,
        panel=[layer("Panel", p("#000"), fill("deep", 0.34, 0, *crest(*w["panel"], at=0.05)))],
        markkeys=groupkeys(shadow=0.5, specular=True),
        bleedkeys=groupkeys(specular=True),
        panelkeys=groupkeys(shadow=0.55, specular=True),
        groundkeys=groupkeys(specular=True))
    return groups, base_flat(sp, lanes=cut(sp, sp["a"](sheen("spatie"))
                                           + sp["b"](sheen("current"))),
                             after_bar=rims(1.0))


def v05_glass(small=False):
    """The bar as glass: the panel reads through it.

    The one effect in the set that the system does better than paint can. The
    Mark group is given the document's own translucency key, and macOS frosts
    the bar in place: the Deep panel and both lanes show through it, the
    crossing becomes a blend rather than an occlusion, and the bar keeps a hard
    bright lip where it meets the light. It is one key, it survives the dark and
    the tinted variants, and it costs nothing at any size.

    Split, and honestly so. The flat file cannot ask for a material, so it bakes
    an alpha of 0.86 with a solid lip along the top edge, which is a picture of
    the effect rather than the effect.
    """
    sp = shapes(small)
    c = sp["bar"]
    groups = document(sp, markkeys=groupkeys(shadow=0.5, specular=True,
                                             translucency=0.5))
    lip = inner(c, (0, 10 * S), 3 * S, 0.75, "#FFFFFF")
    return groups, base_flat(sp, lanes=cut(sp, sp["a"](sheen("spatie"))
                                           + sp["b"](sheen("current"))),
                             bar='<g opacity="0.86">%s</g>' % c(sheen("shallow")),
                             after_bar=lip)


def v06_wash(small=False):
    """Photos' move: the lanes translucent, so the crossings blend.

    Photos is built entirely on overlap. Eight petals, every one of them alpha
    0.80 in the dark appearance, and every overlap a mixed colour rather than
    the top petal winning. Our design has two overlaps and currently loses both:
    the bar covers each lane outright and the crossing, which is the whole
    subject of the mark, is drawn as an occlusion.

    Here the Bleed group is translucent, so where a lane runs under the bar the
    Deep panel tints it and the lane darkens through the crossing instead of
    stopping at it. The layered document asks for the material; the flat file
    bakes the nearest alpha it can.
    """
    sp = shapes(small)
    p = sp["panel"]
    groups = document(sp, bleedkeys=groupkeys(translucency=0.55))
    lanes = cut(sp, '<g opacity="0.82">%s</g>'
                % (sp["a"](sheen("spatie")) + sp["b"](sheen("current"))))
    return groups, base_flat(sp, lanes=lanes)


def v07_seat(small=False):
    """A soft shading inside the bottom of every piece, so each one seats.

    The quietest of the reference effects and the one that does the most work:
    a shape with a little shadow gathered inside its own lower edge stops
    floating on what is behind it and starts resting in it. Apple has it under
    every Photos petal and along the bottom of the Find My rings.

    03 turned upside down. Where the crest puts the whole ramp in the top
    seventh and lets everything under it clamp to the palette colour, this puts
    the ramp in the bottom fifth and lets everything above it clamp there
    instead, so the piece is its own colour until it nears its base and then
    deepens into it. Same key, same one gradient per piece, opposite end.

    Split for the same reason as 04. The flat file bakes real blurred inner
    shadows, which is a better picture of the effect than a ramp; the layered
    document cannot have them, and the ramp is what it can have.
    """
    sp, w = shapes(small), where(small)
    p, c = sp["panel"], sp["bar"]
    a, b = sp["a"], sp["b"]

    def base(y0, y1, at=0.20):
        """The ramp at the BOTTOM of a piece rather than at the top."""
        return y1 - (y1 - y0) * at, y1

    def seats(k):
        return (inner(p, (0, -26 * S), 22 * S, 0.42 * k, "#000814")
                + inner(c, (0, -20 * S), 15 * S, 0.34 * k, lib.C["fathom"])
                + cut(sp, inner(a, (0, -16 * S), 12 * S, 0.30 * k, lib.C["abyss"])
                      + inner(b, (0, -16 * S), 12 * S, 0.30 * k, lib.C["abyss"])))
    lanes = split_lanes(sp,
                        afill=fill("spatie", 0, 0.24, *base(*w["a"], at=0.26)),
                        bfill=fill("current", 0, 0.24, *base(*w["b"], at=0.26)))
    groups = document(
        sp,
        mark=[layer("Mark", c("#000"), fill("shallow", 0, 0.20, *base(*w["bar"], at=0.26)))],
        lanes=lanes,
        panel=[layer("Panel", p("#000"), fill("deep", 0, 0.34, *base(*w["panel"], at=0.18)))])
    return groups, base_flat(sp, lanes=cut(sp, sp["a"](sheen("spatie"))
                                           + sp["b"](sheen("current"))),
                             after_bar=seats(1.0))


def v08_lit(small=False):
    """No paint at all. The system's own material, turned all the way up.

    The shipped document asks for a specular on the Mark group and nowhere
    else, and gives Panel 0.55 against Mark 0.50, which tells the system the bar
    is no higher than the panel it lies on. Here every group is lit, the ladder
    is real, and not one pixel of artwork is touched. On macOS 26 that is the
    cheapest shine available and it cannot go muddy, because there is nothing
    baked for the system's pass to be drawn on top of.

    The flat `.icns` has no such key and gets the only thing paint can say in
    its place: the same contacts, opened up.
    """
    sp = shapes(small)
    groups = document(
        sp,
        markkeys=groupkeys(shadow=0.85, specular=True),
        bleedkeys=groupkeys(shadow=0.30, specular=True),
        panelkeys=groupkeys(shadow=0.42, specular=True),
        groundkeys=groupkeys(specular=True))
    return groups, base_flat(sp, lanes=cut(sp, sp["a"](sheen("spatie"))
                                           + sp["b"](sheen("current"))),
                             seat=1.45)


def v09_liquid(small=False):
    """One ramp doing crown and base at once, on the panel and nothing else.

    Finding 8 in one row. The gradient is placed so that the panel's top eighth
    is above its start and clamps to the lighter stop, and its bottom third is
    below its stop and clamps to the deeper one, with the ramp travelling
    between them. That reads as a lit crown fading into a seated base out of a
    single two stop fill, which is the most a layered piece can be given and
    still be given it cleanly.

    Everything else on the tile is left exactly as it ships. The row exists to
    find out how much of the shine the largest shape can carry alone, because
    every painted effect on the bar is a liability at 16 points and this one
    puts nothing on the bar at all.

    Split. The layered document takes the ramp as a key and the system's own
    specular on top of it; the flat file takes the same ramp as an SVG gradient
    and then bakes the blurred rim and seating the layered side cannot have.
    """
    sp, w = shapes(small), where(small)
    p = sp["panel"]
    top, bot = w["panel"]
    ramp = (top + (bot - top) * 0.10, top + (bot - top) * 0.66)
    groups = document(
        sp,
        panel=[layer("Panel", p("#000"), fill("deep", 0.26, 0.20, *ramp))],
        panelkeys=groupkeys(shadow=0.55, specular=True))
    body = base_flat(
        sp,
        lanes=cut(sp, sp["a"](sheen("spatie")) + sp["b"](sheen("current"))),
        after_panel=(p(paint("deep", 0.26, 0.20, *ramp))
                     + inner(p, (0, 13 * S), 5 * S, 0.52, "#FFFFFF")
                     + inner(p, (0, -26 * S), 22 * S, 0.44, "#000814")))
    return groups, body


def v10_shine(small=False):
    """The stack, at the dose each part survives at.

    Every piece gets 09's single ramp, placed to give a crown at its top and a
    seated base at its bottom, at two thirds of 09's strength. The bar gets 05's
    translucency as a key on top of that, so the panel reads through it and the
    crossing becomes a blend. The shadow ladder is 08's, softened. The layered
    document is therefore ALL KEYS AND NO PAINT, which is the only version of
    this that cannot go muddy under the system's own pass.

    The flat file, which has no keys at all, bakes the same ramps as SVG
    gradients and adds the rim and the seating it is allowed to blur. Split,
    and the two columns on the page are the honest picture of how far apart
    the two outputs have to be.
    """
    sp, w = shapes(small), where(small)
    p, c = sp["panel"], sp["bar"]

    def ramp(y0, y1, a=0.12, b=0.66):
        return y0 + (y1 - y0) * a, y0 + (y1 - y0) * b
    lanes = split_lanes(sp,
                        afill=fill("spatie", 0.16, 0.12, *ramp(*w["a"])),
                        bfill=fill("current", 0.16, 0.12, *ramp(*w["b"])))
    groups = document(
        sp,
        mark=[layer("Mark", c("#000"), fill("shallow", 0.20, 0.10, *ramp(*w["bar"], a=0.16)))],
        lanes=lanes,
        panel=[layer("Panel", p("#000"), fill("deep", 0.20, 0.14, *ramp(*w["panel"], a=0.10)))],
        ground=[layer("Ground", fullbleed("#000"), fill("foam", 0.05, 0.05))],
        markkeys=groupkeys(shadow=0.72, specular=True, translucency=0.34),
        bleedkeys=groupkeys(shadow=0.26, specular=True),
        panelkeys=groupkeys(shadow=0.46, specular=True),
        groundkeys=groupkeys(specular=True))
    body = base_flat(
        sp,
        lanes=cut(sp, sp["a"](paint("spatie", 0.16, 0.12, *ramp(*w["a"])))
                  + sp["b"](paint("current", 0.16, 0.12, *ramp(*w["b"])))),
        bar=c(paint("shallow", 0.20, 0.10, *ramp(*w["bar"], a=0.16))),
        after_panel=(p(paint("deep", 0.20, 0.14, *ramp(*w["panel"], a=0.10)))
                     + inner(p, (0, -26 * S), 22 * S, 0.40, "#000814")),
        after_bar=(inner(c, (0, 11 * S), 4 * S, 0.34, "#FFFFFF")
                   + inner(c, (0, -17 * S), 14 * S, 0.22, lib.C["fathom"])))
    return groups, (fullbleed(paint("foam", 0.05, 0.05, 0, 1024))
                    + body[len(fullbleed(flat("foam"))):])


VARIANTS = [
    ("00-current", "the shipped icon, for comparison", "shipped", v00_current),
    ("01-sheet", "one vertical grade across the whole tile", "system", v01_sheet),
    ("02-piece", "each piece graded across its own height", "system", v02_piece),
    ("03-crest", "the grade compressed into the top seventh", "system", v03_crest),
    ("04-rim", "a lit upper edge and a shaded lower one", "split", v04_rim),
    ("05-glass", "the bar translucent, the panel reading through", "split", v05_glass),
    ("06-wash", "the lanes translucent, so the crossings blend", "split", v06_wash),
    ("07-seat", "a soft shading inside every lower edge", "split", v07_seat),
    ("08-lit", "no paint at all, the system's material turned up", "system", v08_lit),
    ("09-liquid", "one ramp, crown and base, on the panel alone", "split", v09_liquid),
    ("10-shine", "all of it, at the dose each part survives", "split", v10_shine),
]


# ---------------------------------------------------------------- rendering
def render(fn, small=False):
    """The groups, the full bleed composite, and the composite at the Big Sur
    template. Same contract as gen10.render, with groups in place of layers."""
    lib.SMALL = small
    lib.reset()
    groups, body = fn(small)
    return groups, wrap_flat(body), wrap_legacy(body)


SWIFT = r'''import AppKit

// Renders the icon macOS itself draws for a bundle, at one size, to a PNG.
// This is the whole point of the file: the layered column on the page is what
// Icon Services composites, not an approximation of it.
let a = CommandLine.arguments
guard a.count >= 4 else { fputs("usage: rendericon <app> <size> <out.png> [dark]\n", stderr); exit(2) }
let path = a[1], size = Int(a[2])!, out = a[3]
let dark = a.count > 4 && a[4] == "dark"
let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
var img: NSImage!
appearance.performAsCurrentDrawingAppearance { img = NSWorkspace.shared.icon(forFile: path) }
img.size = NSSize(width: size, height: size)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: size, height: size)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high
img.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
'''


def renderer():
    """The little Swift tool above, compiled on demand into `.build`."""
    exe = os.path.join(BUILD, "rendericon")
    src = exe + ".swift"
    os.makedirs(BUILD, exist_ok=True)
    if not os.path.exists(src) or open(src).read() != SWIFT:
        with open(src, "w") as f:
            f.write(SWIFT)
        if os.path.exists(exe):
            os.remove(exe)
    if not os.path.exists(exe):
        subprocess.run(["xcrun", "swiftc", "-O", "-o", exe, src], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return exe


def systemshots(name, groups, sizes):
    """Write the variation as a real `.icon`, compile it the way build.sh does,
    and ask macOS to draw it at each size.

    Everything lands in `Tools/icon/.build/shine/<name>`, which is ignored, and
    the throwaway bundle has an identifier of its own so Icon Services cannot
    serve one variation's pixels for another's.
    """
    w = os.path.join(BUILD, name)
    shutil.rmtree(w, ignore_errors=True)
    assets = os.path.join(w, "S.icon", "Assets")
    os.makedirs(assets)

    doc = {"fill": "automatic", "groups": []}
    for gname, layers, keys in groups:
        entry = {"layers": []}
        for i, l in enumerate(layers):
            fn = "%s-%d.svg" % (l["name"].lower(), i)
            with open(os.path.join(assets, fn), "w") as f:
                f.write(wrap_layer(l["body"]))
            item = {"image-name": fn, "name": l["name"]}
            for k in ("fill", "opacity", "blend-mode", "specular"):
                if k in l:
                    item[k] = l[k]
            entry["layers"].append(item)
        entry.update(keys)
        doc["groups"].append(entry)
    with open(os.path.join(w, "S.icon", "icon.json"), "w") as f:
        json.dump(doc, f, indent=1)

    out = os.path.join(w, "out")
    os.makedirs(out)
    r = subprocess.run(
        ["xcrun", "actool", os.path.join(w, "S.icon"), "--compile", out,
         "--app-icon", "S", "--output-partial-info-plist", os.path.join(w, "p.plist"),
         "--platform", "macosx", "--target-device", "mac",
         "--minimum-deployment-target", "15.0", "--errors", "--warnings"],
        capture_output=True, text=True)
    car = os.path.join(out, "Assets.car")
    if not os.path.exists(car):
        # actool reports failure in the plist it prints and is not reliably non
        # zero about it, so the file's absence is the only honest test.
        sys.stderr.write(r.stdout[:2000] + "\n")
        raise SystemExit("shine: actool produced no Assets.car for " + name)

    app = os.path.join(w, "S.app", "Contents")
    os.makedirs(os.path.join(app, "MacOS"))
    os.makedirs(os.path.join(app, "Resources"))
    shutil.copy(car, os.path.join(app, "Resources", "Assets.car"))
    with open(os.path.join(app, "Info.plist"), "w") as f:
        f.write('<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC '
                '"-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/'
                'PropertyList-1.0.dtd"><plist version="1.0"><dict>'
                '<key>CFBundleExecutable</key><string>S</string>'
                '<key>CFBundleIdentifier</key><string>be.spatie.bloom.shine.%s</string>'
                '<key>CFBundleName</key><string>S</string>'
                '<key>CFBundlePackageType</key><string>APPL</string>'
                '<key>CFBundleIconName</key><string>S</string>'
                '<key>LSMinimumSystemVersion</key><string>15.0</string>'
                '</dict></plist>' % name.replace("-", ""))
    ex = os.path.join(app, "MacOS", "S")
    with open(ex, "w") as f:
        f.write("#!/bin/sh\n")
    os.chmod(ex, 0o755)

    exe = renderer()
    shots = {}
    for size in sizes:
        png = os.path.join(w, "%d.png" % size)
        subprocess.run([exe, os.path.join(w, "S.app"), str(size), png], check=True)
        shots[size] = png
    return shots


# ------------------------------------------------------------------- sheet
SIZES = [1024, 512, 256, 128, 64, 32, 16]


def datauri(path):
    with open(path, "rb") as f:
        return "data:image/png;base64," + base64.b64encode(f.read()).decode()


CSS = depth.CSS + """
.tag.shipped { border-color: #4A5560; color: #8E9AA3; }
.real { color: #4FD8C4; }
.apple { border-top: 1px solid #262B31; padding: 34px 40px 10px; max-width: 1240px; }
.apple h2 { font-size: 21px; margin: 0 0 10px; }
.apple p { color: #9AA7B0; max-width: 88ch; }
.apple dl { color: #9AA7B0; max-width: 88ch; }
.apple dt { color: #9BE9DC; font: 12px ui-monospace, Menlo, monospace;
  margin-top: 12px; }
.apple dd { margin: 3px 0 0; }
"""

HEAD = """<header><h1>Bloom, ten shine studies</h1>
<p>The design does not change and neither does the palette. Foam ground, Deep
panel with its spur, two lanes, the pale bar riding inside the spur, the same
silhouette, no border added anywhere. What changes in each row is how light
behaves on it: a gradient inside a shape, a gloss along its upper edge, a
translucency where two shapes overlap, a shading gathered inside a lower edge.
Every gradient is centred on the colour it grades, lighter above and deeper
below by the same amount, so a piece's average tone is the palette entry it
started as.</p>
<p><span class="real">The left hand column is not a simulation.</span> Each row
is written out as a real <code>.icon</code> bundle, compiled with
<code>actool</code> exactly the way <code>build.sh</code> compiles the shipped
one, and handed to Icon Services, which composites it with the system's own
material, shadow and specular and gives back the pixels Finder would show. The
previous sheet had to guess at that pass. This one photographs it.</p>
<p>On the right the flat <code>.icns</code>, which nothing helps, drawn to the
Big Sur template at 824 inside 1024 because the app still runs on macOS 15.
That is why the right hand icon sits smaller in its square, and why several
rows are marked <strong>split</strong>: an effect the system will produce from
one key has to be painted by hand on that side, and the two drawings are not
the same picture.</p>
<p>The big pair is the 1024 render on a light ground and a dark one. The strips
under it are ACTUAL SIZE at 16, 32, 64, 128, 256 and 512, smallest first. All
of it comes from the same framed artwork at every size, which is what the
layered document really does; the shipped <code>.icns</code> swaps in the
unframed drawing below 64 and that swap is deliberately left out here, so each
row shows what its own light is worth as it shrinks.</p>
</header>"""

APPLE = """<section class="apple"><h2>What Apple's own icons turned out to
contain</h2>
<p>Read out of the layered documents themselves. The four macOS 26 icons live
in <code>Assets.car</code> inside each app and <code>assetutil --info</code>
prints every key in them, so none of this is off a screenshot.</p>
<dl>
<dt>Numbers has no layered icon at all</dt>
<dd>Its <code>Assets.car</code> carries no icon stack. The app still ships a
flat <code>.icns</code> and everything glassy about it on this machine is the
system's material applied to a legacy bitmap. The icon pointed at as the
clearest case of a graded shape has no gradient in it.</dd>
<dt>A layer's fill is a key, and the artwork under it is a silhouette</dt>
<dd>Apple's layers carry <code>LayerGradientColorName</code>; the SVG's own
colours are discarded. Verified here by giving a layer a fill and watching the
drawing turn into a mask.</dd>
<dt>Every gradient in all four is vertical, two stops, no exceptions</dt>
<dd><code>0.500,0.000 - 0.500,1.000</code>. Not one diagonal and not one
radial. The renderer says as much itself: <em>radial gradients are not
supported</em>.</dd>
<dt>The ramp often stops early</dt>
<dd><code>0.500,0.000 - 0.500,0.700</code> appears in Photos and in Find My:
the grade completes seven tenths of the way down and the rest is flat. Pushed
further up it becomes a lit crown rather than a wash, which is what row 03 is
built on.</dd>
<dt>The system's own ground is a gradient</dt>
<dd><code>system-light</code> is #FFFFFF to #ECECEC, top to bottom.
<code>system-dark</code> is 19.2 percent grey to 7.8 percent. A near white
ground graded by about eight percent of its own value is exactly what the
system would have drawn for us, which is row 01.</dd>
<dt>Translucency lives in the colour and in the key, and Apple uses both</dt>
<dd>Photos' petals are alpha 0.80 in the dark appearance and opaque in the
light one. Find My's radar ramps #61A6FF at alpha 0.40 down to #0087FF at alpha
0.84, and its back circle is <code>Multiply</code>. Every overlap is a blend
and never an occlusion.</dd>
<dt>Lighting is per layer and on by default</dt>
<dd><code>LayerHasLightingEffects</code> is true on every shape layer in all
four and false on the details Maps draws over its own puck. Our document asks
for it on the Mark group and nowhere else, which is row 08.</dd>
</dl></section>"""


def sheet(outdir):
    """The page. Every picture is embedded once as a CSS rule and used by
    class, because each appears twice, on the light ground and the dark one."""
    os.makedirs(outdir, exist_ok=True)
    pngs = os.path.join(outdir, "png")
    os.makedirs(pngs, exist_ok=True)

    rules, cards, seen = [], [], {}
    for name, blurb, wherekey, fn in VARIANTS:
        groups, _, legacy = render(fn, False)
        shots = systemshots(name, groups, SIZES)
        cols = []
        for label, key_, source in (
                ("layered document, drawn by macOS itself", "L", shots),
                ("flat .icns, the Big Sur body at 824 in 1024", "F", legacy)):
            cls = {}
            for size in SIZES:
                c = "i%s%s%d" % (name.split("-")[0], key_, size)
                if key_ == "L":
                    uri = datauri(source[size])
                else:
                    p = os.path.join(pngs, "%s-F-%d.png" % (name, size))
                    uri = depth.png(source, size, p)
                rules.append(".%s{background-image:url(%s)}" % (c, uri))
                cls[size] = c
                seen[(name, key_, size)] = c
            small = "".join(
                '<div class="sz"><i class="%s" style="width:%dpx;height:%dpx">'
                '</i><span>%d</span></div>' % (cls[s], s, s, s)
                for s in sorted(SIZES[1:]))
            cols.append(
                '<div class="col"><h3>%s</h3><div class="bigs">'
                '<div class="big light"><i class="%s"></i></div>'
                '<div class="big dark"><i class="%s"></i></div></div>'
                '<div class="strip light">%s</div>'
                '<div class="strip dark">%s</div></div>'
                % (label, cls[1024], cls[1024], small, small))
        cards.append(
            '<section class="card"><div class="hd"><span class="num">%s</span>'
            '<h2>%s</h2><span class="tag %s">effect lives: %s</span>'
            '<span class="blurb">%s</span></div><p class="note">%s</p>'
            '<div class="cols">%s</div></section>'
            % (name.split("-")[0], name.split("-", 1)[1], wherekey, wherekey,
               blurb, NOTE[name], "".join(cols)))

    grid = depth.grids(seen, variants=VARIANTS,
                       title="All eleven at the sizes that decide it",
                       note="A gloss either survives being made small or turns "
                            "to mud, and this is where that is settled. Each "
                            "row is one size, every variation in the same order "
                            "as above, actual size on top and the same pixels "
                            "magnified underneath. If two cells in a row look "
                            "the same, that variation is buying nothing at that "
                            "size.",
                       labels=(("L", "layered document, drawn by macOS itself"),
                               ("F", "flat .icns")))

    html = ("<!doctype html><meta charset=utf-8><title>Bloom icon, ten shine "
            "studies</title><style>%s\n%s</style>%s%s%s%s%s"
            % (CSS, "".join(rules), HEAD, APPLE, "".join(cards), grid, VERDICT))
    out = os.path.join(outdir, "shine.html")
    with open(out, "w") as f:
        f.write(html)
    return out, sheet1024(outdir)


# ------------------------------------------------------------ the short one
#
# The full sheet is long on purpose: an icon is judged at 16 points and the
# strips are where that is settled. But comparing eleven IDEAS means holding
# eleven pictures in the eye at once, and no amount of scrolling does that. So
# there is a second page with the 1024 renders and nothing else, laid out to
# fit, the shipped drawing among them so the row has a baseline in it.
GRID1024 = """
body { margin: 0; background: #16181C; color: #E8EDF0;
  font: 15px/1.6 ui-sans-serif, -apple-system, "SF Pro Text", system-ui, sans-serif; }
* { box-sizing: border-box; }
header { padding: 40px 40px 18px; max-width: 96ch; }
h1 { font-size: 28px; margin: 0 0 12px; letter-spacing: -0.01em; }
header p { color: #9AA7B0; margin: 0 0 10px; }
code { font: 13px ui-monospace, "SF Mono", Menlo, monospace; color: #9BE9DC; }
.wrap { display: grid; gap: 22px; padding: 10px 40px 60px;
  grid-template-columns: repeat(auto-fill, minmax(260px, 1fr)); }
.t { background: #EDEDED; border-radius: 18px; padding: 16px 16px 12px; }
.t.d { background: #1C1C1E; }
.t img { display: block; width: 100%; height: auto; border-radius: 4px; }
.cap { display: flex; align-items: baseline; gap: 8px; margin-top: 10px; }
.cap b { font: 13px ui-monospace, Menlo, monospace; font-weight: 600; }
.t .cap b { color: #22262B; }
.t.d .cap b { color: #E8EDF0; }
.cap span { font-size: 11px; letter-spacing: 0.06em; text-transform: uppercase; }
.t .cap span { color: #6E7C86; }
.t.d .cap span { color: #7E8B94; }
.cap em { font-style: normal; font-size: 12px; }
.t .cap em { color: #5C6872; }
.t.d .cap em { color: #7E8B94; }
.pair { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; }
.grounds { padding: 0 40px; color: #6E7C86; font-size: 12px;
  letter-spacing: 0.06em; text-transform: uppercase; }
"""


def sheet1024(outdir):
    """The same eleven, at 1024, and nothing else on the page.

    Each tile carries the layered render on a light ground and on a dark one,
    because a near white icon on a near white page is not a fair look at it.
    Everything is embedded, so the file can be moved anywhere.
    """
    tiles = []
    for name, blurb, wherekey, fn in VARIANTS:
        png = os.path.join(BUILD, name, "1024.png")
        if not os.path.exists(png):
            groups, _, _ = render(fn, False)
            png = systemshots(name, groups, [1024])[1024]
        uri = datauri(png)
        cap = ('<div class="cap"><b>%s</b><span>%s</span></div>'
               '<div class="cap"><em>%s</em></div>'
               % (name, wherekey, blurb))
        tiles.append('<div class="pair"><div class="t"><img src="%s"></div>'
                     '<div class="t d"><img src="%s"></div></div>%s'
                     % (uri, uri, cap))
    html = ('<!doctype html><meta charset=utf-8><title>Bloom icon, ten shine '
            'studies at 1024</title><style>%s</style>'
            '<header><h1>Bloom, ten shine studies at 1024</h1>'
            '<p>The eleven ideas at full size and nothing else, for comparing '
            'them against each other rather than against the sizes they have '
            'to survive. Every tile is the layered <code>.icon</code> as macOS '
            'itself composites it, on a light ground and a dark one. '
            '<code>00-current</code> is the shipped drawing and is the '
            'baseline in the row.</p>'
            '<p>The design, the palette and the silhouette are the same in all '
            'eleven. One thing IS corrected in every tile including the '
            'baseline: at the leaving edge the mid teal lane no longer rides '
            'out over the Foam margin alongside the bar. The dark spur stays, '
            'because a pale bar on a near white margin cannot be seen without '
            'it; only the pale bar and the dark spur cross the edge now. The '
            'long sheet says how.</p>'
            '<p>The strips at 512 down to 16, the flat <code>.icns</code> '
            'column and the verdict are on the long sheet.</p></header>'
            '<div class="wrap">%s</div>'
            % (GRID1024, "".join('<div>%s</div>' % t for t in tiles)))
    out = os.path.join(outdir, "shine-1024.html")
    with open(out, "w") as f:
        f.write(html)
    return out


NOTE = {
    "00-current": (
        "Foam ground, Deep panel with its spur, two lanes, the pale bar riding "
        "inside the spur. Flat colour with a barely visible sheen, contact "
        "shadows baked into the flat file, one specular key on the Mark group."),
    "01-sheet": (
        "Every piece graded on one axis running the whole canvas, lighter at "
        "the top and deeper at the bottom by about eight percent of its own "
        "value, which is the drop the system's own ground uses. The effect "
        "lives in the keys: four <code>linear-gradient</code> fills and no "
        "paint."),
    "02-piece": (
        "The same grade, confined to each piece rather than to the tile, so "
        "the bar is light at its own top edge wherever it lies and so is each "
        "lane. One <code>orientation</code> per layer, set from that piece's "
        "own top and bottom on the canvas."),
    "03-crest": (
        "The ramp told to finish a seventh of the way down each piece, so what "
        "shows is a tight bright band on the upper edge with flat palette "
        "colour under it. Apple's early stop, pushed further up. The body of "
        "every piece keeps its palette value, which is why this one holds "
        "further down than 02."),
    "04-rim": (
        "The flat file bakes the real thing: a bright hairline inside the top "
        "of the panel and of the bar and a soft dark band inside the bottom of "
        "each, both clipped INSIDE the piece so nothing is added around a shape "
        "and no silhouette moves. The layered document cannot have it, because "
        "its renderer throws blurs away, so it says rim in keys instead: a ramp "
        "across the top twentieth of every piece and the system\u2019s own specular "
        "turned on for all four groups."),
    "05-glass": (
        "One key. The Mark group is given the document's translucency and "
        "macOS frosts the bar in place, so the panel and both lanes read "
        "through it and the crossing becomes a blend. The flat file bakes an "
        "alpha of 0.86 with a solid lip, which is a picture of the effect "
        "rather than the effect."),
    "06-wash": (
        "Photos' whole construction: the Bleed group translucent, so where a "
        "lane runs under the bar it is tinted by the Deep panel and darkens "
        "through the crossing instead of stopping at it. Layered asks for the "
        "material, flat bakes the nearest alpha."),
    "07-seat": (
        "03 upside down. The ramp sits in the bottom fifth of each piece and "
        "everything above it clamps to the palette colour, so a piece is its "
        "own tone until it nears its base and then deepens into it. The flat "
        "file bakes real blurred inner shadows instead, which is a better "
        "picture of the same idea than a ramp is."),
    "08-lit": (
        "No paint whatsoever. Every group lit, and the shadow ladder made "
        "real: Ground 0, Panel 0.42, Bleed 0.30, Mark 0.85, against the "
        "shipped 0.55 and 0.50 that tell the system the bar is no higher than "
        "the panel it lies on."),
    "09-liquid": (
        "One ramp placed so the panel\u2019s top tenth is above its start and clamps "
        "light, its bottom third is below its stop and clamps deep, and the "
        "grade travels between them: a lit crown fading into a seated base out "
        "of a single two stop fill. Nothing else on the tile is touched, so "
        "nothing it does can damage the bar at 16 points."),
    "10-shine": (
        "09's ramp on every piece at two thirds strength, 05's translucency on "
        "the bar as a key, and 08's shadow ladder softened. The layered "
        "document is all keys and no paint, which is the only version of this "
        "that cannot go muddy under the system\u2019s own pass; the flat file bakes "
        "the same ramps and adds the rim and seating it is allowed to blur."),
}

VERDICT = """
<section class="verdict"><h2>What I would ship</h2>
<p><strong>03-crest</strong>, and if the taste for it runs further,
<strong>10-shine</strong>. 03 is the closest thing here to what the reference
icons actually do and it is almost free: four <code>linear-gradient</code> keys
with their ramps stopped near the top, no paint at all in the layered document,
and the same two canvas coordinates baked as an SVG gradient in the flat one.
Because the body of each piece keeps its palette value and only the upper
eighth is lifted, it costs no contrast anywhere, which is why it is still doing
something at 32 where the full height grades have gone quietly pale.</p>
<p><strong>Runners up.</strong> 05-glass is the most interesting single key in
the set and the one thing here that the system does better than paint ever
could: the bar frosts, the panel reads through it, and the crossing stops being
an occlusion. It survives the dark and the tinted variants for free, which no
baked alpha does. 08-lit costs nothing and fixes a real bug in the shipped
document, which currently tells the system the bar is no higher than the panel.
02-piece is the honest Numbers reading and the best of the three gradient rows
at 512 and above.</p>
<p><strong>Honest about the small sizes.</strong> Judge these on the 64, 32 and
16 strips and on the grid, not on the 1024s.</p>
<ul>
<li><strong>02-piece goes pale.</strong> Grading a piece across its own height
means half of it is darker than the palette and half is lighter, and at 32 the
eye reads the average rather than the ramp. The bar in particular loses the
punch it needs against the Deep panel. Beautiful at 512, merely washed at
32.</li>
<li><strong>04-rim only works large.</strong> The bright hairline is five units
wide; at 64 that is under a third of a pixel and it is gone, and what remains
is the dark band at the bottom, which reads as a slightly thinner piece rather
than a rounder one. It is also the row that fights the system hardest, because
the system is already drawing a specular on precisely that edge.</li>
<li><strong>06-wash costs the crossing.</strong> The idea is right and it is
what Photos is built on, but our overlap is a pale bar over a dark lane rather
than two mid tones, so the blend darkens the bar instead of enriching it and by
64 the bar looks dirty rather than deep. Photos gets away with it because none
of its petals is near white.</li>
<li><strong>07-seat survives further than expected</strong> and is the only
baked row that does. At 32 the shading inside the panel's lower edge still
separates the panel from the margin. Keep it at the reduced dose 10 uses.</li>
<li><strong>09-liquid is the safe half of 10.</strong> Everything it does is on
the biggest shape on the tile, so nothing it does can damage the bar at 16.
If 10 turns out to be too much, this is what to fall back to.</li>
<li><strong>01-sheet is the least interesting and the most correct.</strong> It
is exactly what the system would have done to a ground it owned, so it never
looks wrong; it also never looks like much. Worth having under any of the
others rather than instead of them.</li>
</ul>
<p><strong>Nothing here changes the shipped icon.</strong> Every variation is a
function in <code>Tools/icon/shine.py</code>. Shipping one is pointing
<code>make.py</code> at it and taking the groups it asks for, which is one line
and one dictionary.</p>
</section>
"""


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, ".build",
                                                             "shinesheet")
    for path in sheet(out):
        print("==>", path)
