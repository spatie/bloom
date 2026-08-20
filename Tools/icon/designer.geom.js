// The menu bar mark's geometry, ported from Tools/icon/menubar.py.
//
// THIS FILE IS A PORT AND HAS TO STAY ONE. Everything the designer page draws
// comes from here, and the page's only claim is that what it shows is what the
// generator would write. Tools/icon/check_designer.py runs this file in node,
// runs menubar.py beside it, and compares the polygons vertex by vertex and the
// rendered pixels one by one. If a function here stops matching its Python
// twin, that script says so.
//
// The constants below are lib9's, which is where the app icon's own lane comes
// from. They are checked by the same script rather than trusted.

const SPAN0 = -280.0, SPAN1 = 1304.0;
const XS = [-280.0, 248.54368932038835, 571.6504854368932, 1304.0];

function bez(p, t) {
  const u = 1 - t;
  return u * u * u * p[0] + 3 * u * u * t * p[1]
       + 3 * u * t * t * p[2] + t * t * t * p[3];
}

function weights(win) {
  return [bez([1, 1, 0, 0], win[0]), bez([1, 1, 0, 0], win[1])];
}

function centreline(ystart, yend, x0, x1, win, n) {
  n = n === undefined ? 72 : n;
  const [a, b] = weights(win);
  const drop = (ystart - yend) / (a - b);
  const y1 = ystart - a * drop;
  const y0 = y1 + drop;
  const ys = [y0, y0, y1, y1];
  const xa = bez(XS, win[0]), xb = bez(XS, win[1]);
  const pts = [];
  for (let i = 0; i <= n; i++) {
    const t = win[0] + (win[1] - win[0]) * i / n;
    pts.push([x0 + (x1 - x0) * (bez(XS, t) - xa) / (xb - xa), bez(ys, t)]);
  }
  return pts;
}

function unit(dx, dy) {
  const d = Math.hypot(dx, dy) || 1.0;
  return [dx / d, dy / d];
}

function frames(pts) {
  const out = [];
  for (let i = 0; i < pts.length; i++) {
    const a = pts[Math.max(i - 1, 0)];
    const b = pts[Math.min(i + 1, pts.length - 1)];
    const t = unit(b[0] - a[0], b[1] - a[1]);
    out.push([t, [-t[1], t[0]]]);
  }
  return out;
}

function radii(pts, width) {
  const n = pts.length - 1;
  if (typeof width === "function") {
    const out = [];
    for (let i = 0; i < pts.length; i++) out.push(width(i / n) / 2.0);
    return out;
  }
  return new Array(pts.length).fill(width / 2.0);
}

function edge(pts, width, side) {
  const rs = radii(pts, width), fr = frames(pts), out = [];
  for (let i = 0; i < pts.length; i++) {
    const n = fr[i][1], r = rs[i] * side;
    out.push([pts[i][0] + n[0] * r, pts[i][1] + n[1] * r]);
  }
  return out;
}

function cap(p, tangent, normal, r, atEnd, capness) {
  const n = atEnd ? normal : [-normal[0], -normal[1]];
  const t = atEnd ? tangent : [-tangent[0], -tangent[1]];
  const out = [];
  for (let k = 1; k < 12; k++) {
    const a = Math.PI * k / 12.0;
    const c = Math.cos(a), sn = Math.sin(a) * capness;
    out.push([p[0] + r * (n[0] * c + t[0] * sn),
              p[1] + r * (n[1] * c + t[1] * sn)]);
  }
  return out;
}

function ribbon(pts, width, caps, capness) {
  caps = caps === undefined ? [true, true] : caps;
  capness = capness === undefined ? 1.0 : capness;
  const fr = frames(pts), rs = radii(pts, width);
  const left = [], right = [];
  for (let i = 0; i < pts.length; i++) {
    const n = fr[i][1], r = rs[i];
    left.push([pts[i][0] + n[0] * r, pts[i][1] + n[1] * r]);
    right.push([pts[i][0] - n[0] * r, pts[i][1] - n[1] * r]);
  }
  let out = left.slice();
  const last = pts.length - 1;
  if (caps[1]) out = out.concat(cap(pts[last], fr[last][0], fr[last][1], rs[last], true, capness));
  out = out.concat(right.slice().reverse());
  if (caps[0]) out = out.concat(cap(pts[0], fr[0][0], fr[0][1], rs[0], false, capness));
  return out;
}

function cove(arm, y, run, n) {
  n = n === undefined ? 24 : n;
  let apex = null, at = 0;
  for (let i = 0; i < arm.length - 1; i++) {
    const [ax, ay] = arm[i], [bx, by] = arm[i + 1];
    if ((ay - y) * (by - y) <= 0 && ay !== by) {
      apex = ax + (bx - ax) * (y - ay) / (by - ay);
      at = i;
      break;
    }
  }
  if (apex === null) return null;
  const x0 = apex - run;
  if (x0 <= arm[0][0]) return null;
  let j = -1;
  for (let i = 0; i < arm.length; i++) if (arm[i][0] <= x0) j = i;
  if (j < 0 || j + 1 >= arm.length) return null;
  const [ax, ay] = arm[j], [bx, by] = arm[j + 1];
  const k = bx !== ax ? (x0 - ax) / (bx - ax) : 0.0;
  const p0 = [x0, ay + (by - ay) * k];
  const [dx, dy] = unit(bx - ax, by - ay);
  if (Math.abs(dy) < 1e-9) return null;
  const t = (y - p0[1]) / dy;
  if (t <= 0) return null;
  const c = [p0[0] + dx * t, y];
  const p2 = [c[0] + Math.hypot(c[0] - p0[0], c[1] - p0[1]), y];
  const curve = [];
  for (let m = 0; m <= n; m++) {
    const u = m / n, v = 1 - u;
    curve.push([v * v * p0[0] + 2 * v * u * c[0] + u * u * p2[0],
                v * v * p0[1] + 2 * v * u * c[1] + u * u * p2[1]]);
  }
  const tail = [];
  for (let i = at; i >= 0; i--) if (arm[i][0] >= x0) tail.push(arm[i]);
  return curve.concat([[apex, y]], tail, [p0]);
}

function area(poly) {
  let s = 0.0;
  for (let i = 0; i < poly.length; i++) {
    const [x, y] = poly[i], [x2, y2] = poly[(i + 1) % poly.length];
    s += x * y2 - x2 * y;
  }
  return s / 2.0;
}

function solid(poly) {
  return area(poly) > 0 ? poly : poly.slice().reverse();
}

function ease(s) { return s * s * (3 - 2 * s); }

const DEFAULTS = {
  lane: 13.0, fill: 0.87, width: 120.0, spread: 1.0, land: 0.72,
  stagger: 0.22, t0: 0.0, trunk: 1.0, trunk_start: 0.0, cap: 1.0,
  lanes: 3, cove_run: 0.0, taper: 0.0,
};

function design(kw) {
  const p = Object.assign({}, DEFAULTS, kw || {});
  const w = +p.width, lane = +p.lane, win = [+p.t0, 1.0];
  const t = lane * p.trunk, capness = p.cap;
  const out = [solid(ribbon(
    centreline(50.0, 50.0, p.trunk_start * w + t / 2, w - t / 2, win), t,
    undefined, capness))];

  const taper = p.taper;
  let armW;
  if (taper > 0) armW = (s) => lane * (1 - taper * 0.38 * (1 - ease(s)));
  else if (taper < 0) armW = (s) => lane * (1 + taper * 0.82 * ease(s));
  else armW = lane;

  const reach = p.spread * (50.0 - lane / 2);
  const arms = [[50.0 - reach, p.land]];
  if (Math.trunc(p.lanes) > 2) arms.push([50.0 + reach, p.land - p.stagger]);
  for (const [y0, xm] of arms) {
    const pts = centreline(y0, 50.0, lane / 2, xm * w, win);
    out.push(solid(ribbon(pts, armW, undefined, capness)));
    if (p.cove_run > 0) {
      const above = y0 < 50.0;
      const g = cove(edge(pts, armW, above ? 1 : -1),
                     above ? 50.0 - t / 2 : 50.0 + t / 2, lane * p.cove_run);
      if (g) out.push(solid(g));
    }
  }
  return [w, out];
}

function fit(polys, w, height, bleed) {
  const k = height / 100.0;
  const out = polys.map(p => p.map(([x, y]) => [bleed + x * k, bleed + y * k]));
  return [out, [w * k + 2 * bleed, height + 2 * bleed]];
}

const PRESETS = {
  gather: { lane: 13.0, fill: 1.00, width: 118.0, land: 0.70, stagger: 0.22, t0: 0.20 },
  flow:   { lane: 13.0, fill: 1.00, width: 120.0, land: 0.72, stagger: 0.22 },
  calm:   { lane: 13.0, fill: 0.87, width: 120.0, land: 0.72, stagger: 0.22 },
  stem:   { lane: 13.0, fill: 1.00, width: 120.0, land: 0.78, stagger: 0.22, taper: -1.0 },
  fillet: { lane: 13.0, fill: 1.00, width: 118.0, land: 0.70, stagger: 0.22, t0: 0.20, cove_run: 1.7 },
  stout:  { lane: 15.5, fill: 1.00, width: 122.0, land: 0.72, stagger: 0.22 },
  wide:   { lane: 17.0, fill: 0.87, width: 140.0, land: 0.82, stagger: 0.24 },
  two:    { lane: 20.0, fill: 0.92, width: 116.0, land: 0.70, lanes: 2 },
  spine:  { lane: 12.5, fill: 0.90, width: 120.0, land: 0.74, stagger: 0.22, trunk: 19.0 / 12.5 },
  tall:   { lane: 14.0, fill: 1.06, width: 120.0, land: 0.72, stagger: 0.22 },
};

// The neighbours, so the mark can be judged against what actually sits beside
// it. Measured off the owner's own bar: Dropbox 16.0 points tall, 1Password
// 16.0, and the system battery about 11.
function rrect(x0, y0, x1, y1, r, ccw) {
  const pts = [];
  const corners = [[x1 - r, y0 + r, -90], [x1 - r, y1 - r, 0],
                   [x0 + r, y1 - r, 90], [x0 + r, y0 + r, 180]];
  for (const [cx, cy, a0] of corners) {
    for (let k = 0; k <= 12; k++) {
      const a = (a0 + k * 90 / 12) * Math.PI / 180;
      pts.push([cx + r * Math.cos(a), cy + r * Math.sin(a)]);
    }
  }
  return ccw ? pts.reverse() : pts;
}

const NEIGHBOURS = [
  { h: 16.0, box: [100.0, 88.0], polys: [
    [[0, 16], [25, 0], [50, 16], [25, 32]],
    [[50, 16], [75, 0], [100, 16], [75, 32]],
    [[0, 48], [25, 32], [50, 48], [25, 64]],
    [[50, 48], [75, 32], [100, 48], [75, 64]],
    [[25, 69], [50, 53], [75, 69], [50, 85]]] },
  { h: 16.0, box: [100.0, 100.0], polys: (() => {
    const o = [], i = [];
    for (let a = 0; a < 48; a++) {
      o.push([50 + 50 * Math.cos(a * Math.PI / 24), 50 + 50 * Math.sin(a * Math.PI / 24)]);
      i.push([50 + 33 * Math.cos(-a * Math.PI / 24), 50 + 33 * Math.sin(-a * Math.PI / 24)]);
    }
    return [o, i, [[43, 44], [57, 44], [55, 86], [45, 86]]];
  })() },
  { h: 11.0, box: [100.0, 44.0], polys: [
    rrect(0, 0, 88, 44, 12, false), rrect(4.5, 4.5, 83.5, 39.5, 8, true),
    rrect(9, 9, 52, 35, 5, false), rrect(91, 15, 100, 29, 4, false)] },
];

const BAR_H = 24.0, BLEED = 1.5, ART = 15.0, PAD = 9.0, GAP = 13.0;

// One menu bar strip as a list of placed polygons, in points, matching the
// layout the earlier comparison pages used so the two can be held side by side.
function strip(params, points) {
  const [w, polys] = design(params);
  const art = (points - 2 * BLEED) * params.fill;
  const [fitted, size] = fit(polys, w, art, (points - art) / 2.0);
  const out = [];
  let x = PAD;
  const place = (ps, dx, dy, k) =>
    out.push(...ps.map(p => p.map(([px, py]) => [dx + px * k, dy + py * k])));
  const n0 = NEIGHBOURS[0], k0 = n0.h / n0.box[1];
  place(n0.polys, x, (BAR_H - n0.h) / 2, k0);
  x += n0.box[0] * k0 + GAP;
  place(fitted, x, (BAR_H - size[1]) / 2, 1.0);
  x += size[0] + GAP;
  for (const nb of NEIGHBOURS.slice(1)) {
    const k = nb.h / nb.box[1];
    place(nb.polys, x, (BAR_H - nb.h) / 2, k);
    x += nb.box[0] * k + GAP;
  }
  return [out, x - GAP + PAD];
}

if (typeof module !== "undefined") {
  module.exports = { bez, centreline, ribbon, edge, cove, solid, design, fit,
                     strip, DEFAULTS, PRESETS, XS, SPAN0, SPAN1 };
}
