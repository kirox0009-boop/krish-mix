# krish-mix — KrishMix MT5 Suite

**Chhe separate** MetaTrader 5 Expert Advisors jo ek team ki tarah kaam karte hain. Har EA ka apna kaam, apne indicators, apna decision. Coordination shared state bus ke through.

| EA | File | Kaam | Kitne chart |
|---|---|---|---|
| **EA1** | [`KM1_Entry.mq5`](MQL5/Experts/KrishMix/KM1_Entry.mq5) | Analysis → **pinpoint entry**. TP hai, SL nahi | per symbol |
| **EA2** | [`KM2_Grid.mq5`](MQL5/Experts/KrishMix/KM2_Grid.mq5) | Grid brain — kholni hai ya **wait**? distance? lot? | per symbol |
| **EA3** | [`KM3_Hedge.mq5`](MQL5/Experts/KrishMix/KM3_Hedge.mq5) | Recovery hedge — bade lot se fast recovery | per symbol |
| **EA4** | [`KM4_BasketTP.mq5`](MQL5/Experts/KrishMix/KM4_BasketTP.mq5) | Adaptive basket exit — **kitne profit pe close** | per symbol |
| **EA5** | [`KM5_Portfolio.mq5`](MQL5/Experts/KrishMix/KM5_Portfolio.mq5) | **Multi-asset** entries + cross-asset recovery + portfolio exit | **ek baar** |
| **EA6** | [`KM6_TfSelect.mq5`](MQL5/Experts/KrishMix/KM6_TfSelect.mq5) | **Timeframe bot** — scalp / intraday / swing decide karta hai | **ek baar** |

**Koi stop loss nahi. Koi equity-percent rule nahi. Koi halt state nahi.** Loss ka jawab EA3 ka hedge, EA5 ka cross-asset assist, aur EA4/EA5 ka basket exit hai.

---

## Is version me kya naya hai

### 1. EA4 ab initial order ka TP nahi churata ← *aapki main complaint*

**Problem:** EA1 ne `1:3` TP ke saath order bheja, par EA4 ka `$1` money floor usse turant band kar deta tha. TP ko chance hi nahi milta tha.

**Fix:** `InpRespectEntryTP = true`. Jab tak koi position **akeli hai aur apna TP carry kar rahi hai**, EA4 usko **chhuta hi nahi**. Basket management tabhi shuru hoti hai jab:

- EA2 ne us side pe **grid khol di**, **ya**
- legs `InpManageFromLegs` (default 2) tak pahunch gaye, **ya**
- kisi leg ka apna TP nahi hai (to usse band karne wala koi nahi)

Panel pe dikhega: `riding its own TP (1 leg, no grid yet)`. Yahi guard EA5 ke portfolio exit me bhi hai.

### 2. Multi-asset cross-recovery (EA5)

Ek asset phasa hai to **doosre assets usse nikalne me help karte hain**. Aur initial orders bhi har asset pe lagte hain — **"ek asset me chal raha hai to doosre me nahi" jaisi koi limit nahi**.

### 3. Chaar naye strategy layers (EA1 me)

Purane indicators aur triggers **bilkul waise hi kaam karte hain**. Yeh sirf **extra tareeke** hain qualify karne ke.

| Layer | Kya hai |
|---|---|
| **INSIDEBAR** | M30 swing high pe inside bar → baby candle ka low toota → sell, `1:3` TP |
| **FIBREV** | Trend-based fib ke 3 projection levels = reversal zones |
| **PLAYBOOK** | 5-step top-down analysis → named edge |
| **Fresh-trend gate** | Ghuse hue trend me entry nahi — **sirf corner se** |

### 4. Timeframe bot (EA6)

Decide karta hai scalping / intraday / swing, aur working timeframe publish karta hai.

---

## Naye strategies detail me

### INSIDEBAR — M30 swing extreme inside bar

Aapka gold M30 setup, exactly:

```
1. Market ne fresh swing HIGH banaya
2. Wahi candle BADI hai            (>= InpIbMotherMinAtr x ATR, default 0.80)
3. Agli candle BABY hai, poori uske andar
   (baby range <= InpIbBabyMaxFrac x mother, default 0.55)
4. Baby ka LOW toota              -> SELL entry
5. TP = 1:3                        (InpIbRewardRatio)
6. SL nahi                         -> EA2/3/4 sambhalenge
```

Buy side mirror hai — fresh swing LOW pe baby ka high toota.

**Implied risk** `InpIbRiskFromMother = true` pe mother candle ke extreme se naapa jaata hai (jahan stop hota agar hota). Verified: risk avg `0.88 ATR` → target avg `2.64 ATR` ≈ **$16 gold travel**. Rate: **~3.4 triggers per din** M30 pe.

### FIBREV — trend-based Fibonacci

Normal retracement nahi. Teen point chahiye:

```
A = impulse shuru      B = impulse khatam      C = pullback khatam

level(r) = C + (B - A) x r      r = 0.618, 1.000, 1.618
```

**Down impulse** → teeno levels C ke **neeche** → price wahan girta hai aur **palatta** hai → **BUY**. Up impulse mirror.

Example (verified):
```
A(high)=2700  B(low)=2650  C(pullback high)=2680
impulse = -50, C ne 60% retrace kiya
levels: 2649.10 / 2630.00 / 2599.10   -> sab C ke neeche -> BUY reversal
```

> **Tuning note:** `InpFibTolerAtr = 0.50` pe price kaafi baar "at level" hota hai (verified: scans ka **12.6%**). Agar zyada entries lag rahi hain to `0.25`–`0.35` kar dein.

### PLAYBOOK — 5-step top-down

Aapke exact steps, aur **poori reasoning panel aur log me likhi aati hai**:

| Step | Timeframe | Kya dekhta hai |
|---|---|---|
| **1** | H4 | Uptrend / downtrend / consolidating |
| **2** | M15 | Support, resistance, major trendline — mark karke price se distance |
| **3** | M5 | VWAP (+σ bands), moving average, RSI divergence, chart patterns (H&S, rising/falling wedge) |
| **4** | — | **Named edge** resolve karta hai |
| **5** | — | Working timeframe EA6 se |

Named edges:

| Edge | Kab |
|---|---|
| `VWAP+PriceAction` | VWAP band edge pe stretch + price action confirmation |
| `S/R+RSIdivergence` | Strong level pe divergence |
| `Pattern@Level` | Chart pattern kisi level pe resolve ho raha hai |
| `Trendline+VWAP` | Trendline touch + VWAP sahi side |

Panel pe aisa dikhega:
```
1) UPTREND on PERIOD_H4 (maturity 32, fresh)
2) PERIOD_M15: sup 2648.20 x3 (0.4 atr away) | rising line 2647.10 (0.6 atr)
3) PERIOD_M5: vwap 2651.30 (-1.42 sd below) | ma below | div bullishRegular | pat none
4) EDGE S/R+RSIdivergence LONG, confidence 78 from 4 legs
5) style INTRADAY -> working PERIOD_M15
```

### Fresh-trend gate — corner se hi entry

"Ghuse hue trend me entry nahi" — yeh **maturity score** se enforce hota hai:

```
maturity = 60% x (extension in ATR / 12) + 40% x (legs / 5)
```

Entry allowed hoti hai jab:

| Condition | Kyun |
|---|---|
| Koi trend hi nahi | Late hone ka sawal nahi |
| **Counter-trend** entry | Reversal setups isi tarah kaam karte hain |
| Structure abhi **flip** hua (`<= 25` bars) | Naya trend |
| Price origin ke **paas** (`<= 3 ATR`) | Corner |
| Maturity `<= 40` | Abhi jawan hai |
| Pullback `>= 50%` | Deep pullback = naya corner |

Verified: jo entries **actual trend join** kar rahi hain, unme se **~47% block** hoti hain. Yahi filter ka kaam hai.

---

## EA5 — multi-asset cross-recovery

### Kaise kaam karta hai

```
KM5 poore book ko ek pass me scan karta hai, symbol-wise bucket banata hai

  sabse deep drawdown wala symbol dhundta hai      -> "STUCK"
  jitna paisa wapas kamana hai woh calculate karta hai
  baaki symbols me se jinke paas CONVICTION hai unhe chunta hai
  load un sab me BAANT deta hai
  har symbol pe uska apna lot size karta hai
```

**Conviction** ka matlab: `|score| >= 55`, `ADX >= 24`, regime us direction me trend kar raha hai, aur **exhaustion flag nahi** (move ke end pe assist lagana ulta nuksan hai).

### Sizing — yeh sabse important technical point hai

Contract values **char order of magnitude** alag hain:

| Asset | $1 price move per lot |
|---|---|
| XAGUSD (silver) | $5,000 |
| XTIUSD (oil) | $1,000 |
| XAUUSD (gold) | $100 |
| BTCUSD / USTEC / US30 | $1 |

Isliye recovery horizon **ATR multiples** me hai (`InpAssistHorizonAtr = 8`), price units me nahi. `$200` recover karne ke liye (verified):

| Asset | 8 ATR travel | Lot | Delivers |
|---|---|---|---|
| XAUUSD | $48 | 0.04 | $192 |
| BTCUSD | $4,000 | 0.05 | $200 |
| XAGUSD | $1.20 | 0.03 | $180 |
| XTIUSD | $4.00 | 0.05 | $200 |
| USTEC | 640 pts | 0.30 | $192 |
| US30 | 1,200 pts | 0.20 | $240 |

### Overshoot guard — ek real hazard jo mila

Indices ka **minimum volume 0.10 lot** hai. US30 pe 0.10 lot × 8 ATR ≈ **$120 recovery**. To `$50` ka drawdown wahan assist karna **hi nahi chahiye** — "help" problem se badi ban jaayegi.

`InpAssistMaxOvershoot = 2.0` → aisa helper **skip** hota hai, aur log me reason aata hai:

```
KM5 assist skips US30: minimum 0.10 lots would recover 120.00
for a 40.00 share (3.0x overshoot)
```

### Load splitting example (verified)

```
XAUUSD -$600 stuck, 3 helpers with conviction

  BTCUSD  share $200 -> 0.05 lots -> delivers $200
  XAGUSD  share $200 -> 0.03 lots -> delivers $180
  USTEC   share $200 -> 0.30 lots -> delivers $192
  combined $572 vs $600 needed  (0.95x)
```

### Symbols

Default: `XAUUSD,BTCUSD,XAGUSD,XTIUSD,USTEC,US30`

Broker naam alag hote hain (`XAUUSD.a`, `XAUUSDm`, `NAS100`, `US100`). EA khud **suffix resolve** karta hai — exact → prefix → contains. Jo na mile woh log me aata hai:

```
KM5 WARNING: could not resolve -> XTIUSD (check the exact names in Market Watch)
```

**Tradable vs discovered:** jo symbol list me hai wahan KM5 order khol sakta hai. Jo list me nahi hai par suite ki positions hold kar raha hai, woh **accounting me aata hai** (warna jis symbol ko bachana hai wahi invisible ho jaata).

---

## EA6 — timeframe bot

| Style | Timeframes |
|---|---|
| SCALP | M1 / M3 / M5 |
| INTRADAY | M5 / M15 |
| SWING | H1 / H4 |

Decision **arithmetic** hai, preference nahi. Chaar inputs:

1. **Spread economics** (sabse heavy) — scalping tabhi chalti hai jab spread us range ke saamne chhota ho jo ek bar actually deta hai. `spread / ATR(M5)` `0.25` se upar = scalp uneconomic. **Gold aur indices pe yeh test akela hi din ka zyada hissa scalping ko reject kar deta hai** — yeh honest jawab hai, achha lagne wala nahi.
2. **Volatility** — ATR vs apna long average
3. **Trend persistence** — H1 ADX
4. **Session liquidity** — London/NY overlap

Ek instance poori watchlist cover karta hai, aur `KM.<symbol>.style` / `KM.<symbol>.worktf` publish karta hai.

---

## Architecture

MT5 me **ek chart pe ek hi EA**. Coordination **terminal Global Variables** se (`KM.<symbol>.<key>`), jo restart ke baad bhi bache rehte hain.

```
        per traded symbol (4 charts each)              once (1 chart each)
    ┌──────────────────────────────────┐       ┌────────────────────────────┐
    │ KM1 entry    ── publishes view   │       │ KM6 tfselect               │
    │ KM2 grid                         │◄─────►│   publishes style + tf     │
    │ KM3 hedge                        │  bus  │                            │
    │ KM4 basket exit (per symbol)     │◄─────►│ KM5 portfolio              │
    └──────────────────────────────────┘       │   multi-asset entries,     │
                                               │   cross-asset assist,      │
                                               │   portfolio exit           │
                                               └────────────────────────────┘
```

Har panel pe **Suite:** line hai — `E1-Entry:on E2-Grid:on ... E6-TfSelect:on` — heartbeat se. Koi `OFF` ho to woh EA attach nahi hua.

### Chart layout

**Minimum (ek asset, poori depth):** 6 charts
```
XAUUSD M1  -> KM1        XAUUSD M1 -> KM3        (koi bhi) -> KM5
XAUUSD M1  -> KM2        XAUUSD M1 -> KM4        (koi bhi) -> KM6
```

**Multi-asset (recommended):** 6 charts. Gold pe poori suite (KM1-4), baaki 5 assets **KM5 handle karta hai** — entries + assist + portfolio exit. KM5 khud dekh leta hai ki gold pe KM1 zinda hai (`InpDeferToSuite`) aur wahan entry nahi kholta.

> Har asset pe poori suite chahiye to 6 assets × 4 = **24 charts** + KM5 + KM6. Chalega, par practical nahi. KM5 ka design isi liye hai.

### Shared library

| File | Kya hai |
|---|---|
[`Common.mqh`](MQL5/Include/KrishMix/Common.mqh) | Magic layout, lot normalization, `moneyPerPricePerLot`, margin, symbol resolution |
| [`StateBus.mqh`](MQL5/Include/KrishMix/StateBus.mqh) | Cross-EA communication + heartbeats |
| [`Signals.mqh`](MQL5/Include/KrishMix/Signals.mqh) | **Indicator engine** — composite score, regime, volatility, exhaustion |
| [`Structure.mqh`](MQL5/Include/KrishMix/Structure.mqh) | **NEW** — swings, inside bar, S/R, trendlines, trend maturity, patterns |
| [`Fib.mqh`](MQL5/Include/KrishMix/Fib.mqh) | **NEW** — trend-based fib projections |
| [`Vwap.mqh`](MQL5/Include/KrishMix/Vwap.mqh) | **NEW** — session VWAP + σ bands, RSI divergence |
| [`Playbook.mqh`](MQL5/Include/KrishMix/Playbook.mqh) | **NEW** — 5-step top-down engine |
| [`TfSelect.mqh`](MQL5/Include/KrishMix/TfSelect.mqh) | **NEW** — style / timeframe selection |
| [`Portfolio.mqh`](MQL5/Include/KrishMix/Portfolio.mqh) | **NEW** — multi-symbol book + assist math |
| [`Positions.mqh`](MQL5/Include/KrishMix/Positions.mqh) | Book scan, baskets, recovery groups |
| [`Execution.mqh`](MQL5/Include/KrishMix/Execution.mqh) | Order send/close, retries, TP validation, margin trimming |

### Magic numbers

Chhe EAs, **ek hi `InpMagicBase`** (default `51000`):

```
magic = base + eaSlot*10 + (buy ? 1 : 2)

51011 EA1 buy   51021 EA2 buy   51031 EA3 buy   51051 EA5 buy
51012 EA1 sell  51022 EA2 sell  51032 EA3 sell  51052 EA5 sell
```

`base+1 .. base+99` family hai. **Base badlein to chhe jagah same badlein.**

---

## Installation

1. MT5 → **File → Open Data Folder**
2. `MQL5/Include/KrishMix/` — **gyarah** `.mqh` files copy karein
3. `MQL5/Experts/KrishMix/` — **chhe** `.mq5` files copy karein
4. **F4** → har EA file **F7** (Compile). `0 errors` aana chahiye
5. Charts attach karein (upar layout dekhein), `MQL5/Presets/` se matching `.set` **Load** karein
6. Har ek me **Common → Allow Algo Trading** tick karein
7. Toolbar ka **Algo Trading** green

**Check:** kisi bhi panel pe `Suite: E1-Entry:on ... E6-TfSelect:on` dikhna chahiye.

**Requirements:** MT5, **hedging account** (netting pe sab `OnInit` me reject karenge).

---

## ⚠️ Risk — honestly

Jo aapne maanga wahi bana hai, aur iska matlab saaf hona chahiye:

- **Koi stop loss nahi** — kisi bhi position pe
- **Koi equity-percent close nahi**
- **Koi halt state nahi** — EA2 gridding rokta nahi (caps default 0)
- **EA4/EA5 loss me close nahi karte** — sirf profit me

Matlab: **is system me aisa koi mechanism nahi hai jo bounded loss guarantee kare.** Bacha hua backstop sirf broker ka margin call hai.

**Multi-asset ne is baat ko badla nahi — badhaya bhi hai aur ghataya bhi:**

- **Ghataya:** ek asset ka drawdown chhe markets se recover ho sakta hai, ek se nahi. Correlation kam hone se recovery ke zyada raste.
- **Badhaya:** ab **ek saath chhe markets me exposure** hai. Risk-off event me gold, indices, oil, crypto **saath me** ek direction chal sakte hain — tab "diversification" gayab ho jaati hai aur chhe drawdown ek saath aate hain. Yeh real hai, ignore na karein.

Jo cheezein rakhi gayi hain (limitation nahi, broker reality):

- **Margin pre-check** — unaffordable order server reject karta hi hai
- **`InpAssistMaxOvershoot`** — sizing sanity, `0` karke off ho sakta hai
- **Exhaustion block** (EA3/EA5) — limitation nahi, **timing** hai

**Testing:**

1. **Strategy Tester** ek time pe **ek hi EA** chalata hai. Chhe EAs ka combined behaviour **sirf demo pe** dikhega. Yeh iss design ki asli limitation hai
2. **Demo pe 3–4 hafte** minimum, saare panels dekhte hue
3. Gold ke **strong trending periods** aur ek **risk-off day** (jab sab assets saath chalein) dekhein
4. Utne balance se shuru karein jitna poora kho sakte hain

Yeh code research/educational purpose ke liye hai. Live capital ka risk poora aapka hai.

---

## Safe wind-down

1. **KM1 aur KM5 detach karein** (`InpAllowEntries = false` bhi chalega) — naye entries band
2. **KM2 detach karein** — nayi grid legs band
3. **KM3, KM4, KM5 chalne dein** — recovery aur profit-me-close hota rahega
4. Sab flat hone pe baaki detach karein

---

## Troubleshooting

| Problem | Fix |
|---|---|
| `needs a HEDGING account` | Broker se hedging account lein |
| Panel me koi EA `OFF` | Woh EA attach nahi, ya Algo Trading off |
| EA ek doosre ki positions nahi dekh rahe | `InpMagicBase` chhe jagah same nahi hai |
| **EA1 entry nahi kar raha** | Panel ka **block histogram** — `<== main` wali line asli constraint hai. Neeche table dekhein |
| **Order turant close ho raha, TP hit nahi hua** | `InpRespectEntryTP = true` hai? EA4 panel pe `riding its own TP` dikhna chahiye |
| Bahut zyada FIBREV entries | `InpFibTolerAtr` `0.50` → `0.30` |
| KM5 assist fire nahi kar raha | Panel ka `assist:` line reason batata hai — aksar "no other asset has conviction" |
| KM5 `could not resolve` | Market Watch me exact naam dekhein, `InpSymbols` update karein |
| KM6 hamesha SWING bol raha | Normal hai — spread test scalping reject kar raha hai. `InpSpreadScalpMax` badha ke dekhein |

### EA1 block histogram

`InpDiagLogSeconds = 60` (preset me already on). Panel:

```
why no entry (of 84213 checks)
  score below floor           52104  61.9%  <== main
  mid-trend, not a corner     15832  18.8%
  no pinpoint trigger         10673  12.7%
best seen: |score| 58.2 (floor 35.0), adx 31.4 (floor 18.0)

layer            qualified  entered
  PULLBACK             412       18
  BREAKOUT              38        3
  REVERSAL              22        2
  INSIDEBAR            140       12
  FIBREV               890       21
  PLAYBOOK             205        9
```

`best seen` line sabse kaam ki — agar best `|score|` kabhi floor tak nahi pahuncha to floor unrealistic hai. `layer` table batata hai kaun layer actually contribute kar raha hai.

| `<== main` | Fix |
|---|---|
| `score below floor` | `InpMinScore` kam karein |
| `adx below floor` | `InpMinAdx` **aur** `InpAdxTrendLevel` **dono** (same value) |
| `mid-trend, not a corner` | Fresh gate kaam kar raha hai. `InpFreshMaturityMax` `40` → `55`, ya `InpFreshTrendOnly = false` |
| `no pinpoint trigger` | `InpDonchianPeriod` `40` → `25` |
| `higher timeframes disagree` | `InpRequireMtfAgree = false` |
| `market view not ready` | Log me exact buffer naam milega. M15/H1/H4 chart ek baar khol ke scroll karein (history download) |
| `structure not ready` | Chart pe `InpDonchianPeriod + swingLookback` se zyada bars chahiye |

Sab diagnostics **Toolbox → Experts** me.

---

## Not verified

Sandbox me MQL5 toolchain nahi hai, to **yeh code compile ya backtest nahi hua.** Script se jo verify kiya gaya:

- 17 files structurally balanced (braces, parens, brackets)
- Saare `KM_*` identifiers defined; 10 classes ke saare method calls resolve (object, array-of-object, aur static)
- Saare struct field accesses valid; reset functions har field cover karte hain
- Har `Inp*` apne EA me declared; koi unused nahi
- **Saare 6 presets source defaults se generate hue** — 243 keys, key-for-key parity guaranteed
- **Numerically verified:** fib projection math (dono direction), EA3 recovery sizing, EA5 cross-asset assist sizing across chhe assets, overshoot guard thresholds
- **Behaviourally verified** synthetic data pe: INSIDEBAR ~3.4 triggers/din M30 pe (risk 0.88 ATR → target 2.64 ATR), fresh gate trend-joining entries ka ~47% block karta hai, FIBREV 12.6% scans, swing/pattern/level detectors sab usable rate pe

MetaEditor me **F7** se compile karein. Error aaye to error text bhej dein.
