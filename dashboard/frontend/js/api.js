/* Talking to the backend.

   State arrives two ways: an SSE stream that pushes a document whenever
   the poller publishes one, and a plain fetch used for the first paint and
   as a fallback if the stream drops. The series, trades and strategy
   endpoints are pulled on demand because they are heavier and only change
   on the sample interval. */

async function jget(path) {
  const r = await fetch(path, { credentials: 'same-origin' });
  if (!r.ok) {
    let detail = '';
    try { detail = (await r.json()).error || ''; } catch { /* ignore */ }
    throw new Error(`${r.status} ${detail}`.trim());
  }
  return r.json();
}

async function jpost(path, body) {
  const r = await fetch(path, {
    method: 'POST',
    credentials: 'same-origin',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body || {}),
  });
  let data = {};
  try { data = await r.json(); } catch { /* ignore */ }
  return { ok: r.ok, status: r.status, data };
}

export const api = {
  state:      () => jget('/api/state'),
  session:    () => jget('/api/session'),
  health:     () => jget('/api/health'),
  series:     (range) => jget(`/api/series?range=${encodeURIComponent(range)}`),
  trades:     (range, limit = 80) =>
                jget(`/api/trades?range=${encodeURIComponent(range)}&limit=${limit}`),
  strategies: (range) => jget(`/api/strategies?range=${encodeURIComponent(range)}`),

  unlock: (pin) => jpost('/api/unlock', { pin }),
  lock:   ()    => jpost('/api/lock', {}),
};

/** SSE with automatic reconnect and a status callback. */
export function connectStream({ onState, onStatus }) {
  let es = null;
  let retry = 1000;
  let closed = false;

  const open = () => {
    if (closed) return;
    try {
      es = new EventSource('/api/events');
    } catch (err) {
      onStatus?.('down', String(err));
      setTimeout(open, retry);
      return;
    }

    es.addEventListener('open', () => {
      retry = 1000;
      onStatus?.('up');
    });

    es.addEventListener('state', (ev) => {
      try {
        onState?.(JSON.parse(ev.data));
        onStatus?.('up');
      } catch (err) {
        onStatus?.('down', 'bad frame: ' + err);
      }
    });

    es.addEventListener('error', () => {
      // EventSource retries on its own, but only for some failures, so
      // take over explicitly with a capped backoff
      onStatus?.('down');
      try { es.close(); } catch { /* ignore */ }
      if (closed) return;
      setTimeout(open, retry);
      retry = Math.min(retry * 2, 15000);
    });
  };

  open();

  return {
    close() {
      closed = true;
      try { es?.close(); } catch { /* ignore */ }
    },
  };
}
