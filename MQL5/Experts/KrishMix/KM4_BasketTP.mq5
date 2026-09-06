//+------------------------------------------------------------------+
//|                                           KM4_BasketTP.mq5       |
//|                                                                  |
//|  KRISHMIX EA 4 of 4  -  ADAPTIVE BASKET EXIT                       |
//|                                                                  |
//|  The only EA in the suite that closes anything. Nothing here uses   |
//|  a fixed take profit: the target is recomputed from the market on   |
//|  every bar, because what a basket is worth waiting for in a strong  |
//|  trend is not what it is worth waiting for in a dead range.         |
//|                                                                  |
//|  THREE GROUPS, judged in this order                                 |
//|                                                                  |
//|    1. RECOVERY GROUP   a drowning basket PLUS the EA3 legs opened   |
//|                        to rescue it. These must be judged together  |
//|                        - the rescue leg's gain is what lifts the     |
//|                        group out. Closing them separately would      |
//|                        throw away the whole point of the hedge.      |
//|    2. DIRECTION BASKET every buy leg, or every sell leg, on its own. |
//|                        The normal harvest when there is no hedge.     |
//|    3. WHOLE BOOK       optional last sweep when everything together  |
//|                        is net positive.                              |
//|                                                                  |
//|  HOW THE TARGET MOVES                                               |
//|    base            money per 1.00 lot x the group's volume, so the   |
//|                    ask scales with the exposure being carried        |
//|    trend with us   RAISE the target, let a good move pay more        |
//|    trend against   LOWER it, take what is there before it goes       |
//|    range           slightly lower, moves are small                   |
//|    volatility      raise in HIGH / EXTREME, lower in LOW             |
//|    exhaustion      lower - the move that is paying us is ending      |
//|    depth relief    each extra leg LOWERS the bar, so a deep basket   |
//|                    escapes instead of holding out for a full win     |
//|    age relief      the longer it has been carried, the lower the ask |
//|                                                                  |
//|  INVARIANT: a group is only ever closed in PROFIT. The target floor  |
//|  is always positive, so no relief factor can turn this into a loss   |
//|  cut. There is no equity percentage rule and no halt state anywhere. |
//+------------------------------------------------------------------+
#property copyright "krish-mix"
#property link      "https://github.com/kirox0009-boop/krish-mix"
#property version   "1.00"
#property description "KrishMix 4/4 - adaptive basket exit. Recomputes the basket target from market conditions."
#property description "Closes recovery groups, direction baskets or the whole book - only ever in profit."

#include <KrishMix\Common.mqh>
#include <KrishMix\StateBus.mqh>
#include <KrishMix\Signals.mqh>
#include <KrishMix\Positions.mqh>
#include <KrishMix\Execution.mqh>

//+------------------------------------------------------------------+
input group "=== Suite wiring (keep identical in all 4 EAs) ==="
input long             InpMagicBase        = KM_MAGIC_BASE_DEFAULT; // Magic base
input double           InpCommissionPerLot = 0.0;   // Round-turn commission per 1.00 lot
input int              InpSlippagePoints   = 40;    // Max deviation, points

input group "=== Base target ==="
input double           InpTargetPerLot     = 25.0;  // Money per 1.00 lot of group volume
input double           InpMinTarget         = 1.00;  // Absolute floor, always > 0
input double           InpMaxTarget         = 0.0;   // Absolute ceiling, 0 = none

input group "=== Regime shaping ==="
input double           InpTrendWithFactor  = 1.60;  // Trend running our way: ask for more
input double           InpTrendAgainstFactor = 0.60;// Trend against: take it sooner
input double           InpRangeFactor      = 0.85;  // Ranging market
input double           InpExhaustFactor    = 0.70;  // Our move looks exhausted: take it

input group "=== Volatility shaping ==="
input double           InpLowVolFactor     = 0.80;  // Compressed volatility
input double           InpHighVolFactor    = 1.30;  // Elevated volatility
input double           InpExtremeVolFactor = 1.50;  // Extreme volatility

input group "=== Relief (deep and old baskets get easier to close) ==="
input int              InpDepthReliefFrom  = 3;     // Relief starts past this many legs
input double           InpDepthReliefStep  = 0.92;  // Multiplier per extra leg
input double           InpAgeReliefPerHour = 0.97;  // Multiplier per hour carried
input double           InpMinReliefFloor   = 0.15;  // Combined relief never below this

input group "=== Groups to manage ==="
input bool             InpCloseRecoveryGrp = true;  // Close a losing basket together with its hedge
input bool             InpCloseDirection   = true;  // Close plain buy / sell baskets
input bool             InpCloseWholeBook   = true;  // Final sweep on the whole book
input double           InpWholeBookFactor  = 1.20;  // Whole-book target multiplier

input group "=== Trailing ==="
input bool             InpUseTrailing      = false; // Ride past the target before closing
input double           InpTrailGiveback    = 0.35;  // Give back this fraction of the peak

input group "=== Leg take profits ==="
input bool             InpStripTpWhenDeep  = false; // Remove EA1 leg TPs once a basket is deep
input int              InpStripTpFromLegs  = 4;     // Depth at which to strip them

input group "=== Signal engine (EA4's own read) ==="
input int              InpEmaFast          = 8;     // Fast EMA
input int              InpEmaSlow          = 21;    // Slow EMA
input int              InpEmaFilter        = 50;    // Filter EMA
input ENUM_TIMEFRAMES  InpMtf1             = PERIOD_M15; // Higher timeframe 1
input ENUM_TIMEFRAMES  InpMtf2             = PERIOD_H1;  // Higher timeframe 2
input int              InpAdxPeriod        = 14;    // ADX period
input int              InpAtrPeriod        = 14;    // ATR period
input int              InpDonchianPeriod   = 40;    // Donchian lookback

input group "=== Display ==="
input bool             InpShowPanel        = true;  // On-chart panel

//+------------------------------------------------------------------+
CKMBus     Bus;
CKMSignals Sig;
CKMBook    Book;
CKMExec    Exec;

//--- peak tracking for the optional trailing, one slot per group
#define KM4_G_BUY   0
#define KM4_G_SELL  1
#define KM4_G_RECOV 2
#define KM4_G_BOOK  3
double   g_peak[4];

//--- last computed targets, for the panel
double   g_tgtBuy = 0.0, g_tgtSell = 0.0, g_tgtRecov = 0.0, g_tgtBook = 0.0;
string   g_whyBuy = "-", g_whySell = "-", g_whyRecov = "-";
int      g_closes = 0;
string   g_lastAction = "-";

//+------------------------------------------------------------------+
int OnInit()
  {
   if((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
     {
      Alert("KrishMix needs a HEDGING account. This one is netting.");
      return(INIT_FAILED);
     }

   if(InpMinTarget <= 0.0)
     {
      Alert("InpMinTarget must be greater than zero: EA4 never closes a group at a loss.");
      return(INIT_FAILED);
     }

   Bus.Init(_Symbol);
   Book.Init(_Symbol, InpMagicBase, InpCommissionPerLot);
   Exec.Init(_Symbol, InpSlippagePoints, "KM4");

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
      Alert("KM4: signal engine failed to initialise.");
      return(INIT_FAILED);
     }

   ArrayInitialize(g_peak, 0.0);

   PrintFormat("KM4 BasketTP v%s | %s | magic base %I64d (manages every KrishMix leg)",
               KM_VERSION, _Symbol, InpMagicBase);
   PrintFormat("KM4 base target %.2f per 1.00 lot | floor %.2f | ceiling %s",
               InpTargetPerLot, InpMinTarget,
               (InpMaxTarget > 0.0 ? DoubleToString(InpMaxTarget, 2) : "none"));
   PrintFormat("KM4 groups: recovery=%s direction=%s wholeBook=%s",
               (InpCloseRecoveryGrp ? "on" : "off"),
               (InpCloseDirection ? "on" : "off"),
               (InpCloseWholeBook ? "on" : "off"));
   Print("KM4: a group is only ever closed in profit. No equity rule, no halt.");

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
   Bus.Beat(KM_EA_BASKET);

   MarketView v;
   if(!Sig.Refresh(v) || !v.valid)
     {
      Panel(v);
      return;
     }

   Book.Scan();

   if(Book.Total() == 0)
     {
      ArrayInitialize(g_peak, 0.0);
      g_tgtBuy = g_tgtSell = g_tgtRecov = g_tgtBook = 0.0;
      g_whyBuy = g_whySell = g_whyRecov = "flat";
      Panel(v);
      return;
     }

   if(InpStripTpWhenDeep)
      StripDeepTps();

//--- 1) recovery group first: the hedge only makes sense as a group
   if(InpCloseRecoveryGrp && HandleRecoveryGroup(v))
     {
      Panel(v);
      return;
     }

//--- 2) plain direction baskets
   if(InpCloseDirection && HandleDirection(v))
     {
      Panel(v);
      return;
     }

//--- 3) whole book sweep
   if(InpCloseWholeBook && HandleWholeBook(v))
     {
      Panel(v);
      return;
     }

   Publish();
   Panel(v);
  }

//+------------------------------------------------------------------+
//| The adaptive target for a group.                                  |
//|                                                                  |
//| 'dir' is the direction the group WANTS price to move for it to     |
//| gain, so the regime factors can tell "with us" from "against us".  |
//+------------------------------------------------------------------+
double AdaptiveTarget(const KMAgg &a, const ENUM_KM_DIR dir,
                      const MarketView &v, string &why)
  {
   why = "";

   if(a.count == 0 || a.lots <= 0.0)
     {
      why = "empty";
      return 0.0;
     }

//--- base scales with the volume being carried
   double base = InpTargetPerLot * a.lots;
   double f    = 1.0;
   string tags = "";

//--- regime ------------------------------------------------------
   ENUM_KM_DIR against = (dir == KM_DIR_BUY ? KM_DIR_SELL : KM_DIR_BUY);

   if(KM_RegimeFavours(v.regime, dir))
     {
      f *= MathMax(0.1, InpTrendWithFactor);
      tags += "trend+ ";
     }
   else if(KM_RegimeFavours(v.regime, against))
     {
      f *= MathMax(0.1, InpTrendAgainstFactor);
      tags += "trend- ";
     }
   else
     {
      f *= MathMax(0.1, InpRangeFactor);
      tags += "range ";
     }

//--- volatility --------------------------------------------------
   if(v.volState == KM_VOL_LOW)
     {
      f *= MathMax(0.1, InpLowVolFactor);
      tags += "volLo ";
     }
   else if(v.volState == KM_VOL_HIGH)
     {
      f *= MathMax(0.1, InpHighVolFactor);
      tags += "volHi ";
     }
   else if(v.volState == KM_VOL_EXTREME)
     {
      f *= MathMax(0.1, InpExtremeVolFactor);
      tags += "volEx ";
     }

//--- the move paying us is running out of steam: bank it ----------
   bool payingMoveExhausted = (dir == KM_DIR_BUY ? v.bullExhaust : v.bearExhaust);
   if(payingMoveExhausted)
     {
      f *= MathMax(0.1, InpExhaustFactor);
      tags += "exhaust ";
     }

//--- relief: deep and old baskets get an easier exit --------------
   double relief = 1.0;

   if(InpDepthReliefFrom > 0 && a.count > InpDepthReliefFrom)
      relief *= MathPow(MathMax(0.5, MathMin(1.0, InpDepthReliefStep)),
                        a.count - InpDepthReliefFrom);

   if(a.firstOpen > 0 && InpAgeReliefPerHour < 1.0)
     {
      double hours = (double)(TimeCurrent() - a.firstOpen) / 3600.0;
      if(hours > 0.0)
         relief *= MathPow(MathMax(0.5, InpAgeReliefPerHour), MathMin(hours, 72.0));
     }

   relief = MathMax(MathMax(0.01, InpMinReliefFloor), relief);
   if(relief < 1.0)
      tags += StringFormat("relief%.2f ", relief);

   double target = base * f * relief;

//--- the floor keeps this an exit in profit, never a loss cut ------
   target = MathMax(target, InpMinTarget);
   if(InpMaxTarget > 0.0)
      target = MathMin(target, InpMaxTarget);

   why = StringFormat("%.2f = %.2f x%.2f x%.2f [%s]", target, base, f, relief, tags);
   return target;
  }

//+------------------------------------------------------------------+
//| Trailing wrapper. Without trailing this is a plain >= test.       |
//+------------------------------------------------------------------+
bool ReadyToClose(const int slot, const double profit, const double target)
  {
   if(target <= 0.0)
      return false;

   if(!InpUseTrailing)
     {
      if(profit >= target)
         return true;
      g_peak[slot] = 0.0;
      return false;
     }

   if(profit >= target && profit > g_peak[slot])
      g_peak[slot] = profit;

   if(g_peak[slot] >= target)
     {
      double give  = MathMax(0.01, MathMin(0.9, InpTrailGiveback));
      double floorP = MathMax(target, g_peak[slot] * (1.0 - give));
      if(profit <= floorP)
         return true;
     }

   return false;
  }

//+------------------------------------------------------------------+
//| Group 1: a drowning basket plus the recovery legs rescuing it     |
//+------------------------------------------------------------------+
bool HandleRecoveryGroup(const MarketView &v)
  {
   g_tgtRecov = 0.0;
   g_whyRecov = "-";

   KMAgg hb, hs;
   Book.AggSlot(KM_EA_HEDGE, true,  hb);
   Book.AggSlot(KM_EA_HEDGE, false, hs);

   if(hb.count == 0 && hs.count == 0)
     {
      g_whyRecov = "no recovery legs open";
      g_peak[KM4_G_RECOV] = 0.0;
      return false;
     }

//--- a buy-side rescue means the SELL basket was drowning, and vice versa
   ENUM_KM_DIR losing = KM_DIR_NONE;
   if(hb.lots > hs.lots)
      losing = KM_DIR_SELL;
   else if(hs.lots > 0.0)
      losing = KM_DIR_BUY;

   if(losing == KM_DIR_NONE)
     {
      g_whyRecov = "cannot resolve the rescued side";
      return false;
     }

   KMAgg grp;
   Book.AggRecoveryGroup(losing, grp);
   if(grp.count == 0)
      return false;

//--- the group profits when price keeps moving the rescue's way
   ENUM_KM_DIR groupDir = (losing == KM_DIR_BUY ? KM_DIR_SELL : KM_DIR_BUY);

   string why;
   double target = AdaptiveTarget(grp, groupDir, v, why);
   g_tgtRecov = target;
   g_whyRecov = why;

   if(!ReadyToClose(KM4_G_RECOV, grp.profit, target))
      return false;

   ulong tickets[];
   int n = Book.TicketsRecoveryGroup(losing, tickets);
   if(n <= 0)
      return false;

   PrintFormat("KM4 CLOSE RECOVERY GROUP: %d legs (%.2f lots) at %.2f %s, target %.2f | rescued %s basket | %s",
               grp.count, grp.lots, grp.profit, AccountInfoString(ACCOUNT_CURRENCY),
               target, (losing == KM_DIR_BUY ? "BUY" : "SELL"), why);

   int left = Exec.CloseTickets(tickets);
   AfterClose(StringFormat("recovery group %.2f", grp.profit), left);
   g_peak[KM4_G_RECOV] = 0.0;
   return true;
  }

//+------------------------------------------------------------------+
//| Group 2: plain direction baskets                                  |
//+------------------------------------------------------------------+
bool HandleDirection(const MarketView &v)
  {
   for(int pass = 0; pass < 2; pass++)
     {
      bool isBuy = (pass == 0);

      //--- a direction holding rescue legs is part of a recovery group
      //--- and must be judged there, not harvested on its own
      if(InpCloseRecoveryGrp && Book.HasHedgeLegs(isBuy))
        {
         if(isBuy)
            g_whyBuy = "held by the recovery group";
         else
            g_whySell = "held by the recovery group";
         continue;
        }

      KMAgg a;
      Book.AggDirection(isBuy, a);

      int    slot = (isBuy ? KM4_G_BUY : KM4_G_SELL);
      string why;
      double target = 0.0;

      if(a.count > 0)
         target = AdaptiveTarget(a, (isBuy ? KM_DIR_BUY : KM_DIR_SELL), v, why);
      else
        {
         why = "flat";
         g_peak[slot] = 0.0;
        }

      if(isBuy)
        {
         g_tgtBuy = target;
         g_whyBuy = why;
        }
      else
        {
         g_tgtSell = target;
         g_whySell = why;
        }

      if(a.count == 0)
         continue;

      if(!ReadyToClose(slot, a.profit, target))
         continue;

      ulong tickets[];
      int n = Book.TicketsDirection(isBuy, tickets);
      if(n <= 0)
         continue;

      PrintFormat("KM4 CLOSE %s BASKET: %d legs (%.2f lots) at %.2f %s, target %.2f | %s",
                  (isBuy ? "BUY" : "SELL"), a.count, a.lots, a.profit,
                  AccountInfoString(ACCOUNT_CURRENCY), target, why);

      int left = Exec.CloseTickets(tickets);
      AfterClose(StringFormat("%s basket %.2f", (isBuy ? "buy" : "sell"), a.profit), left);
      g_peak[slot] = 0.0;
      return true;
     }

   return false;
  }

//+------------------------------------------------------------------+
//| Group 3: everything together                                      |
//+------------------------------------------------------------------+
bool HandleWholeBook(const MarketView &v)
  {
   KMAgg all;
   Book.AggAll(all);

   g_tgtBook = 0.0;
   if(all.count == 0)
     {
      g_peak[KM4_G_BOOK] = 0.0;
      return false;
     }

//--- both directions present, so no single regime helps: use the
//--- net exposure to decide which way the book wants price to go
   ENUM_KM_DIR netDir = (all.buyLots >= all.sellLots ? KM_DIR_BUY : KM_DIR_SELL);

   string why;
   double target = AdaptiveTarget(all, netDir, v, why) * MathMax(0.1, InpWholeBookFactor);
   target = MathMax(target, InpMinTarget);
   g_tgtBook = target;

   if(!ReadyToClose(KM4_G_BOOK, all.profit, target))
      return false;

   ulong tickets[];
   int n = Book.TicketsAll(tickets);
   if(n <= 0)
      return false;

   PrintFormat("KM4 CLOSE WHOLE BOOK: %d legs (%.2f lots) at %.2f %s, target %.2f | %s",
               all.count, all.lots, all.profit, AccountInfoString(ACCOUNT_CURRENCY), target, why);

   int left = Exec.CloseTickets(tickets);
   AfterClose(StringFormat("whole book %.2f", all.profit), left);
   ArrayInitialize(g_peak, 0.0);
   return true;
  }

//+------------------------------------------------------------------+
//| Remove the per-leg TPs once a basket is deep, so the group can    |
//| be closed as one instead of losing its best leg early.            |
//+------------------------------------------------------------------+
void StripDeepTps(void)
  {
   for(int pass = 0; pass < 2; pass++)
     {
      bool isBuy = (pass == 0);

      KMAgg a;
      Book.AggDirection(isBuy, a);
      if(a.count < InpStripTpFromLegs)
         continue;

      for(int i = 0; i < Book.Total(); i++)
        {
         KMLeg leg;
         if(!Book.Leg(i, leg))
            continue;
         if(leg.isBuy != isBuy)
            continue;
         if(leg.tp == 0.0)
            continue;

         if(Exec.SetTP(leg.ticket, 0.0))
            PrintFormat("KM4: stripped TP from #%I64u (%s basket is %d legs deep)",
                        leg.ticket, (isBuy ? "buy" : "sell"), a.count);
        }
     }
  }

//+------------------------------------------------------------------+
void AfterClose(const string what, const int leftOpen)
  {
   g_closes++;
   g_lastAction = what + (leftOpen > 0 ? StringFormat(" (%d stuck)", leftOpen) : "");

   Bus.Set(KM_KEY_LASTCLOSE, (double)TimeCurrent());
   Bus.Set(KM_KEY_CYCLE, Bus.Get(KM_KEY_CYCLE, 0.0) + 1.0);
  }

//+------------------------------------------------------------------+
void Publish(void)
  {
   Bus.Set(KM_KEY_TGT_BUY,   g_tgtBuy);
   Bus.Set(KM_KEY_TGT_SELL,  g_tgtSell);
   Bus.Set(KM_KEY_TGT_GROUP, g_tgtRecov);
  }

//+------------------------------------------------------------------+
void Panel(const MarketView &v)
  {
   if(!InpShowPanel)
      return;

   static datetime last = 0;
   datetime now = TimeCurrent();
   if(now == last)
      return;
   last = now;

   KMAgg b, s, all, hb, hs;
   Book.AggDirection(true,  b);
   Book.AggDirection(false, s);
   Book.AggAll(all);
   Book.AggSlot(KM_EA_HEDGE, true,  hb);
   Book.AggSlot(KM_EA_HEDGE, false, hs);

   string cur = AccountInfoString(ACCOUNT_CURRENCY);

   string t = "==== KM4  ADAPTIVE BASKET EXIT ====\n";
   t += StringFormat("%s   legs %d   %.2f lots\n", _Symbol, all.count, all.lots);
   t += "Suite: " + Bus.Roster() + "\n";
   t += "-----------------------------------\n";

   if(v.valid)
      t += StringFormat("regime %-12s vol %-7s adx %5.1f  score %+6.1f\n",
                        KM_RegimeName(v.regime), KM_VolName(v.volState),
                        v.trendStrength, v.score);
   else
      t += "market view: warming up\n";

   t += "-----------------------------------\n";
   t += StringFormat("BUY   %d legs %.2f lots  P/L %8.2f %s\n", b.count, b.lots, b.profit, cur);
   if(b.count > 0)
      t += "  target " + g_whyBuy + "\n";

   t += StringFormat("SELL  %d legs %.2f lots  P/L %8.2f %s\n", s.count, s.lots, s.profit, cur);
   if(s.count > 0)
      t += "  target " + g_whySell + "\n";

   if(hb.count > 0 || hs.count > 0)
     {
      t += "-----------------------------------\n";
      t += StringFormat("RECOVERY legs: buy %d (%.2f)  sell %d (%.2f)\n",
                        hb.count, hb.lots, hs.count, hs.lots);
      t += "  group target " + g_whyRecov + "\n";
     }

   t += "-----------------------------------\n";
   t += StringFormat("BOOK  P/L %8.2f %s", all.profit, cur);
   if(g_tgtBook > 0.0)
      t += StringFormat("   target %.2f", g_tgtBook);
   t += "\n";
   t += StringFormat("closes: %d   last: %s\n", g_closes, g_lastAction);
   t += StringFormat("balance %.2f  equity %.2f  free %.2f\n",
                     AccountInfoDouble(ACCOUNT_BALANCE),
                     AccountInfoDouble(ACCOUNT_EQUITY),
                     AccountInfoDouble(ACCOUNT_MARGIN_FREE));
   t += "closes in profit only - no equity rule\n";

   Comment(t);
  }
//+------------------------------------------------------------------+
