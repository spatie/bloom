#!/usr/bin/env python3
"""Assembles Tools/icon/designer.html, the page the owner picks the mark on.

    python3 Tools/icon/build_designer.py

One file out, nothing loaded from anywhere: the geometry in designer.geom.js is
inlined rather than linked, because the page has to work from a file:// URL with
no server and no network. Tools/icon/check_designer.py is what proves the
inlined copy still draws what menubar.py draws.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import menubar as m  # noqa: E402

GEOM = open(os.path.join(HERE, "designer.geom.js")).read()

# Every knob, in the order they are shown. The last field is what the readout
# beside the slider says, as a javascript expression over the current value `v`
# and the current art height in points `A`.
KNOBS = [
    ("lane", "Lane weight", 5, 28, 0.1,
     "v.toFixed(1) + ' units, ' + (v * A / 100).toFixed(2) + ' pt'"),
    ("trunk", "Trunk weight", 0.4, 2.2, 0.01,
     "'x' + v.toFixed(2) + ', ' + (v * P.lane * A / 100).toFixed(2) + ' pt'"),
    ("fill", "Height of the mark", 0.6, 1.2, 0.01,
     "(v * 15).toFixed(2) + ' pt art, Dropbox 16.0'"),
    ("width", "Width of the mark", 85, 170, 1,
     "(v * A / 100).toFixed(1) + ' pt wide'"),
    ("spread", "Fan spread", 0.3, 1.0, 0.01,
     "v >= 0.995 ? 'out to the edges' : v.toFixed(2)"),
    ("land", "Where the upper lane lands", 0.4, 1.0, 0.01,
     "(v * 100).toFixed(0) + '% of the width'"),
    ("stagger", "Stagger of the lower lane", 0.0, 0.45, 0.01,
     "v < 0.02 ? 'level, which is an arrow' : (v * 100).toFixed(0) + '% earlier'"),
    ("t0", "S in the curve", 0.0, 0.35, 0.005,
     "v < 0.005 ? 'the whole band, a full S' : (v <= 0.205 && v >= 0.195 ? "
     "'where gather is cut' : v.toFixed(3) + ', less S')"),
    ("trunk_start", "Where the trunk begins", 0.0, 0.5, 0.01,
     "v < 0.005 ? 'the full width' : (v * 100).toFixed(0) + '% in'"),
    ("cap", "Terminals", 0.0, 1.3, 0.01,
     "v < 0.02 ? 'cut flat' : (v > 0.98 && v < 1.02 ? 'round' : "
     "(v > 1 ? 'past round' : v.toFixed(2) + ', part way to flat'))"),
    ("cove_run", "Coved junctions", 0.0, 3.0, 0.05,
     "v < 0.03 ? 'off' : v.toFixed(2) + ' lane widths back'"),
    ("taper", "Weight along a lane", -1.0, 1.0, 0.02,
     "Math.abs(v) < 0.02 ? 'even' : (v < 0 ? 'thins into the trunk' : "
     "'thins at the open end')"),
]

PRESET_ORDER = ["calm", "gather", "flow", "stem", "fillet", "stout", "wide",
                "two", "spine", "tall"]

BODY = r"""
<div class="page">
<header>
  <h1>Bloom's menu bar mark, as thirteen numbers</h1>
  <p class="lede">Everything here is drawn by the same geometry
  <code>Tools/icon/menubar.py</code> uses, ported and then checked against it
  vertex by vertex and pixel by pixel, so a mark built on this page can be
  shipped without being redrawn. Move a slider and every picture below moves
  with it.</p>
</header>

<div class="split">
  <aside class="controls">
    <div class="block">
      <h2>Start from</h2>
      <div class="presets" id="presets"></div>
    </div>
    <div class="block">
      <h2>Lanes</h2>
      <div class="seg" id="seg">
        <button data-n="2">two</button><button data-n="3">three</button>
      </div>
    </div>
    <div class="block" id="knobs"></div>
    <div class="block">
      <h2>What you built</h2>
      <textarea id="out" spellcheck="false" wrap="off" readonly></textarea>
      <button class="copy" id="copy">Copy</button>
      <p class="hint">Paste it into <code>PRESETS</code> in
      <code>Tools/icon/menubar.py</code>, set <code>CHOICE</code> to its name
      and run <code>python3 Tools/icon/menubar.py</code>. Nothing else has to
      change: <code>CHOICE</code> takes a preset as happily as a function. Put
      the same line in <code>designer.geom.js</code> only if you want a button
      for it on this page.</p>
    </div>
  </aside>

  <main class="preview">
    <section>
      <h2>The curve</h2>
      <div class="row"><canvas id="big-dark"></canvas><canvas id="big-light"></canvas></div>
    </section>

    <section>
      <h2>In the bar, actual size</h2>
      <p class="note">Dropbox on the left is 16.0 points tall, the ring 16.0 and
      the battery about 11, measured off the owner's own bar. The 1x columns are
      an external monitor and they are the ones that decide: that is where a lane
      or a counter runs out of pixels first.</p>
      <div class="bars" id="bars"></div>
    </section>

    <section>
      <h2>Every device pixel at 1x</h2>
      <p class="note">The same mark at 16 and 18 points on a 1x display with one
      block per pixel, and under them what a column through the trunk actually
      lands on. A trunk that is one block at 60 percent is a grey hairline on an
      external monitor, whatever it looks like magnified.</p>
      <div class="row px" id="pixels"></div>
      <p class="measure" id="section"></p>
    </section>
  </main>
</div>
</div>
"""

CSS = r"""
:root { color-scheme: light dark; --bg:#fbfbfc; --fg:#17171b; --dim:#5b5b66;
  --card:#fff; --line:#e3e3e8; --accent:#3b5bdb; }
@media (prefers-color-scheme: dark) {
  :root { --bg:#131317; --fg:#ececf1; --dim:#a0a0ad; --card:#1b1b21;
    --line:#2c2c35; --accent:#7f9cf5; }
}
* { box-sizing: border-box; }
body { margin:0; padding:32px 28px 80px; background:var(--bg); color:var(--fg);
  font:14px/1.5 -apple-system, BlinkMacSystemFont, "SF Pro Text", Helvetica, Arial, sans-serif; }
.page { max-width:1400px; margin:0 auto; }
h1 { font-size:24px; margin:0 0 8px; letter-spacing:-0.01em; }
.lede { color:var(--dim); max-width:64em; margin:0 0 24px; }
h2 { font-size:11px; text-transform:uppercase; letter-spacing:.07em;
  color:var(--dim); margin:0 0 10px; font-weight:600; }
code { font-family:ui-monospace, SFMono-Regular, Menlo, monospace; font-size:.92em; }
.split { display:grid; grid-template-columns:330px minmax(0,1fr); gap:26px; align-items:start; }
.controls { position:sticky; top:20px; }
.block { background:var(--card); border:1px solid var(--line); border-radius:12px;
  padding:14px 16px; margin-bottom:14px; }
.presets { display:flex; flex-wrap:wrap; gap:6px; }
.presets button, .seg button, .copy { font:inherit; font-size:12.5px; cursor:pointer;
  border:1px solid var(--line); background:transparent; color:var(--fg);
  border-radius:7px; padding:4px 10px; font-family:ui-monospace, SFMono-Regular, Menlo, monospace; }
.presets button:hover, .seg button:hover, .copy:hover { border-color:var(--accent); }
.presets button.on, .seg button.on { background:var(--accent); border-color:var(--accent); color:#fff; }
.seg { display:flex; gap:6px; }
.knob { margin-bottom:13px; }
.knob:last-child { margin-bottom:0; }
.knob label { display:flex; justify-content:space-between; align-items:baseline; gap:10px;
  font-size:12.5px; margin-bottom:3px; }
.knob .val { color:var(--dim); font-size:11.5px; text-align:right;
  font-family:ui-monospace, SFMono-Regular, Menlo, monospace; }
.knob input { width:100%; margin:0; accent-color:var(--accent); }
textarea { width:100%; height:132px; font-family:ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size:11px; line-height:1.45; border:1px solid var(--line); border-radius:8px;
  background:var(--bg); color:var(--fg); padding:8px; resize:vertical; }
.copy { margin-top:8px; }
.hint { color:var(--dim); font-size:11.5px; margin:8px 0 0; }
.preview section { background:var(--card); border:1px solid var(--line);
  border-radius:12px; padding:16px 18px; margin-bottom:14px; }
.note { color:var(--dim); font-size:12.5px; margin:-4px 0 12px; max-width:70em; }
.row { display:flex; gap:14px; flex-wrap:wrap; align-items:flex-start; }
canvas { display:block; image-rendering:pixelated; }
#big-dark, #big-light { border-radius:10px; }
.bars { display:grid; grid-template-columns:repeat(auto-fit, minmax(215px,1fr));
  gap:16px 22px; }
.bars .col h3 { font-size:11px; text-transform:uppercase; letter-spacing:.07em;
  color:var(--dim); margin:0 0 6px; font-weight:600; }
.bars canvas { border-radius:3px; margin-bottom:5px; }
.row.px { align-items:flex-end; }
.px figure { margin:0; }
.px canvas { border-radius:4px; outline:1px solid var(--line); }
.px figcaption { color:var(--dim); font-size:11px; margin-top:5px;
  font-family:ui-monospace, SFMono-Regular, Menlo, monospace; }
.measure { margin:14px 0 0; font-size:12.5px;
  font-family:ui-monospace, SFMono-Regular, Menlo, monospace; }
@media (max-width:1080px) { .split { grid-template-columns:1fr; }
  .controls { position:static; } }
"""

APP = r"""
const DARK = "#1b1e28", LIGHT = "#f0f0f2";
const INK_DARK = "#ffffff", INK_LIGHT = "#1c1c20";
const COLUMNS = [[16,1],[16,2],[18,1],[18,2]];
const KNOBS = __KNOBS__;
const PRESET_ORDER = __PRESETS__;

let P = Object.assign({}, DEFAULTS, PRESETS.calm);

function fillPath(ctx, polys) {
  const path = new Path2D();
  for (const p of polys) {
    path.moveTo(p[0][0], p[0][1]);
    for (let i = 1; i < p.length; i++) path.lineTo(p[i][0], p[i][1]);
    path.closePath();
  }
  ctx.fill(path, "nonzero");
}

function sized(cv, wpx, hpx, cssw) {
  cv.width = wpx; cv.height = hpx;
  cv.style.width = cssw + "px";
  cv.style.height = (hpx * cssw / wpx) + "px";
  return cv.getContext("2d");
}

// The mark alone, fitted the way menubar.py fits it: the image stays the height
// AppKit lays out and the art shrinks inside it, so height given back to the
// bleed is height the mark does not occupy.
function markAt(points) {
  const [w, polys] = design(P);
  const art = (points - 2 * BLEED) * P.fill;
  return fit(polys, w, art, (points - art) / 2.0);
}

function drawBig(cv, bg, ink) {
  const artPt = 120, box = artPt * 1.3, pad = 18, k = 2;
  const [w, polys] = design(P);
  const [fitted, size] = fit(polys, w, artPt * P.fill, (box - artPt * P.fill) / 2);
  const ctx = sized(cv, (size[0] + 2 * pad) * k, (size[1] + 2 * pad) * k, size[0] + 2 * pad);
  ctx.setTransform(k, 0, 0, k, 0, 0);
  ctx.fillStyle = bg; ctx.fillRect(0, 0, size[0] + 2 * pad, size[1] + 2 * pad);
  ctx.translate(pad, pad);
  ctx.fillStyle = ink;
  fillPath(ctx, fitted);
}

// The canvas is a whole number of device pixels and the drawing is not stretched
// to fill it. Rounding the width and then scaling by the rounded ratio squeezed
// the art by up to half a pixel, which is exactly the size of the thing these
// panels exist to show.
function drawStrip(cv, points, scale, bg, ink) {
  const [polys, total] = strip(P, points);
  const ctx = sized(cv, Math.ceil(total * scale), Math.round(BAR_H * scale),
                    Math.ceil(total * scale) / scale);
  ctx.setTransform(scale, 0, 0, scale, 0, 0);
  ctx.fillStyle = bg; ctx.fillRect(0, 0, total + 1, BAR_H);
  ctx.fillStyle = ink;
  fillPath(ctx, polys);
}

// At 1x a point IS a device pixel, so the transform is the identity and the
// canvas is a whole pixel wider than the art rather than the art being squeezed
// into a whole number of pixels.
function drawPixels(cv, points, bg, ink, zoom) {
  const [fitted, size] = markAt(points);
  const wpx = Math.ceil(size[0]), hpx = Math.round(size[1]);
  const off = document.createElement("canvas");
  off.width = wpx; off.height = hpx;
  const o = off.getContext("2d");
  o.fillStyle = bg; o.fillRect(0, 0, wpx, hpx);
  o.fillStyle = ink;
  fillPath(o, fitted);
  const ctx = sized(cv, wpx * zoom, hpx * zoom, wpx * zoom);
  ctx.imageSmoothingEnabled = false;
  ctx.drawImage(off, 0, 0, wpx * zoom, hpx * zoom);
}

// What the trunk actually comes out as at 1x, which is the question this panel
// is asked: how many device pixel rows it lands on and how much ink the darkest
// of them gets.
//
// Worked out from the geometry rather than read back out of the canvas, and the
// reason is measurable. Skia supersamples four times in y, so it quantises the
// coverage of a horizontal edge to quarters: a trunk at 0.735 of a pixel and one
// at 0.848 both come back as exactly 192 of 255, and the panel would report the
// same "75 percent" for a mark at 16 points and at 18. The overlap of a band
// with a pixel row is arithmetic, and arithmetic does not round to quarters.
// Checked against rsvg-convert, which renders the shipped asset: it gives 73 and
// 87 percent where this gives 74 and 85.
function trunkSection(points) {
  const [fitted, size] = markAt(points);
  const trunk = fitted[0];
  let x0 = Infinity, x1 = -Infinity;
  for (const q of trunk) { x0 = Math.min(x0, q[0]); x1 = Math.max(x1, q[0]); }
  // Half a pixel inside where the terminal starts, which is the straight run of
  // the trunk and past every junction on it. Worked out from the terminal's own
  // reach rather than from a fraction of the length, because a heavy trunk's
  // terminal is a large part of it and a fraction lands inside the curve.
  const art = (points - 2 * BLEED) * P.fill;
  const thick = P.lane * P.trunk * art / 100.0;
  const x = Math.max(x0 + 0.02 * (x1 - x0), x1 - P.cap * thick / 2 - 0.5);
  const ys = [];
  for (let i = 0; i < trunk.length; i++) {
    const a = trunk[i], b = trunk[(i + 1) % trunk.length];
    if ((a[0] - x) * (b[0] - x) <= 0 && a[0] !== b[0]) {
      ys.push(a[1] + (b[1] - a[1]) * (x - a[0]) / (b[0] - a[0]));
    }
  }
  if (ys.length < 2) return "not measurable here";
  const top = Math.min(...ys), bot = Math.max(...ys);
  let rows = 0, best = 0;
  for (let y = Math.floor(top); y < Math.ceil(bot); y++) {
    const cover = Math.min(bot, y + 1) - Math.max(top, y);
    if (cover > 0.03) rows++;
    best = Math.max(best, cover);
  }
  return (bot - top).toFixed(2) + " pt, which is " + rows + " px with the darkest at "
       + Math.round(Math.min(best, 1) * 100) + "%";
}

// Laid out the way PRESETS is written in menubar.py, continuation lines under
// the opening bracket, so what comes off this page reads like the rest of the
// file rather than like something a page printed.
function output() {
  const A = 15 * P.fill;
  const keys = ["lane","fill","width","spread","land","stagger","t0","trunk",
                "trunk_start","cap","lanes","cove_run","taper"];
  const parts = keys.map(k => k + "=" + (k === "lanes" ? Math.trunc(P[k])
                                         : (+P[k]).toFixed(k === "t0" ? 3 : 2)));
  const head = '    "mine": dict(';
  const pad = " ".repeat(head.length);
  const lines = [];
  for (let i = 0; i < parts.length; i += 3)
    lines.push((i ? pad : head) + parts.slice(i, i + 3).join(", ")
               + (i + 3 < parts.length ? "," : "),"));
  return "# Tools/icon/menubar.py, inside PRESETS\n"
       + lines.join("\n") + "\n\n"
       + '# then set:  CHOICE = "mine"\n'
       + "# and run:   python3 Tools/icon/menubar.py\n\n"
       + "# lane " + (P.lane * A / 100).toFixed(2) + " pt, trunk "
       + (P.trunk * P.lane * A / 100).toFixed(2) + " pt, art " + A.toFixed(2)
       + " pt tall, " + (P.width * A / 100).toFixed(1) + " pt wide\n";
}

function render() {
  drawBig(document.getElementById("big-dark"), DARK, INK_DARK);
  drawBig(document.getElementById("big-light"), LIGHT, INK_LIGHT);

  const bars = document.getElementById("bars");
  bars.innerHTML = "";
  for (const [points, scale] of COLUMNS) {
    const col = document.createElement("div");
    col.className = "col";
    col.innerHTML = "<h3>" + points + " pt at " + scale + "x</h3>";
    for (const [bg, ink] of [[DARK, INK_DARK], [LIGHT, INK_LIGHT]]) {
      const cv = document.createElement("canvas");
      col.appendChild(cv);
      drawStrip(cv, points, scale, bg, ink);
    }
    bars.appendChild(col);
  }

  const px = document.getElementById("pixels");
  px.innerHTML = "";
  const sections = [];
  for (const points of [16, 18]) {
    for (const [bg, ink, mode] of [[DARK, INK_DARK, "dark"], [LIGHT, INK_LIGHT, "light"]]) {
      const fig = document.createElement("figure");
      const cv = document.createElement("canvas");
      fig.appendChild(cv);
      drawPixels(cv, points, bg, ink, 7);
      const cap = document.createElement("figcaption");
      cap.textContent = points + " pt " + mode;
      fig.appendChild(cap);
      px.appendChild(fig);
    }
    sections.push("at " + points + " pt the trunk is " + trunkSection(points));
  }
  document.getElementById("section").textContent =
    "On this setting, " + sections.join(", and ") + ".";

  const A = 15 * P.fill;
  for (const k of KNOBS) {
    const el = document.getElementById("val-" + k[0]);
    if (el) el.textContent = k[6](P[k[0]], A, P);
  }
  document.getElementById("out").value = output();
  for (const b of document.querySelectorAll("#seg button"))
    b.classList.toggle("on", +b.dataset.n === +P.lanes);
}

function buildKnobs() {
  const host = document.getElementById("knobs");
  for (const [key, label, lo, hi, step] of KNOBS) {
    const wrap = document.createElement("div");
    wrap.className = "knob";
    wrap.innerHTML = '<label><span>' + label + '</span>'
      + '<span class="val" id="val-' + key + '"></span></label>';
    const inp = document.createElement("input");
    inp.type = "range"; inp.min = lo; inp.max = hi; inp.step = step;
    inp.id = "in-" + key;
    inp.addEventListener("input", () => { P[key] = +inp.value; sync(false); });
    wrap.appendChild(inp);
    host.appendChild(wrap);
  }
}

function buildPresets() {
  const host = document.getElementById("presets");
  for (const name of PRESET_ORDER) {
    const b = document.createElement("button");
    b.textContent = name;
    b.dataset.name = name;
    b.addEventListener("click", () => {
      P = Object.assign({}, DEFAULTS, PRESETS[name]);
      sync(true);
    });
    host.appendChild(b);
  }
}

// `fromPreset` decides whether the sliders are pushed to match P or left where
// the hand put them, which is the difference between jumping to a starting
// point and dragging one control.
function sync(fromPreset) {
  if (fromPreset) {
    for (const [key] of KNOBS) {
      const inp = document.getElementById("in-" + key);
      if (inp) inp.value = P[key];
    }
  }
  for (const b of document.querySelectorAll("#presets button")) {
    const q = Object.assign({}, DEFAULTS, PRESETS[b.dataset.name]);
    b.classList.toggle("on", Object.keys(DEFAULTS)
      .every(k => Math.abs(q[k] - P[k]) < 1e-9));
  }
  render();
}

buildKnobs();
buildPresets();
for (const b of document.querySelectorAll("#seg button"))
  b.addEventListener("click", () => { P.lanes = +b.dataset.n; sync(false); });
document.getElementById("copy").addEventListener("click", async () => {
  const ta = document.getElementById("out");
  try { await navigator.clipboard.writeText(ta.value); }
  catch (e) { ta.removeAttribute("readonly"); ta.select();
              document.execCommand("copy"); ta.setAttribute("readonly", ""); }
  const b = document.getElementById("copy");
  b.textContent = "Copied"; setTimeout(() => { b.textContent = "Copy"; }, 1200);
});
sync(true);
"""


def build():
    knobs = "[\n" + ",\n".join(
        '  ["%s", "%s", %s, %s, %s, 0, (v, A, P) => %s]'
        % (k, label, lo, hi, step, fmt)
        for k, label, lo, hi, step, fmt in KNOBS) + "\n]"
    app = (APP.replace("__KNOBS__", knobs)
              .replace("__PRESETS__", repr(PRESET_ORDER).replace("'", '"')))
    html = ('<!doctype html><html lang="en"><head><meta charset="utf-8">'
            '<meta name="viewport" content="width=device-width, initial-scale=1">'
            "<title>Bloom menu bar designer</title><style>%s</style></head>"
            "<body>%s<script>\n%s\n%s\n</script></body></html>"
            % (CSS, BODY, GEOM, app))
    out = os.path.join(HERE, "designer.html")
    with open(out, "w") as f:
        f.write(html)
    return out, len(html)


if __name__ == "__main__":
    print("==> %s (%d bytes)" % build())
