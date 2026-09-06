//+------------------------------------------------------------------+
//|                                              KM1_Entry.mq5       |
//|                                                                  |
//|  KRISHMIX EA 1 of 4  -  PINPOINT ENTRY                            |
//|                                                                  |
//|  The analyst of the suite. It does the heavy reading of the market |
//|  and only fires when several independent conditions line up, so    |
//|  entries are few and deliberate rather than constant.              |
//|                                                                  |
//|  Confluence gate (every enabled item must pass):                   |
//|    1. composite score beyond the conviction floor                  |
//|    2. both higher timeframes agreeing with that direction          |
//|    3. ADX above the minimum trend strength                        |
//|    4. volatility not in the EXTREME band (news spikes skipped)     |
//|    5. spread inside the allowance                                  |
//|    6. ONE pinpoint trigger firing:                                 |
//|         PULLBACK   trend intact, price tagged the fast EMA and     |
//|                    closed back on the trend side                   |
//|         BREAKOUT   close beyond the Donchian edge with the ATR     |
//|                    already expanding                               |
//|         REVERSAL   range regime plus an exhaustion flag at the      |
//|                    band extreme                                    |
//|    7. cooldown since the last entry has elapsed                    |
//|                                                                  |
//|  Orders carry a TAKE PROFIT and NO STOP LOSS. When price goes the  |
//|  other way the position is handed over to EA2 (grid), EA3 (hedge)  |
//|  and EA4 (basket exit) - that is the whole point of the suite.     |
//|                                                                  |
//|  This EA is also the publisher of the shared market view that the  |
//|  other three read off the state bus.                               |
//+------------------------------------------------------------------+
#property copyright "krish-mix"
#property link      "https://github.com/kirox0009-boop/krish-mix"
#property version   "1.00"
#property description "KrishMix 1/4 - pinpoint entry engine. TP only, no SL by design."
#property description "Publishes the shared market view for EA2, EA3 and EA4."

#include <KrishMix\Common.mqh>
#include <KrishMix\StateBus.mqh>
#include <KrishMix\Signals.mqh>
#include <KrishMix\Positions.mqh>
#include <KrishMix\Execution.mqh>

//+------------------------------------------------------------------+
enum ENUM_KM1_TPMODE
  {
   KM1_TP_ATR   = 0, // ATR multiple
   KM1_TP_PRICE = 1, // Fixed price distance
   KM1_TP_MONEY = 2  // Money target converted to distance
  };

//+------------------------------------------------------------------+
input group "=== Suite wiring (keep identical in all 4 EAs) ==="
input long            InpMagicBase        = KM_MAGIC_BASE_DEFAULT; // Magic base
input double          InpCommissionPerLot = 0.0;   // Round-turn commission per 1.00 lot
input int             InpSlippagePoints   = 30;    // Max deviation, points

input group "=== Entry sizing ==="
input double          InpLot              = 0.01;  // Entry lot
input int             InpMaxPerDirection  = 1;     // Max EA1 positions per direction (0 = unlimited)
input bool            InpAllowBoth        = true;  // May hold an EA1 buy and sell at the same time

input group "=== Confluence gate ==="
input double          InpMinScore         = 45.0;  // Conviction floor, 0..100
input bool            InpRequireMtfAgree  = true;  // Both higher timeframes must agree
input double          InpMinAdx           = 20.0;  // Minimum ADX
input bool            InpSkipExtremeVol   = true;  // Skip the EXTREME volatility band
input double          InpMaxSpreadPoints  = 60;    // Spread allowance (0 = off)

input group "=== Pinpoint triggers ==="
input bool            InpUsePullback      = true;  // Pullback-to-EMA continuation
input bool            InpUseBreakout      = true;  // Donchian breakout with expansion
input bool            InpUseReversal      = true;  // Range exhaustion reversal
input double          InpBreakoutAtrRatio = 1.15;  // Min ATR ratio for a breakout entry
input int             InpCooldownSeconds  = 300;   // Min seconds between EA1 entries
input bool            InpOneEntryPerBar   = true;  // At most one entry per bar

input group "=== Take profit (no stop loss is ever sent) ==="
input ENUM_KM1_TPMODE InpTpMode           = KM1_TP_ATR; // TP mode
input double          InpTpAtrMult        = 1.80;  // ATR multiple
input double          InpTpPrice          = 3.00;  // Fixed distance in price units
input double          InpTpMoney          = 2.00;  // Money target for the entry lot

input group "=== Signal engine ==="
input int             InpEmaFast          = 8;     // Fast EMA
input int             InpEmaSlow          = 21;    // Slow EMA
input int             InpEmaFilter        = 50;    // Filter EMA
input ENUM_TIMEFRAMES InpMtf1             = PERIOD_M15; // Higher timeframe 1
input ENUM_TIMEFRAMES InpMtf2             = PERIOD_H1;  // Higher timeframe 2
input int             InpAdxPeriod        = 14;    // ADX period
input int             InpRsiPeriod        = 14;    // RSI period
input int             InpAtrPeriod        = 14;    // ATR period
input int             InpDonchianPeriod   = 40;    // Donchian lookback

input group "=== Display ==="
input bool            InpShowPanel        = true;  // On-chart panel

//+------------------------------------------------------------------+
CKMBus     Bus;
CKMSignals Sig;
CKMBook    Book;
CKMExec    Exec;

datetime   g_lastEntryTime = 0;
datetime   g_lastEntryBar  = 0;
string     g_lastTrigger   = "-";
string     g_lastBlock     = "-";
int        g_entryCount    = 0;

//+------------------------------------------------------------------+
int OnInit()
  {
   if((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
     {
      Alert("KrishMix needs a HEDGING account. This one is netting.");
      return(INIT_FAILED);
     }

   if(InpLot <= 0.0)
     {
      Alert("Entry lot must be greater than zero.");
      return(INIT_FAILED);
     }

   Bus.Init(_Symbol);
   Book.Init(_Symbol, InpMagicBase, InpCommissionPerLot);
   Exec.Init(_Symbol, InpSlippagePoints, "KM1");

   SignalConfig cfg;
   KM_DefaultSignalConfig(cfg);
   cfg.emaFast        = InpEmaFast;
   cfg.emaSlow        = InpEmaSlow;
   cfg.emaFilter      = InpEmaFilter;
   cfg.mtf1           = InpMtf1;
   cfg.mtf2           = InpMtf2;
   cfg.adxPeriod      = InpAdxPeriod;
   cfg.rsiPeriod      = InpRsiPeriod;
   cfg.atrPeriod      = InpAtrPeriod;
   cfg.donchianPeriod = InpDonchianPeriod;
   Sig.Config(cfg);

   if(!Sig.Init(_Symbol, PERIOD_CURRENT))
     {
      Alert("KM1: signal engine failed to initialise.");
      return(INIT_FAILED);
     }

   PrintFormat("KM1 Entry v%s | %s %s | magic base %I64d -> buy %I64d / sell %I64d",
               KM_VERSION, _Symbol, EnumToString((ENUM_TIMEFRAMES)Period()),
               InpMagicBase,
               KM_Magic(InpMagicBase, KM_EA_ENTRY, true),
               KM_Magic(InpMagicBase, KM_EA_ENTRY, false));
   PrintFormat("KM1 gate: score>=%.0f mtf=%s adx>=%.0f | triggers pullback=%s breakout=%s reversal=%s",
               InpMinScore, (InpRequireMtfAgree ? "yes" : "no"), InpMinAdx,
               (InpUsePullback ? "on" : "off"), (InpUseBreakout ? "on" : "off"),
               (InpUseReversal ? "on" : "off"));
   Print("KM1: orders are sent with TP and WITHOUT SL by design.");

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
   Bus.Beat(KM_EA_ENTRY);

   MarketView v;
   if(!Sig.Refresh(v) || !v.valid)
     {
      g_lastBlock = "indicators warming up";
      Panel(v);
      return;
     }

//--- EA1 is the analyst: publish for EA2 / EA3 / EA4 -----------------
   Bus.PublishView(v.score, v.regime, v.volState, v.atr, v.trendStrength);

   Book.Scan();

   ENUM_KM_DIR dir = Decide(v);
   if(dir != KM_DIR_NONE)
      TryEnter(dir, v);

   Panel(v);
  }

//+------------------------------------------------------------------+
//| The confluence gate. Returns the direction to take, or NONE, and  |
//| records why it refused so the panel can show it.                  |
//+------------------------------------------------------------------+
ENUM_KM_DIR Decide(const MarketView &v)
  {
   g_lastBlock = "-";

//--- tradability ---------------------------------------------------
   if(!TerminalInfoInteger(TERMINAL_CONNECTED) ||
      !MQLInfoInteger(MQL_TRADE_ALLOWED)       ||
      !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
     {
      g_lastBlock = "trading not allowed";
      return KM_DIR_NONE;
     }

   if(InpMaxSpreadPoints > 0.0 && KM_SpreadPoints(_Symbol) > InpMaxSpreadPoints)
     {
      g_lastBlock = StringFormat("spread %.0f > %.0f", KM_SpreadPoints(_Symbol), InpMaxSpreadPoints);
      return KM_DIR_NONE;
     }

//--- cooldown ------------------------------------------------------
   if(InpCooldownSeconds > 0 && g_lastEntryTime > 0 &&
      (TimeCurrent() - g_lastEntryTime) < InpCooldownSeconds)
     {
      g_lastBlock = StringFormat("cooldown %ds left",
                                 InpCooldownSeconds - (int)(TimeCurrent() - g_lastEntryTime));
      return KM_DIR_NONE;
     }

   datetime curBar = (datetime)SeriesInfoInteger(_Symbol, PERIOD_CURRENT, SERIES_LASTBAR_DATE);
   if(InpOneEntryPerBar && curBar == g_lastEntryBar)
     {
      g_lastBlock = "already entered this bar";
      return KM_DIR_NONE;
     }

//--- 1. conviction -------------------------------------------------
   ENUM_KM_DIR bias = Sig.Bias(v, InpMinScore);
   if(bias == KM_DIR_NONE)
     {
      g_lastBlock = StringFormat("score %.0f below %.0f", v.score, InpMinScore);
      return KM_DIR_NONE;
     }

//--- 2. higher timeframe agreement ---------------------------------
   if(InpRequireMtfAgree && !v.mtfAgree)
     {
      g_lastBlock = "higher timeframes disagree";
      return KM_DIR_NONE;
     }

//--- 3. trend strength --------------------------------------------
   if(v.trendStrength < InpMinAdx)
     {
      g_lastBlock = StringFormat("adx %.1f < %.1f", v.trendStrength, InpMinAdx);
      return KM_DIR_NONE;
     }

//--- 4. volatility ------------------------------------------------
   if(InpSkipExtremeVol && v.volState == KM_VOL_EXTREME)
     {
      g_lastBlock = StringFormat("volatility EXTREME (atr x%.2f)", v.atrRatio);
      return KM_DIR_NONE;
     }

//--- 5. pinpoint trigger -----------------------------------------
   string trig = "";
   if(!Trigger(v, bias, trig))
     {
      g_lastBlock = "no pinpoint trigger";
      return KM_DIR_NONE;
     }

//--- 6. exposure ------------------------------------------------
   bool isBuy = (bias == KM_DIR_BUY);

   KMAgg mine;
   Book.AggSlot(KM_EA_ENTRY, isBuy, mine);
   if(InpMaxPerDirection > 0 && mine.count >= InpMaxPerDirection)
     {
      g_lastBlock = StringFormat("EA1 already holds %d on that side", mine.count);
      return KM_DIR_NONE;
     }

   if(!InpAllowBoth)
     {
      KMAgg other;
      Book.AggSlot(KM_EA_ENTRY, !isBuy, other);
      if(other.count > 0)
        {
         g_lastBlock = "opposite EA1 position open";
         return KM_DIR_NONE;
        }
     }

   g_lastTrigger = trig;
   return bias;
  }

//+------------------------------------------------------------------+
//| Pinpoint triggers. One of them must fire.                        |
//+------------------------------------------------------------------+
bool Trigger(const MarketView &v, const ENUM_KM_DIR dir, string &which)
  {
   which = "";
   bool isBuy = (dir == KM_DIR_BUY);

   double lows[], highs[];
   if(CopyLow(_Symbol, PERIOD_CURRENT, 1, 2, lows) != 2)
      return false;
   if(CopyHigh(_Symbol, PERIOD_CURRENT, 1, 2, highs) != 2)
      return false;

   double low1  = lows[0];
   double high1 = highs[0];

//--- PULLBACK: trend intact, last bar tagged the fast EMA and closed
//--- back on the trend side. The classic continuation entry.
   if(InpUsePullback)
     {
      if(isBuy &&
         (v.regime == KM_REGIME_TREND_UP || v.regime == KM_REGIME_BREAKOUT_UP) &&
         v.emaFast > v.emaSlow &&
         low1 <= v.emaFast &&
         v.closePrice > v.emaFast)
        {
         which = "PULLBACK";
         return true;
        }

      if(!isBuy &&
         (v.regime == KM_REGIME_TREND_DOWN || v.regime == KM_REGIME_BREAKOUT_DN) &&
         v.emaFast < v.emaSlow &&
         high1 >= v.emaFast &&
         v.closePrice < v.emaFast)
        {
         which = "PULLBACK";
         return true;
        }
     }

//--- BREAKOUT: close beyond the Donchian edge while ATR expands
   if(InpUseBreakout && v.atrRatio >= InpBreakoutAtrRatio)
     {
      if(isBuy && v.swingHigh > 0.0 && v.closePrice >= v.swingHigh)
        {
         which = "BREAKOUT";
         return true;
        }
      if(!isBuy && v.swingLow > 0.0 && v.closePrice <= v.swingLow)
        {
         which = "BREAKOUT";
         return true;
        }
     }

//--- REVERSAL: range regime, stretched to a band edge, momentum turning
   if(InpUseReversal && v.regime == KM_REGIME_RANGE)
     {
      if(isBuy && v.bearExhaust)
        {
         which = "REVERSAL";
         return true;
        }
      if(!isBuy && v.bullExhaust)
        {
         which = "REVERSAL";
         return true;
        }
     }

   return false;
  }

//+------------------------------------------------------------------+
//| Take profit distance in price units                              |
//+------------------------------------------------------------------+
double TpDistance(const MarketView &v)
  {
   switch(InpTpMode)
     {
      case KM1_TP_PRICE:
         return MathMax(0.0, InpTpPrice);

      case KM1_TP_MONEY:
        {
         double perLot = KM_MoneyPerPricePerLot(_Symbol);
         if(perLot <= 0.0 || InpLot <= 0.0)
            return 0.0;
         return InpTpMoney / (perLot * InpLot);
        }

      default: // KM1_TP_ATR
         if(v.atr <= 0.0)
            return 0.0;
         return v.atr * MathMax(0.1, InpTpAtrMult);
     }
  }

//+------------------------------------------------------------------+
void TryEnter(const ENUM_KM_DIR dir, const MarketView &v)
  {
   bool   isBuy = (dir == KM_DIR_BUY);
   double entry = isBuy ? KM_Ask(_Symbol) : KM_Bid(_Symbol);
   double dist  = TpDistance(v);

   double tp = 0.0;
   if(dist > 0.0)
      tp = isBuy ? (entry + dist) : (entry - dist);

   long   magic = KM_Magic(InpMagicBase, KM_EA_ENTRY, isBuy);
   string note  = StringFormat("%s|s%.0f|%s", g_lastTrigger, v.score, KM_RegimeName(v.regime));

   ulong ticket = 0;
   if(!Exec.Open(isBuy, InpLot, magic, tp, note, ticket))
     {
      g_lastBlock = Exec.LastError();
      return;
     }

   g_lastEntryTime = TimeCurrent();
   g_lastEntryBar  = (datetime)SeriesInfoInteger(_Symbol, PERIOD_CURRENT, SERIES_LASTBAR_DATE);
   g_entryCount++;

   PrintFormat("KM1 ENTRY %s %.2f @ %.*f | trigger %s | score %.0f | %s | adx %.1f | tp %.*f (%.2f away, no SL)",
               (isBuy ? "BUY" : "SELL"), InpLot, _Digits, entry,
               g_lastTrigger, v.score, KM_RegimeName(v.regime), v.trendStrength,
               _Digits, tp, dist);
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

   KMAgg b, s;
   Book.AggSlot(KM_EA_ENTRY, true,  b);
   Book.AggSlot(KM_EA_ENTRY, false, s);

   string cur = AccountInfoString(ACCOUNT_CURRENCY);

   string t = "==== KM1  PINPOINT ENTRY ====\n";
   t += StringFormat("%s %s   spread %.0f pts\n", _Symbol,
                     EnumToString((ENUM_TIMEFRAMES)Period()), KM_SpreadPoints(_Symbol));
   t += "Suite: " + Bus.Roster() + "\n";
   t += "------------------------------\n";

   if(v.valid)
     {
      t += StringFormat("score %+6.1f   adx %5.1f   %s\n", v.score, v.trendStrength,
                        (v.mtfAgree ? "MTF agree" : "MTF split"));
      t += StringFormat("regime %-12s vol %-7s (atr x%.2f)\n",
                        KM_RegimeName(v.regime), KM_VolName(v.volState), v.atrRatio);
      t += StringFormat("atr %.*f   rsi %5.1f   stoch %5.1f\n", _Digits, v.atr, v.rsi, v.stoch);
      t += StringFormat("donchian %.*f / %.*f\n", _Digits, v.swingHigh, _Digits, v.swingLow);
      if(v.bullExhaust) t += "flag: BULL EXHAUSTION\n";
      if(v.bearExhaust) t += "flag: BEAR EXHAUSTION\n";
     }
   else
      t += "market view: warming up\n";

   t += "------------------------------\n";
   t += StringFormat("EA1 buy  %d pos %.2f lots  %.2f %s\n", b.count, b.lots, b.profit, cur);
   t += StringFormat("EA1 sell %d pos %.2f lots  %.2f %s\n", s.count, s.lots, s.profit, cur);
   t += StringFormat("entries taken: %d   last trigger: %s\n", g_entryCount, g_lastTrigger);
   t += "gate: " + g_lastBlock + "\n";
   t += "no stop loss is used - EA2/3/4 manage adverse moves\n";

   Comment(t);
  }
//+------------------------------------------------------------------+
