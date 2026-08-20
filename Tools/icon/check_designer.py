#!/usr/bin/env python3
"""Proves that designer.html draws what menubar.py would draw.

    python3 Tools/icon/check_designer.py

The designer page is only worth having if a shape built on it can be shipped
unchanged, so the geometry behind it is a PORT of menubar.py rather than a
lookalike, and this script is what keeps it one. It checks three things and
prints the numbers rather than a verdict, because "close enough" is a judgement
and the numbers are what it should be made on.

  THE CONSTANTS. designer.geom.js carries lib9's cubic as literals. They are
  recomputed here from lib9 itself and compared.

  THE GEOMETRY. Three parameter sets are drawn by both sides and every vertex of
  every polygon is compared. These should agree to the last bit or close to it:
  the two are the same arithmetic in the same order on the same doubles, and the
  only room for disagreement is one library's cos against another's.

  THE PIXELS. The same three are rasterised by rsvg-convert and by the browser
  and compared pixel by pixel. These will NOT agree exactly and nobody should
  expect them to: cairo and Skia antialias differently, and a difference in the
  grey of an edge pixel is a difference in one rasteriser's idea of coverage,
  not in the shape. What matters is that no pixel flips side: the report gives
  the mean and worst difference and how many pixels differ once thresholded,
  which is the number that would mean the page is lying.
"""
import base64
import json
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
BUILD = os.path.join(HERE, ".build", "designer")
sys.path.insert(0, HERE)
import lib9      # noqa: E402
import menubar as m   # noqa: E402

GEOM = os.path.join(HERE, "designer.geom.js")

# One from the family he picked, one that exercises the varying weight, and one
# that turns on everything the first two leave off.
CASES = {
    "calm": dict(m.PRESETS["calm"]),
    "stem": dict(m.PRESETS["stem"]),
    "everything": dict(lane=16.0, fill=0.94, width=132.0, spread=0.78,
                       land=0.80, stagger=0.30, t0=0.12, trunk=1.35,
                       trunk_start=0.18, cap=0.55, lanes=3, cove_run=1.4,
                       taper=0.6),
}
SCALE = 3


def js(expr):
    out = subprocess.run(
        ["node", "-e", "const g=require(%s);%s" % (json.dumps(GEOM), expr)],
        capture_output=True, text=True, timeout=120)
    if out.returncode:
        raise SystemExit(out.stderr.strip())
    return out.stdout


def check_constants():
    src = open(GEOM).read()
    want = [-280.0, lib9.CX + (300 - 512) * lib9.S,
            lib9.CX + (560 - 512) * lib9.S, 1304.0]
    got = json.loads(re.search(r"const XS = (\[[^\]]*\]);", src).group(1))
    worst = max(abs(a - b) for a, b in zip(want, got))
    print("constants      XS worst difference from lib9: %.3g" % worst)
    return worst


def geometry(name, params):
    _, want = m.design(**params)
    got = json.loads(js("console.log(JSON.stringify(g.design(%s)[1]))"
                        % json.dumps(params)))
    if len(want) != len(got):
        raise SystemExit("%s: %d polygons in python, %d in js"
                         % (name, len(want), len(got)))
    worst, n = 0.0, 0
    for a, b in zip(want, got):
        if len(a) != len(b):
            raise SystemExit("%s: polygon lengths differ" % name)
        for (x1, y1), (x2, y2) in zip(a, b):
            worst = max(worst, abs(x1 - x2), abs(y1 - y2))
            n += 1
    print("geometry       %-11s %d polygons, %d vertices, worst difference %.3g"
          % (name, len(want), n, worst))
    return worst


def size_of(params):
    w, polys = m.design(**params)
    points = 18.0
    art = (points - 2 * m.BLEED) * params.get("fill", 1.0)
    polys, size = m.fit(polys, w, art, (points - art) / 2.0)
    return polys, size, (int(round(size[0] * SCALE)), int(round(size[1] * SCALE)))


def python_png(name, params):
    polys, size, px = size_of(params)
    d = []
    for p in polys:
        d.append("M%.6f,%.6f" % p[0] + "".join("L%.6f,%.6f" % q for q in p[1:]) + "Z")
    # preserveAspectRatio is off so that rsvg stretches the box to the surface
    # exactly the way the canvas transform below does. Left on, a rounded
    # surface would be letterboxed and every comparison would be off by a
    # fraction of a pixel for a reason that has nothing to do with the shape.
    svg = ('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" '
           'viewBox="0 0 %.6f %.6f" preserveAspectRatio="none">'
           '<rect width="%.6f" height="%.6f" fill="#fff"/>'
           '<path fill="#000" fill-rule="nonzero" d="%s"/></svg>'
           % (px[0], px[1], size[0], size[1], size[0], size[1], "".join(d)))
    src = os.path.join(BUILD, "py-%s.svg" % name)
    dst = os.path.join(BUILD, "py-%s.png" % name)
    with open(src, "w") as f:
        f.write(svg)
    subprocess.run(["rsvg-convert", src, "-o", dst], check=True, timeout=60)
    return dst, size, px


def browser_pngs(sizes):
    """Every case drawn by the browser's own rasteriser.

    Through --screenshot and not --dump-dom, which writes its output and then
    does not exit on this machine. The page is one canvas at the exact pixel
    size, the window is bigger than it, and the shot is cropped back down, so
    what is compared is the canvas's own pixels and no chrome around them.
    """
    from PIL import Image
    chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    geom = open(GEOM).read()
    paths = {}
    for name, params in CASES.items():
        size, px = sizes[name]
        page = os.path.join(BUILD, "harness-%s.html" % name)
        with open(page, "w") as f:
            f.write("<!doctype html><meta charset=utf-8>"
                    "<style>html,body{margin:0;padding:0;background:#fff}"
                    "canvas{display:block}</style><body><script>\n"
                    + geom + "\n"
                    + "const P = %s, SIZE = %s, PX = %s;\n"
                    % (json.dumps(params), json.dumps(size), json.dumps(px))
                    + """
const [w, polys] = design(P);
const points = 18.0, art = (points - 2 * 1.5) * P.fill;
const [fitted] = fit(polys, w, art, (points - art) / 2.0);
const c = document.createElement("canvas");
c.width = PX[0]; c.height = PX[1];
document.body.appendChild(c);
const x = c.getContext("2d");
x.fillStyle = "#fff"; x.fillRect(0, 0, PX[0], PX[1]);
x.setTransform(PX[0] / SIZE[0], 0, 0, PX[1] / SIZE[1], 0, 0);
const path = new Path2D();
for (const p of fitted) {
  path.moveTo(p[0][0], p[0][1]);
  for (let i = 1; i < p.length; i++) path.lineTo(p[i][0], p[i][1]);
  path.closePath();
}
x.fillStyle = "#000"; x.fill(path, "nonzero");
</script></body>""")
        shot = os.path.join(BUILD, "shot-%s.png" % name)
        if os.path.exists(shot):
            os.remove(shot)
        proc = subprocess.Popen(
            [chrome, "--headless", "--disable-gpu", "--hide-scrollbars",
             "--force-device-scale-factor=1",
             "--user-data-dir=" + os.path.join(BUILD, "chrome-" + name),
             "--screenshot=" + shot,
             "--window-size=%d,%d" % (max(px[0], 400) + 40, max(px[1], 400) + 40),
             "--virtual-time-budget=3000", "file://" + page],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(120):
            if os.path.exists(shot) and os.path.getsize(shot) > 0:
                break
            time.sleep(0.5)
        proc.kill()
        proc.wait(timeout=30)
        if not os.path.exists(shot):
            raise SystemExit("the browser produced no shot for %s" % name)
        out = os.path.join(BUILD, "js-%s.png" % name)
        Image.open(shot).convert("RGB").crop((0, 0, px[0], px[1])).save(out)
        paths[name] = out
    return paths


def compare(name, a, b):
    from PIL import Image
    ia = Image.open(a).convert("L")
    ib = Image.open(b).convert("L")
    if ia.size != ib.size:
        raise SystemExit("%s: %s vs %s" % (name, ia.size, ib.size))
    pa, pb = list(ia.tobytes()), list(ib.tobytes())
    diffs = [abs(x - y) for x, y in zip(pa, pb)]
    flips = sum(1 for x, y in zip(pa, pb) if (x < 128) != (y < 128))
    over8 = sum(1 for d in diffs if d > 8)
    print("pixels         %-11s %dx%d, mean %.2f, worst %d of 255, "
          "%d over 8, %d cross the halfway line"
          % (name, ia.size[0], ia.size[1], sum(diffs) / len(diffs),
             max(diffs), over8, flips))
    return max(diffs), flips


def main():
    os.makedirs(BUILD, exist_ok=True)
    print("Tools/icon/designer.geom.js against Tools/icon/menubar.py\n")
    check_constants()

    # The names both sides carry have to agree. A name only one side has is not a
    # failure and must not be reported as one: a mark built on the page becomes a
    # preset in menubar.py, and it only needs to exist in designer.geom.js if the
    # owner wants a button for it on the page.
    jp = json.loads(js("console.log(JSON.stringify(g.PRESETS))"))
    shared = sorted(set(m.PRESETS) & set(jp))
    for name in shared:
        want, got = m.PRESETS[name], jp[name]
        if set(want) != set(got) or any(abs(want[k] - got[k]) > 1e-12 for k in want):
            raise SystemExit("preset %s differs between python and js" % name)
    only_py = sorted(set(m.PRESETS) - set(jp))
    only_js = sorted(set(jp) - set(m.PRESETS))
    print("presets        all %d shared names agree between python and js%s%s"
          % (len(shared),
             ", %s only in menubar.py" % ", ".join(only_py) if only_py else "",
             ", %s only in designer.geom.js" % ", ".join(only_js) if only_js else ""))

    page = os.path.join(HERE, "designer.html")
    inlined = open(GEOM).read() in open(page).read()
    print("page           designer.html inlines designer.geom.js verbatim: %s\n"
          % ("yes" if inlined else "NO, REBUILD IT"))
    if not inlined:
        raise SystemExit("run python3 Tools/icon/build_designer.py")

    worst_geom = max(geometry(n, p) for n, p in CASES.items())
    print()

    sizes = {}
    py = {}
    for name, params in CASES.items():
        path, size, px = python_png(name, params)
        py[name] = path
        sizes[name] = [list(size), list(px)]
    jsp = browser_pngs(sizes)
    worst_px = 0
    flips = 0
    for name in CASES:
        wpx, fl = compare(name, py[name], jsp[name])
        worst_px = max(worst_px, wpx)
        flips += fl

    print("\nworst vertex disagreement anywhere: %.3g box units" % worst_geom)
    print("pixels crossing the halfway line, all three cases: %d" % flips)
    return 0 if worst_geom < 1e-9 else 1


if __name__ == "__main__":
    sys.exit(main())
