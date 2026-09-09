/* Formatting helpers. Kept in one place so money, lots and ages read the
   same everywhere. */

export const el = (tag, cls, text) => {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (text !== undefined && text !== null) n.textContent = String(text);
  return n;
};

export function clear(node) {
  while (node.firstChild) node.removeChild(node.firstChild);
  return node;
}

/** Signed money, always two decimals. */
export function money(v, cur = '') {
  if (v === null || v === undefined || Number.isNaN(v)) return '—';
  const n = Number(v);
  const s = n < 0 ? '-' : '';
  const body = Math.abs(n).toLocaleString(undefined, {
    minimumFractionDigits: 2, maximumFractionDigits: 2,
  });
  return `${s}${cur ? cur + ' ' : ''}${body}`;
}

/** Money with an explicit + so a gain is unmistakable at a glance. */
export function signed(v, cur = '') {
  if (v === null || v === undefined || Number.isNaN(v)) return '—';
  const n = Number(v);
  return (n > 0 ? '+' : '') + money(n, cur);
}

export function num(v, dp = 2) {
  if (v === null || v === undefined || Number.isNaN(v)) return '—';
  return Number(v).toFixed(dp);
}

export function pct(v, dp = 2) {
  if (v === null || v === undefined || Number.isNaN(v)) return '—';
  return `${Number(v).toFixed(dp)}%`;
}

export function lots(v) {
  if (v === null || v === undefined) return '—';
  return Number(v).toFixed(2);
}

/** Price at the instrument's own precision. */
export function price(v, digits = 2) {
  if (v === null || v === undefined || Number.isNaN(v)) return '—';
  return Number(v).toFixed(Math.max(0, Math.min(8, digits)));
}

/** Compact duration: 4d 3h / 3h 12m / 12m 04s / 42s */
export function dur(seconds) {
  const s = Math.max(0, Math.floor(Number(seconds) || 0));
  const d = Math.floor(s / 86400);
  const h = Math.floor((s % 86400) / 3600);
  const m = Math.floor((s % 3600) / 60);
  const ss = s % 60;
  if (d) return `${d}d ${h}h`;
  if (h) return `${h}h ${String(m).padStart(2, '0')}m`;
  if (m) return `${m}m ${String(ss).padStart(2, '0')}s`;
  return `${ss}s`;
}

export function ago(ts) {
  if (!ts) return '—';
  return dur(Date.now() / 1000 - Number(ts)) + ' ago';
}

export function clockTime(ts) {
  if (!ts) return '—';
  const d = new Date(Number(ts) * 1000);
  return d.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' });
}

export function dateTime(ts) {
  if (!ts) return '—';
  const d = new Date(Number(ts) * 1000);
  return d.toLocaleString(undefined, {
    month: 'short', day: '2-digit', hour: '2-digit', minute: '2-digit',
  });
}

/** Axis label density depends on the span, so pick a sensible format. */
export function axisTime(ts, spanSeconds) {
  const d = new Date(Number(ts) * 1000);
  if (spanSeconds > 4 * 86400) {
    return d.toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
  }
  if (spanSeconds > 36 * 3600) {
    return d.toLocaleString(undefined, { weekday: 'short', hour: '2-digit' });
  }
  return d.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' });
}

export const cls = (v) => (Number(v) > 0 ? 'up' : Number(v) < 0 ? 'down' : 'mut');

export const eaClass = (tag) => 'tag ' + String(tag || '').toLowerCase();
