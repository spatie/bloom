#!/usr/bin/env python3
"""Builds ~/Desktop/bloom-icon-02-piece.html: 02-piece at several amounts of
upper dark on the leaving edge. Nothing here is shipped and nothing outside
Tools/icon/.build and the one Desktop file is written."""
import base64
import os
import subprocess
import sys

ICON = os.path.dirname(os.path.abspath(__file__))
SC = os.path.join(ICON, ".build", "trim")
os.makedirs(SC, exist_ok=True)
sys.path.insert(0, ICON)

import depth  # noqa: E402
import gen10  # noqa: E402
import lib  # noqa: E402
import lib9  # noqa: E402
import shine  # noqa: E402
from gen10 import BAND_X1, CY, END, H, HS, M, band_in, into, kof, outof, squircle_panel  # noqa: E402
from lib import sh_group  # noqa: E402

K = kof(M)

# --------------------------------------------------------------- the options
#
# `up` and `down` are how far the spur is proud of the bar, in the panel's own
# units, the frame make.py's "26 units proud of it on each side" is written in.
# `x1` is where the spur's band ENDS, and it is the whole bug: a band's centre
# line is a cubic whose control points are fixed, so moving the end point
# reparametrises it and the spur rides above the bar it was meant to be
# concentric with.
SPUR_X1_OLD = outof(1200.0, M)   # 1485.1 in the panel's frame
SPUR_X1_BAR = BAND_X1            # 1304.0, the bar's own end

OPTIONS = [
    ("00-current", "the shipped spur", 26, 26, SPUR_X1_OLD),
    ("01-aligned", "the spur ended where the bar ends, nothing else changed",
     26, 26, SPUR_X1_BAR),
    ("02-match", "aligned, then 17 units proud on both sides", 17, 17, SPUR_X1_BAR),
    ("03-low", "aligned, 13 above, 17 below", 13, 17, SPUR_X1_BAR),
    ("04-hairline", "aligned, 9 above, 17 below", 9, 17, SPUR_X1_BAR),
]


def shapes(up, down, x1, small=False, m=M):
    """depth.shapes with the spur's two sides and its end point given."""
    h = HS if small else H
    barh = h * 1.04
    plain = squircle_panel(m)
    d = (down - up) / 2.0
    spur = band_in(CY - 40 + d, END + d, barh + up + down, m, x1=x1)
    panel = sh_group(plain, spur)
    a = band_in(gen10.YA, END - h * 1.02, h * 0.92, m)
    b = band_in(gen10.YB + 26, END + h * 1.02, h * 0.92, m)
    c = band_in(CY - 40, END, barh, m)
    return dict(h=h, m=m, plain=plain, spur=spur, panel=panel, a=a, b=b, c=c,
                tile=lib9.sh_squircle(), bar=lib.sh_clip(c, panel))


def piece(up, down, x1):
    """shine.v02_piece, with the spur parameterised. Everything else, the
    grades included, is that function's own."""
    def fn(small=False):
        sp, w = shapes(up, down, x1, small), shine.where(small)
        u, dn = 0.14, 0.11
        lanes = shine.split_lanes(
            sp,
            afill=shine.fill("spatie", u, dn, *w["a"]),
            bfill=shine.fill("current", u, dn, *w["b"]))
        groups = shine.document(
            sp,
            mark=[shine.layer("Mark", sp["bar"]("#000"),
                              shine.fill("shallow", u, dn, *w["bar"]))],
            lanes=lanes,
            panel=[shine.layer("Panel", sp["panel"]("#000"),
                               shine.fill("deep", u, dn, *w["panel"]))],
            ground=[shine.layer("Ground", lib9.fullbleed("#000"),
                                shine.fill("foam", u, dn, *w["ground"]))])
        body = depth.base_flat(
            sp,
            lanes=shine.cut(sp, sp["a"](shine.paint("spatie", u, dn, *w["a"]))
                            + sp["b"](shine.paint("current", u, dn, *w["b"]))),
            bar=sp["bar"](shine.paint("shallow", u, dn, *w["bar"])),
            after_panel=sp["panel"](shine.paint("deep", u, dn, *w["panel"])))
        head = lib9.fullbleed(lib.flat("foam"))
        return groups, (lib9.fullbleed(shine.paint("foam", u, dn, *w["ground"]))
                        + body[len(head):])
    return fn


# ------------------------------------------------------------- measuring it
#
# The numbers on the page are read off the pixels rather than off the geometry,
# so a mistake in the geometry cannot hide behind a caption.
PAL = {"F": (233, 247, 244), "S": (155, 233, 220), "D": (0x14, 0x3B, 0x3F)}


def profile(png, box=None):
    """Dark above the bar and dark below it, in 1024 canvas units, averaged
    across the margin."""
    from PIL import Image
    im = Image.open(png).convert("RGBA")
    px = im.load()
    w, hgt = im.size
    xs = [x for x in range(w) if px[x, hgt // 2][3] > 8]
    ys = [y for y in range(hgt) if px[w // 2, y][3] > 8]
    x0, x1 = min(xs), max(xs)
    y0 = min(ys)
    k = (x1 - x0 + 1) / 1024.0

    def near(c):
        return min(PAL, key=lambda n: sum((a - b) ** 2 for a, b in zip(c[:3], PAL[n])))

    ups, dns = [], []
    for cx in (900, 940, 980, 1010):
        x = int(round(x0 + k * cx))
        if x > x1 - 2:
            continue
        col = [near(px[x, y]) for y in range(int(y0 + k * 500), int(y0 + k * 800))]
        run = "".join(col)
        # the bar is the one long S run in the middle
        best, bi, i = 0, -1, 0
        while i < len(run):
            j = i
            while j < len(run) and run[j] == run[i]:
                j += 1
            if run[i] == "S" and j - i > best:
                best, bi = j - i, i
            i = j
        if bi < 0:
            continue
        # One or two antialiased pixels sit between the bar and the dark it
        # lies in, so the walk steps over a short non-dark gap rather than
        # stopping at it and reporting a skirt of nothing.
        def walk(start, step):
            n, skipped, i = 0, 0, start
            while 0 <= i < len(run):
                if run[i] == "D":
                    n += 1
                    skipped = 0
                elif n == 0 and skipped < 2:
                    skipped += 1
                else:
                    break
                i += step
            return n

        u = walk(bi - 1, -1)
        d = walk(bi + best, 1)
        ups.append(u / k)
        dns.append(d / k)
    if not ups:
        return 0.0, 0.0, (x0, y0, x1, k)
    return sum(ups) / len(ups), sum(dns) / len(dns), (x0, y0, x1, k)


def crop(png, out, scale=4):
    """The leaving edge, magnified, nearest neighbour so a pixel stays a
    pixel."""
    from PIL import Image
    im = Image.open(png).convert("RGBA")
    w, hgt = im.size
    px = im.load()
    xs = [x for x in range(w) if px[x, hgt // 2][3] > 8]
    ys = [y for y in range(hgt) if px[w // 2, y][3] > 8]
    x0, x1, y0 = min(xs), max(xs), min(ys)
    k = (x1 - x0 + 1) / 1024.0
    L = int(round(x0 + k * 760))
    R = min(x1 + 3, int(round(x0 + k * 1030)))
    T = int(round(y0 + k * 528))
    B = int(round(y0 + k * 792))
    c = im.crop((L, T, R, B))
    c = c.resize((c.width * scale, c.height * scale), Image.NEAREST)
    bg = Image.new("RGBA", c.size, (11, 13, 16, 255))
    bg.alpha_composite(c)
    bg.convert("RGB").save(out)
    return out


def zoomstrip(rows, size, zoom, out):
    """Every option at one small size, side by side and magnified, because
    reading a 16 against the 16 four screens further down is not reading."""
    from PIL import Image
    ims = [Image.open(r["shots"][size]).convert("RGBA").resize(
        (size * zoom, size * zoom), Image.NEAREST) for r in rows]
    gap = 26
    w = sum(i.width for i in ims) + gap * (len(ims) - 1)
    canvas = Image.new("RGBA", (w, ims[0].height), (20, 22, 26, 255))
    x = 0
    for i in ims:
        canvas.alpha_composite(i, (x, 0))
        x += i.width + gap
    canvas.convert("RGB").save(out)
    return out


def uri(path):
    with open(path, "rb") as f:
        return "data:image/png;base64," + base64.b64encode(f.read()).decode()


SIZES = [1024, 512, 256, 128, 64, 32, 16]


def main():
    rows = []
    for name, blurb, up, down, x1 in OPTIONS:
        fn = piece(up, down, x1)
        groups, flatsvg, legacy = shine.render(fn)
        shots = shine.systemshots("t02-" + name, groups, SIZES)
        fp = os.path.join(SC, name + "-flat.png")
        with open(os.path.join(SC, name + ".svg"), "w") as f:
            f.write(flatsvg)
        subprocess.run(["rsvg-convert", "-w", "1024", "-h", "1024",
                        os.path.join(SC, name + ".svg"), "-o", fp], check=True)
        u, d, _ = profile(shots[1024])
        uf, df, _ = profile(fp)
        big = crop(shots[1024], os.path.join(SC, name + "-crop.png"))
        rows.append(dict(name=name, blurb=blurb, up=up, down=down,
                         aligned=(x1 == SPUR_X1_BAR),
                         meas=(u, d), flatmeas=(uf, df),
                         shots=shots, crop=big, flat=fp))
        print("%-12s up=%2d down=%2d  measured above %5.1f  below %5.1f "
              " (flat %5.1f / %5.1f)" % (name, up, down, u, d, uf, df))
    page(rows)


def page(rows):
    out = os.path.expanduser("~/Desktop/bloom-icon-02-piece.html")
    h = [HEAD]
    for r in rows:
        u, d = r["meas"]
        uf, df = r["flatmeas"]
        h.append(
            '<section class="row"><div class="rowhead">'
            '<h2>%s</h2><p class="what">%s</p>'
            '<p class="num">spur proud of the bar: <b>%d</b> units above, '
            '<b>%d</b> units below, in the panel\'s frame &middot; end point '
            '<b>%s</b> &middot; measured on the pixels: <b>%.0f</b> dark above '
            'the bar, <b>%.0f</b> below, in 1024 canvas units '
            '(flat file %.0f / %.0f)</p></div>'
            '<div class="cols"><div class="big"><img src="%s" alt="">'
            '<span class="cap">1024, as macOS composites it</span></div>'
            '<div class="big"><img class="mag" src="%s" alt="">'
            '<span class="cap">the leaving edge, 5&times;</span></div></div>'
            '<div class="strip">%s</div></section>'
            % (r["name"], r["blurb"], r["up"], r["down"],
               "the bar's own, 1304" if r["aligned"] else "1200 on the tile",
               u, d, uf, df,
               uri(r["shots"][1024]), uri(r["crop"]),
               "".join('<figure style="width:%dpx"><img src="%s" width="%d" '
                       'height="%d" alt=""><figcaption>%d</figcaption></figure>'
                       % (max(s, 48), uri(r["shots"][s]), s, s, s)
                       for s in SIZES if s <= 128)))
    z16 = zoomstrip(rows, 16, 16, os.path.join(SC, "zoom16.png"))
    z32 = zoomstrip(rows, 32, 10, os.path.join(SC, "zoom32.png"))
    names = " &middot; ".join(r["name"] for r in rows)
    h.append(
        '<section class="note"><h2>The five at 16, and at 32, in one line</h2>'
        '<p class="num">%s, in that order.</p>'
        '<div class="zoom"><img src="%s" alt=""></div>'
        '<div class="zoom"><img src="%s" alt=""></div></section>'
        % (names, uri(z16), uri(z32)))
    h.append(TAIL)
    with open(out, "w") as f:
        f.write("".join(h))
    print(out)


HEAD = """<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Bloom 02-piece, the leaving edge</title><style>
:root { color-scheme: dark; }
* { box-sizing: border-box; }
body { margin: 0; background: #0B0D10; color: #D9E2E8;
  font: 15px/1.65 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; }
header { padding: 44px 40px 8px; max-width: 1240px; }
h1 { font-size: 27px; margin: 0 0 14px; letter-spacing: -0.01em; }
header p { color: #9AA7B0; max-width: 86ch; }
b { color: #9BE9DC; font-weight: 600; }
code { font: 12.5px ui-monospace, "SF Mono", Menlo, monospace; color: #9BE9DC; }
.row { border-top: 1px solid #23282E; padding: 30px 40px; max-width: 1240px; }
.rowhead h2 { font: 600 17px ui-monospace, "SF Mono", Menlo, monospace;
  color: #4FD8C4; margin: 0 0 4px; }
.what { margin: 0 0 6px; color: #D9E2E8; }
.num { margin: 0 0 18px; color: #8E9AA3; font-size: 13.5px; max-width: 100ch; }
.cols { display: flex; gap: 28px; flex-wrap: wrap; align-items: flex-start; }
.big img { display: block; width: 340px; height: 340px; border-radius: 12px;
  background: #14171B; }
.big img.mag { width: auto; height: 340px; image-rendering: pixelated;
  border: 1px solid #262B31; }
.cap { display: block; margin-top: 7px; color: #6F7B84; font-size: 12px; }
.strip { display: flex; gap: 22px; align-items: flex-end; margin-top: 22px;
  padding-top: 18px; border-top: 1px dashed #23282E; }
.strip figure { margin: 0; text-align: center; }
.strip img { display: block; margin: 0 auto; image-rendering: auto; }
.strip figcaption { margin-top: 8px; color: #6F7B84; font-size: 11px;
  font-family: ui-monospace, Menlo, monospace; }
.note { border-top: 1px solid #23282E; padding: 34px 40px 60px; max-width: 1240px; }
.note h2 { font-size: 19px; margin: 0 0 10px; }
.note p, .note li { color: #9AA7B0; max-width: 86ch; }
.note li { margin-bottom: 8px; }
.shipped { border: 1px solid #2C6E63; background: #10201E; border-radius: 10px;
  padding: 12px 16px; color: #BFD6D1; max-width: 86ch; }
.zoom { margin: 18px 0; overflow-x: auto; }
.zoom img { display: block; image-rendering: pixelated; max-width: none; }
pre.meas { background: #101317; border: 1px solid #262B31; border-radius: 10px;
  padding: 14px 16px; overflow-x: auto; color: #9BE9DC;
  font: 12px/1.7 ui-monospace, "SF Mono", Menlo, monospace; max-width: 88ch; }
</style></head><body>
<header><h1>02-piece, trimming the dark above the bar</h1>
<p class="shipped"><b>02-match is what shipped.</b> Aligned, and 17 units proud
on both sides. This page is the record of the choice, not a live question.</p>
<p>Every row below is <code>02-piece</code>. The palette does not change, the
grades do not change, the lanes do not change, and the correction that stops a
lane riding out over the margin is in all of them. The only thing that moves is
the spur: how far it is proud of the bar above and below, and where its band
ends.</p>
<p>Each icon is a real <code>.icon</code> bundle, compiled with
<code>actool</code> and drawn by Icon Services, so the left hand picture is a
photograph of macOS drawing it rather than a guess. The numbers in each row are
read off those pixels, not off the geometry.</p>
<p><b>Where the extra dark above came from.</b> It is not the panel: past the
panel's own edge at x&nbsp;874 there is nothing but the spur, and the pixel
above the spur is Foam. It is not an unequal height either: the spur is
<code>bar height + 52</code>, exactly 26 units proud on each side, as the
docstring says. It is the spur's <b>end point</b>. The bar's band runs to
<code>1304</code> in the panel's frame; the spur's runs to
<code>outof(1200)</code>, which is <code>1485</code>. A band's centre line is a
cubic whose two control points are fixed, so stretching the end point
reparametrises the curve: at any given x the longer band has not yet travelled
as far down its own descent. Across the margin the spur's centre line therefore
sits about <b>7 canvas units above</b> the bar's, and 26 units of symmetric
skirt becomes 25 above and 12 below. The bar is not seated low inside a frame by
choice. It is seated low because the frame drifted up.</p>
<p>So the fix has two halves, and the first one is free: end the spur where the
bar ends and the two are concentric again. Then choose how proud it should be.
The lower edge as it stands today, about 12 canvas units, is the reference,
because that is the side nobody complained about.</p></header>
"""

TAIL = """<section class="note"><h2>Reading the small sizes</h2>
<p>This is the risk of the change and the reason the strip is here.
<code>icon.json</code> carries one set of artwork for every size, so whatever
the spur is at 1024 is what Finder gets at 16, divided by 64. A skirt of 11
canvas units is a sixth of a pixel at 16. It is not a band at that size in any
of these rows, the one shipping today included.</p>
<p>What survives at 16 is not the skirt. It is the tab: bar plus skirt plus
skirt, a dark shape reaching the tile's edge with a pale line through it. That
tab is 37 canvas units narrower in <code>02-match</code> than in
<code>00-current</code> and 43 narrower in <code>04-hairline</code>, which is
half a pixel at 16 and one pixel at 32. Every row still reads as a crossing at
both sizes, and the pale line through the tab is the same width in all five
because the bar is never touched.</p>
<h2>The one row that is not a trim</h2>
<p><code>01-aligned</code> is the free half of the fix on its own. It takes 6
canvas units off the top and puts 5 back on the bottom, because concentric at 26
units is 17 and 17 rather than 22 and 11. It is the honest baseline for the rows
under it and it is not the answer, since the bar now sits inside a thicker frame
overall than the one that was complained about.</p>
<h2>What to ship</h2>
<p><b>02-match.</b> Aligned, and 17 units proud on both sides, which measures 11
canvas units above and 11 below. Eleven is what the lower edge measures today,
and the lower edge is the side nobody complained about, so this is the trim
stated in the only number the drawing already agreed on. The dark still
accompanies the bar across the white, which is the whole reason the spur exists:
Shallow on Foam measures 1.26 and cannot be seen on its own.</p>
<p>If it still reads heavy, <code>03-low</code> is the next step and it says
something slightly different: 8 above against 11 below puts the bar high in its
tab, so the dark reads as the bar's own shadow rather than as a frame it sits
in. <code>04-hairline</code> at 6 above is where the upper edge stops being a
band and becomes an outline, and it is included as the stated limit rather than
as a candidate.</p>
</section></body></html>
"""


if __name__ == "__main__":
    main()
