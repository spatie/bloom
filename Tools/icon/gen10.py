"""The ten of round ten.

Round nine took a white border away. This round puts one back, on purpose.

The border round nine removed was never designed. The artwork drew its own 824
tile inside the system's 1024, and the ring of bare system material left over
showed as a frame nobody had drawn. The fix was to go full bleed.

What is wanted now is the opposite thing that looks the same from a distance: a
margin we draw ourselves, in our own colour, with a piece of the figure lying
across it so it reads as a stack of layers rather than as artwork that stopped
short. Preview on macOS 26 does exactly this and the reason it works is the
lens: it straddles the inner panel's edge and lands on the white, so the white
is obviously a surface something sits on.

MEASURED OFF PREVIEW, at 512, tile 50..461:

  margin        62 of 411 per side, 15.1 percent of the tile. 154 units in our
                1024. That is generous. Round nine's plate was 68.
  inner panel   112..400 square, dead centre, 70 percent of the tile.
  panel radius  about 55 at 512, 137 in our 1024, on a 718 panel. A CONCENTRIC
                offset would have been 76. Preview's panel is nearly twice as
                round as concentric, and that is what keeps it from reading as
                a printing error.
  the lens      outer glass radius 106 at 512, centre (325, 324). It clears the
                panel's lower right corner by 31, half the margin's width, and
                it carries a shadow on the white and a darker rim where it
                crosses. Not a shape that only just touches.

THE GROUND STILL FILLS THE CANVAS. If our artwork stops short of 1024 the
system's own material shows past it and round nine's border is back, only now
with a second frame inside it. So: full bleed ground in Foam, a panel inset
within it, and something crossing.

THE ONE THING THAT NEARLY KILLED THIS. The piece that leaves in `corner` is the
pale bar, Shallow #9BE9DC. Against Foam #E9F7F4 that measures 1.26, well under
the 1.60 two layers need, so a Shallow bar lying on a Foam margin is very
nearly invisible. Preview has the same problem and solves it the same way we
do: its glass ring is near white on near white, and what makes it read is a
darker rim along one side and a shadow underneath. So the bar grows a side the
moment it leaves the panel, in Current, which measures 2.16 against Shallow and
sits inside the 1.15 to 2.30 a thickness band wants, and 2.73 against Foam. The
face still fails against the margin and check.py says so rather than hiding it.
Three directions here (03, 04, 05) avoid the problem outright by putting a dark
piece on the white instead of a pale one.

  01 exit     corner exact, the bar out through the panel's lower right corner,
              across the margin and off the tile
  02 land     corner exact, the same bar stopped with a cap on the margin, air
              beyond it. The shadow one
  03 wick     the Spatie lane crosses IN over the left margin, the bar is cut
              by the panel's own corner curve
  04 through  both: a lane in over the left margin, the bar out over the lower
              right. The frame broken twice by one thread
  05 tongue   the panel grows out to the corner and the bar rides inside it, so
              what lies on the white is Deep and not Shallow
  06 broad    01 with a 215 margin. The frame as the loudest thing on the tile
  07 near     01 with an 88 margin. The frame as a hairline
  08 card     01 with a tight radius panel, so the panel is a card rather than
              an echo of the tile
  09 paper    01 on a Paper margin with an Abyss panel. The widest step the
              ramp will give a frame
  10 kiss     01 with the bar crossing by 24 units only. The stated negative:
              a shape that just touches reads as a misalignment

01, 02, 06, 07, 08, 09 and 10 keep `corner` exactly as it is inside the panel.
Nothing in the figure is redrawn; the whole composition is scaled into the
panel the way `wrap_legacy` scales it into the Big Sur body, so the picture is
identical relative to the shape that holds it.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lib9
import lib  # noqa: E402  reached through lib9's sys.path
from lib9 import (CX, CY, S, clipped, contact, flat, fullbleed, outside,
                  sh_squircle, sheen, wrap_flat, wrap_layer, wrap_legacy)
from lib import sh_group, sh_move, sh_path, sh_rect

# corner's own numbers, unchanged. They are measured against a tile that is the
# whole canvas, and everything below re-measures them against the panel.
H = 150 * S            # the settled lane height
HS = 168 * S           # the same lane opened up for 16 and 32
YA = CY - 362 * S      # where the upper lane arrives
YB = CY + 362 * S      # where the lower lane arrives
END = CY + 196         # where all three leave

M = 150.0              # the default margin, near enough Preview's 154
BAND_X0, BAND_X1 = -280.0, 1304.0


# ------------------------------------------------------- the panel's frame
#
# Every direction draws the SAME figure into a smaller square. The map is one
# line, p -> m + k*p with k = (1024 - 2m)/1024, and it is applied to the
# geometry rather than to a transform, because a <g transform> is not a legal
# child of a clipPath and half of what is drawn here ends up inside one.
def kof(m):
    return (1024.0 - 2 * m) / 1024.0


def into(p, m):
    return m + kof(m) * p


def outof(x, m):
    """The inverse. Lets a cap be placed at a position on the TILE and still be
    handed to the band in the panel's own frame."""
    return (x - m) / kof(m)


def band_in(y0, y1, h, m, x0=BAND_X0, x1=BAND_X1):
    """lib9.band, drawn in the panel's frame.

    The curve is not reshaped. Every coordinate the band is built from,
    including the two control points lib9 keeps to itself, goes through the
    same map, so a band in a 718 panel and a band in a 1024 tile are the same
    band at two scales."""
    k = kof(m)
    c0, c1 = CX + (300 - 512) * S, CX + (560 - 512) * S
    ax0, ax1, ac0, ac1 = (into(x0, m), into(x1, m), into(c0, m), into(c1, m))
    ay0, ay1, ah = into(y0, m), into(y1, m), k * h
    return sh_path(
        "M%.1f,%.1f C%.1f,%.1f %.1f,%.1f %.1f,%.1f L%.1f,%.1f C%.1f,%.1f "
        "%.1f,%.1f %.1f,%.1f Z"
        % (ax0, ay0 - ah / 2, ac0, ay0 - ah / 2, ac1, ay1 - ah / 2,
           ax1, ay1 - ah / 2, ax1, ay1 + ah / 2, ac1, ay1 + ah / 2,
           ac0, ay0 + ah / 2, ax0, ay0 + ah / 2))


def capped_in(y0, y1, h, m, x0, x1):
    """The same band, ended inside the drawing with a round cap.

    x0 and x1 are in the panel's frame, like every other argument here. The
    band is never reshaped: it is drawn whole, shown only between the two, and
    a disc of its own half height is set on its centre line at each end."""
    k = kof(m)

    def make(f):
        cid = "p%d" % len(lib._defs)
        lib._defs.append(
            '<clipPath id="%s"><rect x="%.1f" y="-800" width="%.1f" '
            'height="2624"/></clipPath>'
            % (cid, into(x0 + h / 2, m), k * (x1 - x0 - h)))
        return ('<g clip-path="url(#%s)">%s</g>' % (cid, band_in(y0, y1, h, m)(f))
                + _disc(x0 + h / 2, y0, y1, h, m)(f)
                + _disc(x1 - h / 2, y0, y1, h, m)(f))
    return make


def _disc(x, y0, y1, h, m):
    return lib.sh_circle(into(x, m), into(lib9.yat(y0, y1, x), m),
                         kof(m) * h / 2)


def squircle_panel(m):
    """The system's own shape, scaled into the margin.

    Scaling the tile's shape rather than insetting it is what keeps the panel
    off the concentric trap. An inset of 150 would leave a radius of about 80;
    scaling leaves about 160, and Preview's panel is on the scaled side of that
    same choice."""
    return sh_squircle(m, m, 1024 - 2 * m, 1024 - 2 * m)


def rect_panel(m, r):
    return sh_rect(m, m, 1024 - 2 * m, 1024 - 2 * m, r)


def side(sh, colour="current"):
    """The side of a piece, in the one direction the whole set lights from.

    This is lib.thick's lower half on its own, so it can be laid under a shape
    in one place and not in another. It is used in exactly one place: where the
    pale bar has left the panel and is lying on the near white margin, where
    its face has no step against the ground to stand on."""
    if lib.SMALL:
        return ""
    dx, dy = lib.THICK_D
    return sh_move(sh, dx, dy)(sheen(colour))


# ---------------------------------------------------------------- the shape
#
# Seven of the ten are one recipe with different numbers, so the recipe is
# written once. A knob that only one direction turns is still a knob and not a
# separate copy of the drawing, because two copies drift.
def figure(m, small, bar="off", capx=None, panel=None, ground="foam",
           panelcol="deep", lane=False, tongue=False):
    """The whole picture, as (layers, flat body).

    bar     "off"   the pale bar leaves the panel and runs off the tile
            "cap"   it leaves the panel and stops on the margin with a cap
            "clip"  it never leaves: the panel's own corner curve cuts it
    capx    where the cap's far edge lands, measured on the TILE
    lane    the upper Spatie lane crosses OUT over the upper left of the margin
    tongue  the panel itself runs out to the lower right and the bar rides
            inside it, so the piece lying on the white is Deep

    A piece that crosses the frame is clipped on the side it is NOT crossing
    on, and only there. `corner` runs every one of its three lanes clean across
    the canvas, so a bar left free to leave on the right is also free to leave
    on the left, and a figure that breaks its frame on all four sides is not a
    figure in a frame. So the bar is shown inside the panel plus a strip at the
    right, and a crossing lane inside the panel plus a strip at the left.
    """
    h = HS if small else H
    p = panel or squircle_panel(m)
    if tongue:
        p = sh_group(p, band_in(CY - 40, END, h * 1.04 + 52, m,
                                x1=outof(1200, m)))
    right = sh_group(p, sh_rect(1024 - m - 60, -400, 2400, 1824))
    # A crossing lane is cut at the panel's RIGHT edge and nowhere else. An
    # earlier version cut it at the left edge instead and let the panel supply
    # the rest, which left a wedge of lane missing wherever the panel's corner
    # curve had not yet reached the cut: a notch, in the one place the eye is
    # being asked to look. The panel's right boundary at the height the lane
    # leaves is straight, so a vertical cut there is the panel's own edge.
    left = sh_rect(-400, -400, 400 + 1024 - m, 1824)

    a0 = band_in(YA, END - h * 1.02, h * 0.92, m)
    b0 = band_in(YB + 26, END + h * 1.02, h * 0.92, m)
    if bar == "cap":
        c0 = capped_in(CY - 40, END, h * 1.04, m, BAND_X0, outof(capx, m))
    else:
        c0 = band_in(CY - 40, END, h * 1.04, m)

    # The drawn versions. Never hand one of these to contact() as the piece
    # being fallen ON: a clipPath may not contain a group, and every one of
    # them is a group. The unclipped shape underneath is the right answer
    # there anyway, because two pieces can only cast on each other where they
    # overlap and the clip never takes away an overlap that mattered.
    a = lib.sh_clip(a0, left) if lane else a0
    c = c0 if bar == "clip" else lib.sh_clip(c0, p if tongue else right)

    tile = sh_squircle()
    lanes = a0(sheen("spatie")) + b0(sheen("current"))
    inpanel = (clipped(b0(sheen("current")), p) + a(sheen("spatie"))
               if lane else clipped(lanes, p))
    mark = (clipped(c(sheen("shallow")), p) if bar == "clip"
            else outside(side(c), p) + c(sheen("shallow")))

    layers = [
        ("Mark", mark, MARKKEYS),
        ("Bleed", inpanel, BLEEDKEYS),
        ("Panel", p(flat(panelcol)), PANELKEYS),
        ("Ground", fullbleed(flat(ground)), {}),
    ]

    o = [fullbleed(flat(ground)),
         # The panel seated on the margin. Lighter than round nine's plate
         # shadow, because that one fell on Abyss and this one falls on Foam.
         contact(p, tile, d=(0, 16 * S), blur=20 * S, alpha=0.22),
         p(flat(panelcol))]
    if lane:
        o += [clipped(b0(sheen("current")), p),
              outside(contact(a, tile, d=(0, 20 * S), blur=17 * S, alpha=0.24), p),
              a(sheen("spatie")),
              contact(a, p, d=(0, 20 * S), blur=15 * S, alpha=0.26)]
    else:
        o += [clipped(lanes, p)]
    o += [contact(c, a0, d=(0, 26 * S), blur=13 * S, alpha=0.34),
          contact(c, b0, d=(0, -26 * S), blur=13 * S, alpha=0.34)]
    if bar == "clip":
        o += [clipped(c(sheen("shallow")), p)]
    else:
        o += [contact(c, p, d=(0, 26 * S), blur=15 * S, alpha=0.30),
              outside(contact(c, tile, d=(0, 26 * S), blur=20 * S, alpha=0.26), p),
              outside(side(c), p),
              c(sheen("shallow"))]
    return layers, "".join(o)


# ------------------------------------------------------------------ the ten
def exit_(small=False):
    """corner exact, the bar out through the panel's lower right corner.

    The whole of `corner` scaled into a 724 panel, and then one thing left
    undone: the bar is not clipped to the panel. It therefore leaves exactly
    where it used to leave the tile, on the corner's curve, crosses 150 units
    of Foam and is cut by the tile's own edge. The margin is a road rather than
    a mat, which is the most this direction can claim."""
    return figure(M, small)


def land(small=False):
    """The same bar, stopped on the margin with a cap.

    Preview's move rather than ours: a piece of the figure lying on the white
    with air past it. 131 units of the bar are on the margin against a margin
    185 wide, and 53 units of Foam are left beyond the cap, so it is
    unmistakably a thing on a surface rather than a thing that overshot.
    Both shadows are drawn, one clipped to the panel and one to the margin, and
    at this size the shadow on the white is what makes the pale face read."""
    return figure(185.0, small, bar="cap", capx=970.0)


def wick(small=False):
    """The lane crosses in, the panel's corner cuts the bar.

    The colour legal version, and the argument against the other seven. What
    lies on the white here is Spatie, which measures 4.76 against Foam and
    needs no side and no shadow to be seen. The bar never leaves: the panel's
    own lower right curve cuts it, which is `corner`'s idea moved one layer
    in."""
    return figure(M, small, bar="clip", lane=True)


def through(small=False):
    """In over the left margin, out over the lower right.

    The frame broken twice by one continuous thread, which is the only way to
    say that the panel is lying UNDER the figure rather than holding it. The
    entering lane is Spatie and reads on the white on its own; the leaving bar
    is Shallow and needs its side."""
    return figure(M, small, lane=True)


def tongue(small=False):
    """The panel runs out to the corner and the bar rides inside it.

    If a pale bar cannot be seen on a near white margin, send something dark
    out with it. The panel grows a spur along the bar's own path, 26 units
    proud of it on each side, so what crosses the margin is Deep at 14.4
    against Foam with the Shallow bar inside it. No exception is needed and
    nothing is recoloured.

    THIS IS THE ROUND TEN DRAWING AND IT IS NOT WHAT SHIPS. design.py is, and
    it differs in three ways decided after this round closed: the grade, the
    lanes cut at the plain panel, and a spur that ends where the bar ends and
    is 17 units proud rather than 26. Do not read a difference between this and
    Resources/ as a bug in either."""
    return figure(M, small, tongue=True)


def broad(small=False):
    """01 with the margin at 215.

    Twenty one percent per side against Preview's fifteen. The panel falls to
    58 percent of the tile and the frame becomes the loudest thing on it. Here
    to find the ceiling, and it finds it."""
    return figure(215.0, small)


def near(small=False):
    """01 with the margin at 88.

    Round nine's plate was 68 and read as a mistake. This is the same question
    asked with the crossing that round nine did not have: does a thin frame
    stop looking like a leftover once something is lying across it."""
    return figure(88.0, small)


def card(small=False):
    """01 with a tight radius panel.

    The scaled squircle in the other nine leaves the panel about 160 round on a
    724 side. This asks for 96, which is far enough off the tile's own curve
    that the panel reads as a separate card rather than as the tile drawn
    twice. The failure mode being avoided is the other one, a radius so close
    to concentric that the pair looks like a registration error."""
    return figure(155.0, small, panel=rect_panel(155.0, 96.0))


def paper(small=False):
    """01 with the frame pushed as hard as the ramp allows.

    Paper is the colder, whiter end of the neutrals and Abyss is the darkest
    rung there is, so this is the widest step a margin and a panel can be
    given: 16.9 against Foam on Deep's 14.4. It is the answer to the round
    nine complaint that a Foam dominant field reads as a white app. If the
    tile is going to be white, the panel has to be heavy enough to pay for it,
    and one variation should say what happens when that is taken to the end of
    the ramp rather than to the middle of it.

    Fathom was tried here first, on the reasoning that a bluer panel carries
    more colour than a darker one. It renders washed out against a white
    margin: on a dark ground Fathom is a raised surface, on a white one it is
    just a weaker Deep."""
    return figure(M, small, ground="paper", panelcol="abyss")


def kiss(small=False):
    """01 with the bar crossing by 24 units.

    The stated negative. A shape that only just reaches the margin does not
    read as a shape lying on a surface, it reads as a shape that missed its
    mark by a hair. It is drawn so that the amount that has to cross can be
    argued from a picture instead of from a sentence."""
    return figure(M, small, bar="cap", capx=898.0)


# ------------------------------------------------------------- icon.json keys
#
# Unchanged from round nine except that Panel replaces Plate. The system draws
# the group shadow, which is why the layered assets carry no contact() of their
# own, and it is the system's shadow that seats the panel on the margin and the
# bar on the panel exactly the way Preview's is seated.
MARKKEYS = {"shadow": {"kind": "neutral", "opacity": 0.5}, "specular": True,
            "translucency": {"enabled": False, "value": 0.5}}
BLEEDKEYS = {"translucency": {"enabled": False, "value": 0.5}}
PANELKEYS = {"shadow": {"kind": "neutral", "opacity": 0.55},
             "translucency": {"enabled": False, "value": 0.5}}


ICONS = [
    ("01-exit", exit_), ("02-land", land), ("03-wick", wick),
    ("04-through", through), ("05-tongue", tongue), ("06-broad", broad),
    ("07-near", near), ("08-card", card), ("09-paper", paper),
    ("10-kiss", kiss),
]

# What crosses, and where. Printed on the contact sheet, because it is the only
# question the round is actually asking.
CROSS = {
    "01-exit": "the bar, panel corner, off the tile",
    "02-land": "the bar, panel corner, stops on the margin",
    "03-wick": "a lane, left edge, inward only",
    "04-through": "a lane in on the left, the bar out at the corner",
    "05-tongue": "the panel itself, corner, the bar inside it",
    "06-broad": "the bar, panel corner, off the tile",
    "07-near": "the bar, panel corner, off the tile",
    "08-card": "the bar, panel corner, off the tile",
    "09-paper": "the bar, panel corner, off the tile",
    "10-kiss": "the bar, 24 units past the panel. Too little",
}

BLURB = {
    "01-exit": "corner exact, the bar off the corner and off the tile",
    "02-land": "the bar stops on the margin, air beyond the cap",
    "03-wick": "a dark lane on the white, the panel's curve cuts the bar",
    "04-through": "in on the left, out at the corner. Broken twice",
    "05-tongue": "the panel runs out with the bar inside it",
    "06-broad": "the margin at 215. The ceiling",
    "07-near": "the margin at 88. The floor",
    "08-card": "a tight radius panel, a card and not an echo",
    "09-paper": "a Paper margin, an Abyss panel. The widest step",
    "10-kiss": "24 units of crossing. The stated negative",
}

# The margin each one draws, for the sheets and the README, so a number in a
# table cannot drift from the number in the drawing.
MARGIN = {"01-exit": 150, "02-land": 185, "03-wick": 150, "04-through": 150,
          "05-tongue": 150, "06-broad": 215, "07-near": 88, "08-card": 155,
          "09-paper": 150, "10-kiss": 150}


def render(fn, small=False):
    """One direction, three ways round: the layered groups, the full bleed
    composite, and the same composite at the Big Sur template for the `.icns`.
    Same contract as gen9.render, in the same order."""
    lib.SMALL = small
    lib.reset()
    layers, body = fn(small)
    out = [(name, wrap_layer(b), keys) for name, b, keys in layers]
    return out, wrap_flat(body), wrap_legacy(body)


def unframed(small=True):
    """`corner` with no frame at all, which is what ships today.

    A frame costs the small sizes more than anything else in this round: at 16
    a 150 margin is two pixels of white and the panel is twelve pixels across,
    inside which three bands still have to read. The `.icns` is allowed to
    solve that by dropping the frame below 64, because an `.icns` already
    carries different geometry at different sizes. THE LAYERED DOCUMENT IS NOT:
    icon.json has one set of artwork for every size, so on macOS 26 whatever is
    drawn here is what appears at 16.

    This is the comparison row on small-sizes.png and it is the recommended
    small artwork for every direction in the round."""
    lib.SMALL = small
    lib.reset()
    h = HS if small else H
    c = lib9.band(CY - 40, END, h * 1.04)
    a = lib9.band(YA, END - h * 1.02, h * 0.92)
    b = lib9.band(YB + 26, END + h * 1.02, h * 0.92)
    body = "".join([
        fullbleed(flat("deep")), a(sheen("spatie")), b(sheen("current")),
        contact(c, a, d=(0, 26 * S), blur=13 * S, alpha=0.34),
        contact(c, b, d=(0, -26 * S), blur=13 * S, alpha=0.34),
        c(sheen("shallow")),
    ])
    return wrap_flat(body), wrap_legacy(body)
