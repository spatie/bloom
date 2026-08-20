#!/usr/bin/env python3
"""Builds the menu bar template image from the app icon's own gesture.

    python3 Tools/icon/menubar.py            the asset and the comparison sheet
    python3 Tools/icon/menubar.py --sheet    the sheet only

Writes `Resources/BloomMenuBar.pdf`, which `MenuBarStatusItem` loads out of the
bundle and marks as a template. Everything else it writes goes to
`Tools/icon/.build/menubar/` and is not shipped.

A TEMPLATE, NOT A WHITE PICTURE. The mark is drawn in black on transparency and
`NSImage.isTemplate` is set on it. The status bar then tints it: white on a dark
menu bar, near black on a light one, and inverted again while the menu is open
and the item is pressed. A white glyph would be right in exactly one of those
four cases. What the owner asked for is what a template renders as; the way to
get it is not to draw it.

THIS IS A REDUCTION, NOT A SCALE. The app icon is 15 points tall in the menu
bar, which is 15 device pixels on an external display. Its ground, its panel and
its three bands close into a texture well before that: a lane 20 percent of the
tile high is three pixels and the gaps between them are one. So nothing here
scales the icon down. What it keeps is the icon's one gesture, three lanes that
arrive apart and end up going the same way, and it keeps it by drawing the same
curve: `centreline` samples lib9's own eased lane. Every candidate below is built
from that one curve and they differ only in how many lanes there are and what
becomes of them.

WHAT THE REDUCTION HAD TO CHANGE, and it is one thing. In the icon the three
lanes leave TOUCHING, spaced h*1.02 on a height of h, and what tells them apart
is that they are three different colours. A template has no colour, so keeping
them apart costs height: a lane and a gap that both survive 1x are 2 points and
2.25, and three of each is the whole box with nothing left for the fan to open
by. `trio` is that version and it reads as three lines that are not quite
parallel.

The shipped mark spends the height differently. The lanes MERGE: they are 6.6
points apart on the left, where nothing has to survive but air, and by two thirds
of the width they are one lane running out to the right. Same three lanes, same
curve, and what was a bundle on the tile is a junction here.

MEASURED OFF THE OWNER'S OWN MENU BAR, at 2x, the icons occupying rows 16..50:

  Dropbox        16.5 points tall at the ink edge, 18.0 wide, solid shapes
  the database   17.5 tall, 17.0 wide, 1.5 point strokes
  1Password      16.0 tall, 16.0 wide
  Saturn         14.5 tall, 21.0 wide
  the old mark   11.0 tall, 13.5 wide

The old mark is `point.3.connected.trianglepath.dotted` at its default size, and
being five points shorter than everything beside it is why it read as faint.
`ART_HEIGHT` is 15.0: level with Saturn, a little under Dropbox, and short of the
17.5 the database fills, because a mark that fills its box looks bigger than
everything next to it.

AND THEN THE OWNER SAID IT WAS HARSH. What ships reads as three straight-ish
lines converging to a point, and beside Dropbox and 1Password that is the
hardest thing on the bar. `SWEEP` and the ten candidates under it are the
answer: they turn the four things that make it so, one at a time, so that what
is being chosen between is one variable rather than ten drawings. The comment
above `SWEEP` says which four. Nothing under it is shipped until `CHOICE` says
so.

AND THEN THE OWNER DREW IT HIMSELF. Three rounds of candidates ended with him
opening `designer.html` and turning the knobs, and `mine` at the foot of
`PRESETS` is what came off that page, pasted unchanged. It answers the thin
reading with weight rather than with a different gesture: arrivals tapered into
the trunk so the joins have no needle, and a lane more than twice `gather`'s.

`level` under it is `mine` at Dropbox's height, and that is what ships. At the
18.00 points he drew it at, the mark measured taller than everything in his bar
and he asked for it brought down; `level` is the same drawing with one number
changed, so every proportion he set on the page is kept and only the scale
moves. The weight survives the reduction with room to spare: a 3.14 point lane
and a 3.67 point trunk, against 1.95 on `gather` and 2.76 on `two`, which was
the heaviest thing in the round he called thin.

WHAT THE BAR WILL ACTUALLY DRAW, measured rather than assumed, because the
worry that decided the height was clipping and it turns out not to bite.
`NSStatusBar.system.thickness` is 22 points and the button is 22 tall, and
neither is the limit. The image is centred in the menu bar's own band, which is
33 points on the notched built-in display and 24 elsewhere, and it is drawn
whole until it exceeds that. A scratch status item carrying 19, 22, 24, 27, 30
and 34 points of art gave back every one of them at full height; only the last,
which needs a 37 point image, came back cut to 33 with its top and bottom gone.
So the ceiling is the bar's height less the two bleeds: 30 points of art on the
built-in display, 21 on a 24 point bar. Neither 16.00 nor the 18.00 he drew is
anywhere near it, and the reason to choose between them is how the mark sits
beside its neighbours, not what the bar will allow.

THE 1x CASE IS THE ONE THAT DECIDES. On the built-in display a gap of 1.5 points
is three pixels and everything survives. On an external 1x display it is one and
a half, and a design tuned on the laptop turns to mud there. The sheet renders
every candidate at 1x as well as 2x for that reason, and the shipped choice is
the one whose gaps are still gaps at 1x.
"""
import math
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
RESOURCES = os.path.join(ROOT, "Resources")
BUILD = os.path.join(HERE, ".build", "menubar")

sys.path.insert(0, HERE)
import lib9  # noqa: E402

# The candidate that ships. One line, and the other fifteen stay in the file, so
# swapping the mark is a rerun rather than a redraw.
CHOICE = "level"

# The mark's optical height in points, and the bleed left around it. The bleed is
# part of the asset rather than of the layout: `NSStatusItem` centres the image
# in its button, so a canvas a touch taller than the art is what leaves the
# breathing room Apple's own items have above and below.
ART_HEIGHT = 15.0
BLEED = 1.5


# ------------------------------------------------------------------ the curve
#
# The icon's lane, and nothing else. lib9.band draws a cubic from y0 on the left
# to y1 on the right with its control points at fixed fractions of the span, and
# the tile shows the part of it between x=0 and x=1024 of a span running from
# -280 to 1304. Both are read off lib9 rather than copied, so a change to the
# icon's easing reaches the menu bar mark without anybody remembering to bring
# it.
SPAN0, SPAN1 = -280.0, 1304.0
XS = (SPAN0, lib9.CX + (300 - 512) * lib9.S, lib9.CX + (560 - 512) * lib9.S, SPAN1)


def _bez(p, t):
    u = 1 - t
    return (u * u * u * p[0] + 3 * u * u * t * p[1]
            + 3 * u * t * t * p[2] + t * t * t * p[3])


def _tat(x):
    """Where on the cubic the tile's edge at x falls. lib9.yat inverts the same
    curve and then evaluates y on it; this wants the parameter itself."""
    lo, hi = 0.0, 1.0
    for _ in range(40):
        mid = (lo + hi) / 2
        if _bez(XS, mid) < x:
            lo = mid
        else:
            hi = mid
    return (lo + hi) / 2


# What the tile shows of the band, computed rather than quoted: the parameters at
# which the icon's left and right edges cut it. It comes out at 0.19 to 0.86,
# which is the middle of the band and none of its settled end.
TILE_WINDOW = (_tat(0.0), _tat(1024.0))

# The stretch of the band the mark is cut from, as parameters on the same cubic.
#
# TILE_WINDOW is the icon's, and it is the middle of the band, where the ease
# is symmetric: the lane is still turning when it reaches the right edge and
# leaves the tile at an angle. Drawn into a box fifteen points wide that reads as
# three tilted bars, because at this size a lane has room to say one thing and
# "sloped" is not the thing.
#
# So the mark is cut from the END of the same band instead, WINDOW below. At t=1
# the cubic's tangent is flat by construction, so the lanes arrive parallel and
# the box shows what the tile has no room to: lanes that spread out on the left,
# gather, and leave side by side. Same curve, later stretch.
WINDOW = (0.20, 1.0)


def _weights(window):
    """How much of each end of the band shows at the two ends of the window, so a
    lane can be asked for by where it is SEEN to start and stop."""
    return [_bez((1.0, 1.0, 0.0, 0.0), t) for t in window]


def centreline(ystart, yend, x0, x1, n=72, window=WINDOW):
    """The icon's lane, entering the box at ystart and leaving it at yend.

    The two arguments are where the lane is seen, not the band's own asymptotes:
    a window that does not reach the band's ends shows neither of them, so the
    asymptotes are solved for and the drawing is asked for in the numbers the box
    is laid out in. Everything else is lib9's curve, sampled.
    """
    a, b = _weights(window)
    # ystart = a*y0 + (1-a)*y1 and yend = b*y0 + (1-b)*y1, solved for y0 and y1.
    drop = (ystart - yend) / (a - b)
    y1 = ystart - a * drop
    y0 = y1 + drop
    ys = (y0, y0, y1, y1)
    xa, xb = _bez(XS, window[0]), _bez(XS, window[1])
    pts = []
    for i in range(n + 1):
        t = window[0] + (window[1] - window[0]) * i / n
        # The cubic's x is not linear in t, so the sample is placed at its own x
        # rather than at an even step, which is what keeps the curve the shape it
        # is instead of stretching it.
        pts.append((x0 + (x1 - x0) * (_bez(XS, t) - xa) / (xb - xa), _bez(ys, t)))
    return pts


# ------------------------------------------------------------------- polygons
def _unit(dx, dy):
    d = math.hypot(dx, dy) or 1.0
    return dx / d, dy / d


def _frames(pts):
    """A tangent and a normal at every vertex, averaged from the segments either
    side. Good enough because every curve here is gentle: the error in a mitre is
    second order in the turn angle, and the sharpest turn on a lane is under two
    degrees per sample."""
    out = []
    for i, p in enumerate(pts):
        a = pts[max(i - 1, 0)]
        b = pts[min(i + 1, len(pts) - 1)]
        t = _unit(b[0] - a[0], b[1] - a[1])
        out.append((t, (-t[1], t[0])))
    return out


def _cap(p, tangent, normal, r, at_end, cap=1.0):
    """The terminal at one end of a ribbon, swept from one edge to the other so
    it bulges past the end rather than doubling back over the ribbon.

    Half an ellipse, r across the ribbon and r * cap along it, which is a half
    circle at cap = 1 and the flat chord at cap = 0. The two are one formula
    because the terminal is the single loudest thing about a mark this small and
    the owner has to be able to move it without the shape changing under him:
    a cut end and a round end are the same drawing at two settings.
    """
    n = normal if at_end else (-normal[0], -normal[1])
    t = tangent if at_end else (-tangent[0], -tangent[1])
    out = []
    for k in range(1, 12):
        a = math.pi * k / 12.0
        c, sn = math.cos(a), math.sin(a) * cap
        out.append((p[0] + r * (n[0] * c + t[0] * sn),
                    p[1] + r * (n[1] * c + t[1] * sn)))
    return out


def _radii(pts, width):
    """Half the weight at every vertex. A number is a lane of one thickness; a
    function of the fraction along the lane is a lane that is drawn rather than
    plotted, thicker where the hand pressed and thinner where it lifted."""
    n = len(pts) - 1
    if callable(width):
        return [width(i / n) / 2.0 for i in range(len(pts))]
    return [width / 2.0] * len(pts)


def edge(pts, width, side=1):
    """One side of the ribbon a centre line would paint. `side` is +1 for the
    normal's side and -1 for the other, and the two of them are what a fillet
    needs: the crotch of a junction is where two of these cross."""
    rs = _radii(pts, width)
    return [(p[0] + n[0] * r * side, p[1] + n[1] * r * side)
            for p, (_, n), r in zip(pts, _frames(pts), rs)]


def ribbon(pts, width, caps=(True, True), cap=1.0):
    """A centre line given a width: the shape a stroke would paint, as a polygon.

    Drawn rather than stroked because two candidates cut a slot in themselves,
    and a slot is either a subpath with the opposite winding or a piece that is
    simply not painted. A stroked path can be neither, so everything here is a
    filled polygon and there is one mechanism instead of two.

    `width` is a number or a function of the fraction along the line, which is
    how the modulated candidates get their weight to swell through a bend. The
    caps are half circles at whatever the weight is where they sit, so a lane
    that thins to nothing ends in a point without anybody special casing it.
    """
    fr = _frames(pts)
    rs = _radii(pts, width)
    left = [(p[0] + n[0] * r, p[1] + n[1] * r) for p, (_, n), r in zip(pts, fr, rs)]
    right = [(p[0] - n[0] * r, p[1] - n[1] * r) for p, (_, n), r in zip(pts, fr, rs)]
    out = list(left)
    if caps[1]:
        out += _cap(pts[-1], fr[-1][0], fr[-1][1], rs[-1], True, cap)
    out += list(reversed(right))
    if caps[0]:
        out += _cap(pts[0], fr[0][0], fr[0][1], rs[0], False, cap)
    return out


def cove(arm, y, run, n=24):
    """The curve that rounds the corner where a lane lands on a level trunk.

    A circle inscribed in that corner is worth nothing here. The corner measures
    thirty odd degrees, and an arc small enough to stay local in thirty degrees
    is a third of a point across, which is under one device pixel: the arithmetic
    is right and the eye cannot see it. What softens a junction at this size is a
    cove, the same thing a typeface puts where an arm meets a stem, and it is
    drawn large on purpose.

    So it is built as a quadratic, which is tangent to both sides by
    construction: it leaves the lane's edge a run before the corner, its control
    point is where that edge's own tangent crosses the trunk, and it lands on the
    trunk an equal run past it. What comes back is the counter's point filled in,
    bounded above by that curve, so the outline runs along the lane, turns once,
    and carries on along the trunk with no corner in it anywhere.
    """
    apex = None
    for i, ((ax, ay), (bx, by)) in enumerate(zip(arm, arm[1:])):
        if (ay - y) * (by - y) <= 0 and ay != by:
            apex, at = ax + (bx - ax) * (y - ay) / (by - ay), i
            break
    if apex is None:
        return None
    x0 = apex - run
    if x0 <= arm[0][0]:
        return None
    j = max(i for i, q in enumerate(arm) if q[0] <= x0)
    (ax, ay), (bx, by) = arm[j], arm[j + 1]
    k = (x0 - ax) / (bx - ax) if bx != ax else 0.0
    p0 = (x0, ay + (by - ay) * k)
    dx, dy = _unit(bx - ax, by - ay)
    if abs(dy) < 1e-9:
        return None
    t = (y - p0[1]) / dy
    if t <= 0:
        return None
    c = (p0[0] + dx * t, y)
    p2 = (c[0] + math.hypot(c[0] - p0[0], c[1] - p0[1]), y)
    curve = []
    for m in range(n + 1):
        u = m / n
        v = 1 - u
        curve.append((v * v * p0[0] + 2 * v * u * c[0] + u * u * p2[0],
                      v * v * p0[1] + 2 * v * u * c[1] + u * u * p2[1]))
    tail = [q for q in reversed(arm[:at + 1]) if q[0] >= x0]
    return curve + [(apex, y)] + tail + [p0]


def area(poly):
    s = 0.0
    for i, (x, y) in enumerate(poly):
        x2, y2 = poly[(i + 1) % len(poly)]
        s += x * y2 - x2 * y
    return s / 2.0


def solid(poly):
    """Every filled piece wound the same way, so overlapping pieces union under
    the nonzero rule instead of cancelling."""
    return poly if area(poly) > 0 else list(reversed(poly))


def squircle(x, y, w, h):
    """The system's icon shape at any size, from lib9's measured quadrant."""
    d = lib9.squircle(x, y, w, h)
    pts = []
    for chunk in d.replace("M", " ").replace("L", " ").replace("Z", " ").split():
        a, b = chunk.split(",")
        pts.append((float(a), float(b)))
    return pts


def clip(poly, curve, keep):
    """The part of a polygon on one side of a y = f(x) curve.

    `keep` is "above" or "below" in screen terms, so above means the smaller y.
    This is how a slot gets drawn without a boolean library: the panel is cut
    into the piece above the bar and the piece below it, and the slot between
    them is never painted, so it never has to be subtracted.
    """
    sign = 1.0 if keep == "above" else -1.0

    def yat(x):
        if x <= curve[0][0]:
            return curve[0][1]
        if x >= curve[-1][0]:
            return curve[-1][1]
        lo, hi = 0, len(curve) - 1
        while hi - lo > 1:
            mid = (lo + hi) // 2
            if curve[mid][0] <= x:
                lo = mid
            else:
                hi = mid
        (x0, y0), (x1, y1) = curve[lo], curve[hi]
        k = 0.0 if x1 == x0 else (x - x0) / (x1 - x0)
        return y0 + (y1 - y0) * k

    def g(p):
        return sign * (p[1] - yat(p[0]))

    def cross(p, q):
        lo, hi = 0.0, 1.0
        for _ in range(30):
            mid = (lo + hi) / 2
            m = (p[0] + (q[0] - p[0]) * mid, p[1] + (q[1] - p[1]) * mid)
            if (g(m) < 0) == (g(p) < 0):
                lo = mid
            else:
                hi = mid
        t = (lo + hi) / 2
        return (p[0] + (q[0] - p[0]) * t, p[1] + (q[1] - p[1]) * t)

    out = []
    for i, p in enumerate(poly):
        q = poly[(i + 1) % len(poly)]
        pin, qin = g(p) < 0, g(q) < 0
        if pin:
            out.append(p)
        if pin != qin:
            out.append(cross(p, q))
    return out


# ------------------------------------------------------------ the candidates
#
# Each returns (width, [polygon, ...]) in a box 100 units tall with y running
# down, filled as one nonzero path. Sixteen of them now: the first six were the
# reductions the mark was chosen from, and the ten below them are the answer to
# the owner's next note, that the chosen one reads as harsh. They all stay,
# because the only honest way to pick a mark for a fifteen point box is to look
# at all of them at fifteen points rather than to reason about them at 512.
#
# THE WEIGHT IS THE NEIGHBOURS', NOT THE ICON'S. On the tile a lane is a fifth of
# the height, a ribbon with a lit face and a side. Two of those and their gap do
# not fit in fifteen points, and a mark drawn at the icon's proportions sits in
# the bar looking like a stack of bars rather than like the database and the
# padlock either side of it, which are drawn at a point and a half. So a lane
# here is 2 points and the gap is wider than the lane, which is Apple's own
# proportion in `slider.horizontal.3` and the one thing that survives 1x.
LANE = 13.0          # a lane's weight, 1.95 points
GAP = 15.0           # what is left between two lanes in a bundle, 2.25 points

# Where the two arriving lanes land on the one that leaves, as fractions of the
# width. Level, at 0.60 and 0.60, the mark is a stroke with two swept barbs on
# its left and its shaft running right, which is a left pointing arrow and reads
# in a menu bar as a control for hiding things. A fifth of the width apart it is
# two branches landing one after the other, which is what the app does.
TOP_LANDS, BOTTOM_LANDS = 0.70, 0.48


def gather():
    """Three lanes arriving and one leaving, and they do not arrive together.

    The icon's gesture with the one thing the icon can afford and this cannot
    taken out. On the tile three lanes converge and stay three, spaced h*1.02 on
    a height of h, told apart by being three different colours. In a template
    there is no colour, so keeping them apart costs height a fifteen point box
    does not have: `trio` below is that version, and its gaps close at 1x.

    Letting them MERGE spends the height in the one place it can be seen. The fan
    is 6.6 points across on the left, where nothing has to survive but air, and
    by two thirds of the width the three are one lane running out to the right.

    THE TWO ARRIVALS ARE STAGGERED, and that is not decoration. Landed at the
    same x they make an arrowhead, and an arrowhead in a menu bar is a send
    button. Landed 20 percent of the width apart they make what the tile draws:
    the icon's own lanes are not symmetric either, its upper lane crosses most of
    the canvas to arrive and its lower one barely moves.
    """
    w = 118.0
    lanes = [solid(ribbon(centreline(50.0, 50.0, LANE / 2, w - LANE / 2), LANE))]
    for y0, xm in ((LANE / 2, TOP_LANDS), (100 - LANE / 2, BOTTOM_LANDS)):
        lanes.append(solid(ribbon(centreline(y0, 50.0, LANE / 2, xm * w), LANE)))
    return w, lanes


def trio():
    """The icon's three lanes, spread on the left and bundled on the right.

    The literal reduction, and the one to beat. It keeps what the tile does,
    three lanes that arrive apart and leave side by side, and it is drawn here at
    the only weight that lets it: a lane of 1.65 points with 3.3 points of air
    either side, which is Apple's proportion in `slider.horizontal.3` and thin
    enough that the gaps hold at 1x.

    What it costs is the gesture. Three lanes and their two gaps take 77 of the
    100 units, so the fan has 23 to open by, which at fifteen points is a third
    of a point of slope per lane. It reads as three lines that are very slightly
    not parallel, and three lines in a menu bar is a list.
    """
    w = 133.0
    lane, gap = LANE * 0.85, GAP * 1.47
    d = lane + gap
    lanes = [(lane / 2, 50 - d), (50.0, 50.0), (100 - lane / 2, 50 + d)]
    return w, [solid(ribbon(centreline(y0, y1, lane / 2, w - lane / 2), lane))
               for y0, y1 in lanes]


def pair():
    """Two lanes converging, and no third.

    What trio looks like with a third of the information taken out. Worth
    drawing because two lanes can be twice as far apart as three, and a gap that
    survives is worth more than a lane that does not.
    """
    w = 126.0
    d = (LANE + GAP * 1.6) / 2
    lanes = [(LANE / 2, 50 - d), (100 - LANE / 2, 50 + d)]
    return w, [solid(ribbon(centreline(y0, y1, LANE / 2, w - LANE / 2), LANE))
               for y0, y1 in lanes]


def meet():
    """Two lanes arriving level and one leaving.

    `gather` with the third lane taken out and the two arrivals put back level,
    which is the version to look at before accepting the stagger. It is the
    cleanest shape in the round at 1x and it is also, unmistakably, an arrow
    pointing left.
    """
    w = 118.0
    xm = 0.60 * w
    return w, [solid(ribbon(centreline(50.0, 50.0, xm - LANE, w - LANE / 2), LANE))] + [
        solid(ribbon(centreline(y0, 50.0, LANE / 2, xm), LANE))
        for y0 in (LANE / 2, 100 - LANE / 2)]


def bar():
    """The crossing bar on its own.

    The negative, drawn so it can be looked at rather than argued about. It is
    the crispest of the first six at 1x by a distance and it says nothing: one eased
    stroke is a swoosh, and a swoosh is not the mark for an app whose whole
    subject is several things running at once.
    """
    w = 118.0
    t = LANE * 1.5
    return w, [solid(ribbon(centreline(20.0, 80.0, t / 2, w - t / 2), t))]


def panel():
    """The panel silhouette with the bar cut through it and a tongue running out.

    The app icon's own composition with the colour gone: what was a Deep panel is
    the mark, what was the pale bar is the slot the mark does not cover, and the
    spur still carries the slot out past the panel's lower right corner.

    The slot is never painted rather than subtracted. The panel is cut into the
    piece above the bar and the piece below it, the strip of spur lying either
    side of the bar is its own ribbon, and a disc closes the tongue's tip, so
    five solids union under the nonzero rule and the slot is where none of them
    is.
    """
    w = 124.0
    p = squircle(0, 0, 100.0, 100.0)
    slot = LANE * 1.25
    wall = 7.0                      # how much spur is proud of the slot per side
    mid = centreline(40.0, 74.0, -12.0, w - (slot + 2 * wall) / 2)
    inside = [q for q in mid if q[0] >= 0.0]
    off = (slot + wall) / 2
    return w, [
        solid(clip(p, [(x, y - slot / 2) for x, y in mid], "above")),
        solid(clip(p, [(x, y + slot / 2) for x, y in mid], "below")),
        solid(ribbon([(x, y - off) for x, y in inside], wall, caps=(False, True))),
        solid(ribbon([(x, y + off) for x, y in inside], wall, caps=(False, True))),
        solid(ribbon(mid[-2:], slot + 2 * wall)),
    ]



# ------------------------------------------------- the fluid ten
#
# The shipped mark reads as three straight-ish lines converging to a point, and
# beside Dropbox and 1Password that is the hardest thing on the bar. Four things
# make it so and each of them can be turned separately, which is what these ten
# are for:
#
#   THE WINDOW. `WINDOW` above cuts the mark from the band's settled end, where
#   the ease has already spent itself, so a lane is nearly straight and then
#   flattens. `SWEEP` takes the whole band instead: flat, one bend, flat, which
#   is an S rather than a bent line. Same curve, more of it.
#
#   THE JOIN. A lane landing on the trunk at four degrees leaves a needle of
#   empty wedge. At fifteen points that needle is one pixel that flickers with
#   the rounding, and it is the single sharpest thing in the mark. It can be
#   filled (`fillet`), dissolved by thinning the lane into the trunk (`stem`),
#   or refused by not landing at all (`near`, `wake`).
#
#   THE WEIGHT. One thickness end to end is a plot. Weight that swells through
#   the bend is a stroke.
#
#   THE FILL. The mark is 15.0 where Dropbox is 16.0, and it is the only mark on
#   the bar made of lines rather than a body, so it carries further than its
#   height says. `calm` gives some of that height back.
SWEEP = (0.0, 1.0)


def _ease(s):
    return s * s * (3 - 2 * s)


def flow():
    """The shipped composition cut from the whole band, so the lanes are S
    curves. Nothing else changes: same three lanes, same stagger, same weight.
    This is the curvature on its own, so the rest can be judged against it."""
    w = 120.0
    r = LANE / 2
    out = [solid(ribbon(centreline(50.0, 50.0, r, w - r, window=SWEEP), LANE))]
    for y0, xm in ((r, 0.72), (100 - r, 0.50)):
        out.append(solid(ribbon(
            centreline(y0, 50.0, r, xm * w, window=SWEEP), LANE)))
    return w, out


def swell():
    """flow with the weight modulated the way a nib would lay it: each arriving
    lane starts light at its open end and reaches full weight through its bend,
    and the trunk thickens as the lanes feed into it. A lane that is one
    thickness end to end is plotted; one that changes has a direction."""
    w = 120.0
    r = LANE / 2
    trunk = lambda s: LANE * (0.80 + 0.20 * _ease(s))
    arm = lambda s: LANE * (0.62 + 0.38 * _ease(s))
    out = [solid(ribbon(centreline(50.0, 50.0, r, w - r, window=SWEEP), trunk))]
    for y0, xm in ((r, 0.72), (100 - r, 0.50)):
        out.append(solid(ribbon(
            centreline(y0, 50.0, r, xm * w, window=SWEEP), arm)))
    return w, out


def stem():
    """The lanes thin into the trunk instead of butting against it.

    A lane at full weight landing at a shallow angle leaves the needle of empty
    wedge described above. A lane that has narrowed to a fifth of its weight by
    the time it arrives leaves none: its edges dive across the trunk's edge
    steeply and the outline turns a broad corner instead of a sharp one. It is
    how a vein meets a midrib, and it costs nothing at the open end, where the
    lane is at full weight and doing the reading."""
    w = 120.0
    r = LANE / 2
    taper = lambda s: LANE * (1.0 - 0.82 * _ease(s))
    out = [solid(ribbon(centreline(50.0, 50.0, r, w - r, window=SWEEP), LANE))]
    for y0, xm in ((r, 0.78), (100 - r, 0.56)):
        out.append(solid(ribbon(
            centreline(y0, 50.0, r, xm * w, window=SWEEP), taper)))
    return w, out


def fillet_():
    """The shipped mark with a gusset in each crotch, and nothing else touched.

    The smallest change that answers the complaint, and worth seeing on its own
    before anything else is spent: if what reads as harsh is the corner where a
    lane lands rather than the straightness of the lanes themselves, then this is
    the whole of the fix and the mark the owner already approved otherwise stays
    exactly as it is.
    """
    w = 118.0
    r = LANE / 2
    trunk = centreline(50.0, 50.0, r, w - r)
    out = [solid(ribbon(trunk, LANE))]
    for y0, xm, above in ((r, TOP_LANDS, True), (100 - r, BOTTOM_LANDS, False)):
        arm = centreline(y0, 50.0, r, xm * w)
        out.append(solid(ribbon(arm, LANE)))
        # +n is the lower side of a rightward line, so the edge facing the
        # counter is the arm's lower one under the trunk's upper one.
        g = cove(edge(arm, LANE, 1 if above else -1),
                 50 - LANE / 2 if above else 50 + LANE / 2, LANE * 1.7)
        if g:
            out.append(solid(g))
    return w, out


def near():
    """Three lanes that never touch. The two arrivals run out of width just
    short of the trunk, a lane's width of air between cap and edge, so the
    convergence is read rather than drawn. There is no junction to be sharp, and
    at fifteen points the eye closes a gap that small anyway. The gamble is 1x,
    where that air is one pixel and may close on its own."""
    w = 122.0
    r = LANE / 2
    air = 4.0
    trunk = centreline(50.0, 50.0, r, w - r, window=SWEEP)
    out = [solid(ribbon(trunk, LANE))]
    for y0, sign, xm in ((r, -1, 0.74), (100 - r, 1, 0.54)):
        yend = 50 + sign * (LANE + air)
        out.append(solid(ribbon(
            centreline(y0, yend, r, xm * w, window=SWEEP), LANE)))
    return w, out


def duet():
    """Two lanes and no third, so each of them can be twice as far from the
    other and twice as curved before they crowd. One runs the width, the other
    sweeps up out of the lower left and joins it late. Half the information of
    the shipped mark and, at fifteen points, most of the meaning."""
    w = 116.0
    lane = LANE * 1.14
    r = lane / 2
    # Both lanes flatten onto y=52 as they run out, so the last fifth of the
    # width is one lane and there is no junction anywhere: the trunk IS the two
    # of them arrived. Staggered starts, because two mirrored curves meeting at
    # a point is an arrowhead.
    out = [solid(ribbon(centreline(28.0, 58.0, r, w - r, window=SWEEP), lane)),
           solid(ribbon(centreline(94.0, 58.0, 0.34 * w, w - r, window=SWEEP),
                        lane))]
    return w, out


def wake():
    """Two S curves running the whole width, out of phase, never meeting.

    The pure case: no junction, no convergence, nothing to be sharp anywhere.
    What it says is current rather than gathering, which may be the wrong thing
    to say, and it is here so the wrong thing can be looked at."""
    w = 124.0
    r = LANE / 2
    out = []
    # Staggered in x as well as offset in y, because two strokes of the same
    # length stacked one above the other is a list, whatever shape they are.
    for y0, y1, xa, xb in ((16.0, 46.0, r, 0.84 * w),
                           (58.0, 88.0, 0.16 * w, w - r)):
        out.append(solid(ribbon(centreline(y0, y1, xa, xb, window=SWEEP), LANE)))
    return w, out


def brush():
    """Two lanes with no ends: the weight rises out of nothing and falls back
    into it, so there are no caps to cut flat and no tips to catch the light.
    The convergence is a crossing rather than a landing, and where they overlap
    they are simply thicker."""
    w = 122.0
    heavy = lambda s: LANE * 1.20 * math.sin(math.pi * s) ** 0.40
    light = lambda s: LANE * 1.02 * math.sin(math.pi * s) ** 0.40
    main = centreline(54.0, 42.0, 1.0, w - 1.0, window=SWEEP)
    xj = 0.72 * w
    # The second stroke ends ON the first one's centre line rather than crossing
    # it, so the two lie down together instead of piling up where they meet.
    yj = next(y for x, y in main if x >= xj)
    return w, [
        solid(ribbon(main, heavy)),
        solid(ribbon(centreline(93.0, yj, 0.10 * w, xj, window=SWEEP), light)),
    ]


def calm():
    """flow, given back some of its height.

    The mark measures 15.0 where Dropbox is 16.0, and it is the only thing on
    the bar drawn in lines rather than as a body, so it reads bigger than it
    measures. This is the same drawing at 87 percent, which puts the art at 13.1
    points inside the same 18 point box, with the weight kept up so the lanes do
    not go thin as well as short. FILL below is what does it."""
    return flow()


def crest():
    """One lane and a shorter one riding above it, and no junction at all.

    The most reduced of the ten: two round capped strokes, both S curves, the
    upper one about two thirds the length and slightly lighter. Nothing meets,
    nothing crosses, and the pair reads as one gesture because they are two
    stretches of the same curve."""
    w = 118.0
    lane = LANE * 1.16
    r = lane / 2
    out = [solid(ribbon(centreline(88.0, 58.0, r, 0.80 * w, window=SWEEP), lane))]
    out.append(solid(ribbon(centreline(42.0, 12.0, 0.20 * w, w - r,
                                       window=SWEEP), lane * 0.9)))
    return w, out


# ------------------------------------------------- calm, heavier
#
# The owner picked `calm` and then said it looks thin in the bar. It does: at 87
# percent of the standard art a lane of 13 units is 1.70 points, against 1.95 for
# the mark that ships and against a Dropbox drawn as a solid body. His complaint
# is relative weight beside his other icons, not absolute thickness.
#
# THE ONE LINE VERSION OF THIS IS WRONG. Winding LANE up and changing nothing
# else spends points the box has already given away. `calm` is 13.1 points of art
# in an 18 point image, and what holds its three lanes apart is not air between
# parallel lanes, which it does not have, but the two counters left between each
# arriving lane and the trunk it lands on. Those counters are what closes first,
# and at 1x they are two pixels. Close them and the mark is a blob, which is the
# failure `trio` and `panel` were rejected for.
#
# So each of the five below pays for its weight with something, and they differ
# in WHAT they give back rather than in how thick they are:
#
#   stout   the height calm gave up: back to the full 15 points of art
#   open    horizontal room: a wider box, so the lanes arrive shallower and the
#           counters are longer at the same outer height
#   two     a lane: two heavier lanes instead of three
#   spine   nothing. The weight goes only on the trunk, which is what carries at
#           a glance, and the arrivals stay at calm's weight
#   tall    vertical extent: 15.9 points of art, level with Dropbox at 16.0
#
# Everything else is calm's: the S curves off the whole band, the round
# terminals, the staggered landings, and no two arrivals level with each other.
def _fan(w, lane, arms, trunk=None):
    """calm's composition at any weight. A level trunk with one or two lanes
    arriving on it, each one an S off the whole band and each landing at its own
    x, because two landing at the same one is an arrowhead."""
    t = lane if trunk is None else trunk
    out = [solid(ribbon(centreline(50.0, 50.0, t / 2, w - t / 2, window=SWEEP), t))]
    for y0, xm in arms:
        out.append(solid(ribbon(
            centreline(y0, 50.0, lane / 2, xm * w, window=SWEEP), lane)))
    return w, out


def stout():
    """Heavier, and given back the height calm gave up.

    calm is flow at 87 percent, so the simplest way to pay for a thicker lane is
    to stop being short: 15.0 points of art, which is what the mark in the bar
    measures today, with the lane wound from 13 units to 15.5. That is 2.33
    points of lane against 1.95 today, and the counters are wider than calm's
    rather than narrower, because they grew with the box."""
    lane = 15.5
    return _fan(122.0, lane, ((lane / 2, 0.72), (100 - lane / 2, 0.50)))


def wide():
    """Heavier, and given back horizontal room instead of height.

    Stays at calm's 13.1 points, so it sits no taller beside Dropbox than the one
    he picked, and buys the room for an 18 unit lane by being wider: the box goes
    from 120 to 134 and both landings move right, so each lane arrives shallower
    and its counter is longer at the same outer height. The cost is bar width,
    which is the one dimension the menu bar is not short of."""
    lane = 17.0
    return _fan(140.0, lane, ((lane / 2, 0.82), (100 - lane / 2, 0.58)))


def two():
    """Heavier, and given back a lane.

    Three lanes at 13.1 points is what makes calm thin: the box is divided three
    ways before anything is drawn. Two lanes divide it twice and can be half
    again as heavy, 2.76 points, which is the weight of a real menu bar glyph.
    What it gives up is the third lane, and with it the reading that several
    things are running rather than two. The remaining arrival still lands off
    centre, so it is a branch joining a road and not an arrow."""
    lane = 20.0
    return _fan(116.0, lane, ((lane / 2, 0.70),))


def spine():
    """Heavier where it reads, and nowhere else.

    The trunk is the part that carries at a glance, so it takes the weight, 2.57
    points, and the two arrivals stay at calm's 1.69. Nothing is given back
    because nothing has to be: the counters are set by where the ARRIVALS run,
    and they have not moved. The risk is the opposite of the one he reported,
    that a heavy bar with light feathers on it reads as a bar."""
    lane, trunk = 12.5, 19.0
    return _fan(120.0, lane, ((lane / 2, 0.74), (100 - lane / 2, 0.52)),
                trunk=trunk)


def tall():
    """Heavier, and allowed to fill more of the box than the mark ever has.

    calm measures 13.1 points where Dropbox measures 16.0 and 1Password 16.0.
    This is 15.9, level with both of them, which is taller than the mark that
    ships as well as the one he picked. A 14 unit lane on that height is 2.23
    points. The old worry was that a mark filling its box looks bigger than
    everything next to it; the reply is that his complaint is that it does not."""
    lane = 14.0
    return _fan(120.0, lane, ((lane / 2, 0.72), (100 - lane / 2, 0.50)))


# ------------------------------------------------- one drawing, thirteen knobs
#
# The owner has now rejected three rounds of fixed candidates, and the reason is
# in the record: every round he asked for one thing to move and got a fresh set
# of drawings to choose between, which is a slower way of saying no. `design`
# below is every candidate in this file that is a trunk with lanes arriving on
# it, written once with its choices as arguments, so the question stops being
# "which of these five" and becomes "where do these thirteen numbers go".
#
# It is the thing `Tools/icon/designer.html` draws, and that page's whole claim
# is that its geometry IS this function: the same curve, the same ribbon, the
# same terminals, ported and then checked pixel against pixel. If this signature
# changes, that port changes with it or the page starts lying.
#
# WHAT IS NOT A KNOB, and why.
#
#   The band. XS and the window's far end at t = 1 are lib9's, shared with the
#   app icon, and they are what lets this mark claim to be the icon's own
#   gesture rather than something that resembles it. A knob on the band is a
#   knob on the icon.
#
#   The window's far end. At t = 1 the cubic's tangent is flat, which is what
#   makes the lanes arrive parallel. Move it and they arrive at an angle, which
#   is `trio`'s failure: three tilted bars.
#
#   The bleed. The image AppKit lays out is 18 points and the art sits centred
#   in it. That is a render size, not a drawing decision, and the page shows the
#   two sizes it is used at rather than offering a slider for them.
DEFAULTS = dict(
    lane=13.0,          # a lane's weight in box units, so 13 is 13 percent of art
    fill=0.87,          # art height as a fraction of the standard 15.0 points
    width=120.0,        # the box's width in the same units the height is 100 of
    spread=1.0,         # how far up and down the box the arrivals start
    land=0.72,          # where the upper lane lands, as a fraction of the width
    stagger=0.22,       # how much earlier the lower one lands. Zero is an arrow
    t0=0.0,             # where on the band the mark is cut from. 0 is the full S
    trunk=1.0,          # the trunk's weight as a multiple of a lane's
    trunk_start=0.0,    # where the trunk begins, as a fraction of the width
    cap=1.0,            # terminals: 1 is a half circle, 0 is a flat cut
    lanes=3,            # three arriving, or two
    cove_run=0.0,       # how far back a junction is coved, in lane widths
    taper=0.0,          # -1 thins into the trunk, +1 thins at the open end
)


def design(**kw):
    """Every trunk and lanes candidate in this file, as one drawing."""
    p = dict(DEFAULTS)
    p.update(kw)
    w, lane, win = float(p["width"]), float(p["lane"]), (float(p["t0"]), 1.0)
    t = lane * p["trunk"]
    cap = p["cap"]
    out = [solid(ribbon(centreline(50.0, 50.0, p["trunk_start"] * w + t / 2,
                                   w - t / 2, window=win), t, cap=cap))]

    taper = p["taper"]
    if taper > 0:
        arm_w = lambda s: lane * (1 - taper * 0.38 * (1 - _ease(s)))
    elif taper < 0:
        arm_w = lambda s: lane * (1 + taper * 0.82 * _ease(s))
    else:
        arm_w = lane

    reach = p["spread"] * (50.0 - lane / 2)
    arms = [(50.0 - reach, p["land"])]
    if int(p["lanes"]) > 2:
        arms.append((50.0 + reach, p["land"] - p["stagger"]))
    for y0, xm in arms:
        pts = centreline(y0, 50.0, lane / 2, xm * w, window=win)
        out.append(solid(ribbon(pts, arm_w, cap=cap)))
        if p["cove_run"] > 0:
            above = y0 < 50.0
            g = cove(edge(pts, arm_w, 1 if above else -1),
                     50.0 - t / 2 if above else 50.0 + t / 2, lane * p["cove_run"])
            if g:
                out.append(solid(g))
    return w, out


# Every named candidate above that `design` can say, as the numbers that say it.
# Checked against the functions themselves by Tools/icon/check_designer.py, so a
# preset cannot quietly stop being the mark it is named after.
PRESETS = {
    "gather": dict(lane=13.0, fill=1.00, width=118.0, land=0.70, stagger=0.22,
                   t0=0.20),
    "flow":   dict(lane=13.0, fill=1.00, width=120.0, land=0.72, stagger=0.22),
    "calm":   dict(lane=13.0, fill=0.87, width=120.0, land=0.72, stagger=0.22),
    "stem":   dict(lane=13.0, fill=1.00, width=120.0, land=0.78, stagger=0.22,
                   taper=-1.0),
    "fillet": dict(lane=13.0, fill=1.00, width=118.0, land=0.70, stagger=0.22,
                   t0=0.20, cove_run=1.7),
    "stout":  dict(lane=15.5, fill=1.00, width=122.0, land=0.72, stagger=0.22),
    "wide":   dict(lane=17.0, fill=0.87, width=140.0, land=0.82, stagger=0.24),
    "two":    dict(lane=20.0, fill=0.92, width=116.0, land=0.70, lanes=2),
    "spine":  dict(lane=12.5, fill=0.90, width=120.0, land=0.74, stagger=0.22,
                   trunk=19.0 / 12.5),
    "tall":   dict(lane=14.0, fill=1.06, width=120.0, land=0.72, stagger=0.22),

    # The one the owner built himself on `designer.html`, pasted off the page
    # unchanged. "mine" is the name that page prints, not a description; every
    # other name here says what the mark does and this one says who drew it.
    #
    # It is the biggest mark this file has ever shipped: 18.00 points of art in
    # a 21.00 point image, where `gather` was 15.00 in 18.00 and the SF Symbol
    # it replaced was 11.0. That is taller than Dropbox at 16.0 and 1Password at
    # 16.0, which the docstring above argues against and he has overruled,
    # because the complaint the whole round is answering is that the mark reads
    # thin. The lane is 3.53 points and the trunk 4.13, against 1.95 and 1.95 on
    # `gather`, so it is more than twice the weight, and the taper thins each
    # arrival into the trunk so the joins carry no needle.
    "mine":   dict(lane=19.60, fill=1.20, width=119.00,
                   spread=1.00, land=0.89, stagger=0.22,
                   t0=0.000, trunk=1.17, trunk_start=0.00,
                   cap=1.00, lanes=3, cove_run=0.00,
                   taper=-0.28),
}


# His mark at the height of the thing next to it.
#
# `mine` is 18.00 points of art. Measured in his own bar it came back at exactly
# that, 18.00 tall and 21.00 wide, and it was the tallest thing there: Dropbox
# beside it measures 16.5 at the ink edge and about 16.3 once the antialiased
# rows are weighted, the 1Password ring 16.0, the database 17.5, the battery
# 13.0. He asked for Dropbox's height instead, and this is it.
#
# ONE NUMBER MOVES, WHICH IS THE POINT. `fill` is the only difference from
# `mine`, so the drawing is not redrawn at a new size: every proportion he set
# on the page, the landings, the stagger, the taper, the trunk's ratio to a
# lane, is carried over and the whole thing is scaled. It is the same lever
# `calm` is `flow` at 87 percent with.
#
# AND THE WEIGHT SURVIVES IT, which was the thing worth checking, because the
# complaint this whole round answers is that the mark reads thin and a shorter
# mark is a lighter one. A lane is 19.60 box units, so at 16.50 points of art it
# is 3.23 points and the trunk is 3.78. `gather`, the mark he called thin, has
# 1.95 of each, and `two`, the heaviest of the five he was offered after that,
# has 2.76. So this is still above everything he rejected, and height and weight
# are not in tension here.
#
# 16.5 AND NOT 16.0. It shipped at 16.0 first, on the grounds that two earlier
# passes over his bar had arrived at that number independently and a round
# number is easier to move. 16.5 is what the ink edge of Dropbox actually
# measures at 2x, and he asked for Dropbox's height rather than for a tidy
# figure, so the measurement wins. Half a point on a sixteen point mark is three
# percent; it is a full pixel at 2x on the tallest row of the drawing, which is
# why it is worth taking rather than rounding away.
DROPBOX_HEIGHT = 16.5
PRESETS["level"] = dict(PRESETS["mine"], fill=DROPBOX_HEIGHT / ART_HEIGHT)


# How much of the box each mark fills, as a fraction of the standard art
# height. One number, applied at render time, so a candidate can be tried
# smaller without its geometry being redrawn.
FILL = {"calm": 0.87, "stout": 1.00, "wide": 0.87, "two": 0.92,
        "spine": 0.90, "tall": 1.06}


CANDIDATES = [
    ("gather", gather), ("trio", trio), ("pair", pair),
    ("meet", meet), ("bar", bar), ("panel", panel),
    ("flow", flow), ("swell", swell), ("stem", stem), ("fillet", fillet_),
    ("near", near), ("duet", duet), ("wake", wake), ("brush", brush),
    ("calm", calm), ("crest", crest),
    ("stout", stout), ("wide", wide), ("two", two), ("spine", spine),
    ("tall", tall),
]

BLURB = {
    "gather": "three lanes arrive, one leaves, staggered",
    "trio": "the icon exactly: spread on the left, bundled on the right",
    "pair": "two lanes converging, and no third",
    "meet": "two lanes arrive level, one leaves",
    "bar": "the crossing bar alone. The negative",
    "panel": "the panel, the bar cut through it, a tongue out",
    "flow": "the same three lanes cut from the whole band, so they are S curves",
    "swell": "flow, with the weight swelling through each bend",
    "stem": "the lanes thin into the trunk, so the joins have no needle in them",
    "fillet": "the shipped mark with an arc inscribed in each crotch, nothing else",
    "near": "the arrivals stop short: convergence read, never drawn",
    "duet": "two lanes only, twice the air, joining late",
    "wake": "two S curves out of phase that never meet",
    "brush": "no caps at all: the weight rises out of nothing and falls back",
    "calm": "flow at 87 percent, so it sits under Dropbox rather than level",
    "crest": "one lane and a shorter one above it, nothing meeting",
    "stout": "calm heavier, paid for with the height calm gave up",
    "wide": "calm heavier, paid for with width: shallower arrivals, longer counters",
    "two": "calm heavier, paid for with a lane: two at 2.76 points instead of three",
    "spine": "the trunk heavier and the arrivals left at calm's weight",
    "tall": "calm heavier and 15.9 points tall, level with Dropbox",
}

# The ten the owner was first choosing between, in the order they were shown.
FLUID = ["flow", "swell", "stem", "fillet", "near",
         "duet", "wake", "brush", "calm", "crest"]

# He picked calm and asked for it heavier. These are the five, and they differ in
# what each gives back for the weight rather than in how thick they are.
HEAVIER = ["stout", "wide", "two", "spine", "tall"]


# A candidate by name, whether somebody wrote it as a function above or the
# designer page handed over a row of numbers. `CHOICE` can therefore be set to a
# preset that has no function at all, which is what makes shipping something the
# owner built himself a paste and a constant rather than a translation.
def draw(name):
    if name in dict(CANDIDATES):
        return dict(CANDIDATES)[name]()
    return design(**PRESETS[name])


def fill_of(name):
    if name in FILL:
        return FILL[name]
    if name in PRESETS:
        return PRESETS[name].get("fill", 1.0)
    return 1.0


# --------------------------------------------------------------- the backends
#
# One geometry, two writers. The PDF is what ships, because AppKit redraws a PDF
# at whatever scale the display asks for and one file is then right on a 1x
# monitor and a 2x one. The SVG exists so the same polygons can be handed to
# rsvg-convert at exact pixel sizes for the sheet.
def fit(polys, w, height, bleed=BLEED):
    """The box scaled to a height in points, with the bleed added around it."""
    k = height / 100.0
    return ([[(bleed + x * k, bleed + y * k) for x, y in p] for p in polys],
            (w * k + 2 * bleed, height + 2 * bleed))


def svg(polys, size, colour="#000"):
    d = []
    for p in polys:
        d.append("M%.3f,%.3f" % p[0]
                 + "".join("L%.3f,%.3f" % q for q in p[1:]) + "Z")
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="%.3f" height="%.3f" '
            'viewBox="0 0 %.3f %.3f"><path fill="%s" fill-rule="nonzero" '
            'd="%s"/></svg>' % (size[0], size[1], size[0], size[1], colour,
                                "".join(d)))


def pdf(polys, size):
    """A one page PDF, written out by hand.

    Nothing here needs a PDF library: one page, one content stream, one filled
    path, and the page box is the image's size in points, which is what AppKit
    reads back as `NSImage.size`. Writing it by hand keeps this folder buildable
    with nothing installed, which is what vendoring lib.py beside it was for.
    """
    ops = ["0 g", "1 0 0 -1 0 %.4f cm" % size[1]]
    for p in polys:
        ops.append("%.4f %.4f m" % p[0])
        ops += ["%.4f %.4f l" % q for q in p[1:]]
        ops.append("h")
    ops.append("f")
    stream = ("\n".join(ops) + "\n").encode("ascii")

    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        ("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 %.4f %.4f] "
         "/Contents 4 0 R /Resources << >> >>" % size).encode("ascii"),
        b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"\nendstream",
    ]
    out = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = []
    for i, body in enumerate(objects, start=1):
        offsets.append(len(out))
        out += b"%d 0 obj\n" % i + body + b"\nendobj\n"
    start = len(out)
    out += b"xref\n0 %d\n" % (len(objects) + 1)
    out += b"0000000000 65535 f \n"
    for off in offsets:
        out += b"%010d 00000 n \n" % off
    out += (b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n"
            % (len(objects) + 1, start))
    return bytes(out)


# -------------------------------------------------------------------- outputs
def asset(name=CHOICE):
    """The shipped template image."""
    w, polys = draw(name)
    polys, size = fit(polys, w, ART_HEIGHT * fill_of(name))
    out = os.path.join(RESOURCES, "BloomMenuBar.pdf")
    with open(out, "wb") as f:
        f.write(pdf(polys, size))
    return out


def png(name, points, scale, path, colour="#000"):
    """One candidate at an exact pixel size, through rsvg-convert.

    `points` is the whole image's height, bleed included, which is the number
    AppKit lays out: the shipped asset is 18, of which 15 is mark. The size is
    asked for in pixels rather than left to the SVG, because the question the
    sheet answers is what the rasteriser does with a 2 point lane at 1x, and a
    render at any other size cannot answer it.
    """
    w, polys = draw(name)
    # The image stays the height AppKit was asked for and the art inside it
    # shrinks, because that is what a shorter mark in the bar actually is: the
    # status item centres whatever it is given, so height given back to the
    # bleed is height the mark does not occupy.
    art = (points - 2 * BLEED) * fill_of(name)
    polys, size = fit(polys, w, art, (points - art) / 2.0)
    src = os.path.join(BUILD, "tmp.svg")
    with open(src, "w") as f:
        f.write(svg(polys, size, colour))
    subprocess.run(["rsvg-convert", "-w", str(int(round(size[0] * scale))),
                    "-h", str(int(round(size[1] * scale))), src, "-o", path],
                   check=True)
    return path


# The owner's own menu bar, sampled off a capture of it, and a light one for the
# case a template exists to handle. Colours rather than the screenshot itself, so
# the sheet is reproducible and carries no picture of anybody's desk.
DARK = (25, 30, 80)
LIGHT = (242, 242, 244)
FONTS = ["/System/Library/Fonts/SFNS.ttf",
         "/System/Library/Fonts/SFNSDisplay.ttf",
         "/System/Library/Fonts/Helvetica.ttc"]


def sheet():
    """Every candidate at both sizes, both scales and both bars, at actual size
    and again with every device pixel drawn as a block.

    The magnified copies are nearest neighbour on purpose: a smoothed
    enlargement of a fifteen pixel image shows what was hoped for rather than
    what the display will do with it.
    """
    from PIL import Image, ImageDraw, ImageFont

    def font(size):
        for face in FONTS:
            try:
                return ImageFont.truetype(face, size)
            except OSError:
                continue
        return ImageFont.load_default(size)

    os.makedirs(BUILD, exist_ok=True)
    zoom, pad, columns = 8, 16, [(16, 1), (16, 2), (18, 1), (18, 2)]
    rows = []
    for name, _ in CANDIDATES:
        cells = {}
        for points, scale in columns:
            path = os.path.join(BUILD, "%s-%dpt@%dx.png" % (name, points, scale))
            png(name, points, scale, path)
            cells[(points, scale)] = Image.open(path).convert("RGBA")
        rows.append((name, cells))

    wide = max(max(im.width for im in cells.values()) for _, cells in rows)
    tall = max(max(im.height for im in cells.values()) for _, cells in rows)
    colw = wide * zoom + wide + 30
    rowh = tall * zoom * 2 + 60
    width = pad * 2 + colw * len(columns)
    top = 78
    height = top + rowh * len(rows) + 76
    sheet = Image.new("RGBA", (width, height), (255, 255, 255, 255))
    draw = ImageDraw.Draw(sheet)

    draw.text((pad, 16), "Bloom in the menu bar: every candidate, each drawn at "
                         "the size it is used at",
              fill=(20, 20, 24), font=font(21))
    draw.text((pad, 44), "One template image per row. The top strip in each cell "
                         "is a dark menu bar, the bottom strip a light one, and "
                         "the system tints the same file for both.",
              fill=(110, 110, 118), font=font(14))
    for i, (points, scale) in enumerate(columns):
        draw.text((pad + colw * i, top - 6),
                  "%d points at %dx, so %d device pixels, %.0f of them mark"
                  % (points, scale, points * scale, (points - 2 * BLEED) * scale),
                  fill=(60, 60, 66), font=font(14))

    y = top + 18
    for name, cells in rows:
        draw.text((pad, y + 4), name, fill=(20, 20, 24), font=font(17))
        draw.text((pad + 62, y + 6), BLURB[name], fill=(140, 140, 148), font=font(13))
        for i, key in enumerate(columns):
            im = cells[key]
            big = im.resize((im.width * zoom, im.height * zoom), Image.NEAREST)
            for j, bg in enumerate((DARK, LIGHT)):
                # What the status bar does to a template: it tints it with the
                # label colour of the bar's own appearance, which is white on one
                # of these and near black on the other.
                ink = (255, 255, 255, 255) if j == 0 else (28, 28, 32, 255)
                tile = Image.new("RGBA", big.size, bg + (255,))
                tinted = Image.new("RGBA", big.size, ink)
                tinted.putalpha(big.split()[3])
                tile.alpha_composite(tinted)
                x = pad + colw * i
                sheet.alpha_composite(tile, (x, y + 24 + j * (big.height + 6)))
                # Actual size beside the magnification, so the sheet shows the
                # thing itself and not only the microscope.
                one = Image.new("RGBA", (im.width + 10, big.height), bg + (255,))
                mark = Image.new("RGBA", im.size, ink)
                mark.putalpha(im.split()[3])
                one.alpha_composite(mark, (5, (big.height - im.height) // 2))
                sheet.alpha_composite(one, (x + big.width + 8,
                                            y + 24 + j * (big.height + 6)))
        y += rowh

    draw.text((pad, y + 8),
              "Magnified eight times, nearest neighbour, so one block is one "
              "device pixel. The narrow strip beside each is the same file at "
              "actual size.", fill=(110, 110, 118), font=font(14))
    draw.text((pad, y + 32),
              "The 1x columns are the ones that decide: that is an external "
              "monitor, where a 2 point lane has two pixels and the gap holding "
              "trio's bundle apart has two and a bit.",
              fill=(110, 110, 118), font=font(14))
    out = os.path.join(BUILD, "candidates.png")
    sheet.convert("RGB").save(out)
    return out


if __name__ == "__main__":
    os.makedirs(BUILD, exist_ok=True)
    if "--sheet" not in sys.argv:
        print("==>", asset())
    print("==>", sheet())
