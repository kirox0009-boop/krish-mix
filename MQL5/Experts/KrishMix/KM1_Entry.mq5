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
input double          InpMinScore         = 35.0;  // Conviction floor, 0..100
input bool            InpRequireMtfAgree  = true;  // Both higher timeframes must agree
input double          InpMinAdx           = 18.0;  // Minimum ADX
input double          InpAdxTrendLevel    = 18.0;  // ADX at which a TREND regime is declared
input bool            InpSkipExtremeVol   = true;  // Skip the EXTREME volatility band
input double          InpMaxSpreadPoints  = 60;    // Spread allowance (0 = off)

input group "=== Pinpoint triggers ==="
input bool            InpUsePullback      = true;  // Pullback-to-EMA continuation
input bool            InpUseBreakout      = true;  // Donchian breakout with expansion
input bool            InpUseReversal      = true;  // Range exhaustion reversal
input double          InpReversalStretch  = 35.0;  // Reversal: score must be stretched THIS far against
input double          InpBreakoutAtrRatio = 1.15;  // Min ATR ratio for a breakout entry
input int             InpCooldownSeconds  = 300;   // Min seconds between EA1 entries
input bool            InpOneEntryPerBar   = true;  // At most one entry per bar

input group "=== Diagnostics ==="
input int             InpDiagLogSeconds   = 0;     // Log a gate summary every N seconds (0 = off)

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

//--- Block histogram. "It is not trading" is useless on its own; what
//--- matters is WHICH condition is the binding constraint on this broker's
//--- data. These counters are shown on the panel and can be logged.
#define KM1_B_NOTALLOWED 0
#define KM1_B_SPREAD     1
#define KM1_B_COOLDOWN   2
#define KM1_B_SAMEBAR    3
#define KM1_B_SCORE      4
#define KM1_B_MTF        5
#define KM1_B_ADX        6
#define KM1_B_VOL        7
#define KM1_B_TRIGGER    8
#define KM1_B_EXPOSURE   9
#define KM1_B_SENDFAIL   10
#define KM1_B_WARMUP     11
#define KM1_B_COUNT      12

long   g_block[KM1_B_COUNT];
long   g_evaluated  = 0;
double g_scoreBest  = 0.0;   // best |score| seen, tells you if the floor is realistic
double g_adxBest    = 0.0;

string BlockName(const int i)
  {
   switch(i)
     {
      case KM1_B_NOTALLOWED: return "trading not allowed";
      case KM1_B_SPREAD:     return "spread too wide";
      case KM1_B_COOLDOWN:   return "cooldown";
      case KM1_B_SAMEBAR:    return "already entered this bar";
      case KM1_B_SCORE:      return "score below floor";
      case KM1_B_MTF:        return "higher timeframes disagree";
      case KM1_B_ADX:        return "adx below floor";
      case KM1_B_VOL:        return "volatility extreme";
      case KM1_B_TRIGGER:    return "no pinpoint trigger";
      case KM1_B_EXPOSURE:   return "already holding / max reached";
      case KM1_B_SENDFAIL:   return "order send failed";
      case KM1_B_WARMUP:     return "market view not ready";
     }
   return "?";
  }

void Blocked(const int reason, const string detail)
  {
   if(reason >= 0 && reason < KM1_B_COUNT)
      g_block[reason]++;
   g_lastBlock = detail;
  }

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
   cfg.donchianShift  = 2;
//--- The PULLBACK trigger requires a TREND regime, and the regime is only
//--- declared TREND at cfg.adxTrendLevel. If that sat above InpMinAdx the
//--- gate would pass ADX values that the regime then refused, silently
//--- blocking every pullback in the gap. Keep them aligned.
   cfg.adxTrendLevel  = InpAdxTrendLevel;
   cfg.adxRangeLevel  = MathMax(5.0, InpAdxTrendLevel - 5.0);
   Sig.Config(cfg);

   if(InpAdxTrendLevel > InpMinAdx)
      PrintFormat("KM1 WARNING: InpAdxTrendLevel (%.1f) is above InpMinAdx (%.1f). "
                  "Pullbacks cannot fire between them.", InpAdxTrendLevel, InpMinAdx);

   if(!Sig.Init(_Symbol, PERIOD_CURRENT))
     {
      Alert("KM1: signal engine failed to initialise.");
      return(INIT_FAILED);
     }

   ArrayInitialize(g_block, 0);

   PrintFormat("KM1 Entry v%s | %s %s | magic base %I64d -> buy %I64d / sell %I64d",
               KM_VERSION, _Symbol, EnumToString((ENUM_TIMEFRAMES)Period()),
               InpMagicBase,
               KM_Magic(InpMagicBase, KM_EA_ENTRY, true),
               KM_Magic(InpMagicBase, KM_EA_ENTRY, false));
   PrintFormat("KM1 continuation gate: score>=%.0f | mtf=%s | adx>=%.0f (regime trend at %.0f)",
               InpMinScore, (InpRequireMtfAgree ? "required" : "off"),
               InpMinAdx, InpAdxTrendLevel);
   PrintFormat("KM1 triggers: pullback=%s breakout=%s reversal=%s (reversal needs score stretched %.0f against)",
               (InpUsePullback ? "on" : "off"), (InpUseBreakout ? "on" : "off"),
               (InpUseReversal ? "on" : "off"), InpReversalStretch);
   Print("KM1: orders are sent with TP and WITHOUT SL by design.");
   if(InpDiagLogSeconds > 0)
      PrintFormat("KM1: gate diagnostics will be logged every %d seconds.", InpDiagLogSeconds);
   else
      Print("KM1: set InpDiagLogSeconds (e.g. 60) to log why entries are being skipped.");

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
      //--- This is the most common reason an EA looks dead: one indicator
      //--- in the stack is not ready, usually a higher-timeframe EMA whose
      //--- history the terminal has not downloaded yet. Say exactly which.
      Blocked(KM1_B_WARMUP, "market view not ready -> " + Sig.LastIssue());

      static datetime lastWarn = 0;
      if(TimeCurrent() - lastWarn >= 30)
        {
         lastWarn = TimeCurrent();
         Print("KM1 waiting on the market view: ", Sig.LastIssue());
         Print("KM1 history available: ", Sig.WarmupReport());
        }

      Panel(v);
      return;
     }

//--- EA1 is the analyst: publish for EA2 / EA3 / EA4 -----------------
   Bus.PublishView(v.score, v.regime, v.volState, v.atr, v.trendStrength);

   Book.Scan();

   ENUM_KM_DIR dir = Decide(v);
   if(dir != KM_DIR_NONE)
      TryEnter(dir, v);

   DiagLog(v);
   Panel(v);
  }

//+------------------------------------------------------------------+
//| Periodic gate summary in the Experts log. Tells you which single  |
//| condition is actually holding the EA back on live data.           |
//+------------------------------------------------------------------+
void DiagLog(const MarketView &v)
  {
   if(InpDiagLogSeconds <= 0)
      return;

   static datetime last = 0;
   if(TimeCurrent() - last < InpDiagLogSeconds)
      return;
   last = TimeCurrent();

   PrintFormat("KM1 DIAG | now: score %+.1f adx %.1f regime %s vol %s (atr x%.2f) mtf %s%s%s",
               v.score, v.trendStrength, KM_RegimeName(v.regime),
               KM_VolName(v.volState), v.atrRatio,
               (v.mtfAgree ? "agree" : "split"),
               (v.bullExhaust ? " BULL-EXH" : ""),
               (v.bearExhaust ? " BEAR-EXH" : ""));
   PrintFormat("KM1 DIAG | best seen: |score| %.1f, adx %.1f | your floors: score %.1f, adx %.1f",
               g_scoreBest, g_adxBest, InpMinScore, InpMinAdx);

   string line = "";
   for(int i = 0; i < KM1_B_COUNT; i++)
      if(g_block[i] > 0)
         line += StringFormat("%s=%I64d  ", BlockName(i), g_block[i]);

   PrintFormat("KM1 DIAG | %d entries in %I64d evaluations. Blocks: %s",
               g_entryCount, g_evaluated, (line == "" ? "none" : line));
  }

//+------------------------------------------------------------------+
//| The confluence gate. Returns the direction to take, or NONE, and  |
//| records why it refused so the panel can show it.                  |
//+------------------------------------------------------------------+
ENUM_KM_DIR Decide(const MarketView &v)
  {
   g_evaluated++;
   if(MathAbs(v.score) > g_scoreBest)
      g_scoreBest = MathAbs(v.score);
   if(v.trendStrength > g_adxBest)
      g_adxBest = v.trendStrength;

//--- tradability ---------------------------------------------------
   if(!TerminalInfoInteger(TERMINAL_CONNECTED) ||
      !MQLInfoInteger(MQL_TRADE_ALLOWED)       ||
      !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
     {
      Blocked(KM1_B_NOTALLOWED, "trading not allowed (check the Algo Trading button)");
      return KM_DIR_NONE;
     }

   if(InpMaxSpreadPoints > 0.0 && KM_SpreadPoints(_Symbol) > InpMaxSpreadPoints)
     {
      Blocked(KM1_B_SPREAD, StringFormat("spread %.0f > %.0f",
                                         KM_SpreadPoints(_Symbol), InpMaxSpreadPoints));
      return KM_DIR_NONE;
     }

//--- cooldown ------------------------------------------------------
   if(InpCooldownSeconds > 0 && g_lastEntryTime > 0 &&
      (TimeCurrent() - g_lastEntryTime) < InpCooldownSeconds)
     {
      Blocked(KM1_B_COOLDOWN, StringFormat("cooldown, %ds left",
                                           InpCooldownSeconds - (int)(TimeCurrent() - g_lastEntryTime)));
      return KM_DIR_NONE;
     }

   datetime curBar = (datetime)SeriesInfoInteger(_Symbol, PERIOD_CURRENT, SERIES_LASTBAR_DATE);
   if(InpOneEntryPerBar && curBar == g_lastEntryBar)
     {
      Blocked(KM1_B_SAMEBAR, "already entered on this bar");
      return KM_DIR_NONE;
     }

//--- Two independent cases, and they need OPPOSITE readings.
//---
//---   continuation  score points the way we want to trade
//---   reversal      score points AGAINST us, stretched to an extreme,
//---                 with momentum already turning back
//---
//--- The original build demanded a positive score for a buy AND a
//--- bearExhaust flag on the same bar. bearExhaust requires RSI <= 32,
//--- which on its own subtracts about 11 points from the score while the
//--- band, stochastic and EMA terms subtract more. The two conditions are
//--- arithmetically incompatible, so the reversal trigger could never
//--- fire. It is judged on its own terms now.
   ENUM_KM_DIR contBias = Sig.Bias(v, InpMinScore);
   ENUM_KM_DIR revBias  = KM_DIR_NONE;

   if(InpUseReversal)
     {
      if(v.bearExhaust && v.score <= -InpReversalStretch)
         revBias = KM_DIR_BUY;      // stretched down and turning: buy it
      else if(v.bullExhaust && v.score >= InpReversalStretch)
         revBias = KM_DIR_SELL;     // stretched up and turning: sell it
     }

   if(contBias == KM_DIR_NONE && revBias == KM_DIR_NONE)
     {
      Blocked(KM1_B_SCORE, StringFormat("score %+.0f, needs %+.0f (or %+.0f stretched for a reversal)",
                                        v.score, InpMinScore, InpReversalStretch));
      return KM_DIR_NONE;
     }

//--- EXHAUSTION TAKES PRECEDENCE.
//---
//--- By the time a score is stretched far enough to raise an exhaustion
//--- flag it is also well past the continuation floor, so if continuation
//--- were checked first it would win every tie and the reversal case would
//--- stay unreachable. Precedence is not just a tie-break here: a market
//--- that is stretched to a band extreme with momentum already turning is
//--- exactly where a continuation entry is the wrong trade.
   bool isReversal = (revBias != KM_DIR_NONE);
   ENUM_KM_DIR dir = (isReversal ? revBias : contBias);

//--- MTF agreement applies to continuation only. A reversal is
//--- counter-trend by definition, so demanding agreement would kill it.
   if(!isReversal && InpRequireMtfAgree && !v.mtfAgree)
     {
      Blocked(KM1_B_MTF, "higher timeframes disagree");
      return KM_DIR_NONE;
     }

//--- Trend strength applies to continuation only, for the same reason.
   if(!isReversal && v.trendStrength < InpMinAdx)
     {
      Blocked(KM1_B_ADX, StringFormat("adx %.1f < %.1f", v.trendStrength, InpMinAdx));
      return KM_DIR_NONE;
     }

   if(InpSkipExtremeVol && v.volState == KM_VOL_EXTREME)
     {
      Blocked(KM1_B_VOL, StringFormat("volatility EXTREME (atr x%.2f)", v.atrRatio));
      return KM_DIR_NONE;
     }

//--- pinpoint trigger --------------------------------------------
   string trig = "";
   if(isReversal)
      trig = "REVERSAL";
   else if(!Trigger(v, dir, trig))
     {
      Blocked(KM1_B_TRIGGER, StringFormat("no trigger (regime %s, score %+.0f)",
                                          KM_RegimeName(v.regime), v.score));
      return KM_DIR_NONE;
     }

//--- exposure ---------------------------------------------------
   bool isBuy = (dir == KM_DIR_BUY);

   KMAgg mine;
   Book.AggSlot(KM_EA_ENTRY, isBuy, mine);
   if(InpMaxPerDirection > 0 && mine.count >= InpMaxPerDirection)
     {
      Blocked(KM1_B_EXPOSURE, StringFormat("EA1 already holds %d %s position(s)",
                                           mine.count, (isBuy ? "buy" : "sell")));
      return KM_DIR_NONE;
     }

   if(!InpAllowBoth)
     {
      KMAgg other;
      Book.AggSlot(KM_EA_ENTRY, !isBuy, other);
      if(other.count > 0)
        {
         Blocked(KM1_B_EXPOSURE, "opposite EA1 position is open");
         return KM_DIR_NONE;
        }
     }

   g_lastTrigger = trig;
   return dir;
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

//--- REVERSAL is NOT handled here. It needs a score pointing the other
//--- way, so it cannot share this function's continuation direction and
//--- is decided in Decide() instead.

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
      Blocked(KM1_B_SENDFAIL, "order send failed -> " + Exec.LastError());
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

//--- the histogram: which condition is the binding constraint
   t += "-----------------------------------\n";
   t += StringFormat("why no entry (of %I64d checks)\n", g_evaluated);

   long worst = 0;
   int  worstIdx = -1;
   for(int i = 0; i < KM1_B_COUNT; i++)
      if(g_block[i] > worst)
        {
         worst = g_block[i];
         worstIdx = i;
        }

   for(int i = 0; i < KM1_B_COUNT; i++)
     {
      if(g_block[i] <= 0)
         continue;
      double pct = (g_evaluated > 0 ? 100.0 * (double)g_block[i] / (double)g_evaluated : 0.0);
      t += StringFormat("  %-26s %6I64d  %4.1f%%%s\n",
                        BlockName(i), g_block[i], pct, (i == worstIdx ? "  <== main" : ""));
     }

   t += StringFormat("best seen: |score| %.1f (floor %.1f), adx %.1f (floor %.1f)\n",
                     g_scoreBest, InpMinScore, g_adxBest, InpMinAdx);
   t += "no stop loss is used - EA2/3/4 manage adverse moves\n";

   Comment(t);
  }
//+------------------------------------------------------------------+
