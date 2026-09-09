//+------------------------------------------------------------------+
//|                                              KM3_Hedge.mq5       |
//|                                                                  |
//|  KRISHMIX EA 3 of 4  -  RECOVERY HEDGE                             |
//|                                                                  |
//|  This is the loss controller of the suite. There is no stop loss    |
//|  anywhere and no equity cut-off; recovery is what answers a         |
//|  drawdown, and recovery is this EA's only job.                      |
//|                                                                  |
//|  When one side is under water it reads the market with its own      |
//|  indicator stack and asks: do I actually know where price is going? |
//|  Only when the answer is a confident yes does it open a LARGE       |
//|  position in that direction.                                        |
//|                                                                  |
//|  Timing gate - all must hold:                                       |
//|    - the losing basket is past the drawdown trigger                 |
//|      (money, ATR distance, or both)                                 |
//|    - conviction: |score| and ADX above their floors                 |
//|    - the regime genuinely trends / breaks in the hedge direction     |
//|    - both higher timeframes agree                                    |
//|    - NO exhaustion flag in the hedge direction. Hedging into the     |
//|      last gasp of a move is the single worst thing this EA could     |
//|      do, so a stretched-and-stalling reading blocks the trade.       |
//|                                                                  |
//|  Sizing - two parts, which is what makes recovery fast:              |
//|    lock      basketLots x LockRatio                                 |
//|              neutralises further bleed from the losing basket        |
//|    recovery  drawdown / (horizon x moneyPerLot)                      |
//|              the surplus volume that actually earns the loss back    |
//|              over the expected travel distance                       |
//|                                                                  |
//|  The HORIZON is the input that matters most here. Recovering a $450  |
//|  drawdown on gold over a $10 move needs 0.45 extra lots; asking for  |
//|  the same over a $1 move needs 4.50. Short horizons look fast and    |
//|  are how accounts die, so the horizon defaults to a real price       |
//|  distance rather than a small ATR multiple on a 1-minute chart.      |
//|                                                                  |
//|  The group is then handed to EA4, which closes the losing basket     |
//|  and these recovery legs TOGETHER once the group is net positive.    |
//+------------------------------------------------------------------+
#property copyright "krish-mix"
#property link      "https://github.com/kirox0009-boop/krish-mix"
#property version   "1.00"
#property description "KrishMix 3/4 - recovery hedge. Opens large directional volume to earn a drawdown back."
#property description "Sized as lock + recovery surplus. Blocked when the move looks exhausted."

#include <KrishMix\Common.mqh>
#include <KrishMix\StateBus.mqh>
#include <KrishMix\Signals.mqh>
#include <KrishMix\Positions.mqh>
#include <KrishMix\Execution.mqh>
//--- read-only state export for the dashboard
#include <KrishMix\Telemetry.mqh>

//+------------------------------------------------------------------+
enum ENUM_KM3_TRIGGER
  {
   KM3_TRIG_MONEY = 0, // Money drawdown only
   KM3_TRIG_ATR   = 1, // Adverse distance only (ATR multiple)
   KM3_TRIG_BOTH  = 2  // Both must be satisfied
  };

//--- how far price is expected to travel while the recovery works.
//--- This single number sets the recovery lot, so it is the most
//--- important input in this EA. A SHORT horizon demands a huge lot.
enum ENUM_KM3_HORIZON
  {
   KM3_HOR_PRICE = 0, // Price units - broker and timeframe independent
   KM3_HOR_ATR   = 1  // ATR multiple - adapts to volatility
  };

//+------------------------------------------------------------------+
input group "=== Suite wiring (keep identical in all 4 EAs) ==="
input long             InpMagicBase        = KM_MAGIC_BASE_DEFAULT; // Magic base
input double           InpCommissionPerLot = 0.0;   // Round-turn commission per 1.00 lot
input int              InpSlippagePoints   = 40;    // Max deviation, points

input group "=== When to step in ==="
input ENUM_KM3_TRIGGER InpTriggerMode      = KM3_TRIG_BOTH; // Trigger mode
input double           InpTriggerMoney     = 40.0;  // Basket drawdown in money
input double           InpTriggerAtrMult   = 3.00;  // Adverse distance as an ATR multiple
input int              InpMinBasketLegs    = 2;     // Losing basket must hold at least this many legs

input group "=== Conviction gate ==="
input double           InpMinScore         = 55.0;  // |score| floor
input double           InpMinAdx           = 24.0;  // ADX floor
input bool             InpRequireTrendRegime = true;// Regime must trend in the hedge direction
input bool             InpRequireMtfAgree  = true;  // Both higher timeframes must agree
input bool             InpBlockOnExhaustion= true;  // Never hedge into an exhausted move
input double           InpMaxSpreadPoints  = 80;    // Spread allowance (0 = off)

input group "=== Recovery sizing ==="
input double           InpLockRatio        = 1.00;  // Lock part: x the losing basket volume
input ENUM_KM3_HORIZON InpHorizonMode      = KM3_HOR_PRICE; // Recovery horizon mode
input double           InpRecoveryOverPrice= 10.0;  // PRICE mode: recover over this much movement
input double           InpRecoveryAtrTarget= 20.0;  // ATR mode: recover over ATR x this
input double           InpMinHedgeLot      = 0.01;  // Floor for a recovery order
input double           InpMaxHedgeLot      = 2.00;  // Ceiling for a single recovery order
input double           InpMaxHedgeTotal    = 0.0;   // Ceiling for total recovery volume, 0 = unlimited
input double           InpMaxHedgeVsBasket = 12.0;  // Ceiling as a multiple of basket volume (0 = off)

input group "=== Re-hedging ==="
input int              InpMaxHedgeLegs     = 3;     // Max recovery legs per direction (0 = unlimited)
input double           InpRehedgeAtrGap    = 2.50;  // Extra ATR travel before another leg
input int              InpMinSecondsBetween= 120;   // Min seconds between recovery legs

input group "=== Signal engine (EA3's own read) ==="
input int              InpEmaFast          = 8;     // Fast EMA
input int              InpEmaSlow          = 21;    // Slow EMA
input int              InpEmaFilter        = 50;    // Filter EMA
input ENUM_TIMEFRAMES  InpMtf1             = PERIOD_M15; // Higher timeframe 1
input ENUM_TIMEFRAMES  InpMtf2             = PERIOD_H1;  // Higher timeframe 2
input int              InpAdxPeriod        = 14;    // ADX period
input int              InpAtrPeriod        = 14;    // ATR period
input int              InpDonchianPeriod   = 40;    // Donchian lookback

input group "=== Dashboard telemetry (read only) ==="
input bool             InpTelemetry        = true;  // Export state for the dashboard
input int              InpTelemetrySec     = 5;     // Seconds between snapshots

input group "=== Display ==="
input bool             InpShowPanel        = true;  // On-chart panel

//+------------------------------------------------------------------+
CKMBus       Bus;
CKMTelemetry Tel;      // dashboard export, read only
CKMSignals Sig;
CKMBook    Book;
CKMExec    Exec;

struct HedgePlan
  {
   bool        fire;
   ENUM_KM_DIR losingDir;    // side under water
   bool        hedgeIsBuy;   // direction of the recovery order
   double      drawdown;     // positive number, money
   double      excursion;    // adverse distance in price units
   double      lockLot;
   double      recoveryLot;
   double      lot;          // what will actually be sent
   int         legNo;
   string      reason;
  };

HedgePlan g_plan;
int       g_legsFired      = 0;
double    g_lastHedgePrice = 0.0;
datetime  g_lastHedgeTime  = 0;

//+------------------------------------------------------------------+
void ResetPlan(HedgePlan &p)
  {
   p.fire        = false;
   p.losingDir   = KM_DIR_NONE;
   p.hedgeIsBuy  = false;
   p.drawdown    = 0.0;
   p.excursion   = 0.0;
   p.lockLot     = 0.0;
   p.recoveryLot = 0.0;
   p.lot         = 0.0;
   p.legNo       = 0;
   p.reason      = "-";
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   if((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
     {
      Alert("KrishMix needs a HEDGING account. This one is netting.");
      return(INIT_FAILED);
     }

   Bus.Init(_Symbol);
   Book.Init(_Symbol, InpMagicBase, InpCommissionPerLot);
   Exec.Init(_Symbol, InpSlippagePoints, "KM3");

   SignalConfig cfg;
   KM_DefaultSignalConfig(cfg);
   cfg.emaFast        = InpEmaFast;
   cfg.emaSlow        = InpEmaSlow;
   cfg.emaFilter      = InpEmaFilter;
   cfg.mtf1           = InpMtf1;
   cfg.mtf2           = InpMtf2;
   cfg.adxPeriod      = InpAdxPeriod;
   cfg.atrPeriod      = InpAtrPeriod;
   cfg.donchianPeriod = InpDonchianPeriod;
   Sig.Config(cfg);

   if(!Sig.Init(_Symbol, PERIOD_CURRENT))
     {
      Alert("KM3: signal engine failed to initialise.");
      return(INIT_FAILED);
     }

   ResetPlan(g_plan);

   PrintFormat("KM3 Hedge v%s | %s | magic base %I64d -> buy %I64d / sell %I64d",
               KM_VERSION, _Symbol, InpMagicBase,
               KM_Magic(InpMagicBase, KM_EA_HEDGE, true),
               KM_Magic(InpMagicBase, KM_EA_HEDGE, false));
   PrintFormat("KM3 trigger %s: money %.2f | atr x%.2f | conviction score %.0f adx %.0f",
               EnumToString(InpTriggerMode), InpTriggerMoney, InpTriggerAtrMult,
               InpMinScore, InpMinAdx);
   string horizon = (InpHorizonMode == KM3_HOR_ATR)
                    ? StringFormat("ATR x%.2f", InpRecoveryAtrTarget)
                    : StringFormat("%.2f price units", InpRecoveryOverPrice);
   PrintFormat("KM3 sizing: lock %.2fx basket + recovery over %s | max leg %.2f | max %.1fx basket | max total %s",
               InpLockRatio, horizon, InpMaxHedgeLot, InpMaxHedgeVsBasket,
               (InpMaxHedgeTotal > 0.0 ? DoubleToString(InpMaxHedgeTotal, 2) : "unlimited"));
   Print("KM3: a SHORTER recovery horizon means a BIGGER lot. This is the input to tune first.");

   if(InpTelemetry)
     {
      if(Tel.Init("KM3", _Symbol, InpTelemetrySec))
         PrintFormat("KM3 telemetry -> MQL5\\Files\\%s", Tel.FileName());
      else
         Print("KM3 telemetry could not start: ", Tel.LastError());
     }

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   Sig.Release();
   Comment("");
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   Bus.Beat(KM_EA_HEDGE);

   MarketView v;
   if(!Sig.Refresh(v) || !v.valid)
     {
      Panel(v);
      return;
     }

   Book.Scan();

   Plan(v, g_plan);
   Publish();

   if(g_plan.fire)
      Execute(g_plan, v);

   Panel(v);
  }

//+------------------------------------------------------------------+
//| Work out whether a recovery order is justified, and how big.      |
//+------------------------------------------------------------------+
void Plan(const MarketView &v, HedgePlan &p)
  {
   ResetPlan(p);

//--- which side is drowning? -------------------------------------
   ENUM_KM_DIR losing = Book.LosingSide();
   if(losing == KM_DIR_NONE)
     {
      p.reason = "nothing under water";
      return;
     }

   p.losingDir  = losing;
   p.hedgeIsBuy = (losing == KM_DIR_SELL);   // rescue runs with the market

   bool losingIsBuy = (losing == KM_DIR_BUY);

   KMAgg basket;
   Book.AggDirection(losingIsBuy, basket);

   if(basket.count < InpMinBasketLegs)
     {
      p.reason = StringFormat("losing basket has %d leg(s), need %d",
                              basket.count, InpMinBasketLegs);
      return;
     }

   p.drawdown  = MathMax(0.0, -basket.profit);
   p.excursion = Book.AdverseExcursion(losingIsBuy, KM_Bid(_Symbol), KM_Ask(_Symbol));

//--- tradability -------------------------------------------------
   if(!TerminalInfoInteger(TERMINAL_CONNECTED) ||
      !MQLInfoInteger(MQL_TRADE_ALLOWED)       ||
      !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
     {
      p.reason = "trading not allowed";
      return;
     }

   if(InpMaxSpreadPoints > 0.0 && KM_SpreadPoints(_Symbol) > InpMaxSpreadPoints)
     {
      p.reason = StringFormat("spread %.0f > %.0f", KM_SpreadPoints(_Symbol), InpMaxSpreadPoints);
      return;
     }

//--- drawdown trigger --------------------------------------------
   double atrTrigger = v.atr * MathMax(0.1, InpTriggerAtrMult);
   bool   moneyHit   = (p.drawdown  >= InpTriggerMoney);
   bool   atrHit     = (p.excursion >= atrTrigger);

   bool triggered = false;
   switch(InpTriggerMode)
     {
      case KM3_TRIG_MONEY: triggered = moneyHit;             break;
      case KM3_TRIG_ATR:   triggered = atrHit;               break;
      default:             triggered = (moneyHit && atrHit);  break;
     }

   if(!triggered)
     {
      p.reason = StringFormat("below trigger: dd %.2f/%.2f, dist %.2f/%.2f",
                              p.drawdown, InpTriggerMoney, p.excursion, atrTrigger);
      return;
     }

//--- existing recovery exposure ---------------------------------
   KMAgg hedge;
   Book.AggSlot(KM_EA_HEDGE, p.hedgeIsBuy, hedge);
   p.legNo = hedge.count + 1;

   if(InpMaxHedgeLegs > 0 && hedge.count >= InpMaxHedgeLegs)
     {
      p.reason = StringFormat("recovery leg cap %d reached", InpMaxHedgeLegs);
      return;
     }

   if(InpMinSecondsBetween > 0 && g_lastHedgeTime > 0 &&
      (TimeCurrent() - g_lastHedgeTime) < InpMinSecondsBetween)
     {
      p.reason = StringFormat("pacing, %ds since last recovery leg",
                              (int)(TimeCurrent() - g_lastHedgeTime));
      return;
     }

//--- a further leg needs real extra travel, not just a wiggle -----
   if(hedge.count > 0 && g_lastHedgePrice > 0.0 && v.atr > 0.0)
     {
      double gap  = v.atr * MathMax(0.1, InpRehedgeAtrGap);
      double now  = (p.hedgeIsBuy ? KM_Ask(_Symbol) : KM_Bid(_Symbol));
      double move = (p.hedgeIsBuy ? (now - g_lastHedgePrice) : (g_lastHedgePrice - now));

      if(move < gap)
        {
         p.reason = StringFormat("only %.2f of %.2f travel since the last leg", move, gap);
         return;
        }
     }

//--- CONVICTION: do we actually know where price is going? --------
   ENUM_KM_DIR hedgeDir = (p.hedgeIsBuy ? KM_DIR_BUY : KM_DIR_SELL);

   double signedScore = (p.hedgeIsBuy ? v.score : -v.score);
   if(signedScore < InpMinScore)
     {
      p.reason = StringFormat("conviction %.0f < %.0f", signedScore, InpMinScore);
      return;
     }

   if(v.trendStrength < InpMinAdx)
     {
      p.reason = StringFormat("adx %.1f < %.1f", v.trendStrength, InpMinAdx);
      return;
     }

   if(InpRequireTrendRegime && !KM_RegimeFavours(v.regime, hedgeDir))
     {
      p.reason = StringFormat("regime %s does not back the hedge", KM_RegimeName(v.regime));
      return;
     }

   if(InpRequireMtfAgree && !v.mtfAgree)
     {
      p.reason = "higher timeframes disagree";
      return;
     }

//--- the critical check: never chase the last gasp of a move ------
   if(InpBlockOnExhaustion)
     {
      bool exhaustedNow = (p.hedgeIsBuy ? v.bullExhaust : v.bearExhaust);
      if(exhaustedNow)
        {
         p.reason = "move looks exhausted, refusing to hedge into the turn";
         return;
        }
     }

//--- SIZING ------------------------------------------------------
//  lock      : neutralise further bleed from the losing basket
//  recovery  : the surplus that actually earns the drawdown back over
//              the expected travel distance
//
//  The horizon is what controls the size. Recovering $450 over a $10
//  move needs 0.45 extra lots; demanding the same over a $1 move needs
//  4.50 lots. Short horizons look fast and are how accounts die, so the
//  default horizon is a real distance in price units, not a tiny ATR
//  multiple on a 1-minute chart.
   double expectedMove;
   if(InpHorizonMode == KM3_HOR_ATR)
      expectedMove = v.atr * MathMax(0.1, InpRecoveryAtrTarget);
   else
      expectedMove = MathMax(_Point, InpRecoveryOverPrice);

   double perLot = KM_MoneyPerPricePerLot(_Symbol);

   p.lockLot = basket.lots * MathMax(0.0, InpLockRatio);

   if(expectedMove > 0.0 && perLot > 0.0)
      p.recoveryLot = p.drawdown / (expectedMove * perLot);
   else
      p.recoveryLot = 0.0;

   double target = p.lockLot + p.recoveryLot;

//--- sanity ceiling relative to what is being rescued
   if(InpMaxHedgeVsBasket > 0.0 && basket.lots > 0.0)
     {
      double ceiling = basket.lots * InpMaxHedgeVsBasket;
      if(target > ceiling)
        {
         PrintFormat("KM3: recovery target %.2f capped to %.2f (%.1fx basket %.2f)",
                     target, ceiling, InpMaxHedgeVsBasket, basket.lots);
         target = ceiling;
        }
     }

//--- subtract what is already working on the recovery side
   double want = target - hedge.lots;

   if(want <= 0.0)
     {
      p.reason = StringFormat("recovery volume already in place (%.2f of %.2f)",
                              hedge.lots, target);
      return;
     }

   if(InpMaxHedgeTotal > 0.0)
     {
      double room = InpMaxHedgeTotal - hedge.lots;
      if(room <= 0.0)
        {
         p.reason = StringFormat("total recovery cap %.2f reached", InpMaxHedgeTotal);
         return;
        }
      want = MathMin(want, room);
     }

   if(InpMaxHedgeLot > 0.0)
      want = MathMin(want, InpMaxHedgeLot);

   want = MathMax(want, InpMinHedgeLot);
   want = KM_NormalizeLot(_Symbol, want);

//--- margin is a broker fact, not a strategy rule: trim to fit -----
   double affordable = KM_MaxAffordableLot(_Symbol, p.hedgeIsBuy, want);
   if(affordable <= 0.0)
     {
      p.reason = StringFormat("free margin cannot carry %.2f lots", want);
      return;
     }
   if(affordable < want)
     {
      PrintFormat("KM3: trimming recovery %.2f -> %.2f (free margin %.2f)",
                  want, affordable, AccountInfoDouble(ACCOUNT_MARGIN_FREE));
      want = affordable;
     }

   p.lot    = want;
   p.fire   = true;
   p.reason = StringFormat("FIRE leg %d: %.2f lots (lock %.2f + recover %.2f)",
                           p.legNo, p.lot, p.lockLot, p.recoveryLot);
  }

//+------------------------------------------------------------------+
void Execute(HedgePlan &p, const MarketView &v)
  {
   long   magic = KM_Magic(InpMagicBase, KM_EA_HEDGE, p.hedgeIsBuy);
   string note  = StringFormat("R%d|dd%.0f|s%.0f", p.legNo, p.drawdown, v.score);

   ulong ticket = 0;
   if(!Exec.Open(p.hedgeIsBuy, p.lot, magic, 0.0, note, ticket))
     {
      p.reason = Exec.LastError();
      p.fire   = false;
      return;
     }

   g_legsFired++;
   g_lastHedgeTime  = TimeCurrent();
   g_lastHedgePrice = (p.hedgeIsBuy ? KM_Ask(_Symbol) : KM_Bid(_Symbol));

   PrintFormat("KM3 RECOVERY %s %.2f lots (lock %.2f + recover %.2f) | rescuing %s basket dd %.2f over %.2f price | score %.0f adx %.1f %s",
               (p.hedgeIsBuy ? "BUY" : "SELL"), p.lot, p.lockLot, p.recoveryLot,
               (p.losingDir == KM_DIR_BUY ? "BUY" : "SELL"), p.drawdown, p.excursion,
               v.score, v.trendStrength, KM_RegimeName(v.regime));

   p.fire = false;
  }

//+------------------------------------------------------------------+
//| Tell EA4 which group it must judge together                       |
//+------------------------------------------------------------------+
void Publish(void)
  {
   KMAgg hb, hs;
   Book.AggSlot(KM_EA_HEDGE, true,  hb);
   Book.AggSlot(KM_EA_HEDGE, false, hs);

   double lots = hb.lots + hs.lots;
   Bus.Set(KM_KEY_HEDGE_LOTS, lots);

   ENUM_KM_DIR dir = KM_DIR_NONE;
   if(hb.count > 0 && hs.count == 0)
      dir = KM_DIR_BUY;
   else if(hs.count > 0 && hb.count == 0)
      dir = KM_DIR_SELL;
   else if(hb.count > 0 && hs.count > 0)
      dir = (hb.lots >= hs.lots ? KM_DIR_BUY : KM_DIR_SELL);

   Bus.Set(KM_KEY_HEDGE_DIR, (double)dir);

   if(dir != KM_DIR_NONE && g_lastHedgeTime > 0)
      Bus.Set(KM_KEY_HEDGE_TIME, (double)g_lastHedgeTime);
  }

//+------------------------------------------------------------------+
//| Dashboard export. Read only.                                      |
//|                                                                  |
//| The interesting content is the sizing breakdown: how much of the   |
//| order is the lock that neutralises further bleed and how much is    |
//| the surplus that actually earns the drawdown back, plus the exact   |
//| reason when the conviction gate refused to fire.                    |
//+------------------------------------------------------------------+
void WriteTelemetry(const MarketView &v)
  {
   if(!InpTelemetry || !Tel.Enabled() || !Tel.Due())
      return;

   Tel.Begin();
   Tel.SymbolBlock(_Symbol);
   Tel.AccountBlock();

   bool alive[KM_EA_LAST];
   for(int s = KM_EA_FIRST; s <= KM_EA_LAST; s++)
      alive[s - KM_EA_FIRST] = Bus.Alive(s);
   Tel.Roster("roster", alive, KM_EA_LAST - KM_EA_FIRST + 1);

   Tel.Obj("view");
   Tel.Bool("valid",   v.valid);
   Tel.Num("score",    v.score, 1);
   Tel.Str("regime",   KM_RegimeName(v.regime));
   Tel.Str("vol",      KM_VolName(v.volState));
   Tel.Num("atr",      v.atr, _Digits);
   Tel.Num("atrRatio", v.atrRatio, 3);
   Tel.Num("adx",      v.trendStrength, 1);
   Tel.Bool("mtfAgree",    v.mtfAgree);
   Tel.Bool("bullExhaust", v.bullExhaust);
   Tel.Bool("bearExhaust", v.bearExhaust);
   Tel.EndObj();

//--- the baskets this EA is watching, and its own rescue legs
   KMAgg b, sl, hb, hs;
   Book.AggDirection(true,  b);
   Book.AggDirection(false, sl);
   Book.AggSlot(KM_EA_HEDGE, true,  hb);
   Book.AggSlot(KM_EA_HEDGE, false, hs);

   Tel.Obj("baskets");
   Tel.Obj("buy");
   Tel.Int("legs", b.count);  Tel.Num("lots", b.lots, 2);
   Tel.Num("profit", b.profit, 2); Tel.Num("avgPrice", b.avgPrice, _Digits);
   Tel.EndObj();
   Tel.Obj("sell");
   Tel.Int("legs", sl.count); Tel.Num("lots", sl.lots, 2);
   Tel.Num("profit", sl.profit, 2); Tel.Num("avgPrice", sl.avgPrice, _Digits);
   Tel.EndObj();
   Tel.EndObj();

   Tel.Obj("recoveryLegs");
   Tel.Int("buyCount",  hb.count);  Tel.Num("buyLots",  hb.lots, 2);
   Tel.Int("sellCount", hs.count);  Tel.Num("sellLots", hs.lots, 2);
   Tel.Num("profit",    hb.profit + hs.profit, 2);
   Tel.EndObj();

//--- the current plan, fired or not
   Tel.Obj("plan");
   Tel.Bool("wouldFire", g_plan.fire);
   Tel.Str("losingSide", (g_plan.losingDir == KM_DIR_BUY ? "BUY" :
                          (g_plan.losingDir == KM_DIR_SELL ? "SELL" : "-")));
   Tel.Str("hedgeSide",  (g_plan.hedgeIsBuy ? "BUY" : "SELL"));
   Tel.Num("drawdown",   g_plan.drawdown, 2);
   Tel.Num("excursion",  g_plan.excursion, _Digits);
   Tel.Num("lockLot",    g_plan.lockLot, 2);
   Tel.Num("recoveryLot", g_plan.recoveryLot, 2);
   Tel.Num("lot",        g_plan.lot, 2);
   Tel.Int("legNo",      g_plan.legNo);
   Tel.Str("reason",     g_plan.reason);
   Tel.EndObj();

   Tel.Obj("history");
   Tel.Int("legsFired",   g_legsFired);
   Tel.Int("lastFiredTs", (long)g_lastHedgeTime);
   Tel.Num("lastFiredPrice", g_lastHedgePrice, _Digits);
   Tel.EndObj();

   Tel.Obj("config");
   Tel.Str("triggerMode",    EnumToString(InpTriggerMode));
   Tel.Num("triggerMoney",   InpTriggerMoney, 2);
   Tel.Num("triggerAtrMult", InpTriggerAtrMult, 2);
   Tel.Str("horizonMode",    EnumToString(InpHorizonMode));
   Tel.Num("recoveryOverPrice", InpRecoveryOverPrice, 2);
   Tel.Num("recoveryAtrTarget", InpRecoveryAtrTarget, 2);
   Tel.Num("lockRatio",      InpLockRatio, 2);
   Tel.Num("minScore",       InpMinScore, 0);
   Tel.Num("minAdx",         InpMinAdx, 0);
   Tel.Num("maxHedgeLot",    InpMaxHedgeLot, 2);
   Tel.Num("maxHedgeVsBasket", InpMaxHedgeVsBasket, 1);
   Tel.Bool("blockOnExhaustion", InpBlockOnExhaustion);
   Tel.EndObj();

   Tel.HealthBlock();
   Tel.End();
  }

//+------------------------------------------------------------------+
void Panel(const MarketView &v)
  {
//--- exported here because every OnTick exit path reaches Panel()
   WriteTelemetry(v);

   if(!InpShowPanel)
      return;

   static datetime last = 0;
   datetime now = TimeCurrent();
   if(now == last)
      return;
   last = now;

   KMAgg b, s, hb, hs;
   Book.AggDirection(true,  b);
   Book.AggDirection(false, s);
   Book.AggSlot(KM_EA_HEDGE, true,  hb);
   Book.AggSlot(KM_EA_HEDGE, false, hs);
   string cur = AccountInfoString(ACCOUNT_CURRENCY);

   string t = "==== KM3  RECOVERY HEDGE ====\n";
   t += StringFormat("%s   spread %.0f pts\n", _Symbol, KM_SpreadPoints(_Symbol));
   t += "Suite: " + Bus.Roster() + "\n";
   t += "------------------------------\n";

   if(v.valid)
     {
      t += StringFormat("score %+6.1f  adx %5.1f  regime %s\n",
                        v.score, v.trendStrength, KM_RegimeName(v.regime));
      t += StringFormat("vol %s (atr x%.2f)   atr %.*f\n",
                        KM_VolName(v.volState), v.atrRatio, _Digits, v.atr);
      if(v.bullExhaust) t += "flag: BULL EXHAUSTION - long hedge blocked\n";
      if(v.bearExhaust) t += "flag: BEAR EXHAUSTION - short hedge blocked\n";
     }
   else
      t += "market view: warming up\n";

   t += "------------------------------\n";
   t += StringFormat("BUY basket  %d  %.2f lots  %.2f %s\n", b.count, b.lots, b.profit, cur);
   t += StringFormat("SELL basket %d  %.2f lots  %.2f %s\n", s.count, s.lots, s.profit, cur);
   t += StringFormat("recovery legs: buy %d (%.2f) sell %d (%.2f)\n",
                     hb.count, hb.lots, hs.count, hs.lots);
   t += "------------------------------\n";

   if(g_plan.losingDir != KM_DIR_NONE)
     {
      t += StringFormat("under water: %s  dd %.2f %s  dist %.2f\n",
                        (g_plan.losingDir == KM_DIR_BUY ? "BUY" : "SELL"),
                        g_plan.drawdown, cur, g_plan.excursion);
      if(g_plan.lockLot > 0.0 || g_plan.recoveryLot > 0.0)
         t += StringFormat("sizing: lock %.2f + recover %.2f\n", g_plan.lockLot, g_plan.recoveryLot);
     }

   t += "-> " + g_plan.reason + "\n";
   t += StringFormat("legs fired: %d\n", g_legsFired);
   t += StringFormat("free margin %.2f %s\n", AccountInfoDouble(ACCOUNT_MARGIN_FREE), cur);

   Comment(t);
  }
//+------------------------------------------------------------------+
