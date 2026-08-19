"""The twenty directions of round seven.

Round six answered one reference, the Mimestream icon, by throwing away every
rendered pixel. That was right and all of it is kept. Two corrections came
back with it.

  1. No letters. Not a B, not a monogram, not a letterform anywhere. Three
     rounds have now rejected them, so there is not one in here.
  2. More depth and style.

Depth here is never light. It is four things, and only these four.

  THICKNESS   a piece drawn twice, a small step darker and nudged down and
              right, so the sliver that shows along its lower right is its
              own side rather than a shadow of it.
  CONTACT     a soft shadow clipped to the piece it falls on, so it cannot
              exist anywhere two pieces do not actually overlap.
  COUNT       four to six pieces instead of two or three, each a measured
              step from the piece next to it.
  ATTITUDE    pieces tipped off the tile's axes, and pieces far too big for
              the tile to hold.

  A. the mark, pushed. thirteen of the twenty touch it, because it is his own
     logo and round six's version of it is the thing to beat
  01 rim      the two discs, each given a side, one lying on the other
  02 deck     the disc three times over, receding, the bite on the front one
  03 crop     the pair at three times the tile, only the meeting inside it
  04 lift     the bite raised off the disc rather than lying on it
  05 chip     both discs as solid pucks, seen straight on
  06 cant     both discs tipped back, seen from above
  07 cleave   the disc cut across and the two pieces slid out of line
  08 inlay    the bite as a recess sunk into the disc, not a piece on it
  09 ledge    tile, then a plate on it, then the mark on the plate
  10 invert   the same figure on a tile that is itself the colour
  12 cross    two lanes on two headings, crossing once
  15 shear    the mark sliced into three columns, each slid on its own
  16 under    the bite coming out from behind the disc instead of onto it
  19 slip     the whole tile cut across and the halves slid out of line

  B. the work, in the same language
  11 coins    three of the same thing, overlapping, none of them the main one
  13 copies   one pane three times, the front one bitten
  14 lanes    four lanes running the whole tile that never touch
  18 merge    three lanes that arrive separately and leave as one

  C. abstract
  17 well     four frames going down, each sunk into the one around it

  D. control
  20 six      round six's 16 layers, unchanged. The thing to beat
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lib
from lib import (clipbody, contact, flat, ground, puck, recess, reset, sh_circle,
                 sh_clip, sh_ellipse, sh_group, sh_hole, sh_move, sh_path,
                 sh_poly, sh_rect, sh_tile, sheen, thick, wrap)

D = os.path.expanduser("~/Desktop/bloom-icons-v7")


def above(m, c):
    """The half of the canvas above the line y = mx + c, as a shape."""
    return sh_poly([(-500, -500), (1524, -500), (1524, m * 1524 + c), (-500, m * -500 + c)])


def below(m, c):
    return sh_poly([(-500, m * -500 + c), (1524, m * 1524 + c), (1524, 1524), (-500, 1524)])


def band(y0, y1, h):
    """A lane of height h running the whole width, entering at y0 on the left
    and leaving at y1 on the right, easing between the two."""
    return sh_path(
        "M-80,%.1f C300,%.1f 560,%.1f 1104,%.1f L1104,%.1f C560,%.1f 300,%.1f "
        "-80,%.1f Z" % (y0 - h / 2, y0 - h / 2, y1 - h / 2, y1 - h / 2,
                        y1 + h / 2, y1 + h / 2, y0 + h / 2, y0 + h / 2))


# ================================================== A. the mark, pushed
def rim(small=False):
    """The two discs of the current mark, each given a side.

    A step darker under the lower right of each piece says the piece is solid
    rather than printed, and the bite drops a contact shadow where it lies on
    the disc. Five tones and not one lit pixel. This is the plainest statement
    of what round seven adds to round six."""
    disc = sh_circle(444, 424, 372 if not small else 392)
    bite = sh_circle(830, 856, 400)
    return wrap("".join([
        ground(flat("deep")),
        thick(disc, sheen("bloom"), flat("current")),
        contact(bite, disc, blur=13, alpha=0.34),
        thick(bite, sheen("spatie"), flat("fathom")),
    ]))


def deck(small=False):
    """The disc is not one disc. It is the same disc three times, stepping down
    and to the right, each one further up the ramp than the one behind it, with
    the bite lying on the front one.

    Depth by repetition. Five flat pieces, three of them the same piece."""
    o = [ground(flat("deep"))]
    off = 112 if not small else 158
    prev = None
    for i, col in enumerate(("spatie", "current", "shallow")):
        c = sh_circle(300 + i * off, 300 + i * off, 348 if not small else 366)
        if prev is not None:
            o.append(contact(c, prev, d=(20, 24), blur=11, alpha=0.30))
        o.append(c(sheen(col)))
        prev = c
    bite = sh_circle(880, 894, 372)
    o.append(contact(bite, prev, blur=13, alpha=0.34))
    o.append(thick(bite, sheen("spatie"), flat("fathom")))
    return wrap("".join(o))


def crop(small=False):
    """The pair at roughly twice the size the tile can hold. The bright disc is
    now bigger than the tile in every direction, so it IS the tile, and all
    that is left inside the frame is the bite lying on it with a side and a
    shadow.

    Round six's strongest depth cue was a shape running off the edge. This is
    that cue taken as far as it goes: two pieces, one curve, the most colour of
    anything in the set, and the only design here that is still a shape at
    eight points."""
    bite = sh_circle(944, 936, 520 if not small else 540)
    return wrap("".join([
        ground(sheen("bloom", 0.06, 0.12)),
        contact(bite, sh_tile(), d=(30, 38), blur=16, alpha=0.30),
        thick(bite, sheen("spatie"), flat("fathom"), d=(20, 30)),
    ]))


def lift(small=False):
    """The same two discs, except the bite is not lying on the disc, it is held
    a little above it: a longer offset, a wider softening, still clipped to the
    disc so it can only appear where the two overlap.

    The difference between this and 01 is two numbers. Worth seeing side by
    side, because resting on something and hovering over it are two different
    objects."""
    disc = sh_circle(436, 416, 380 if not small else 398)
    bite = sh_circle(832, 852, 396)
    return wrap("".join([
        ground(flat("abyss")),
        thick(disc, sheen("shallow"), flat("bloom")),
        contact(bite, disc, d=(50, 62), blur=26, alpha=0.42),
        thick(bite, sheen("spatie"), flat("fathom"), d=(20, 30)),
    ]))


def chip(small=False):
    """Both discs as solid pucks seen straight on: a face, and under it a wall
    of the next tone down, so each has a measurable height.

    This is faux 3d done the way a flat icon is allowed to do it. No bevel, no
    gradient across the join, no highlight anywhere on the wall. Two tones and
    a hard edge between them."""
    o = [ground(flat("deep"))]
    r1 = 366 if not small else 384
    o.append(puck(420, 396, r1, r1, 72, sheen("bloom"), flat("current")))
    disc = sh_circle(420, 396, r1)
    r2 = 300 if not small else 316
    bite = sh_circle(792, 566, r2)
    o.append(contact(bite, disc, d=(22, 26), blur=12, alpha=0.30))
    o.append(puck(792, 566, r2, r2, 60, sheen("spatie"), flat("fathom")))
    return wrap("".join(o))


def cant(small=False):
    """The pair tipped back, so both discs are ellipses and you are looking
    down on them. Each keeps its wall, so the stack has a real height.

    Perspective costs no light at all. The risk is that tipped and extruded is
    a well worn style, which is why it is in here once rather than five
    times."""
    o = [ground(flat("abyss"))]
    rx1, ry1 = (452, 300) if not small else (470, 318)
    o.append(puck(462, 404, rx1, ry1, 88, sheen("shallow"), flat("current")))
    disc = sh_ellipse(462, 404, rx1, ry1)
    bite = sh_ellipse(852, 664, 356, 238)
    o.append(contact(bite, disc, d=(22, 26), blur=13, alpha=0.30))
    o.append(puck(852, 664, 356, 238, 70, sheen("spatie"), flat("fathom")))
    return wrap("".join(o))


def cleave(small=False):
    """The disc cut once, straight through, and the two pieces slid out of
    line. The ground opens in the cut and the upper piece drops a shadow into
    it.

    Two copies of one thing that no longer line up is the only picture a diff
    has, and a diff is what this app is for. Here it is said on his own mark
    rather than on a document."""
    dx, dy = (68, 88) if not small else (104, 134)
    disc = sh_circle(452, 430, 384 if not small else 402)
    bite = sh_circle(846, 890, 396)
    fig = thick(disc, sheen("shallow"), flat("bloom")) + \
        contact(bite, disc, blur=13, alpha=0.32) + \
        thick(bite, sheen("spatie"), flat("fathom"))
    top, bot = above(0.38, 296), below(0.38, 296)
    return wrap("".join([
        ground(flat("deep")),
        '<g transform="translate(%.1f %.1f)">%s</g>' % (dx, dy, clipbody(fig, bot)),
        contact(top, sh_move(bot, dx, dy), d=(0, 30), blur=15, alpha=0.46),
        clipbody(fig, top),
    ]))


def inlay(small=False):
    """The bite as a hole sunk into the disc rather than a piece lying on it.

    The shadow runs the other way here: clipped to the hole and cast by the
    face around it, so it lands on the far wall and the figure reads as pressed
    in instead of stacked up. Same rule, same numbers, inverted. It is also the
    reading closest to the mark as it stands, where the bite really is a
    hole."""
    disc = sh_circle(448, 430, 400 if not small else 418)
    hole = sh_circle(852, 878, 412)
    return wrap("".join([
        ground(flat("abyss")),
        thick(disc, sheen("bloom"), flat("current")),
        hole(sheen("spatie", 0.03, 0.06)),
        recess(sh_hole(disc, hole), hole, d=(34, 42), blur=13, alpha=0.44),
    ]))


def ledge(small=False):
    """Tile, then a raised plate on it, then the mark on the plate: three
    levels, six pieces, every join carrying a side and a contact shadow.

    This is the reference's own structure, which is a tile with a card on it
    and a shape on the card, said with his own figure instead of a piece of
    post. It is the deepest thing in the set by count, and nothing in it is
    lit."""
    slab = sh_rect(146, 120, 880, 880, 168)
    disc = sh_circle(470, 424, 286 if not small else 302)
    bite = sh_circle(736, 700, 296)
    return wrap("".join([
        ground(flat("abyss")),
        contact(slab, sh_tile(), d=(26, 32), blur=15, alpha=0.40),
        thick(slab, sheen("spatie"), flat("fathom")),
        contact(disc, slab, d=(22, 26), blur=13, alpha=0.34),
        thick(disc, sheen("shallow"), flat("bloom")),
        contact(bite, disc, d=(20, 24), blur=12, alpha=0.32),
        thick(bite, sheen("current"), flat("spatie")),
    ]))


def invert(small=False):
    """The same figure on a tile that is itself the colour, so the icon is
    found in a dock by its hue before its shape.

    Round six learned that a near white field reads as a white app. This is the
    answer to that. Current fills the tile, the disc is the pale piece and the
    bite is brand blue with a side on it."""
    disc = sh_circle(416, 392, 322 if not small else 340)
    bite = sh_circle(714, 690, 322)
    return wrap("".join([
        ground(sheen("current", 0.07, 0.11)),
        thick(disc, sheen("foam", 0.02, 0.05), flat("shallow")),
        contact(bite, disc, blur=13, alpha=0.30),
        thick(bite, sheen("spatie"), flat("fathom")),
    ]))


# ================================================== B. the work
def coins(small=False):
    """Three of the same thing, none of them the main one, each lying over the
    last and all three running off the top and the bottom.

    The app runs the same job several times at once and no run is privileged.
    Three discs of one size, three rungs of one ramp, two contact shadows."""
    o = [ground(flat("deep"))]
    r = 306 if not small else 300
    prev = None
    for i, col in enumerate(("spatie", "current", "shallow")):
        c = sh_circle(176 + i * (336 if not small else 358),
                      640 - i * (128 if not small else 140), r)
        if prev is not None:
            o.append(contact(c, prev, d=(22, 22), blur=12, alpha=0.32))
        o.append(thick(c, sheen(col), flat({"spatie": "fathom", "current": "spatie",
                                            "shallow": "bloom"}[col])))
        prev = c
    return wrap("".join(o))


def copies(small=False):
    """One pane, three times, offset in one direction, and the front one with
    the bite taken out of its corner so the stack is still his mark.

    Nothing is written on the panes and the corners are large, so it is three
    workspaces and not three documents. The stack runs off the right and the
    bottom, which is what stops it being a picture of a file."""
    o = [ground(flat("abyss"))]
    off = 128 if not small else 138
    prev = None
    for i, col in enumerate(("spatie", "current", "shallow")):
        p = sh_rect(96 + i * off, 46 + i * off, 700, 700, 112)
        if prev is not None:
            o.append(contact(p, prev, d=(22, 24), blur=12, alpha=0.30))
        if i == 2:
            hole = sh_circle(878, 838, 262)
            o.append(sh_hole(p, hole)(sheen(col)))
            o.append(hole(sheen("spatie", 0.03, 0.06)))
            o.append(recess(sh_hole(p, hole), hole, d=(26, 32), blur=12, alpha=0.44))
        else:
            o.append(p(sheen(col)))
        prev = p
    return wrap("".join(o))


def lanes(small=False):
    """Four lanes running the whole height of the tile, tipped off vertical,
    never touching each other, each sitting on the tile with a side of its own
    and a contact shadow into the gap beside it.

    Agents in separate worktrees cannot overwrite each other. That is the one
    fact about this app that matters most and this is a picture of it. The
    lanes are unequal in width and the pitch is uneven, because an even pitch
    is a beach towel."""
    o = [ground(flat("abyss"))]
    plan = ((188, 196, "shallow", "bloom"), (404, 124, "current", "spatie"),
            (606, 238, "shallow", "bloom"), (858, 146, "current", "spatie"))
    for x, w, face, side in plan:
        w = w + (26 if small else 0)
        r = sh_rect(x - w / 2, -200, w, 1424, w / 2, deg=9, about=(x, 512))
        o.append(contact(r, sh_tile(), d=(30, 18), blur=15, alpha=0.24))
        o.append(thick(r, sheen(face), flat(side)))
    return wrap("".join(o))


def merge(small=False):
    """Three lanes that arrive apart and leave as one, each passing under the
    next as they close up, with a contact shadow at every join.

    You read the diffs and you merge the ones that were right. That is the
    other half of the app and this is the only design in the set that says it.
    The lanes enter off the left edge and the joined lane leaves off the right,
    so it is a passage rather than a symbol."""
    h = 150 if not small else 168
    o = [ground(flat("deep"))]
    a, b, c = band(150, 512 - h * 0.98, h), band(874, 512 + h * 0.98, h), band(512, 512, h)
    o.append(a(sheen("spatie")))
    o.append(b(sheen("current")))
    o.append(contact(c, a, d=(0, 26), blur=13, alpha=0.34))
    o.append(contact(c, b, d=(0, -26), blur=13, alpha=0.34))
    o.append(c(sheen("shallow")))
    return wrap("".join(o))


# ================================================== back to the mark
def spine(pts, h):
    """A lane of height h whose middle follows a cubic through pts, drawn as a
    closed path so it can be layered rather than stroked."""
    def edge(off, rev=False):
        p = [(x, y + off) for x, y in pts]
        if rev:
            p = p[::-1]
        d = "%.1f,%.1f" % p[0]
        for i in range(1, len(p), 3):
            d += " C%.1f,%.1f %.1f,%.1f %.1f,%.1f" % (p[i][0], p[i][1], p[i + 1][0],
                                                      p[i + 1][1], p[i + 2][0], p[i + 2][1])
        return d
    return sh_path("M" + edge(-h / 2) + " L" + edge(h / 2, True) + " Z")


def cross(small=False):
    """Two lanes on two different headings, crossing once, one over the other,
    with a side on each and a contact shadow only where they actually meet.

    The crossing is off centre and the angle is shallow, because two bars at
    right angles in the middle of a tile is a symbol and this is meant to be a
    place where two runs of work pass each other. Both lanes leave the tile at
    all four edges, so neither of them starts or ends."""
    w1 = 246 if small else 216
    w2 = 208 if small else 182
    a = sh_rect(-300, 640 - w1 / 2, 1624, w1, w1 / 2, deg=-24, about=(560, 640))
    b = sh_rect(-300, 470 - w2 / 2, 1624, w2, w2 / 2, deg=27, about=(560, 470))
    return wrap("".join([
        ground(flat("deep")),
        thick(a, sheen("current"), flat("spatie")),
        contact(b, a, d=(22, 28), blur=14, alpha=0.36),
        thick(b, sheen("shallow"), flat("bloom")),
    ]))


def shear(small=False):
    """The mark sliced into three columns and each column slid on its own, with
    the tile showing in the two cuts and each column dropping a shadow into the
    cut beside it.

    Three copies of one thing, running at once, out of step. It is the app's
    subject and his own logo in the same figure, and it is the most specific
    shape in the set: nothing else in a dock looks like this."""
    o = [ground(flat("deep"))]
    disc = sh_circle(486, 452, 396 if not small else 414)
    bite = sh_circle(872, 900, 386)
    fig = thick(disc, sheen("shallow"), flat("bloom")) + \
        contact(bite, disc, blur=13, alpha=0.32) + \
        thick(bite, sheen("spatie"), flat("fathom"))
    cuts = (((-300, 700, 86), (404, 246, -70), (656, 668, 26)) if not small
            else ((-300, 700, 150), (404, 246, -122), (656, 668, 46)))
    for x0, w, dy in cuts:
        col = sh_rect(x0, -300, w, 1624)
        o.append(contact(sh_move(col, 0, dy), sh_tile(), d=(24, 0), blur=12, alpha=0.40))
        o.append('<g transform="translate(0 %.1f)">%s</g>' % (dy, clipbody(fig, col)))
    return wrap("".join(o))


def under(small=False):
    """The bite coming out from behind the disc rather than lying on top of it,
    so the disc is the nearest piece and drops its shadow onto the bite.

    Every other reading of the mark in this set puts the dark piece in front.
    This is the one that keeps the tonal order of the logo as it stands, where
    the bright disc is the thing you are looking at."""
    disc = sh_circle(430, 414, 388 if not small else 406)
    bite = sh_circle(834, 852, 404)
    return wrap("".join([
        ground(flat("abyss")),
        thick(bite, sheen("spatie"), flat("fathom")),
        contact(disc, bite, d=(30, 36), blur=15, alpha=0.42),
        thick(disc, sheen("shallow"), flat("bloom")),
    ]))


# ================================================== C. abstract
def well(small=False):
    """Four frames, each sunk into the one around it, each a step further down
    the ramp, with the lip of every frame dropping a shadow onto the far wall
    of the next, and a bright floor at the bottom.

    Depth by recession rather than elevation. Nothing rises out of the tile,
    the tile opens. It is the one design in the set that is a place rather than
    an object, which is what the brand's own gradient is already about."""
    o = [ground(sheen("current", 0.06, 0.10))]
    plan = ((78, "spatie"), (176, "fathom"), (282, "shallow"))
    outer = sh_tile()
    for inset, col in plan:
        k = inset - (14 if small else 0)
        r = sh_rect(k, k - 30, 1024 - 2 * k, 1024 - 2 * k,
                    max(28.0, 185.4 - k * 0.55))
        o.append(r(sheen(col)))
        o.append(recess(sh_hole(outer, r), r, d=(26, 32), blur=14, alpha=0.44))
        outer = r
    return wrap("".join(o))


def slip(small=False):
    """The whole tile cut across and the two halves slid out of line, with the
    ground opening in the cut and the upper plate dropping a shadow onto the
    lower one.

    Everything else here layers separate objects. This layers the icon itself:
    one picture, two versions of it, no longer matching. Hardest crop in the
    set and the hardest to mistake for any other app."""
    dx, dy = (104, 40) if not small else (168, 64)
    plate = "".join([
        sh_tile()(flat("deep")),
        thick(sh_circle(452, 440, 356 if not small else 374),
              sheen("shallow"), flat("bloom")),
        sh_circle(818, 850, 380)(sheen("spatie")),
    ])
    top, bot = above(0.30, 336), below(0.30, 336)
    return wrap("".join([
        ground(flat("abyss")),
        '<g transform="translate(%.1f %.1f)">%s</g>' % (dx, dy, clipbody(plate, bot)),
        contact(top, sh_move(bot, dx, dy), d=(0, 30), blur=15, alpha=0.48),
        clipbody(plate, top),
    ]))


# ================================================== D. control
def six(small=False):
    """Round six's 16 layers, rebuilt here unchanged so that it is judged on
    the same sheets as everything else. Three flat pieces, no thickness, no
    contact shadow. This is what the other nineteen have to beat."""
    return wrap("".join([
        ground(flat("abyss")),
        sh_circle(444, 430, 404 if not small else 418)(sheen("shallow", 0.03, 0.05, 118)),
        sh_circle(852, 876, 436)(sheen("current", 0.055, 0.075, 118)),
        sh_clip(sh_poly([(1104, 372), (1104, 1104), (280, 1104)]),
                sh_circle(852, 876, 436))(sheen("fathom", 0.06, 0.02, 118)),
    ]))


ICONS = [
    ("01-rim", rim), ("02-deck", deck), ("03-crop", crop), ("04-lift", lift),
    ("05-chip", chip), ("06-cant", cant), ("07-cleave", cleave), ("08-inlay", inlay),
    ("09-ledge", ledge), ("10-invert", invert), ("11-coins", coins),
    ("12-cross", cross), ("13-copies", copies), ("14-lanes", lanes),
    ("15-shear", shear), ("16-under", under), ("17-well", well),
    ("18-merge", merge), ("19-slip", slip), ("20-six", six),
]

BLURB = {
    "01-rim": "the pair, each given a side",
    "02-deck": "the disc three times, receding",
    "03-crop": "the pair, far too big for the tile",
    "04-lift": "the bite raised, not resting",
    "05-chip": "both discs as solid pucks",
    "06-cant": "the pair tipped back",
    "07-cleave": "the disc cut and slid out of line",
    "08-inlay": "the bite sunk in, not laid on",
    "09-ledge": "tile, plate, mark. Three levels",
    "10-invert": "the figure on a coloured tile",
    "11-coins": "three of the same, overlapping",
    "12-cross": "two lanes crossing, one over",
    "13-copies": "one pane three times, front bitten",
    "14-lanes": "four lanes that never touch",
    "15-shear": "the mark, sliced and slid",
    "16-under": "the bite behind, not on top",
    "17-well": "four frames going down",
    "18-merge": "three lanes arriving, one leaving",
    "19-slip": "the tile itself, cut and slid",
    "20-six": "round six's best. Control",
}


if __name__ == "__main__":
    os.makedirs(os.path.join(D, "svg"), exist_ok=True)
    for name, fn in ICONS:
        for suffix, small in ((".svg", False), ("-small.svg", True)):
            reset()
            lib.SMALL = small
            open(os.path.join(D, "svg", name + suffix), "w").write(fn(small))
    lib.SMALL = False
    print("%d directions, %d svg files" % (len(ICONS), len(ICONS) * 2))
