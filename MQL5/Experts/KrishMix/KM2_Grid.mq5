//+------------------------------------------------------------------+
//|                                               KM2_Grid.mq5       |
//|                                                                  |
//|  KRISHMIX EA 2 of 4  -  GRID / AVERAGING BRAIN                     |
//|                                                                  |
//|  EA1 enters without a stop loss. When price runs the other way,    |
//|  this EA takes over that side and answers three questions on every |
//|  bar, using its own independent indicator stack:                   |
//|                                                                  |
//|    1. ADD or WAIT?                                                 |
//|         It refuses to average into a market that is still pushing   |
//|         hard against the basket. Adding is allowed when the push    |
//|         has cooled, or when an exhaustion flag says the move is     |
//|         running out of sellers / buyers. Waiting through a strong   |
//|         leg and adding near its end is worth far more than adding   |
//|         mechanically every N points.                               |
//|                                                                  |
//|    2. AT WHAT DISTANCE?                                            |
//|         ATR based, then stretched or tightened by regime:           |
//|           trending against the basket  -> much wider               |
//|           exhaustion flag present      -> tighter, the turn is near|
//|           high / extreme volatility    -> wider                    |
//|           deeper level                 -> progressively wider       |
//|                                                                  |
//|    3. WHAT LOT?                                                    |
//|         A smooth progression (additive by default: 0.01, 0.02,      |
//|         0.03 ...), then scaled DOWN while the market is still       |
//|         hostile and allowed full size when the reading supports      |
//|         a turn. Aggressive doubling is available but off.            |
//|                                                                  |
//|  Grid legs are sent WITHOUT a stop loss and, by default, without a  |
//|  take profit: EA4 owns the exit and closes them as a basket.        |
//|                                                                  |
//|  There is deliberately NO equity-percentage cut-off and no halt     |
//|  state. Drawdown is answered by EA3's hedge and EA4's basket exit.  |
//+------------------------------------------------------------------+
#property copyright "krish-mix"
#property link      "https://github.com/kirox0009-boop/krish-mix"
#property version   "1.00"
#property description "KrishMix 2/4 - decides whether to grid, at what distance, and with what lot."
#property description "Refuses to average into a market still pushing against the basket."

#include <KrishMix\Common.mqh>
#include <KrishMix\StateBus.mqh>
#include <KrishMix\Signals.mqh>
#include <KrishMix\Positions.mqh>
#include <KrishMix\Execution.mqh>
//--- read-only state export for the dashboard
#include <KrishMix\Telemetry.mqh>

//+------------------------------------------------------------------+
enum ENUM_KM2_LOTMODE
  {
   KM2_LOT_FIXED    = 0, // Fixed - same lot every level
   KM2_LOT_ADDITIVE = 1, // Additive - 0.01, 0.02, 0.03 ... (smooth)
   KM2_LOT_MULTIPLY = 2  // Multiply - base * factor^(level-1)
  };

//+------------------------------------------------------------------+
input group "=== Suite wiring (keep identical in all 4 EAs) ==="
input long             InpMagicBase        = KM_MAGIC_BASE_DEFAULT; // Magic base
input double           InpCommissionPerLot = 0.0;   // Round-turn commission per 1.00 lot
input int              InpSlippagePoints   = 30;    // Max deviation, points

input group "=== Lot progression ==="
input double           InpBaseLot          = 0.01;  // Base lot (match EA1's entry lot)
input ENUM_KM2_LOTMODE InpLotMode          = KM2_LOT_ADDITIVE; // Progression mode
input double           InpLotIncrement     = 0.01;  // Additive: added per level
input double           InpLotMultiplier    = 1.25;  // Multiply: factor per level
input double           InpMaxLotPerAdd     = 1.00;  // Cap for a single grid order
input double           InpCautiousLotScale = 0.50;  // Lot scale while the market is still hostile

input group "=== Distance ==="
input double           InpAtrStepMult      = 1.20;  // Base step = ATR x this
input double           InpMinStepPrice     = 1.00;  // Never closer than this (price units)
input double           InpTrendWidenMult   = 1.80;  // Widen when trending against the basket
input double           InpExhaustTighten   = 0.75;  // Tighten when exhaustion is flagged
input double           InpHighVolWiden     = 1.30;  // Widen in HIGH volatility
input double           InpExtremeVolWiden  = 1.80;  // Widen in EXTREME volatility
input double           InpLevelWiden       = 1.08;  // Extra widening per level

input group "=== Add or wait ==="
input double           InpMaxPressureToAdd = 55.0;  // Above this pressure, wait (unless exhausted)
input bool             InpWaitOnExtremeVol = true;  // Never add during an EXTREME volatility spike
input bool             InpWaitOnBreakout   = true;  // Never add into a breakout going against us
input bool             InpRequireBarClose  = true;  // Decide on closed bars only
input int              InpMinSecondsBetween= 45;    // Min seconds between two adds
input bool             InpOnlyLosingSide   = true;  // Average only a basket that is under water

input group "=== Exposure (0 = unlimited) ==="
input int              InpMaxLevels        = 0;     // Max levels per direction, 0 = unlimited
input double           InpMaxLotsPerSide   = 0.0;   // Max volume per direction, 0 = unlimited

input group "=== Grid leg take profit ==="
input bool             InpSetTpOnGridLegs  = false; // Give grid legs their own TP
input double           InpGridTpAtrMult    = 2.50;  // That TP as an ATR multiple

input group "=== Signal engine (EA2's own read) ==="
input int              InpEmaFast          = 8;     // Fast EMA
input int              InpEmaSlow          = 21;    // Slow EMA
input int              InpEmaFilter        = 50;    // Filter EMA
input ENUM_TIMEFRAMES  InpMtf1             = PERIOD_M15; // Higher timeframe 1
input ENUM_TIMEFRAMES  InpMtf2             = PERIOD_H1;  // Higher timeframe 2
input int              InpAdxPeriod        = 14;    // ADX period
input int              InpAtrPeriod        = 14;    // ATR period
input int              InpDonchianPeriod   = 40;    // Donchian lookback
input bool             InpCrossCheckEA1    = false; // Also require EA1's published view to agree

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

//--- one decision, fully explained, so the panel and log can show why
struct GridPlan
  {
   bool    add;
   double  distance;    // required adverse distance, price units
   double  achieved;    // distance actually travelled from the anchor
   double  lot;
   int     level;       // level this add would become
   double  pressure;
   bool    exhausted;
   string  reason;
  };

GridPlan g_planBuy, g_planSell;
int      g_addsBuy = 0, g_addsSell = 0;

//--- bar of the last add per side, for the one-add-per-bar rule
datetime g_lastAddBarBuy  = 0;
datetime g_lastAddBarSell = 0;

//+------------------------------------------------------------------+
void ResetPlan(GridPlan &p)
  {
   p.add       = false;
   p.distance  = 0.0;
   p.achieved  = 0.0;
   p.lot       = 0.0;
   p.level     = 0;
   p.pressure  = 0.0;
   p.exhausted = false;
   p.reason    = "-";
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   if((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
     {
      Alert("KrishMix needs a HEDGING account. This one is netting.");
      return(INIT_FAILED);
     }

   if(InpBaseLot <= 0.0)
     {
      Alert("Base lot must be greater than zero.");
      return(INIT_FAILED);
     }

   Bus.Init(_Symbol);
   Book.Init(_Symbol, InpMagicBase, InpCommissionPerLot);
   Exec.Init(_Symbol, InpSlippagePoints, "KM2");

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
      Alert("KM2: signal engine failed to initialise.");
      return(INIT_FAILED);
     }

   ResetPlan(g_planBuy);
   ResetPlan(g_planSell);

   PrintFormat("KM2 Grid v%s | %s | magic base %I64d -> buy %I64d / sell %I64d",
               KM_VERSION, _Symbol, InpMagicBase,
               KM_Magic(InpMagicBase, KM_EA_GRID, true),
               KM_Magic(InpMagicBase, KM_EA_GRID, false));
   PrintFormat("KM2 lot plan %s: L1=%.2f L2=%.2f L3=%.2f L4=%.2f L5=%.2f (cautious scale %.2f)",
               EnumToString(InpLotMode), LotForLevel(1), LotForLevel(2), LotForLevel(3),
               LotForLevel(4), LotForLevel(5), InpCautiousLotScale);
   if(InpTelemetry)
     {
      if(Tel.Init("KM2", _Symbol, InpTelemetrySec))
         PrintFormat("KM2 telemetry -> MQL5\\Files\\%s", Tel.FileName());
      else
         Print("KM2 telemetry could not start: ", Tel.LastError());
     }

   PrintFormat("KM2 exposure caps: levels %s | volume %s",
               (InpMaxLevels > 0 ? IntegerToString(InpMaxLevels) : "unlimited"),
               (InpMaxLotsPerSide > 0.0 ? DoubleToString(InpMaxLotsPerSide, 2) : "unlimited"));

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
   Bus.Beat(KM_EA_GRID);

   MarketView v;
   if(!Sig.Refresh(v) || !v.valid)
     {
      Panel(v);
      return;
     }

   Book.Scan();

//--- plan both sides, then act
   Plan(v, true,  g_planBuy);
   Plan(v, false, g_planSell);

   Publish();

   if(g_planBuy.add)
      Execute(true, g_planBuy, v);
   if(g_planSell.add)
      Execute(false, g_planSell, v);

   Panel(v);
  }

//+------------------------------------------------------------------+
//| Lot for a grid level, computed from the level itself so a gentle  |
//| multiplier still grows instead of stalling on volume rounding.    |
//+------------------------------------------------------------------+
double LotForLevel(const int level)
  {
   int lv = MathMax(1, level);
   double lot;

   switch(InpLotMode)
     {
      case KM2_LOT_ADDITIVE:
         lot = InpBaseLot + (lv - 1) * MathMax(0.0, InpLotIncrement);
         break;
      case KM2_LOT_MULTIPLY:
         lot = InpBaseLot * MathPow(MathMax(1.0, InpLotMultiplier), lv - 1);
         break;
      default:
         lot = InpBaseLot;
         break;
     }

   if(InpMaxLotPerAdd > 0.0)
      lot = MathMin(lot, InpMaxLotPerAdd);

   return KM_NormalizeLot(_Symbol, lot);
  }

//+------------------------------------------------------------------+
//| The required adverse distance for the next level                 |
//+------------------------------------------------------------------+
double RequiredDistance(const MarketView &v, const ENUM_KM_DIR dir,
                        const int level, const bool exhausted)
  {
   double base = v.atr * MathMax(0.1, InpAtrStepMult);
   if(base <= 0.0)
      base = InpMinStepPrice;

   double mult = 1.0;

//--- the market is trending against this basket: stand well back
   ENUM_KM_DIR against = (dir == KM_DIR_BUY ? KM_DIR_SELL : KM_DIR_BUY);
   if(KM_RegimeFavours(v.regime, against))
      mult *= MathMax(1.0, InpTrendWidenMult);

//--- a turn is being flagged: it is worth adding closer
   if(exhausted)
      mult *= MathMax(0.1, InpExhaustTighten);

//--- volatility
   if(v.volState == KM_VOL_HIGH)
      mult *= MathMax(1.0, InpHighVolWiden);
   else if(v.volState == KM_VOL_EXTREME)
      mult *= MathMax(1.0, InpExtremeVolWiden);

//--- deeper levels stand further apart
   if(InpLevelWiden > 1.0 && level > 2)
      mult *= MathPow(InpLevelWiden, level - 2);

   double dist = base * mult;

//--- never inside the floor, and never inside a few spreads
   double spreadPrice = KM_SpreadPoints(_Symbol) * _Point;
   return MathMax(dist, MathMax(InpMinStepPrice, spreadPrice * 4.0));
  }

//+------------------------------------------------------------------+
//| Decide for one side                                              |
//+------------------------------------------------------------------+
void Plan(const MarketView &v, const bool isBuy, GridPlan &p)
  {
   ResetPlan(p);

   ENUM_KM_DIR dir = (isBuy ? KM_DIR_BUY : KM_DIR_SELL);

   KMAgg side;
   Book.AggDirection(isBuy, side);

   if(side.count == 0)
     {
      p.reason = "no basket on this side";
      return;
     }

   p.level     = side.count + 1;
   p.pressure  = Sig.PressureAgainst(v, dir);
   p.exhausted = Sig.ExhaustedAgainst(v, dir);

//--- only average a basket that is actually under water ------------
   if(InpOnlyLosingSide && side.profit >= 0.0)
     {
      p.reason = "basket is in profit, nothing to average";
      return;
     }

//--- tradability ---------------------------------------------------
   if(!TerminalInfoInteger(TERMINAL_CONNECTED) ||
      !MQLInfoInteger(MQL_TRADE_ALLOWED)       ||
      !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
     {
      p.reason = "trading not allowed";
      return;
     }

//--- pacing --------------------------------------------------------
   if(InpMinSecondsBetween > 0 && side.lastOpen > 0 &&
      (TimeCurrent() - side.lastOpen) < InpMinSecondsBetween)
     {
      p.reason = StringFormat("pacing, %ds since last leg",
                              (int)(TimeCurrent() - side.lastOpen));
      return;
     }

//--- at most one add per bar per side
   if(InpRequireBarClose)
     {
      datetime bar     = (datetime)SeriesInfoInteger(_Symbol, PERIOD_CURRENT, SERIES_LASTBAR_DATE);
      datetime lastBar = (isBuy ? g_lastAddBarBuy : g_lastAddBarSell);
      if(bar == lastBar)
        {
         p.reason = "already added on this bar";
         return;
        }
     }

//--- optional exposure caps (unlimited by default) -----------------
   if(InpMaxLevels > 0 && side.count >= InpMaxLevels)
     {
      p.reason = StringFormat("level cap %d reached", InpMaxLevels);
      return;
     }
   if(InpMaxLotsPerSide > 0.0 && side.lots >= InpMaxLotsPerSide)
     {
      p.reason = StringFormat("volume cap %.2f reached", InpMaxLotsPerSide);
      return;
     }

//--- ADD or WAIT: the core judgement -----------------------------
   if(InpWaitOnExtremeVol && v.volState == KM_VOL_EXTREME)
     {
      p.reason = StringFormat("waiting out EXTREME volatility (atr x%.2f)", v.atrRatio);
      return;
     }

   ENUM_KM_DIR against = (isBuy ? KM_DIR_SELL : KM_DIR_BUY);

   if(InpWaitOnBreakout &&
      ((against == KM_DIR_SELL && v.regime == KM_REGIME_BREAKOUT_DN) ||
       (against == KM_DIR_BUY  && v.regime == KM_REGIME_BREAKOUT_UP)))
     {
      p.reason = "waiting out a breakout against the basket";
      return;
     }

   if(p.pressure > InpMaxPressureToAdd && !p.exhausted)
     {
      p.reason = StringFormat("pressure %.0f still too high, waiting", p.pressure);
      return;
     }

   if(InpCrossCheckEA1 && Bus.ViewFresh())
     {
      //--- EA1's independent read must not be screaming the other way
      double ea1Against = (isBuy ? -Bus.Score() : Bus.Score());
      if(ea1Against > InpMaxPressureToAdd && !p.exhausted)
        {
         p.reason = StringFormat("EA1 view still against (%.0f)", ea1Against);
         return;
        }
     }

//--- distance ---------------------------------------------------
   double anchor = Book.GridAnchor(isBuy);
   double now    = (isBuy ? KM_Ask(_Symbol) : KM_Bid(_Symbol));

   p.achieved = (isBuy ? (anchor - now) : (now - anchor));
   p.distance = RequiredDistance(v, dir, p.level, p.exhausted);

   if(p.achieved < p.distance)
     {
      p.reason = StringFormat("distance %.2f of %.2f", p.achieved, p.distance);
      return;
     }

//--- lot -------------------------------------------------------
   double lot = LotForLevel(p.level);

//--- still hostile but distance is met: take a smaller bite
   if(!p.exhausted && p.pressure > (InpMaxPressureToAdd * 0.6))
      lot = KM_NormalizeLot(_Symbol, lot * MathMax(0.1, InpCautiousLotScale));

//--- respect the volume cap if one is set
   if(InpMaxLotsPerSide > 0.0 && (side.lots + lot) > InpMaxLotsPerSide)
     {
      double room = KM_NormalizeLot(_Symbol, InpMaxLotsPerSide - side.lots);
      if(room < SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN))
        {
         p.reason = "no room left under the volume cap";
         return;
        }
      lot = room;
     }

   p.lot = lot;
   p.add = true;
   p.reason = StringFormat("ADD L%d %.2f lots (%s, pressure %.0f)",
                           p.level, lot,
                           (p.exhausted ? "exhaustion flagged" : "pressure cooled"),
                           p.pressure);
  }

//+------------------------------------------------------------------+
void Execute(const bool isBuy, GridPlan &p, const MarketView &v)
  {
   double tp = 0.0;
   if(InpSetTpOnGridLegs && v.atr > 0.0)
     {
      double d = v.atr * MathMax(0.1, InpGridTpAtrMult);
      double e = isBuy ? KM_Ask(_Symbol) : KM_Bid(_Symbol);
      tp = isBuy ? (e + d) : (e - d);
     }

   long   magic = KM_Magic(InpMagicBase, KM_EA_GRID, isBuy);
   string note  = StringFormat("L%d|%s|p%.0f", p.level,
                               (p.exhausted ? "exh" : "cool"), p.pressure);

   ulong ticket = 0;
   if(!Exec.Open(isBuy, p.lot, magic, tp, note, ticket))
     {
      p.reason = Exec.LastError();
      p.add    = false;
      return;
     }

   datetime bar = (datetime)SeriesInfoInteger(_Symbol, PERIOD_CURRENT, SERIES_LASTBAR_DATE);
   if(isBuy)
     {
      g_addsBuy++;
      g_lastAddBarBuy = bar;
     }
   else
     {
      g_addsSell++;
      g_lastAddBarSell = bar;
     }

   PrintFormat("KM2 GRID %s L%d %.2f lots | travelled %.2f of %.2f | %s | pressure %.0f | regime %s | atr %.*f",
               (isBuy ? "BUY" : "SELL"), p.level, p.lot, p.achieved, p.distance,
               (p.exhausted ? "EXHAUSTION" : "pressure cooled"), p.pressure,
               KM_RegimeName(v.regime), _Digits, v.atr);

   p.add = false;
  }

//+------------------------------------------------------------------+
//| Share the grid state so EA3 and EA4 can see how deep we are      |
//+------------------------------------------------------------------+
void Publish(void)
  {
   KMAgg b, s;
   Book.AggDirection(true,  b);
   Book.AggDirection(false, s);

   Bus.Set(KM_KEY_GRID_LVL_BUY,  (double)b.count);
   Bus.Set(KM_KEY_GRID_LVL_SELL, (double)s.count);
   Bus.Set(KM_KEY_GRID_WAIT,
           ((!g_planBuy.add && b.count > 0) || (!g_planSell.add && s.count > 0)) ? 1.0 : 0.0);

   if(b.count > 0 && g_planBuy.distance > 0.0)
      Bus.Set(KM_KEY_GRID_NEXT_BUY, Book.GridAnchor(true) - g_planBuy.distance);
   if(s.count > 0 && g_planSell.distance > 0.0)
      Bus.Set(KM_KEY_GRID_NEXT_SELL, Book.GridAnchor(false) + g_planSell.distance);
  }

//+------------------------------------------------------------------+
//| Dashboard export. Read only, and taken here because every exit    |
//| path from OnTick passes through Panel().                          |
//|                                                                  |
//| The valuable part for a dashboard is not that the grid added a     |
//| level - it is the plan behind the decision: how far price has to   |
//| travel, how far it actually has, how hard the market is still      |
//| pushing, and the reason string when the answer was to wait.        |
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
   Tel.Bool("bullExhaust", v.bullExhaust);
   Tel.Bool("bearExhaust", v.bearExhaust);
   Tel.EndObj();

//--- both sides, each with its basket and its plan
   Tel.Arr("sides");
   for(int pass = 0; pass < 2; pass++)
     {
      bool isBuy = (pass == 0);

      KMAgg a;
      Book.AggDirection(isBuy, a);

      Tel.ArrObj();
      Tel.Str("side", (isBuy ? "BUY" : "SELL"));

      Tel.Obj("basket");
      Tel.Int("legs",     a.count);
      Tel.Num("lots",     a.lots, 2);
      Tel.Num("profit",   a.profit, 2);
      Tel.Num("avgPrice", a.avgPrice, _Digits);
      Tel.Num("anchor",   Book.GridAnchor(isBuy), _Digits);
      Tel.Int("lastOpen", (long)a.lastOpen);
      Tel.EndObj();

      Tel.Obj("plan");
      Tel.Bool("wouldAdd",  (isBuy ? g_planBuy.add       : g_planSell.add));
      Tel.Int("level",      (isBuy ? g_planBuy.level     : g_planSell.level));
      Tel.Num("needed",     (isBuy ? g_planBuy.distance  : g_planSell.distance), _Digits);
      Tel.Num("travelled",  (isBuy ? g_planBuy.achieved  : g_planSell.achieved), _Digits);
      Tel.Num("pressure",   (isBuy ? g_planBuy.pressure  : g_planSell.pressure), 0);
      Tel.Bool("exhausted", (isBuy ? g_planBuy.exhausted : g_planSell.exhausted));
      Tel.Num("nextLot",    LotForLevel(isBuy ? g_planBuy.level : g_planSell.level), 2);
      Tel.Str("reason",     (isBuy ? g_planBuy.reason    : g_planSell.reason));
      Tel.EndObj();

      Tel.Int("addsMade", (isBuy ? g_addsBuy : g_addsSell));
      Tel.EndObj();
     }
   Tel.EndArr();

   Tel.Obj("config");
   Tel.Str("lotMode",          EnumToString(InpLotMode));
   Tel.Num("baseLot",          InpBaseLot, 2);
   Tel.Num("lotIncrement",     InpLotIncrement, 2);
   Tel.Num("atrStepMult",      InpAtrStepMult, 2);
   Tel.Num("minStepPrice",     InpMinStepPrice, 2);
   Tel.Num("maxPressureToAdd", InpMaxPressureToAdd, 0);
   Tel.Num("cautiousLotScale", InpCautiousLotScale, 2);
   Tel.Int("maxLevels",        InpMaxLevels);
   Tel.Num("maxLotsPerSide",   InpMaxLotsPerSide, 2);
   Tel.Bool("onlyLosingSide",  InpOnlyLosingSide);
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

   KMAgg b, s;
   Book.AggDirection(true,  b);
   Book.AggDirection(false, s);
   string cur = AccountInfoString(ACCOUNT_CURRENCY);

   string t = "==== KM2  GRID BRAIN ====\n";
   t += StringFormat("%s   spread %.0f pts\n", _Symbol, KM_SpreadPoints(_Symbol));
   t += "Suite: " + Bus.Roster() + "\n";
   t += "---------------------------\n";

   if(v.valid)
      t += StringFormat("score %+6.1f  adx %5.1f  regime %s  vol %s\n",
                        v.score, v.trendStrength, KM_RegimeName(v.regime), KM_VolName(v.volState));
   else
      t += "market view: warming up\n";

   t += "---------------------------\n";
   t += StringFormat("BUY basket  %d lvl  %.2f lots  %.2f %s\n", b.count, b.lots, b.profit, cur);
   if(b.count > 0)
     {
      t += StringFormat("  avg %.*f  anchor %.*f\n", _Digits, b.avgPrice, _Digits, Book.GridAnchor(true));
      t += StringFormat("  next L%d needs %.2f, travelled %.2f\n",
                        g_planBuy.level, g_planBuy.distance, g_planBuy.achieved);
      t += StringFormat("  lot %.2f  pressure %.0f%s\n", LotForLevel(g_planBuy.level),
                        g_planBuy.pressure, (g_planBuy.exhausted ? "  EXHAUSTED" : ""));
      t += "  -> " + g_planBuy.reason + "\n";
     }

   t += StringFormat("SELL basket %d lvl  %.2f lots  %.2f %s\n", s.count, s.lots, s.profit, cur);
   if(s.count > 0)
     {
      t += StringFormat("  avg %.*f  anchor %.*f\n", _Digits, s.avgPrice, _Digits, Book.GridAnchor(false));
      t += StringFormat("  next L%d needs %.2f, travelled %.2f\n",
                        g_planSell.level, g_planSell.distance, g_planSell.achieved);
      t += StringFormat("  lot %.2f  pressure %.0f%s\n", LotForLevel(g_planSell.level),
                        g_planSell.pressure, (g_planSell.exhausted ? "  EXHAUSTED" : ""));
      t += "  -> " + g_planSell.reason + "\n";
     }

   t += "---------------------------\n";
   t += StringFormat("adds: buy %d  sell %d\n", g_addsBuy, g_addsSell);
   t += StringFormat("free margin %.2f %s\n", AccountInfoDouble(ACCOUNT_MARGIN_FREE), cur);

   Comment(t);
  }
//+------------------------------------------------------------------+
