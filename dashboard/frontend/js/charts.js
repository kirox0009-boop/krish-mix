/* Hand-drawn SVG charts.

   No charting library, so no dependency to install and nothing to build.
   The whole surface needed here is a time-series line chart with an
   optional filled area, a couple of series at once, gridlines, axis labels
   and a crosshair tooltip - which is a small amount of geometry.

   Values arrive as {x, y} with x in unix seconds. */

import { axisTime, el } from './fmt.js';

const NS = 'http://www.w3.org/2000/svg';
const svgEl = (tag, attrs = {}) => {
  const n = document.createElementNS(NS, tag);
  for (const [k, v] of Object.entries(attrs)) n.setAttribute(k, String(v));
  return n;
};

const PAD = { t: 10, r: 8, b: 22, l: 52 };

function niceTicks(min, max, count = 4) {
  if (!(isFinite(min) && isFinite(max))) return [0];
  if (min === max) {
    const pad = Math.abs(min) * 0.05 || 1;
    min -= pad; max += pad;
  }
  const raw = (max - min) / count;
  const mag = Math.pow(10, Math.floor(Math.log10(Math.abs(raw) || 1)));
  const norm = raw / mag;
  const step = (norm >= 5 ? 10 : norm >= 2 ? 5 : norm >= 1 ? 2 : 1) * mag;
  const out = [];
  for (let v = Math.ceil(min / step) * step; v <= max + step * 0.5; v += step) {
    out.push(Number(v.toFixed(10)));
  }
  return out.length ? out : [min, max];
}

const shortNum = (v) => {
  const a = Math.abs(v);
  if (a >= 1e6) return (v / 1e6).toFixed(1) + 'M';
  if (a >= 1e4) return (v / 1e3).toFixed(1) + 'k';
  if (a >= 100) return v.toFixed(0);
  if (a >= 1) return v.toFixed(1);
  return v.toFixed(2);
};

/**
 * Draw a chart into `host`.
 *
 * series: [{ name, color, points:[{x,y}], fill?:bool, dashed?:bool, width?:number }]
 * opts:   { yZero?:bool, yFormat?:fn, legendHost?:el, invertFill?:bool }
 */
export function lineChart(host, series, opts = {}) {
  const live = (series || []).filter((s) => s.points && s.points.length);
  host.replaceChildren();

  if (!live.length) {
    host.appendChild(el('div', 'empty',
      opts.emptyText || 'no samples yet — the backend records one every few seconds'));
    if (opts.legendHost) opts.legendHost.replaceChildren();
    return;
  }

  const rect = host.getBoundingClientRect();
  const W = Math.max(260, Math.round(rect.width || 640));
  const H = Math.max(120, Math.round(rect.height || 188));
  const iw = W - PAD.l - PAD.r;
  const ih = H - PAD.t - PAD.b;

  let xMin = Infinity, xMax = -Infinity, yMin = Infinity, yMax = -Infinity;
  for (const s of live) {
    for (const p of s.points) {
      if (p.x < xMin) xMin = p.x;
      if (p.x > xMax) xMax = p.x;
      if (p.y < yMin) yMin = p.y;
      if (p.y > yMax) yMax = p.y;
    }
  }
  if (opts.yZero) { yMin = Math.min(yMin, 0); yMax = Math.max(yMax, 0); }
  if (xMax === xMin) xMax = xMin + 1;
  if (yMax === yMin) { const p = Math.abs(yMax) * 0.05 || 1; yMin -= p; yMax += p; }

  const ticks = niceTicks(yMin, yMax, 4);
  yMin = Math.min(yMin, ticks[0]);
  yMax = Math.max(yMax, ticks[ticks.length - 1]);

  const sx = (x) => PAD.l + ((x - xMin) / (xMax - xMin)) * iw;
  const sy = (y) => PAD.t + ih - ((y - yMin) / (yMax - yMin)) * ih;

  const svg = svgEl('svg', {
    viewBox: `0 0 ${W} ${H}`, preserveAspectRatio: 'none',
    role: 'img', 'aria-label': opts.label || 'time series',
  });

  // horizontal gridlines + value labels
  for (const t of ticks) {
    const y = sy(t);
    svg.appendChild(svgEl('line',
      { class: 'grid-line', x1: PAD.l, x2: W - PAD.r, y1: y, y2: y }));
    const lb = svgEl('text',
      { class: 'axis-t', x: PAD.l - 7, y: y + 3.5, 'text-anchor': 'end' });
    lb.textContent = (opts.yFormat || shortNum)(t);
    svg.appendChild(lb);
  }

  // zero line stands out when the series crosses it
  if (yMin < 0 && yMax > 0) {
    svg.appendChild(svgEl('line', {
      x1: PAD.l, x2: W - PAD.r, y1: sy(0), y2: sy(0),
      stroke: 'rgba(255,255,255,0.2)', 'stroke-width': 1, 'stroke-dasharray': '3 3',
    }));
  }

  // x axis labels
  const span = xMax - xMin;
  const wanted = Math.max(2, Math.min(6, Math.floor(iw / 92)));
  for (let i = 0; i <= wanted; i++) {
    const x = xMin + (span * i) / wanted;
    const lb = svgEl('text', {
      class: 'axis-t', x: sx(x), y: H - 6,
      'text-anchor': i === 0 ? 'start' : i === wanted ? 'end' : 'middle',
    });
    lb.textContent = axisTime(x, span);
    svg.appendChild(lb);
  }

  // series
  live.forEach((s, idx) => {
    const pts = s.points.slice().sort((a, b) => a.x - b.x);
    const d = pts.map((p, i) => `${i ? 'L' : 'M'}${sx(p.x).toFixed(1)},${sy(p.y).toFixed(1)}`)
                 .join(' ');

    if (s.fill) {
      const base = opts.invertFill ? sy(yMax) : sy(Math.max(yMin, Math.min(0, yMax)));
      const gid = `g${idx}-${Math.random().toString(36).slice(2, 7)}`;
      const grad = svgEl('linearGradient',
        { id: gid, x1: 0, y1: 0, x2: 0, y2: 1, gradientUnits: 'objectBoundingBox' });
      const a = svgEl('stop', { offset: '0%',   'stop-color': s.color, 'stop-opacity': 0.34 });
      const b = svgEl('stop', { offset: '100%', 'stop-color': s.color, 'stop-opacity': 0.01 });
      grad.append(a, b);
      const defs = svgEl('defs');
      defs.appendChild(grad);
      svg.appendChild(defs);
      svg.appendChild(svgEl('path', {
        d: `${d} L${sx(pts[pts.length - 1].x).toFixed(1)},${base.toFixed(1)} ` +
           `L${sx(pts[0].x).toFixed(1)},${base.toFixed(1)} Z`,
        fill: `url(#${gid})`, stroke: 'none',
      }));
    }

    svg.appendChild(svgEl('path', {
      d, fill: 'none', stroke: s.color,
      'stroke-width': s.width || 1.9,
      'stroke-linecap': 'round', 'stroke-linejoin': 'round',
      ...(s.dashed ? { 'stroke-dasharray': '4 3' } : {}),
    }));

    // a dot on the newest point anchors the eye to "now"
    const last = pts[pts.length - 1];
    svg.appendChild(svgEl('circle', {
      cx: sx(last.x), cy: sy(last.y), r: 2.8, fill: s.color,
    }));
  });

  // crosshair + tooltip
  const cross = svgEl('line', {
    y1: PAD.t, y2: PAD.t + ih, stroke: 'rgba(255,255,255,0.28)',
    'stroke-width': 1, opacity: 0,
  });
  svg.appendChild(cross);

  const tip = el('div', 'tip');
  host.appendChild(svg);
  host.appendChild(tip);

  const primary = live[0].points.slice().sort((a, b) => a.x - b.x);

  const move = (ev) => {
    const box = host.getBoundingClientRect();
    const px = ((ev.clientX - box.left) / box.width) * W;
    if (px < PAD.l || px > W - PAD.r) return hide();

    const xVal = xMin + ((px - PAD.l) / iw) * (xMax - xMin);
    let best = primary[0], bd = Infinity;
    for (const p of primary) {
      const d = Math.abs(p.x - xVal);
      if (d < bd) { bd = d; best = p; }
    }

    cross.setAttribute('x1', sx(best.x));
    cross.setAttribute('x2', sx(best.x));
    cross.setAttribute('opacity', 1);

    tip.replaceChildren();
    tip.appendChild(el('div', 'tt', axisTime(best.x, span)));
    for (const s of live) {
      const near = s.points.reduce(
        (acc, p) => (Math.abs(p.x - best.x) < Math.abs(acc.x - best.x) ? p : acc),
        s.points[0]);
      const row = el('div', 'tr');
      const k = el('span', null, s.name);
      k.style.color = s.color;
      row.append(k, el('span', null, (opts.yFormat || shortNum)(near.y)));
      tip.appendChild(row);
    }

    tip.classList.add('on');
    const tw = tip.offsetWidth || 120;
    const relX = (sx(best.x) / W) * box.width;
    tip.style.left = `${Math.max(4, Math.min(box.width - tw - 4, relX + 12))}px`;
    tip.style.top = '8px';
  };

  const hide = () => {
    cross.setAttribute('opacity', 0);
    tip.classList.remove('on');
  };

  host.onpointermove = move;
  host.onpointerleave = hide;

  if (opts.legendHost) {
    const lg = opts.legendHost;
    lg.replaceChildren();
    for (const s of live) {
      const item = el('span', 'lg');
      const swatch = el('i');
      swatch.style.background = s.color;
      item.append(swatch, el('span', null, s.name));
      lg.appendChild(item);
    }
  }
}

/** Redraw on resize, debounced, so charts stay crisp when the window moves. */
export function autoRedraw(fn) {
  let t = null;
  const run = () => { clearTimeout(t); t = setTimeout(fn, 140); };
  window.addEventListener('resize', run);
  return () => window.removeEventListener('resize', run);
}

export const COLORS = {
  equity: '#5ee9f5',
  balance: '#a78bfa',
  profit: '#34d399',
  loss: '#fb7185',
  dd: '#fbbf24',
  realised: '#60a5fa',
};
