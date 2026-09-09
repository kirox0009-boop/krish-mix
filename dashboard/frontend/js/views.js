/* Rendering. Each function owns one region of the page and is safe to call
   on every state frame - it rebuilds its own subtree and nothing else. */

import {
  ago, clear, cls, dateTime, dur, eaClass, el, lots, money, num, pct, price, signed,
} from './fmt.js';

/* ─────────────────────────────  KPI row  ───────────────────────────── */
export function renderKpis(host, st) {
  const a = st.account || {};
  const t = st.totals || {};
  const d = st.drawdown || {};
  const cur = a.currency || '';

  const cards = [
    { l: 'Equity', v: money(a.equity, cur), s: `balance ${money(a.balance, cur)}`,
      accent: 'var(--cyan)' },
    { l: 'Floating P&L', v: signed(t.profit, cur),
      s: `${t.count || 0} open · ${lots(t.lots)} lots`,
      accent: Number(t.profit) >= 0 ? 'var(--up)' : 'var(--down)',
      cls: cls(t.profit) },
    { l: 'Drawdown', v: money(d.current, cur),
      s: `${pct(d.currentPct)} from peak ${money(d.peakEquity, cur)}`,
      accent: 'var(--warn)', cls: Number(d.current) > 0 ? 'warn' : 'mut' },
    { l: 'Exposure', v: lots(t.lots),
      s: `${t.buyCount || 0} buy · ${t.sellCount || 0} sell`,
      accent: 'var(--violet)' },
    { l: 'Margin level', v: a.marginLevel ? pct(a.marginLevel, 0) : '—',
      s: `free ${money(a.freeMargin, cur)}`,
      accent: 'var(--info)',
      cls: a.marginLevel && a.marginLevel < 200 ? 'down'
         : a.marginLevel && a.marginLevel < 500 ? 'warn' : '' },
    { l: 'Symbols', v: String((t.symbols || []).length),
      s: (t.symbols || []).slice(0, 4).join(' ') || '—',
      accent: 'var(--cyan)' },
  ];

  clear(host);
  for (const c of cards) {
    const n = el('div', 'kpi');
    n.style.setProperty('--accent', c.accent);
    n.append(
      el('div', 'kpi-l', c.l),
      el('div', `kpi-v ${c.cls || ''}`.trim(), c.v),
      el('div', 'kpi-s', c.s),
    );
    host.appendChild(n);
  }
}

/* ────────────────────────────  live trades  ──────────────────────────── */
export function renderPositions(host, st) {
  const rows = st.positions || [];
  clear(host);

  if (!rows.length) {
    host.appendChild(el('div', 'empty', 'no open positions'));
    return;
  }

  const dev = !!st.developer;
  const cur = (st.account || {}).currency || '';
  const digitsFor = (sym) => {
    for (const k of Object.keys(st.telemetry || {})) {
      const d = st.telemetry[k]?.data;
      if (d && d.symbol === sym && d.market?.digits != null) return d.market.digits;
    }
    return 2;
  };

  const head = ['Symbol', 'Side', 'Lots', 'Strategy', 'EA', 'Open', 'Now', 'TP',
                'Age', 'P&L'];
  if (dev) head.push('Score @ entry', 'Regime @ entry');

  const table = el('table');
  const thead = el('thead');
  const hr = el('tr');
  head.forEach((h, i) => {
    const th = el('th', i >= 2 && i <= 2 || i >= 5 ? 'r' : '', h);
    if (['Lots', 'Open', 'Now', 'TP', 'Age', 'P&L', 'Score @ entry'].includes(h)) {
      th.className = 'r';
    }
    hr.appendChild(th);
  });
  thead.appendChild(hr);
  table.appendChild(thead);

  const tb = el('tbody');
  for (const p of rows) {
    const dg = digitsFor(p.symbol);
    const tr = el('tr');

    tr.appendChild(el('td', null, p.symbol));

    const sd = el('td');
    sd.appendChild(el('span', `side ${p.side === 'BUY' ? 'buy' : 'sell'}`, p.side));
    tr.appendChild(sd);

    tr.appendChild(el('td', 'r num', lots(p.volume)));

    const sc = el('td');
    const strat = el('span', 'tag', p.strategy || '—');
    strat.title = p.strategyLabel || '';
    sc.appendChild(strat);
    if (p.gridLevel) sc.appendChild(el('span', 'mut', ` L${p.gridLevel}`));
    if (p.recoveryLeg) sc.appendChild(el('span', 'mut', ` R${p.recoveryLeg}`));
    if (p.assistFor) sc.appendChild(el('span', 'mut', ` → ${p.assistFor}`));
    tr.appendChild(sc);

    const ea = el('td');
    ea.appendChild(el('span', eaClass(p.eaTag), p.eaTag || '?'));
    tr.appendChild(ea);

    tr.appendChild(el('td', 'r num mut', price(p.priceOpen, dg)));
    tr.appendChild(el('td', 'r num', price(p.priceCurrent, dg)));

    const tp = el('td', 'r num');
    if (p.tp) {
      tp.textContent = price(p.tp, dg);
      tp.classList.add('mut');
      tp.title = 'has its own take profit — EA4 leaves it alone until the grid opens';
    } else {
      tp.textContent = '—';
      tp.classList.add('mut');
    }
    tr.appendChild(tp);

    tr.appendChild(el('td', 'r num mut', dur(p.ageSeconds)));
    tr.appendChild(el('td', `r num ${cls(p.profit)}`, signed(p.profit, cur)));

    if (dev) {
      tr.appendChild(el('td', 'r num mut',
        p.scoreAtEntry != null ? num(p.scoreAtEntry, 0) : '—'));
      tr.appendChild(el('td', 'mut', p.regimeAtEntry || '—'));
    }

    tb.appendChild(tr);
  }
  table.appendChild(tb);
  host.appendChild(table);
}

/* ──────────────────────  open exposure by strategy  ────────────────────── */
export function renderExposure(host, st) {
  const rows = st.strategies || [];
  clear(host);

  if (!rows.length) {
    host.appendChild(el('div', 'empty', 'nothing open'));
    return;
  }

  const cur = (st.account || {}).currency || '';
  const maxLots = Math.max(...rows.map((r) => r.lots)) || 1;
  const box = el('div', 'exp');

  for (const r of rows) {
    const row = el('div', 'exp-row');

    const name = el('div', 'exp-name');
    name.appendChild(el('span', 'tag', r.strategy));
    name.title = r.strategyLabel || r.strategy;
    row.appendChild(name);

    const bar = el('div', 'exp-bar');
    bar.title = `${r.buy} buy · ${r.sell} sell · ${r.symbols.join(' ')}`;
    const total = r.buy + r.sell || 1;
    const width = (r.lots / maxLots) * 100;
    const b = el('div', 'exp-buy');
    b.style.width = `${(width * r.buy) / total}%`;
    const s = el('div', 'exp-sell');
    s.style.width = `${(width * r.sell) / total}%`;
    bar.append(b, s);
    row.appendChild(bar);

    const meta = el('div', 'exp-meta');
    meta.append(
      el('span', null, `${lots(r.lots)} lot `),
      el('span', cls(r.profit), signed(r.profit, cur)),
    );
    row.appendChild(meta);

    box.appendChild(row);
  }
  host.appendChild(box);
}

/* ─────────────────────  realised strategy scoreboard  ───────────────────── */
export function renderStrategyStats(host, stats) {
  clear(host);
  if (!stats || !stats.length) {
    host.appendChild(el('div', 'empty', 'no closed trades in this window yet'));
    return;
  }

  const table = el('table');
  const thead = el('thead');
  const hr = el('tr');
  for (const [h, r] of [['Strategy', 0], ['EA', 0], ['Trades', 1], ['Win %', 1],
                        ['Net', 1], ['Avg', 1], ['Best', 1], ['Worst', 1]]) {
    hr.appendChild(el('th', r ? 'r' : '', h));
  }
  thead.appendChild(hr);
  table.appendChild(thead);

  const tb = el('tbody');
  for (const s of stats) {
    const tr = el('tr');
    const nc = el('td');
    nc.appendChild(el('span', 'tag', s.strategy));
    tr.appendChild(nc);
    const ec = el('td');
    ec.appendChild(el('span', eaClass(s.eaTag), s.eaTag || '?'));
    tr.appendChild(ec);
    tr.appendChild(el('td', 'r num', s.trades));
    tr.appendChild(el('td', `r num ${s.winRate >= 50 ? 'up' : 'mut'}`, pct(s.winRate, 0)));
    tr.appendChild(el('td', `r num ${cls(s.net)}`, signed(s.net)));
    tr.appendChild(el('td', `r num ${cls(s.avgNet)}`, signed(s.avgNet)));
    tr.appendChild(el('td', 'r num up', signed(s.best)));
    tr.appendChild(el('td', 'r num down', signed(s.worst)));
    tb.appendChild(tr);
  }
  table.appendChild(tb);
  host.appendChild(table);
}

/* ─────────────────────────────  bot cards  ───────────────────────────── */
const LOCK_SVG = `<svg viewBox="0 0 24 24" class="ico" aria-hidden="true">
  <path d="M17 10V8a5 5 0 0 0-10 0v2" fill="none" stroke="currentColor" stroke-width="2"/>
  <rect x="4.5" y="10" width="15" height="10.5" rx="2.5" fill="none"
        stroke="currentColor" stroke-width="2"/></svg>`;

function botRow(k, v) {
  const r = el('div', 'br');
  r.append(el('span', 'k', k), el('span', 'v', v));
  return r;
}

function lockedNote(text) {
  const n = el('div', 'locked');
  n.innerHTML = LOCK_SVG;
  n.appendChild(el('span', null, text));
  return n;
}

export function renderBots(host, st) {
  const tel = st.telemetry || {};
  const keys = Object.keys(tel).sort();
  clear(host);

  if (!keys.length) {
    host.appendChild(el('div', 'empty',
      'no telemetry yet — check that InpTelemetry is on in the EAs, ' +
      'and that they have written a snapshot'));
    return;
  }

  const dev = !!st.developer;

  for (const key of keys) {
    const snap = tel[key] || {};
    const d = snap.data || {};
    const card = el('div', 'bot');

    const h = el('div', 'bot-h');
    const dot = el('span', 'dot ' + (snap.stale ? 'stale' : 'on'));
    h.appendChild(dot);
    h.appendChild(el('span', eaClass(snap.ea), snap.ea));
    h.appendChild(el('span', 'who', botTitle(snap.ea)));
    h.appendChild(el('span', 'sym', snap.symbol));
    card.appendChild(h);

    const rows = el('div', 'bot-rows');
    rows.appendChild(botRow('feed',
      snap.stale ? `stale, ${Math.round(snap.ageSeconds)}s old` : `fresh (${Math.round(snap.ageSeconds)}s)`));

    if (snap.error) rows.appendChild(botRow('issue', snap.error));

    switch (snap.ea) {
      case 'KM1': botKm1(rows, d, dev); break;
      case 'KM2': botKm2(rows, d, dev); break;
      case 'KM3': botKm3(rows, d, dev); break;
      case 'KM4': botKm4(rows, d, dev); break;
      case 'KM5': botKm5(rows, d, dev); break;
      case 'KM6': botKm6(rows, d, dev); break;
      default: break;
    }
    card.appendChild(rows);

    // the reasoning block is the part developer mode unlocks
    if (snap.ea === 'KM1') {
      const nar = d.playbook?.narrative;
      if (dev && nar) {
        card.appendChild(el('div', 'bot-note', nar));
      } else if (!dev) {
        card.appendChild(lockedNote('reasoning hidden — unlock developer mode'));
      }
    }
    if (snap.ea === 'KM2' && !dev) {
      card.appendChild(lockedNote('grid workings hidden'));
    }
    if (snap.ea === 'KM2' && dev) {
      const lines = (d.sides || [])
        .map((s) => `${s.side}: ${s.plan?.reason || '-'}`)
        .join('\n');
      if (lines) card.appendChild(el('div', 'bot-note', lines));
    }
    if (snap.ea === 'KM3' && dev && d.plan?.reason) {
      card.appendChild(el('div', 'bot-note', d.plan.reason));
    }
    if (snap.ea === 'KM4' && dev) {
      const lines = (d.groups || [])
        .filter((g) => g.workings)
        .map((g) => `${g.name}: ${g.workings}`)
        .join('\n');
      if (lines) card.appendChild(el('div', 'bot-note', lines));
    }
    if (snap.ea === 'KM5' && dev && d.assist?.status) {
      card.appendChild(el('div', 'bot-note', 'assist: ' + d.assist.status));
    }

    host.appendChild(card);
  }
}

const botTitle = (ea) => ({
  KM1: 'Entry', KM2: 'Grid', KM3: 'Recovery',
  KM4: 'Basket exit', KM5: 'Portfolio', KM6: 'Timeframe',
}[ea] || ea);

function botKm1(rows, d, dev) {
  const v = d.view || {};
  const g = d.gate || {};
  rows.appendChild(botRow('regime', `${v.regime || '—'} · vol ${v.vol || '—'}`));
  rows.appendChild(botRow('last fired', g.lastTrigger || '—'));
  rows.appendChild(botRow('entries', String(g.entries ?? '—')));

  const entered = (d.layers || []).filter((l) => l.entered > 0)
    .map((l) => `${l.name} ${l.entered}`).join(', ');
  rows.appendChild(botRow('by layer', entered || 'none yet'));

  if (dev) {
    rows.appendChild(botRow('score', `${num(v.score, 1)} (best ${num(g.scoreBest, 1)})`));
    rows.appendChild(botRow('adx', `${num(v.adx, 1)} / floor ${num(g.floors?.minAdx, 0)}`));
    rows.appendChild(botRow('rsi · stoch', `${num(v.rsi, 1)} · ${num(v.stoch, 1)}`));
    rows.appendChild(botRow('mtf', v.mtfAgree ? 'agree' : 'split'));
    const top = (g.blocks || [])[0];
    if (top) rows.appendChild(botRow('main block', `${top.name} (${top.count})`));
    const pb = d.playbook || {};
    if (pb.edge) {
      rows.appendChild(botRow('edge',
        `${pb.edge} ${pb.dir || ''} · conf ${num(pb.confidence, 0)} · ${pb.confluences} legs`));
    }
    const tr = d.structure?.trend;
    if (tr) {
      rows.appendChild(botRow('trend',
        `${tr.dir} mat ${num(tr.maturity, 0)} · ${tr.legs} legs` +
        `${tr.isFresh ? ' · FRESH' : ''}${tr.nearCorner ? ' · CORNER' : ''}`));
    }
  } else {
    const pb = d.playbook || {};
    if (pb.dir) rows.appendChild(botRow('playbook', pb.dir));
  }
}

function botKm2(rows, d, dev) {
  for (const s of d.sides || []) {
    const b = s.basket || {};
    const p = s.plan || {};
    rows.appendChild(botRow(s.side.toLowerCase(),
      `${b.legs || 0} legs · ${lots(b.lots)} lot · ${signed(b.profit)}`));
    if (dev) {
      rows.appendChild(botRow(' ',
        `next L${p.level} · needs ${num(p.needed, 2)} has ${num(p.travelled, 2)} · ` +
        `press ${num(p.pressure, 0)}${p.exhausted ? ' · EXH' : ''}`));
    } else if (b.legs) {
      rows.appendChild(botRow(' ', p.wouldAdd ? 'ready to add' : 'holding back'));
    }
  }
}

function botKm3(rows, d, dev) {
  const p = d.plan || {};
  const r = d.recoveryLegs || {};
  rows.appendChild(botRow('under water', p.losingSide || 'none'));
  rows.appendChild(botRow('drawdown', money(p.drawdown)));
  rows.appendChild(botRow('rescue legs',
    `${(r.buyCount || 0) + (r.sellCount || 0)} · ${lots((r.buyLots || 0) + (r.sellLots || 0))} lot`));
  rows.appendChild(botRow('armed', p.wouldFire ? 'yes' : 'no'));
  if (dev) {
    rows.appendChild(botRow('sizing',
      `lock ${lots(p.lockLot)} + recover ${lots(p.recoveryLot)} = ${lots(p.lot)}`));
  }
}

function botKm4(rows, d, dev) {
  for (const g of d.groups || []) {
    if (!g.legs) continue;
    let txt = `${g.legs} legs · ${signed(g.profit)} / target ${money(g.target)}`;
    if (g.ridingOwnTp) txt = `${g.legs} leg riding its own TP`;
    rows.appendChild(botRow(g.name.toLowerCase(), txt));
  }
  rows.appendChild(botRow('closes', String(d.history?.closes ?? '—')));
  if (d.history?.lastAction) rows.appendChild(botRow('last', d.history.lastAction));
}

function botKm5(rows, d, dev) {
  const p = d.portfolio || {};
  rows.appendChild(botRow('book',
    `${p.legs || 0} legs · ${lots(p.lots)} lot · ${signed(p.profit)}`));
  rows.appendChild(botRow('target', money(p.target)));
  if (p.stuck?.symbol) {
    rows.appendChild(botRow('stuck', `${p.stuck.symbol} ${money(-p.stuck.drawdown)}`));
  }
  rows.appendChild(botRow('assists', String(d.assist?.count ?? 0)));
  if (dev && d.assist) {
    rows.appendChild(botRow('trigger',
      `dd ${money(d.assist.triggerDd)} · horizon ${num(d.assist.horizonAtr, 1)} atr`));
  }
}

function botKm6(rows, d, dev) {
  for (const s of (d.symbols || []).slice(0, 8)) {
    let txt = `${s.style || '—'} ${s.timeframe ? s.timeframe.replace('PERIOD_', '') : ''}`;
    if (dev && s.spreadCost != null) {
      txt += ` · spread ${num(s.spreadCost, 2)}atr`;
    }
    rows.appendChild(botRow(s.symbol, txt));
  }
}

/* ─────────────────────────────  portfolio  ───────────────────────────── */
export function renderPortfolio(card, host, st) {
  const km5 = Object.values(st.telemetry || {}).find((s) => s.ea === 'KM5');
  if (!km5 || !(km5.data?.symbols || []).length) {
    card.hidden = true;
    return;
  }
  card.hidden = false;

  const dev = !!st.developer;
  const syms = km5.data.symbols;
  clear(host);

  const table = el('table');
  const thead = el('thead');
  const hr = el('tr');
  const cols = [['Symbol', 0], ['Legs', 1], ['Buy/Sell', 1], ['Lots', 1],
                ['P&L', 1], ['Drawdown', 1], ['State', 0], ['Regime', 0]];
  if (dev) cols.push(['Score', 1]);
  for (const [h, r] of cols) hr.appendChild(el('th', r ? 'r' : '', h));
  thead.appendChild(hr);
  table.appendChild(thead);

  const tb = el('tbody');
  for (const s of syms) {
    const tr = el('tr');

    const nm = el('td');
    nm.appendChild(el('span', null, s.symbol));
    if (s.isStuck) {
      const w = el('span', 'tag km3', 'STUCK');
      w.style.marginLeft = '6px';
      nm.appendChild(w);
    }
    if (!s.tradable) {
      const w = el('span', 'tag', 'ext');
      w.title = 'holding suite positions but not in the watchlist';
      w.style.marginLeft = '6px';
      nm.appendChild(w);
    }
    tr.appendChild(nm);

    tr.appendChild(el('td', 'r num', s.legs || 0));
    tr.appendChild(el('td', 'r num mut', `${s.buyLegs || 0}/${s.sellLegs || 0}`));
    tr.appendChild(el('td', 'r num', lots(s.lots)));
    tr.appendChild(el('td', `r num ${cls(s.profit)}`, signed(s.profit)));
    tr.appendChild(el('td', `r num ${s.drawdown > 0 ? 'warn' : 'mut'}`,
      s.drawdown ? money(s.drawdown) : '—'));

    const state = el('td');
    const flags = [];
    if (s.gridOpen) flags.push('grid');
    if (s.hedgeOpen) flags.push('hedge');
    if (s.assistLegs) flags.push(`assist ${s.assistLegs}`);
    if (s.suiteEa1Live) flags.push('EA1');
    state.appendChild(el('span', 'mut', flags.join(' · ') || '—'));
    tr.appendChild(state);

    tr.appendChild(el('td', 'mut', s.view?.regime || '—'));
    if (dev) {
      tr.appendChild(el('td', 'r num mut',
        s.view?.score != null ? num(s.view.score, 0) : '—'));
    }
    tb.appendChild(tr);
  }
  table.appendChild(tb);
  host.appendChild(table);
}

/* ────────────────────────────  closed trades  ──────────────────────────── */
export function renderTrades(host, trades) {
  clear(host);
  if (!trades || !trades.length) {
    host.appendChild(el('div', 'empty', 'no closed trades in this window'));
    return;
  }

  const table = el('table');
  const thead = el('thead');
  const hr = el('tr');
  for (const [h, r] of [['When', 0], ['Symbol', 0], ['Side', 0], ['Strategy', 0],
                        ['EA', 0], ['Lots', 1], ['Price', 1], ['Net', 1]]) {
    hr.appendChild(el('th', r ? 'r' : '', h));
  }
  thead.appendChild(hr);
  table.appendChild(thead);

  const tb = el('tbody');
  for (const t of trades) {
    const tr = el('tr');
    tr.appendChild(el('td', 'mut num', dateTime(t.ts)));
    tr.appendChild(el('td', null, t.symbol));
    const sd = el('td');
    sd.appendChild(el('span', `side ${t.side === 'BUY' ? 'buy' : 'sell'}`, t.side || '—'));
    tr.appendChild(sd);
    const st = el('td');
    st.appendChild(el('span', 'tag', t.strategy || '—'));
    tr.appendChild(st);
    const ea = el('td');
    ea.appendChild(el('span', eaClass(t.eaTag), t.eaTag || '?'));
    tr.appendChild(ea);
    tr.appendChild(el('td', 'r num', lots(t.volume)));
    tr.appendChild(el('td', 'r num mut', num(t.price, 2)));
    tr.appendChild(el('td', `r num ${cls(t.net)}`, signed(t.net)));
    tb.appendChild(tr);
  }
  table.appendChild(tb);
  host.appendChild(table);
}

/* ──────────────────────────────  roster  ────────────────────────────── */
export function renderRoster(host, st) {
  const tel = st.telemetry || {};
  // any document carries a roster; prefer a fresh one
  let roster = null;
  for (const s of Object.values(tel)) {
    if (s.data?.roster?.length) { roster = s.data.roster; if (!s.stale) break; }
  }
  clear(host);
  if (!roster) return;

  for (const r of roster) {
    const p = el('span', 'rp' + (r.alive ? ' on' : ''), r.name.replace(/^E\d-/, ''));
    p.title = `${r.name} — ${r.alive ? 'heartbeat fresh' : 'not running on this symbol'}`;
    host.appendChild(p);
  }
}

/* ─────────────────────────────  banners  ───────────────────────────── */
export function renderBanners(host, st) {
  clear(host);
  const add = (kind, html) => {
    const b = el('div', `banner ${kind}`);
    b.innerHTML = html;
    host.appendChild(b);
  };

  if (st.source === 'demo') {
    add('warn',
      '<b>Demo data.</b> No MetaTrader terminal was reachable, so this is a ' +
      'synthetic book. Numbers here are not real.');
  }

  const th = st.telemetryHealth || {};
  if (th.files === 0) {
    const p = th.directory?.path || '(folder not located)';
    add('info',
      '<b>No telemetry files yet.</b> The bot panels stay empty until an EA ' +
      `writes a snapshot. Looking in <code>${p}</code>.`);
  } else if (th.stale > 0) {
    add('warn',
      `<b>${th.stale} of ${th.files} telemetry feeds are stale.</b> ` +
      'That usually means an EA was removed from its chart.');
  }

  const term = st.terminal || {};
  if (st.source === 'mt5' && term.connected === false) {
    add('err', '<b>Terminal is offline.</b> MT5 reports no connection to the broker.');
  }
  if (st.source === 'mt5' && term.tradeAllowed === false) {
    add('warn', '<b>Algo trading is disabled</b> in the terminal, so the EAs cannot trade.');
  }
}
