"""Geometry, palette and drawing helpers for the Bloom v7 icon set.

Round six established the language: flat pieces of paper, a real tonal step
between adjacent pieces, everything cropped by the tile. Round seven keeps all
of that and adds exactly three ways of making it deeper, none of which is
lighting.

1. THICKNESS. thick() draws a silhouette twice: once a small step darker and
   nudged down and right, then the face over it. The sliver that shows is the
   side of a solid piece. It is not a shadow and it is not a bevel.
2. CONTACT SHADOW. contact() draws the top piece's silhouette in black, nudged,
   softened a little, and CLIPPED TO THE PIECE UNDERNEATH IT. It is structurally
   impossible for it to appear anywhere the two pieces do not overlap, which is
   the whole difference between a contact shadow and a drop shadow.
3. MORE PIECES. Four to six layers rather than two or three, each a measured
   step from the one next to it.

There is still no glow, no halation, no specular and no light direction beyond
the shared, almost invisible sheen. Blur appears only inside contact(), and
only ever on black at low alpha, inside a clip.

Tile geometry is the measured Big Sur template, unchanged since round one:
1024 canvas, 824 body, inset 100, corner radius 185.4.
"""
import math

# ---------------------------------------------------------------- palette
C = dict(
    abyss="#061420", deep="#0B2438", fathom="#123B57", spatie="#197593",
    current="#2AA3B4", bloom="#4FD8C4", shallow="#9BE9DC", foam="#E9F7F4",
    mist="#C9D6DC", slate="#5A6B76", paper="#FAFCFC",
)

RAMP = ["abyss", "deep", "fathom", "spatie", "current", "bloom", "shallow", "foam"]

CANVAS = 1024
INSET = 100
BODY = 824
R = 185.4
CX = CY = 512

TILE = ('M100,285.4 A185.4,185.4 0 0 1 285.4,100 L738.6,100 '
        'A185.4,185.4 0 0 1 924,285.4 L924,738.6 A185.4,185.4 0 0 1 738.6,924 '
        'L285.4,924 A185.4,185.4 0 0 1 100,738.6 Z')

HEAD = ('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" '
        'viewBox="0 0 1024 1024">')

# One light story for the whole set: it comes from the upper left. That fixes
# the sheen axis, the side a thickness shows on and the way a contact shadow
# falls. Every number below points down and to the right.
THICK_D = (16.0, 26.0)
SHADOW_D = (26.0, 34.0)

# 16 and 32 are drawn without thickness and without shadows: at those sizes a
# sliver two tenths of a pixel wide is dirt, not depth.
SMALL = False


# ------------------------------------------------------------------ colour
def _hex(c):
    c = c.lstrip("#")
    return tuple(int(c[i:i + 2], 16) for i in (0, 2, 4))


def _str(rgb):
    return "#%02X%02X%02X" % tuple(max(0, min(255, int(round(v)))) for v in rgb)


def shade(colour, t):
    """Mix a colour toward white for t > 0 and toward black for t < 0.
    Only ever called with small t. This is a tonal nudge, not lighting."""
    r, g, b = _hex(C.get(colour, colour))
    if t >= 0:
        return _str((r + (255 - r) * t, g + (255 - g) * t, b + (255 - b) * t))
    return _str((r * (1 + t), g * (1 + t), b * (1 + t)))


def lum(colour):
    def ch(v):
        v /= 255.0
        return v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4
    r, g, b = _hex(C.get(colour, colour))
    return 0.2126 * ch(r) + 0.7152 * ch(g) + 0.0722 * ch(b)


def step(a, b):
    """Contrast ratio between two fills.

    Two pieces that are LAYERS of the design must be at least 1.60 apart or
    they merge into one shape at 16 points. A thickness band is not a layer: it
    is the side of the piece whose face it touches, and it wants to be between
    1.15 and 1.60, close enough to belong to the same object and far enough to
    be seen. check.py holds both rules against every pair in the set."""
    x, y = lum(a) + 0.05, lum(b) + 0.05
    return max(x, y) / min(x, y)


# ------------------------------------------------------------------- fills
_defs = []
_blur = {}


def sheen(colour, up=0.055, down=0.075, angle=62):
    """A shape's fill: the colour, very slightly lighter at the upper left than
    at the lower right, on the one axis the whole set shares. The two ends are
    close enough that the shape still reads as a single flat piece of paper."""
    fid = "s%d" % len(_defs)
    a = math.radians(angle)
    dx, dy = math.cos(a) * 720, math.sin(a) * 720
    x1, y1 = 512 - dx / 2, 512 - dy / 2
    x2, y2 = 512 + dx / 2, 512 + dy / 2
    _defs.append('<linearGradient id="%s" gradientUnits="userSpaceOnUse" '
                 'x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f">'
                 '<stop offset="0" stop-color="%s"/><stop offset="1" stop-color="%s"/>'
                 '</linearGradient>'
                 % (fid, x1, y1, x2, y2, shade(colour, up), shade(colour, -down)))
    return "url(#%s)" % fid


def flat(colour):
    return C.get(colour, colour)


def reset():
    del _defs[:]
    _blur.clear()


def defs():
    return "".join(_defs)


# ------------------------------------------------------------ shape makers
# Everything that can be shadowed or given a thickness is built as a factory:
# a function of one argument, the fill. The same factory then draws the face,
# the thickness under it, the black silhouette of its own shadow and the clip
# path of whatever is lying on it, so those four can never drift apart.
def sh_circle(cx, cy, r):
    return lambda f: ('<circle cx="%.1f" cy="%.1f" r="%.1f" fill="%s"/>'
                      % (cx, cy, r, f))


def sh_ellipse(cx, cy, rx, ry, deg=0.0):
    t = '' if not deg else ' transform="rotate(%.2f %.1f %.1f)"' % (deg, cx, cy)
    return lambda f: ('<ellipse cx="%.1f" cy="%.1f" rx="%.1f" ry="%.1f" fill="%s"%s/>'
                      % (cx, cy, rx, ry, f, t))


def sh_rect(x, y, w, h, r=0.0, deg=0.0, about=None):
    t = ''
    if deg:
        ax, ay = about or (x + w / 2, y + h / 2)
        t = ' transform="rotate(%.2f %.1f %.1f)"' % (deg, ax, ay)
    return lambda f: ('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" rx="%.1f" '
                      'fill="%s"%s/>' % (x, y, w, h, r, f, t))


def sh_path(d, rule=""):
    r = ' fill-rule="evenodd"' if rule else ''
    return lambda f: '<path d="%s" fill="%s"%s/>' % (d, f, r)


def sh_poly(points):
    d = "M%.1f,%.1f" % points[0] + "".join("L%.1f,%.1f" % p for p in points[1:]) + "Z"
    return sh_path(d)


def sh_tile():
    return lambda f: '<path d="%s" fill="%s"/>' % (TILE, f)


def sh_group(*parts):
    return lambda f: "".join(p(f) for p in parts)


def sh_move(sh, dx, dy):
    return lambda f: '<g transform="translate(%.1f %.1f)">%s</g>' % (dx, dy, sh(f))


def sh_clip(sh, window):
    """The shape sh, showing only inside window. Used to slide one half of a
    figure against the other, which is the only picture a diff has."""
    def make(f):
        cid = "k%d" % len(_defs)
        _defs.append('<clipPath id="%s">%s</clipPath>' % (cid, window("#000")))
        return '<g clip-path="url(#%s)">%s</g>' % (cid, sh(f))
    return make


def clipbody(body, window):
    """A finished piece of drawing, showing only inside window. Used by 19,
    where the thing being cut and slid is the whole icon rather than a shape."""
    cid = "w%d" % len(_defs)
    _defs.append('<clipPath id="%s">%s</clipPath>' % (cid, window("#000")))
    return '<g clip-path="url(#%s)">%s</g>' % (cid, body)


def sh_hole(sh, hole):
    """sh with hole punched clean through it, so whatever is behind shows."""
    def make(f):
        mid = "m%d" % len(_defs)
        _defs.append('<mask id="%s">%s%s</mask>'
                     % (mid, sh("#fff"), hole("#000")))
        return '<g mask="url(#%s)">%s</g>' % (mid, sh(f))
    return make


# ------------------------------------------------------------------- depth
def _blurfilter(r):
    key = "%.1f" % r
    if key not in _blur:
        fid = "b%d" % len(_defs)
        _defs.append('<filter id="%s" x="-40%%" y="-40%%" width="180%%" '
                     'height="180%%" color-interpolation-filters="sRGB">'
                     '<feGaussianBlur stdDeviation="%.1f"/></filter>' % (fid, r))
        _blur[key] = fid
    return _blur[key]


def contact(top, under, d=None, blur=9.0, alpha=0.30):
    """The contact shadow. The silhouette of `top`, nudged down and right,
    softened by a few pixels, at low alpha, CLIPPED TO `under`.

    The clip is the point. A shadow that can only be drawn inside the shape it
    is falling on is a statement about which piece is on top of which piece. A
    shadow that can be drawn anywhere is lighting, and lighting is what got
    round five thrown away."""
    if SMALL:
        return ""
    dx, dy = d or SHADOW_D
    cid = "c%d" % len(_defs)
    _defs.append('<clipPath id="%s">%s</clipPath>' % (cid, under("#000")))
    fid = _blurfilter(blur)
    return ('<g clip-path="url(#%s)"><g opacity="%.2f" filter="url(#%s)" '
            'transform="translate(%.1f %.1f)">%s</g></g>'
            % (cid, alpha, fid, dx, dy, top("#000")))


def recess(face, hole, d=None, blur=9.0, alpha=0.34):
    """The same shadow, the other way up. Clipped to the hole and cast by the
    face around it, so it lands on the far wall and the hole reads as sunk into
    the piece rather than sitting on it.

    `face` must be the piece WITH THE HOLE ALREADY PUNCHED OUT OF IT. Passing
    the unpunched piece floods the whole recess, because a shape that covers
    the hole completely still covers it after being nudged."""
    if SMALL:
        return ""
    dx, dy = d or SHADOW_D
    cid = "c%d" % len(_defs)
    _defs.append('<clipPath id="%s">%s</clipPath>' % (cid, hole("#000")))
    fid = _blurfilter(blur)
    return ('<g clip-path="url(#%s)"><g opacity="%.2f" filter="url(#%s)" '
            'transform="translate(%.1f %.1f)">%s</g></g>'
            % (cid, alpha, fid, dx, dy, face("#000")))


def thick(sh, face, edge, d=None):
    """A piece with a side. The silhouette a small step darker, moved down and
    right, then the face on top of it. What shows along the lower right is the
    thickness of a solid, stated with two flat tones and no gradient across the
    join."""
    if SMALL:
        return sh(face)
    dx, dy = d or THICK_D
    return ('<g transform="translate(%.1f %.1f)">%s</g>%s'
            % (dx, dy, sh(edge), sh(face)))


def puck(cx, cy, rx, ry, h, face, side):
    """A disc seen from slightly above: an ellipse for the face, the same
    ellipse h lower, and the wall between them. Three flat pieces, one tone for
    the top and one for the side, which is how a flat icon says solid."""
    if SMALL:
        h = 0
    body = ''
    if h:
        body = ('<ellipse cx="%.1f" cy="%.1f" rx="%.1f" ry="%.1f" fill="%s"/>'
                '<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" fill="%s"/>'
                % (cx, cy + h, rx, ry, side, cx - rx, cy, 2 * rx, h, side))
    return body + sh_ellipse(cx, cy, rx, ry)(face)


# --------------------------------------------------------------- structure
def wrap(body):
    """Everything is drawn oversized and cropped by the tile, so pieces run
    past the edges instead of floating inside them."""
    return (HEAD + "<defs>" + defs()
            + '<clipPath id="t"><path d="%s"/></clipPath>' % TILE
            + "</defs>"
            + '<g clip-path="url(#t)">' + body + "</g></svg>")


def ground(colour):
    return '<path d="%s" fill="%s"/>' % (TILE, colour)


def polar(cx, cy, r, deg):
    a = math.radians(deg)
    return cx + r * math.cos(a), cy + r * math.sin(a)
