# krish-mix — KrishMix MT5 Suite

Chaar **separate** MetaTrader 5 Expert Advisors jo ek team ki tarah kaam karte hain. Har EA ka apna kaam, apne indicators, apna decision. Coordination shared state bus ke through.

| EA | File | Kaam |
|---|---|---|
| **EA1** | [`KM1_Entry.mq5`](MQL5/Experts/KrishMix/KM1_Entry.mq5) | Market analysis → **pinpoint entry**. Order me **TP hai, SL nahi** |
| **EA2** | [`KM2_Grid.mq5`](MQL5/Experts/KrishMix/KM2_Grid.mq5) | Grid brain — grid kholni hai ya **wait**? kis distance pe? kitna lot? |
| **EA3** | [`KM3_Hedge.mq5`](MQL5/Experts/KrishMix/KM3_Hedge.mq5) | Recovery hedge — direction pakad ke **bade lot** se fast recovery |
| **EA4** | [`KM4_BasketTP.mq5`](MQL5/Experts/KrishMix/KM4_BasketTP.mq5) | Adaptive basket exit — **kitne basket profit pe close** karna hai |

**Koi equity-percent rule nahi. Koi halt state nahi. Koi stop loss nahi.** Loss ka jawab EA3 ka hedge aur EA4 ka basket exit hai — jaisa aapne bola.

---

## Lifecycle — poora cycle ek example me

```
 1  EA1  analysis: score +62, ADX 27, TREND-UP, MTF agree
         trigger PULLBACK -> BUY 0.01 @ 2650.00, TP 2651.80, SL nahi

 2       market ulta chala -> 2647.00. EA1 kuch nahi karta (SL nahi hai)

 3  EA2  buy basket -1 leg, under water. Pressure 71 against, exhaustion nahi
         -> "pressure 71 still too high, waiting"          <-- WAIT, add nahi
         2644.00 pe pressure 38 tak gir gaya, ATR distance bhi mil gayi
         -> ADD L2 0.02 lots

 4  EA2  2640 -> L3 0.03  |  2635 -> L4 0.04  |  2629 -> L5 0.05
         (distance har level pe ATR + regime ke hisaab se widen hoti hai)

 5  EA3  buy basket: 0.15 lots, dd -$450, adverse $30
         conviction check: score -68, ADX 31, TREND-DOWN, MTF agree,
         bull-exhaustion flag nahi
         -> RECOVERY SELL 0.60 lots  (lock 0.15 + recover 0.45)

 6  EA4  ab group ban gaya: buy basket (0.15) + recovery sell (0.60)
         group target = 25 x 0.75 lots x1.6 trend x0.78 relief = $23
         2609 pe group +$23 -> POORA GROUP EK SAATH CLOSE
         (buy basket akela close nahi hoga - "held by the recovery group")

 7       sab flat. EA1 wapas naya pinpoint entry dhoondhta hai.
```

---

## Architecture

MT5 me **ek chart pe ek hi EA** attach hota hai. To chaar EAs = **same symbol ke chaar charts**. Aapas me baat karne ke liye **terminal Global Variables** ka namespaced bus use hota hai (`KM.<symbol>.<key>`), jo terminal restart ke baad bhi bacha rehta hai.

```
        ┌──── KM1 chart ────┐   publishes score, regime, vol, ATR
        │  pinpoint entry   │──────────┐
        └───────────────────┘          │
        ┌──── KM2 chart ────┐          ▼
        │   grid brain      │◄── KM.<symbol>.* ──► terminal global variables
        └───────────────────┘          ▲          (score, regime, grid level,
        ┌──── KM3 chart ────┐          │           hedge state, live targets,
        │  recovery hedge   │──────────┤           heartbeats)
        └───────────────────┘          │
        ┌──── KM4 chart ────┐          │
        │  basket exit      │──────────┘   the only EA that closes anything
        └───────────────────┘
```

Har EA ka panel **Suite:** line dikhata hai — `E1-Entry:on E2-Grid:on E3-Hedge:on E4-Basket:OFF` — heartbeat se. Isse turant pata chal jaata hai koi EA attach karna bhool gaye.

### Shared library

| File | Kya hai |
|---|---|
| [`Common.mqh`](MQL5/Include/KrishMix/Common.mqh) | Magic layout, lot normalization, `moneyPerPricePerLot`, margin helpers |
| [`StateBus.mqh`](MQL5/Include/KrishMix/StateBus.mqh) | Cross-EA communication + heartbeats |
| [`Signals.mqh`](MQL5/Include/KrishMix/Signals.mqh) | **Indicator engine** — sab EAs isi ko use karte hain |
| [`Positions.mqh`](MQL5/Include/KrishMix/Positions.mqh) | Book scan, direction baskets, per-EA baskets, recovery groups |
| [`Execution.mqh`](MQL5/Include/KrishMix/Execution.mqh) | Order send/close, retries, TP validation, margin trimming |

### Magic numbers — ek hi base

Chaaron EAs me **ek hi `InpMagicBase`** (default `51000`). Baaki khud derive hota hai:

```
magic = base + eaSlot*10 + (buy ? 1 : 2)

51011 EA1 buy    51021 EA2 buy    51031 EA3 buy
51012 EA1 sell   51022 EA2 sell   51032 EA3 sell
```

`base+1 .. base+99` range family hai, isse koi bhi EA pehchan leta hai ki position suite ki hai, aur kis EA ne kis direction me kholi thi. **Base badlein to chaaron me same badlein.**

---

## Signal engine — sab EAs ka common brain

Ek multi-timeframe stack se ek `MarketView` banta hai. Har EA apna **independent instance** chalata hai (apne periods set kar sakta hai), aur usse apne hisaab se use karta hai.

| Group | Indicators |
|---|---|
| Trend | EMA 8 / 21 / 50 + EMA 50 on M15 aur H1 (MTF agreement) |
| Strength | ADX with +DI / −DI |
| Momentum | MACD histogram (value **aur** slope), RSI, Stochastic |
| Volatility | ATR vs apna 100-bar average, Bollinger width |
| Structure | Donchian 40 breakout, swing high/low |

Output:

- **`score`** −100..+100 — 9 weighted components, ATR se normalized (to volatility ke saath scale hota hai)
- **`regime`** — `RANGE` / `TREND-UP` / `TREND-DOWN` / `BREAKOUT-UP` / `BREAKOUT-DN`
- **`volState`** — `LOW` / `NORMAL` / `HIGH` / `EXTREME`
- **`bullExhaust` / `bearExhaust`** — stretched **aur** momentum roll over ho raha hai
- **`mtfAgree`** — dono higher timeframes score se agree karte hain

Reading har **closed bar** pe ek baar compute hoti hai, andar cache hoti hai. Isse M1 gold ke heavy tick flow me CPU bachta hai.

---

## Installation

1. MT5 → **File → Open Data Folder**
2. `MQL5/Include/KrishMix/` — paanch `.mqh` files copy karein
3. `MQL5/Experts/KrishMix/` — chaar `.mq5` files copy karein
4. **F4** (MetaEditor) → chaar EA files open karein → har ek pe **F7** (Compile). `0 errors` aana chahiye
5. MT5 me **XAUUSD M1 ke chaar chart** kholein
6. Har chart pe ek EA attach karein — KM1, KM2, KM3, KM4
7. Har ek me **Common → Allow Algo Trading** tick karein
8. `MQL5/Presets/` se matching `.set` file **Load** karein
9. Toolbar ka **Algo Trading** green hona chahiye

**Check:** kisi bhi chart ke panel pe `Suite: E1-Entry:on E2-Grid:on E3-Hedge:on E4-Basket:on` dikhna chahiye. Koi `OFF` ho to woh EA attach nahi hua.

**Requirements:** MT5, **hedging account** (netting pe chaaron `OnInit` me reject karenge), XAUUSD, M1.

---

## EA1 — Pinpoint Entry

Saat conditions, sab pass honi chahiye. Panel pe live dikhta hai kaun block kar raha hai.

1. `|score| >= InpMinScore` (45)
2. `InpRequireMtfAgree` — M15 aur H1 dono agree
3. `ADX >= InpMinAdx` (20)
4. Volatility `EXTREME` nahi (news spikes skip)
5. Spread `InpMaxSpreadPoints` ke andar
6. **Ek pinpoint trigger** fire ho:
   - **PULLBACK** — trend intact, last bar ne fast EMA ko touch kiya aur trend side pe close hua
   - **BREAKOUT** — Donchian edge ke paar close + ATR already expand ho raha hai
   - **REVERSAL** — range regime + band extreme pe exhaustion flag
7. Cooldown (`InpCooldownSeconds` 300) khatam + is bar pe entry nahi hui

Order: **TP** (default `ATR x 1.8`), **SL nahi**. EA1 hi shared market view publish karta hai.

Key inputs: `InpLot` `InpMinScore` `InpMinAdx` `InpTpMode` `InpTpAtrMult` `InpCooldownSeconds` `InpMaxPerDirection`

---

## EA2 — Grid Brain

Har bar pe teen sawaal:

### 1. ADD ya WAIT?

Yeh sabse important part hai. Mechanically har N points pe add karna nuksan deta hai. EA2 **rukta hai**:

| Condition | Action |
|---|---|
| `pressure > InpMaxPressureToAdd` (55) aur exhaustion nahi | **WAIT** |
| Volatility `EXTREME` | **WAIT** |
| Breakout regime basket ke against | **WAIT** |
| Pressure thanda ho gaya **ya** exhaustion flag aa gaya | **ADD** |

`pressure` = score jo basket ke against hai, ADX se weighted (0–100).

### 2. Kis distance pe?

```
distance = ATR x InpAtrStepMult
           x 1.8   agar trend basket ke against hai
           x 0.75  agar exhaustion flag hai (turn paas hai, closer add karo)
           x 1.3   HIGH volatility  |  x 1.8  EXTREME
           x 1.08^(level-2)         deeper levels progressively door
           floor: InpMinStepPrice aur spread x4
```

### 3. Kitna lot?

Default **additive** — `0.01, 0.02, 0.03, 0.04, 0.05...`

> Multiply mode bhi hai par additive default hai kyunki `0.01 × 1.25 = 0.0125` broker step pe round hoke wapas `0.01` ban jaata — growth hi na hoti. Multiply mode level se calculate karta hai (last lot se nahi), to rounding pe stall nahi hota.

Aur: market abhi bhi hostile hai par distance mil gayi? Lot `InpCautiousLotScale` (0.5) se **chhota** ho jaata hai. Exhaustion flag hai? Full size.

`InpMaxLevels` aur `InpMaxLotsPerSide` default **0 = unlimited** hain, aapki requirement ke mutabik.

---

## EA3 — Recovery Hedge

### Kab step in karega

- Losing basket trigger paar kar chuka — money (`$40`), ATR distance (`x3`), ya dono
- Basket me kam se kam `InpMinBasketLegs` (2) legs
- **Conviction:** `|score| >= 55`, `ADX >= 24`, regime hedge direction me trend/breakout, MTF agree
- **Exhaustion flag nahi** — yeh critical hai. Move ke last gasp pe hedge kholna sabse bura outcome hai, to stretched-and-stalling reading trade **block** kar deti hai

### Sizing — do hisse

```
lock     = basketLots x InpLockRatio        further bleed neutralize karta hai
recovery = drawdown / (horizon x moneyPerLot)   yeh actually loss wapas kamata hai
total    = lock + recovery
```

**`InpRecoveryOverPrice` iss EA ka sabse important input hai.** Yeh lot size decide karta hai. Gold pe `$450` drawdown recover karna:

| Horizon | Recovery lot | Total (with lock 0.15) | vs basket | Margin @1:500 |
|---|---|---|---|---|
| $20 | 0.23 | 0.38 | 2.5x | $199 |
| **$10** | **0.45** | **0.60** | **4.0x** | **$318** ← default |
| $5 | 0.90 | 1.05 | 7.0x | $556 |
| $1 | 4.50 | 4.65 | 31.0x | $2,464 |

Chhota horizon = bada lot = tez recovery, par utna hi bada risk agar market phir palat jaaye. `$1` horizon 0.15 lot basket se **4.65 lot** hedge banata hai — yeh account udaane ka tareeka hai. Default deliberately `$10` price units me hai, ATR multiple me nahi, kyunki M1 gold ka ATR (~$0.50) itna chhota hai ki `ATR x 2` = `$1` ban jaata.

Safety ceilings: `InpMaxHedgeLot` (2.0), `InpMaxHedgeVsBasket` (12x), aur free margin. Margin trimming strategy limit nahi hai — broker unaffordable order reject kar hi deta hai, to EA pehle se trim kar leta hai.

Re-hedging: `InpMaxHedgeLegs` (3), aur next leg ke liye `InpRehedgeAtrGap` (ATR x2.5) real travel chahiye — wiggle pe nahi.

---

## EA4 — Adaptive Basket Exit

Suite ka **sirf yahi EA close karta hai.** Koi fixed TP nahi — target har bar recompute hota hai.

### Teen groups, isi order me

**1. Recovery group** — drowning basket **+** usko bachane wali EA3 legs. Inko **saath me** judge karna zaroori hai: rescue leg ka gain hi group ko bahar nikaalta hai. Alag-alag close karna hedge ka poora point barbaad kar deta. Jab tak recovery legs open hain, us direction ka basket akela close nahi hoga — panel pe `held by the recovery group` dikhega.

**2. Direction basket** — saare buy legs, ya saare sell legs, apne aap. Normal harvest jab hedge nahi hai.

**3. Whole book** — optional final sweep jab sab milke net positive ho.

### Target kaise move karta hai

```
base = InpTargetPerLot x group volume        exposure ke saath scale
```

| Condition | Effect |
|---|---|
| Trend hamare saath | **x1.6** — achhe move ko zyada pay karne do |
| Trend against | **x0.6** — jo mil raha hai le lo |
| Range | x0.85 |
| Volatility HIGH / EXTREME | x1.3 / x1.5 |
| Volatility LOW | x0.8 |
| Jo move pay kar raha tha woh exhausted | **x0.7** — bank karo |
| **Depth relief** — 3 legs ke baad har extra leg | **x0.92** per leg |
| **Age relief** — har ghante | **x0.97** per hour |

Depth aur age relief practical hai: basket jitna deep aur purana, escape karna utna zyada priority. Combined relief `InpMinReliefFloor` (0.15) se neeche nahi jaata.

**Invariant:** target floor `InpMinTarget` hamesha **positive** hai. Koi relief factor isse loss-cut me nahi badal sakta. **EA4 sirf profit me close karta hai** — isi liye kahin equity rule ki zaroorat nahi.

Example: `0.75` lot group, trend saath, 6 legs → `25 × 0.75 × 1.6 × 0.92³` = **$23.36**

---

## ⚠️ Risk — honestly

Aapne jo maanga wahi bana hai, aur aapko yeh saaf pata hona chahiye ki iska matlab kya hai:

- **Koi stop loss nahi** — kisi bhi position pe
- **Koi equity-percent close nahi** — kuch bhi automatically sab band nahi karega
- **Koi halt state nahi** — EA2 gridding rokta nahi (caps default 0)
- **EA4 loss me close nahi karta** — sirf profit me

Iska seedha matlab: **is system me aisa koi mechanism nahi hai jo bounded loss guarantee kare.** Bacha hua backstop sirf ek hai — broker ka margin call / stop out. Agar gold bina retracement ke ek hi direction me lambi trend kare, aur EA3 ka hedge galat time pe lage (ya conviction gate kabhi pass hi na ho), to drawdown badhta rahega jab tak margin khatam.

Jo cheezein **rakhi gayi hain** (aur woh limitation nahi, broker reality hain):

- **Margin pre-check** — unaffordable order server reject karta hi hai, to EA pehle se volume trim kar leta hai. Isse error spam aur adhoore hedges se bacha jaata hai
- **`InpMaxHedgeVsBasket`** — sizing sanity, taaki ek chhoti basket se galti se 30x lot na khul jaaye. `0` set karke off kar sakte hain
- **Exhaustion block on EA3** — yeh limitation nahi, **timing** hai. Move ke end pe hedge lagana recovery ka ulta kaam karta hai

Isko chalane se pehle:

1. **Strategy Tester** — XAUUSD M1, "Every tick based on real ticks", 3–6 months
   - Tester me ek time pe ek hi EA chalta hai. Chaaron ka combined behaviour **sirf demo pe** dikhega. Yeh iss design ki asli limitation hai — isse pehle jaan lein
2. **Demo pe kam se kam 3–4 hafte**, chaaron attach karke, panels dekhte hue
3. Gold ke **strong trending periods** dekhein — wahi worst case hai
4. Chhote balance se shuru karein jitna aap pura kho sakte hain

Yeh code research/educational purpose ke liye hai. Live capital ka risk poora aapka hai.

---

## Safe wind-down

Chaaron ko beech me detach karne se positions unmanaged reh jaati hain. Sahi tareeka:

1. **KM1 detach karein** — naye entries band
2. **KM2 detach karein** — nayi grid legs band
3. **KM3 aur KM4 chalte rehne dein** — EA3 recovery karega, EA4 profit me close karega
4. Sab flat hone ke baad KM3 aur KM4 detach karein

Ya EA1 me `InpMinScore` `100` kar dein (koi entry nahi) aur EA2 me `InpMaxLevels` `1` kar dein.

---

## Troubleshooting

| Problem | Reason / Fix |
|---|---|
| `needs a HEDGING account` | Account netting hai. Broker se hedging account lein |
| Panel me koi EA `OFF` | Woh EA attach nahi hai, ya Algo Trading off hai |
| Ek EA doosre ki positions nahi dekh raha | `InpMagicBase` chaaron me same nahi hai |
| EA1 kabhi enter nahi karta | Panel ka `gate:` line dekhein — exact reason likha hota hai. `InpMinScore` ya `InpMinAdx` kam karein |
| EA2 grid add nahi kar raha | Panel ka `->` line dekhein. Aksar `pressure still too high` hota hai — yeh **intended** hai. `InpMaxPressureToAdd` badha ke jaldi add kara sakte hain |
| EA3 kabhi fire nahi karta | Conviction gate strict hai. Panel reason dekhein; `InpMinScore` / `InpMinAdx` kam karein ya `InpRequireTrendRegime` off karein |
| EA3 ka lot bahut bada | `InpRecoveryOverPrice` **badhayein** (`$10` → `$20`) |
| Basket target hit par close nahi | Toolbox → Experts me `close #... failed` aur broker retcode dekhein |
| Buy basket profit me hai par close nahi ho raha | `held by the recovery group` — hedge legs open hain, EA4 group ko saath judge karega |
| ECN pe target hit par net profit kam | Chaaron me `InpCommissionPerLot` set karein |

Sab diagnostics MT5 ke **Toolbox → Experts** tab me hain.

---

## Not verified

Sandbox me MQL5 toolchain nahi hai, to **yeh code compile ya backtest nahi hua.** Jo verify kiya gaya hai, script se:

- Chaaron EA aur paanchon include files structurally balanced
- Har `Bus.` / `Sig.` / `Book.` / `Exec.` method call ka definition maujood hai
- Har struct field access valid hai
- Har `Inp*` reference apne EA me declared hai
- Har preset key ek real input se map karta hai, aur koi input chhoota nahi
- EA3 ki recovery sizing aur EA4 ka target math numerically check kiye gaye (isi se `$10` horizon default nikla)

MetaEditor me **F7** se compile karein. Koi error aaye to error text bhejein.
