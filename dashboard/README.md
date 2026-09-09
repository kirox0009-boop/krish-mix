# KrishMix Dashboard

Live web dashboard for the KrishMix suite. Dikhata hai **kaun trade chal raha hai, kis order pe kaun si strategy hai, bot ne kya socha**, aur equity / floating P&L / drawdown / realised P&L ke graphs.

**Do dependencies ke alawa kuch nahi:** Python 3.9+ (stdlib only) aur `MetaTrader5` pip package. Koi npm nahi, koi build step nahi, koi CDN nahi.

---

## Do minute me chalu

```bash
cd dashboard
pip install MetaTrader5          # sirf Windows, aur usi machine pe jahan terminal chal raha hai
python run.py
```

Terminal pe pehli baar aisa print hoga:

```
  KrishMix Dashboard
  ------------------

  DEVELOPER MODE PIN (shown once, write it down):
      418736
  Change it any time with:  python run.py --set-pin <newpin>

  data source     : mt5
  telemetry folder: C:\Users\you\AppData\Roaming\MetaQuotes\Terminal\<id>\MQL5\Files\KrishMix\telemetry
  database        : C:\...\dashboard\krishmix_dashboard.sqlite3
  dashboard       : http://127.0.0.1:8734/

  Ctrl+C to stop
```

**PIN sirf ek baar dikhta hai** — likh lein. Uske baad sirf uska hash store hota hai.

Browser me `http://127.0.0.1:8734` kholein.

**Bina MT5 ke dekhna hai?** `python run.py --demo` — synthetic 6-symbol book banata hai jo suite ki tarah behave karta hai (KM1 entries, KM2 grid legs, KM3 recovery, KM5 assists), Linux/Mac pe bhi chalta hai. UI ka feel dekhne ke liye.

---

## Kaam kaise karta hai

```
  MT5 terminal (Windows)
  │
  ├─ 6 EAs ──► MQL5\Files\KrishMix\telemetry\*.json     ← reasoning (Telemetry.mqh)
  │            KM1_XAUUSD.json  KM2_XAUUSD.json ...
  │            KM5_PORTFOLIO.json  KM6_PORTFOLIO.json
  │
  └─ MetaTrader5 python package ──► account, positions, deal history
                                     │
                              backend/poller.py  (2s loop)
                                     │
                       ┌─────────────┴─────────────┐
                       │                           │
              SQLite time series          backend/redact.py
              (equity, DD, closed)        NORMAL ya DEVELOPER
                       │                           │
                       └─────────────┬─────────────┘
                                     │
                            backend/server.py  (stdlib HTTP + SSE)
                                     │
                            frontend/  vanilla ES modules + SVG charts
```

Do data sources hain, kyunki koi ek akela kaafi nahi:

| Source | Kya deta hai | Kyun |
|---|---|---|
| `MetaTrader5` package | account, open positions, closed deals | asli sach — paisa aur orders |
| EA JSON snapshots | score, indicators, plan, thresholds, narrative | package ke paas EA ki **soch** nahi hoti, aur global variables bhi read nahi kar sakta |

Telemetry folder khud dhoonda jaata hai (`mt5.terminal_info().data_path`) — **koi path configure nahi karna**.

### Kis order pe kaun si strategy — yeh pehle se hi kaam karta hai

Suite ka `CKMExec.Open` har order ka comment aise likhta hai, to backend ko sirf parse karna hai:

```
KM1|PLAYBOOK|s62|TREND-UP     EA1: kaun sa trigger, entry pe score, entry pe regime
KM1|INSIDEBAR|s41|RANGE
KM2|L3|exh|p42                EA2: grid level 3, exhaustion, pressure 42
KM3|R1|dd450|s-68             EA3: recovery leg 1, $450 drawdown pe
KM5|ASSIST|XAUUSD|s61         EA5: gold ko bachane ke liye doosre asset pe assist
```

Plus `magic = base + eaSlot*10 + (buy?1:2)` se EA aur direction pakka pata chalta hai. Agar broker comment kaat de, to magic se fallback hota hai — attribution kabhi blank nahi hota.

---

## Normal mode vs Developer mode

Yeh wahi cheez hai jo aapne maangi thi: **normal mode me sensitive kuch nahi**, aur PIN daal ke sab transparent.

Split jaan-boojh ke **"kya kiya" vs "kaise decide kiya"** pe khinchi gayi hai:

| | Normal mode | Developer mode |
|---|---|---|
| Account, equity, floating P&L, drawdown | ✅ | ✅ |
| Equity / floating / DD / realised graphs | ✅ | ✅ |
| Live trades — symbol, side, lot, price, TP, P&L | ✅ | ✅ |
| **Kis order pe kaun si strategy** (`PLAYBOOK`, `INSIDEBAR`, `GRID`, `RECOVERY`, `ASSIST`) | ✅ | ✅ |
| Kaun se EA zinda hain (roster / heartbeat) | ✅ | ✅ |
| Per-symbol portfolio, kaun asset phansa hai | ✅ | ✅ |
| Closed trades + per-strategy realised scoreboard | ✅ | ✅ |
| Entry ke waqt ka **score** | ❌ | ✅ |
| Composite score, ADX/RSI/Stoch/MACD/BB values, DI | ❌ | ✅ |
| Kitne layers qualify hue, kitne enter hue | ❌ | ✅ |
| Block histogram ("entry kyun nahi hui") | ❌ | ✅ |
| Saare thresholds / floors / poora config | ❌ | ✅ |
| Grid aur hedge ka sizing working | ❌ | ✅ |
| Playbook narrative (poora, jaisa hai) | ❌ | ✅ |
| Fib levels, trend maturity, VWAP bands | ❌ | ✅ |
| KM6 ke scalp/intraday/swing scores | ❌ | ✅ |

Kandhe ke peeche se dekhne wala bas itna dekh payega ki account up hai aur ek inside-bar short chal raha hai. Kitne indicators buy bol rahe hain, score kya hai, threshold kahan hai — **kuch nahi**.

### Yeh secure kaise hai

- **EAs sab kuch export karte hain, redaction backend me hoti hai** — auth ke bilkul paas, ek jagah ([`redact.py`](backend/redact.py)). Agar MQL5 me hi chhipa dete to developer mode ke paas dikhane ke liye kuch bachta hi nahi.
- **Allow-list, deny-list nahi.** Har EA ke liye `SPEC_KM1..SPEC_KM6` me jo field explicitly clear ki gayi hai wahi normal mode me jaati hai. Kal koi naya telemetry field add karega to woh **default se hidden** hoga, leak nahi hoga.
- **`self_check()`** proof karta hai ki koi bhi allow-list `FORBIDDEN_IN_NORMAL` ka key nahi chhoo sakti. Fail hone pe server **start hi nahi hota**.
- **PIN plaintext me kahin nahi.** Sirf salted `pbkdf2_hmac-sha256`, 240,000 iterations. Compare constant-time.
- **Token HttpOnly + SameSite=Strict cookie** me hai, to page ke scripts use kabhi hold nahi karte. UI `/api/session` se poochta hai ki developer mode on hai ya nahi.
- **Rate limit:** 5 galat attempts / 5 min → 15 min lockout (`429` + `retryAfter`). PIN chhota hota hai, isliye yeh optional nahi hai.
- **Sessions memory me hain** — backend restart hone pe sab dobara lock.
- **Dashboard read-only hai.** Order place / modify / close ka **koi endpoint nahi hai**, kahin bhi.

### PIN manage karna

```bash
python run.py --set-pin 918273     # PIN set ya badalna, phir exit
```

UI me: top-right ka **Developer** button → PIN → Unlock. Session 60 min baad khud lock (`session_minutes`). **Lock again** turant lock kar deta hai.

Kisi ko access dena hai to bas PIN de dein — koi user account system nahi hai. Sirf ek hi PIN hai, to jise diya usse wapas lene ka matlab hai PIN badalna.

> **Honest security note:** PIN plain HTTP pe weak hai — network pe sniff ho sakta hai. Default `127.0.0.1` isliye hai. Bahar se dekhna hai to `--host 0.0.0.0` ke bharose na rahein; **SSH tunnel** (`ssh -L 8734:127.0.0.1:8734 user@vps`) ya TLS reverse proxy (Caddy/nginx) use karein. `--host` loopback se bahar hone pe server warning print karta hai.

---

## UI me kya hai

- **Top bar** — roster (kaun se 6 EA zinda hain), range switch (1H/6H/24H/7D/30D), source pill (live terminal ya demo), live-stream dot, Developer button
- **KPI row** — Equity (balance ke saath), Floating P&L, Drawdown (peak se %), Exposure (lots, buy/sell), Margin level, Symbols
- **4 charts** — equity vs balance, floating P&L, drawdown, realised P&L curve. Sab hand-drawn SVG, koi chart library nahi
- **Live trades** — har row pe strategy badge, side, lot, entry, current, TP, age, P&L
- **Open exposure by strategy** — abhi kaun si strategy kitna load utha rahi hai
- **Realised by strategy** — closed-trade scoreboard (trades, win rate, net, best, worst)
- **Bots** — per-EA card, jo har EA ne apni telemetry me bheja hai
- **Portfolio** — EA5 ka cross-asset view; kaun asset phansa hai, kahan assist chal raha hai (KM5 attach na ho to hidden)
- **Closed trades** — recent deals with attribution
- Updates **SSE** se aate hain (`/api/events`), polling se nahi. Stream toote to UI khud fallback poll karta hai.

---

## Options

```bash
python run.py                        # live agar terminal mila, warna demo
python run.py --demo                 # synthetic book force
python run.py --set-pin 918273       # PIN set karke exit
python run.py --host 0.0.0.0         # loopback se bahar (warning padhein)
python run.py --port 9000
python run.py --magic-base 51000     # EAs ke InpMagicBase se match hona chahiye
python run.py --telemetry-dir "D:\...\MQL5\Files\KrishMix\telemetry"
python run.py --config C:\path\config.json
```

Pehli run pe `config.json` ban jaata hai (gitignored). Kaam ke keys:

| Key | Default | Kya |
|---|---|---|
| `host` / `port` | `127.0.0.1` / `8734` | bind |
| `magic_base` | `51000` | **EAs se match hona zaroori** |
| `poll_seconds` | `2` | terminal kitni jaldi padha jaaye |
| `sample_seconds` | `15` | equity curve ka sample interval |
| `retention_days` | `45` | itne purane samples prune ho jaate hain |
| `telemetry_stale_seconds` | `90` | isse purani JSON = stalled feed |
| `session_minutes` | `60` | developer session ki umar |
| `unlock_max_attempts` | `5` | window `unlock_window_seconds` (300) |
| `unlock_lockout_seconds` | `900` | lockout |
| `hide_money_in_normal` | `false` | `true` karein to normal mode paisa bhi chhipa dega (screen share ke liye) |
| `mt5_path` | `""` | khaali = jo terminal chal raha hai usse attach |

---

## API

Sab responses auth state ke hisaab se shaped hote hain. Developer flag **sirf** valid cookie se aata hai.

| Method | Route | Deta hai |
|---|---|---|
| GET | `/api/state` | account, positions (attribution ke saath), totals, strategies, drawdown, telemetry, health |
| GET | `/api/series?range=24h` | equity/balance/floating/DD samples + realised curve |
| GET | `/api/trades?limit=200&range=7d` | closed deals |
| GET | `/api/strategies?range=30d` | per-strategy realised stats |
| GET | `/api/session` | `{developer, expiresIn, pinConfigured, lockedFor, settings}` |
| GET | `/api/health` | source, poller, telemetry feeds, store stats |
| GET | `/api/events` | SSE stream, state change pe push |
| POST | `/api/unlock` | `{pin}` → HttpOnly cookie |
| POST | `/api/lock` | session drop |
| POST | `/api/pin` | PIN badalna (developer mode chahiye) |

`range`: `1h` `6h` `24h` `7d` `30d` `all`. Series 900 points pe thin ho jaati hai, isliye `30d` bhi halka rehta hai.

---

## EA side

Kuch karna nahi hai — telemetry default se **on** hai. Har EA me:

| Input | Default | Kya |
|---|---|---|
| `InpTelemetry` | `true` | JSON snapshot likhna |
| `InpTelemetrySec` | `5` (KM6: `15`) | kitne second me ek baar |

`InpShowPanel` off ho to bhi telemetry likhti hai — snapshot `Panel()` ke pehle statement pe hai, aur suite ka har OnTick exit path `Panel()` se guzarta hai (warm-up aur just-closed states bhi, jo dekhne layak hi hote hain).

Files: `MQL5\Files\KrishMix\telemetry\KM1_XAUUSD.json` etc. Write atomic hai (temp file → `FileMove`), to poller ko kabhi aadha document nahi milta.

---

## Files

```
dashboard/
├── run.py                  entry point
├── selftest.py             backend end-to-end test
├── frontend_check.py       frontend static validation
├── backend/
│   ├── config.py           config + PIN hashing
│   ├── auth.py             sessions, tokens, rate limiting
│   ├── attribution.py      magic + comment → strategy
│   ├── mt5source.py        Mt5Source (live) + DemoSource (synthetic)
│   ├── telemetry.py        EA JSON reader, staleness tracking
│   ├── store.py            SQLite time series + closed trades
│   ├── redact.py           normal vs developer allow-lists  ← the core
│   ├── poller.py           background loop, snapshot publisher
│   ├── server.py           stdlib HTTP + SSE + static files
│   └── app.py              wiring, first-run PIN, self-check
└── frontend/
    ├── index.html
    ├── css/app.css
    └── js/  api.js  fmt.js  charts.js  views.js  app.js
```

---

## Troubleshooting

| Problem | Dekhein |
|---|---|
| `source: demo` par live chahiye | MT5 usi machine pe chal raha ho, `pip install MetaTrader5`, Python **64-bit** |
| Bots cards khaali | Telemetry folder me JSON aayi? EA logs me `telemetry -> ...` line dekhein. `InpTelemetry` on hai? |
| Feed `stale` | Woh EA detach ho gaya, ya chart pe ticks nahi aa rahe (market closed) |
| Positions dikhte hain par strategy `UNKNOWN` | `--magic-base` EAs ke `InpMagicBase` se match nahi kar raha |
| Closed trades khaali | Pehli run 7 din peeche tak dekhti hai; usse purana history ingest nahi hota |
| Developer PIN bhool gaye | `python run.py --set-pin <naya>` |
| `429` unlock pe | Rate limit. `retryAfter` second wait karein |
| Port busy | `--port 9001` |

---

## Testing

Sandbox me network nahi tha, to yeh do scripts likhi gayi hain:

```bash
python selftest.py         # asli server ko ephemeral port pe uthata hai aur drive karta hai
python frontend_check.py   # JS/CSS balance, imports, DOM ids, served content types
```

`selftest.py` verify karta hai: poller snapshot, 10 demo positions, sab attributed, 6 strategies, **normal mode me zero forbidden keys**, developer mode me score/narrative visible, galat PIN reject + `attemptsLeft`, sahi PIN accept, re-lock, 4 galat PIN → `429`, SQLite samples, saare endpoints, unknown endpoint `404`, SSE frame, path traversal blocked.

Dono ka current status: **ALL CHECKS PASSED**.

**Jo verify NAHI hua** (honest disclosure):

- `Telemetry.mqh` **compile nahi hua** — sandbox me MQL5 toolchain nahi hai. JSON builder ka comma state machine aur `Esc()` Python me port kar ke verify kiye gaye (nested docs with newlines, quotes, backslashes, control chars, non-ASCII sab `json.loads` se round-trip hue), par MetaEditor F7 aapko chalana hoga.
- Asli `MetaTrader5` package path kabhi chala hi nahi — woh Windows-only hai. `Mt5Source` code review se saaf hai, par live terminal pe pehli baar aap hi chalayenge. `DemoSource` isi liye hai ki UI aur backend uske bina bhi provable rahe.
