/* Shell: owns the state, wires the stream to the views, and drives the
   developer-mode dialog.

   Two update rates on purpose. The live state (positions, P&L, bot
   reasoning) arrives over SSE and repaints immediately. The series, closed
   trades and strategy scoreboard are heavier and only change on the sample
   interval, so they are pulled on a slower timer and whenever the range
   changes. */

import { api, connectStream } from './api.js';
import { COLORS, autoRedraw, lineChart } from './charts.js';
import { ago, dur, el, money, num } from './fmt.js';
import {
  renderBanners, renderBots, renderExposure, renderKpis, renderPortfolio,
  renderPositions, renderRoster, renderStrategyStats, renderTrades,
} from './views.js';

const $ = (id) => document.getElementById(id);

const ui = {
  brandSub: $('brandSub'), roster: $('roster'), banners: $('banners'),
  sourcePill: $('sourcePill'), liveDot: $('liveDot'),
  devBtn: $('devBtn'), devBtnLabel: $('devBtnLabel'),
  rangeSeg: $('rangeSeg'),
  kpis: $('kpis'),
  chartEquity: $('chartEquity'), legEquity: $('legEquity'),
  chartFloat: $('chartFloat'), legFloat: $('legFloat'),
  chartDd: $('chartDd'), legDd: $('legDd'),
  chartReal: $('chartReal'), legReal: $('legReal'),
  positions: $('positions'), posHint: $('posHint'),
  exposure: $('exposure'), stratStats: $('stratStats'),
  bots: $('bots'), botsHint: $('botsHint'),
  portfolioCard: $('portfolioCard'), portfolio: $('portfolio'),
  trades: $('trades'), tradesHint: $('tradesHint'),
  footInfo: $('footInfo'),
  devModal: $('devModal'), devForm: $('devForm'), devPin: $('devPin'),
  devErr: $('devErr'), devGo: $('devGo'), devCancel: $('devCancel'),
  devUnlocked: $('devUnlocked'), devClose: $('devClose'), devLock: $('devLock'),
  devSub: $('devSub'), devExpiry: $('devExpiry'),
};

const state = {
  st: null,          // last state document
  range: '24h',
  series: null,
  trades: [],
  stratStats: [],
  developer: false,
  streamUp: false,
  lastFrame: 0,
};

/* ──────────────────────────  live state  ────────────────────────── */
function applyState(st) {
  state.st = st;
  state.lastFrame = Date.now();

  const wasDev = state.developer;
  state.developer = !!st.developer;
  if (wasDev !== state.developer) {
    setDevButton(state.developer);
    // the heavier endpoints are shaped by mode too
    refreshSlow();
  }

  if (!st.ready) {
    ui.brandSub.textContent = 'waiting for the first poll…';
    return;
  }

  const a = st.account || {};
  ui.brandSub.textContent =
    [a.company, a.login ? `#${a.login}` : '', a.server].filter(Boolean).join(' · ')
    || 'connected';

  ui.sourcePill.textContent = st.source === 'mt5' ? 'LIVE' : 'DEMO';
  ui.sourcePill.className = 'pill ' + (st.source === 'mt5' ? 'live' : 'demo');

  renderBanners(ui.banners, st);
  renderRoster(ui.roster, st);
  renderKpis(ui.kpis, st);
  renderPositions(ui.positions, st);
  renderExposure(ui.exposure, st);
  renderBots(ui.bots, st);
  renderPortfolio(ui.portfolioCard, ui.portfolio, st);

  const t = st.totals || {};
  ui.posHint.textContent =
    `${t.count || 0} open · ${t.withOwnTp || 0} still on their own TP`;
  ui.botsHint.textContent = state.developer
    ? 'full reasoning visible'
    : 'decisions only — unlock developer mode for the reasoning';

  ui.footInfo.textContent =
    `source ${st.source} · frame ${st.version} · polled ${ago(st.serverTs)}`;
}

/* ──────────────────────────  charts  ────────────────────────── */
function drawCharts() {
  const s = state.series;
  const cur = (state.st?.account || {}).currency || '';
  const fmtMoney = (v) => money(v, cur);

  if (!s || !s.samples?.length) {
    lineChart(ui.chartEquity, [], { legendHost: ui.legEquity });
    lineChart(ui.chartFloat, [], { legendHost: ui.legFloat });
    lineChart(ui.chartDd, [], { legendHost: ui.legDd });
  } else {
    const pts = (key) => s.samples.map((r) => ({ x: r.ts, y: r[key] }));

    lineChart(ui.chartEquity, [
      { name: 'equity', color: COLORS.equity, points: pts('equity'), fill: true },
      { name: 'balance', color: COLORS.balance, points: pts('balance'), dashed: true,
        width: 1.5 },
    ], { legendHost: ui.legEquity, yFormat: fmtMoney, label: 'equity and balance' });

    const fl = pts('floating');
    const lastFl = fl.length ? fl[fl.length - 1].y : 0;
    lineChart(ui.chartFloat, [
      { name: 'floating', color: lastFl >= 0 ? COLORS.profit : COLORS.loss,
        points: fl, fill: true },
    ], { legendHost: ui.legFloat, yZero: true, yFormat: fmtMoney,
         label: 'floating profit and loss' });

    lineChart(ui.chartDd, [
      { name: 'drawdown', color: COLORS.dd, points: pts('drawdown'), fill: true },
    ], { legendHost: ui.legDd, yZero: true, yFormat: fmtMoney, label: 'drawdown' });
  }

  if (!s || !s.realised?.length) {
    lineChart(ui.chartReal, [], {
      legendHost: ui.legReal,
      emptyText: 'no closed trades in this window yet',
    });
  } else {
    const pts = s.realised.map((r) => ({ x: r.ts, y: r.cum }));
    const last = pts[pts.length - 1].y;
    lineChart(ui.chartReal, [
      { name: 'cumulative realised', color: last >= 0 ? COLORS.profit : COLORS.loss,
        points: pts, fill: true },
    ], { legendHost: ui.legReal, yZero: true, yFormat: fmtMoney,
         label: 'cumulative realised profit' });
  }
}

/* ─────────────────────  slower, heavier endpoints  ───────────────────── */
async function refreshSlow() {
  const range = state.range;
  try {
    const [series, trades, strats] = await Promise.all([
      api.series(range),
      api.trades(range, 80),
      api.strategies(range === '1h' || range === '6h' ? '30d' : range),
    ]);
    if (state.range !== range) return; // the user moved on while we waited
    state.series = series;
    state.trades = trades.trades || [];
    state.stratStats = strats.stats || [];

    drawCharts();
    renderTrades(ui.trades, state.trades);
    renderStrategyStats(ui.stratStats, state.stratStats);
    ui.tradesHint.textContent =
      `${state.trades.length} in the last ${range}`;
  } catch (err) {
    ui.tradesHint.textContent = 'could not load history: ' + err.message;
  }
}

/* ─────────────────────────  developer mode  ───────────────────────── */
function setDevButton(on) {
  ui.devBtn.classList.toggle('on', !!on);
  ui.devBtnLabel.textContent = on ? 'Developer ON' : 'Developer';
}

function openDevModal(session) {
  ui.devModal.hidden = false;
  ui.devErr.hidden = true;

  const dev = !!session?.developer;
  ui.devForm.hidden = dev;
  ui.devUnlocked.hidden = !dev;

  if (dev) {
    ui.devExpiry.textContent = session.expiresIn
      ? ` It re-locks itself in ${dur(session.expiresIn)}.` : '';
  } else {
    if (session && session.pinConfigured === false) {
      ui.devSub.textContent =
        'No PIN is configured. Set one with:  python run.py --set-pin <pin>';
      ui.devGo.disabled = true;
    } else {
      ui.devGo.disabled = false;
    }
    if (session?.lockedFor > 0) {
      showDevError(`Too many attempts. Try again in ${dur(session.lockedFor)}.`);
      ui.devGo.disabled = true;
    }
    setTimeout(() => ui.devPin.focus(), 40);
  }
}

function closeDevModal() {
  ui.devModal.hidden = true;
  ui.devPin.value = '';
  ui.devErr.hidden = true;
}

function showDevError(msg) {
  ui.devErr.textContent = msg;
  ui.devErr.hidden = false;
}

async function submitPin(ev) {
  ev.preventDefault();
  const pin = ui.devPin.value.trim();
  if (!pin) return;

  ui.devGo.disabled = true;
  const res = await api.unlock(pin);
  ui.devGo.disabled = false;

  if (res.ok && res.data.developer) {
    closeDevModal();
    state.developer = true;
    setDevButton(true);
    // repaint immediately with the fuller shape
    try { applyState(await api.state()); } catch { /* the stream will catch up */ }
    refreshSlow();
    return;
  }

  const d = res.data || {};
  if (d.retryAfter) {
    showDevError(`Too many attempts. Locked for ${dur(d.retryAfter)}.`);
    ui.devGo.disabled = true;
  } else if (d.attemptsLeft !== undefined) {
    showDevError(`Incorrect PIN. ${d.attemptsLeft} attempt(s) left before a lockout.`);
  } else {
    showDevError(d.error || 'Could not unlock.');
  }
  ui.devPin.value = '';
  ui.devPin.focus();
}

async function lockAgain() {
  await api.lock();
  state.developer = false;
  setDevButton(false);
  closeDevModal();
  try { applyState(await api.state()); } catch { /* ignore */ }
  refreshSlow();
}

/* ─────────────────────────────  wiring  ───────────────────────────── */
function wire() {
  ui.rangeSeg.addEventListener('click', (ev) => {
    const btn = ev.target.closest('button[data-range]');
    if (!btn) return;
    [...ui.rangeSeg.querySelectorAll('button')].forEach((b) =>
      b.classList.toggle('on', b === btn));
    state.range = btn.dataset.range;
    refreshSlow();
  });

  ui.devBtn.addEventListener('click', async () => {
    let session = null;
    try { session = await api.session(); } catch { /* offline */ }
    openDevModal(session);
  });

  ui.devForm.addEventListener('submit', submitPin);
  ui.devCancel.addEventListener('click', closeDevModal);
  ui.devClose.addEventListener('click', closeDevModal);
  ui.devLock.addEventListener('click', lockAgain);

  ui.devModal.addEventListener('click', (ev) => {
    if (ev.target === ui.devModal) closeDevModal();
  });
  document.addEventListener('keydown', (ev) => {
    if (ev.key === 'Escape' && !ui.devModal.hidden) closeDevModal();
  });

  autoRedraw(drawCharts);
}

function markStream(up) {
  state.streamUp = up;
  ui.liveDot.className = 'live ' + (up ? 'on' : 'off');
  ui.liveDot.querySelector('span').textContent = up ? 'live' : 'reconnecting';
}

async function boot() {
  wire();
  markStream(false);

  try {
    const session = await api.session();
    state.developer = !!session.developer;
    setDevButton(state.developer);
  } catch { /* the state document reports it too */ }

  try {
    applyState(await api.state());
  } catch (err) {
    ui.brandSub.textContent = 'backend unreachable';
    ui.banners.innerHTML =
      `<div class="banner err"><b>Cannot reach the backend.</b> ${err.message}</div>`;
  }

  await refreshSlow();

  connectStream({
    onState: applyState,
    onStatus: (s) => markStream(s === 'up'),
  });

  // heavier endpoints on a slow timer
  setInterval(refreshSlow, 30000);

  // if the stream goes quiet, fall back to polling so the page never freezes
  setInterval(async () => {
    if (Date.now() - state.lastFrame < 12000) return;
    try { applyState(await api.state()); } catch { /* ignore */ }
  }, 6000);
}

boot();
