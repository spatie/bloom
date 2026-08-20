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

  Dropbox        16.0 points tall, 18.0 wide, solid shapes
  the database   17.5 tall, 17.0 wide, 1.5 point strokes
  1Password      16.0 tall, 16.0 wide
  Saturn         14.5 tall, 21.0 wide
  the old mark   11.0 tall, 13.5 wide

The old mark is `point.3.connected.trianglepath.dotted` at its default size, and
being five points shorter than everything beside it is why it read as faint.
`ART_HEIGHT` is 15.0: level with Saturn, a little under Dropbox, and short of the
17.5 the database fills, because a mark that fills its box looks bigger than
everything next to it.

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

# The candidate that ships. One line, and the other five stay in the file, so
# swapping the mark is a rerun rather than a redraw.
CHOICE = "gather"

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


def _cap(p, tangent, normal, r, at_end):
    """Half a circle at one end of a ribbon, swept through the tangent so it
    bulges past the end rather than doubling back over the ribbon."""
    a0 = (math.atan2(normal[1], normal[0]) if at_end
          else math.atan2(-normal[1], -normal[0]))
    at = (math.atan2(tangent[1], tangent[0]) if at_end
          else math.atan2(-tangent[1], -tangent[0]))
    turn = math.atan2(math.sin(at - a0), math.cos(at - a0))
    step = math.copysign(math.pi / 12, turn)
    return [(p[0] + r * math.cos(a0 + step * k), p[1] + r * math.sin(a0 + step * k))
            for k in range(1, 12)]


def ribbon(pts, width, caps=(True, True)):
    """A centre line given a width: the shape a stroke would paint, as a polygon.

    Drawn rather than stroked because two candidates cut a slot in themselves,
    and a slot is either a subpath with the opposite winding or a piece that is
    simply not painted. A stroked path can be neither, so everything here is a
    filled polygon and there is one mechanism instead of two.
    """
    r = width / 2.0
    fr = _frames(pts)
    left = [(p[0] + n[0] * r, p[1] + n[1] * r) for p, (_, n) in zip(pts, fr)]
    right = [(p[0] - n[0] * r, p[1] - n[1] * r) for p, (_, n) in zip(pts, fr)]
    out = list(left)
    if caps[1]:
        out += _cap(pts[-1], fr[-1][0], fr[-1][1], r, True)
    out += list(reversed(right))
    if caps[0]:
        out += _cap(pts[0], fr[0][0], fr[0][1], r, False)
    return out


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
# down, filled as one nonzero path. Six of them, because the only honest way to
# pick a mark for a fifteen point box is to look at all of them at fifteen points
# rather than to reason about them at 512.
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
    the crispest of the six at 1x by a distance and it says nothing: one eased
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


CANDIDATES = [
    ("gather", gather), ("trio", trio), ("pair", pair),
    ("meet", meet), ("bar", bar), ("panel", panel),
]

BLURB = {
    "gather": "three lanes arrive, one leaves, staggered",
    "trio": "the icon exactly: spread on the left, bundled on the right",
    "pair": "two lanes converging, and no third",
    "meet": "two lanes arrive level, one leaves",
    "bar": "the crossing bar alone. The negative",
    "panel": "the panel, the bar cut through it, a tongue out",
}


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
    w, polys = dict(CANDIDATES)[name]()
    polys, size = fit(polys, w, ART_HEIGHT)
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
    w, polys = dict(CANDIDATES)[name]()
    polys, size = fit(polys, w, points - 2 * BLEED)
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

    draw.text((pad, 16), "Bloom in the menu bar: six reductions of the app icon, "
                         "each drawn at the size it is used at",
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
