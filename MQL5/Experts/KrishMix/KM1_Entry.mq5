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
//--- add-on strategy layers. Everything above keeps working exactly as
//--- before; these only ever ADD ways to qualify for an entry.
#include <KrishMix\Structure.mqh>
#include <KrishMix\Fib.mqh>
#include <KrishMix\Playbook.mqh>
//--- read-only state export for the dashboard. Nothing in this module can
//--- place, modify or close an order.
#include <KrishMix\Telemetry.mqh>

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

//===================================================================
//  ADD-ON STRATEGY LAYERS
//
//  Each block below is an EXTRA way to qualify for an entry. Turning
//  them all off returns the EA to exactly its previous behaviour.
//
//  They deliberately do NOT go through the composite score floor. The
//  score measures trend-following conviction, so gating a structural
//  or mean-reversion setup behind it is what made the original
//  REVERSAL trigger unreachable. Each layer states its own case.
//===================================================================

input group "=== ADD-ON: inside bar at a swing extreme ==="
//--- The M30 gold setup: price prints a fresh swing high, that bar is a
//--- big candle, the next one is a baby candle inside it, and the entry
//--- is the break of the baby's low. Sell side by default, buy side is
//--- the mirror at a fresh swing low. Reward is 1:3, and there is no
//--- stop loss - if it goes the other way EA2/EA3/EA4 take over.
input bool            InpUseInsideBar     = true;  // Enable the inside-bar break
input ENUM_TIMEFRAMES InpIbTimeframe      = PERIOD_M30; // Timeframe it is read on
input bool            InpIbSellAtHigh     = true;  // Sell the baby-low break at a fresh high
input bool            InpIbBuyAtLow       = true;  // Buy the baby-high break at a fresh low
input double          InpIbRewardRatio    = 3.0;   // Reward per 1 unit of implied risk
input bool            InpIbRiskFromMother = true;  // Implied risk = mother extreme (else baby)
input double          InpIbMotherMinAtr   = 0.80;  // Mother candle must be at least this many ATR
input double          InpIbBabyMaxFrac    = 0.55;  // Baby range as a fraction of the mother
input int             InpIbMaxAgeBars     = 6;     // Ignore an inside bar older than this
input int             InpIbExtremeLookback= 12;    // Bars the mother must be the extreme of

input group "=== ADD-ON: trend-based Fibonacci reversal ==="
//--- Three-point extension, not a retracement. A->B is the impulse, C
//--- ends the pullback, and the three projections from C are where the
//--- next leg tends to terminate. Price reaching one is the signal, and
//--- the trade runs against the impulse.
input bool            InpUseFibRev        = true;  // Enable fib reversal levels
input double          InpFibR1            = 0.618; // Projection 1
input double          InpFibR2            = 1.000; // Projection 2
input double          InpFibR3            = 1.618; // Projection 3
input double          InpFibMinImpulseAtr = 2.0;   // Ignore impulses smaller than this
input double          InpFibMinRetracePct = 20.0;  // C must retrace at least this much
input double          InpFibMaxRetracePct = 90.0;  // ... and no more than this
input double          InpFibTolerAtr      = 0.50;  // How close to a level counts as "at" it
input double          InpFibRewardRatio   = 3.0;   // Reward per 1 unit of implied risk

input group "=== ADD-ON: top-down playbook ==="
//--- Five steps: higher-timeframe bias, mid-timeframe levels and
//--- trendline, low-timeframe VWAP / MA / RSI divergence / patterns,
//--- then a NAMED edge, then the working timeframe from EA6.
input bool            InpUsePlaybook      = true;  // Enable the playbook edge
input ENUM_TIMEFRAMES InpPbHighTf         = PERIOD_H4;  // Step 1 timeframe
input ENUM_TIMEFRAMES InpPbMidTf          = PERIOD_M15; // Step 2 timeframe
input ENUM_TIMEFRAMES InpPbLowTf          = PERIOD_M5;  // Step 3 timeframe
input double          InpPbMinConfidence  = 55.0;  // Minimum edge confidence
input bool            InpPbRequireHtfAlign= false; // Hard-block trades against the HTF bias
input int             InpPbMaPeriod       = 50;    // Moving average on the low timeframe
input double          InpPbVwapMinSd      = 1.20;  // VWAP stretch that counts as a band edge
input bool            InpPbUseBusStyle    = true;  // Take the style/timeframe from EA6

input group "=== ADD-ON: fresh trend only (never join mid-trend) ==="
//--- Entries are taken from the corner of a move, not its middle. A
//--- counter-trend setup is exempt by definition, and a deep pullback
//--- inside an older trend re-creates a corner.
input bool            InpFreshTrendOnly   = true;  // Refuse mid-trend entries
input double          InpFreshMaturityMax = 40.0;  // Maturity at or below this is fresh
input double          InpFreshCornerAtr   = 3.0;   // Still a corner within this many ATR of the origin
input double          InpFreshMinRetrace  = 50.0;  // Pullback depth that re-opens a corner
input int             InpFreshFlipBars    = 25;    // A structure flip this recent counts as fresh
input int             InpFreshMaxLegs     = 5;     // Legs counted as fully mature
input double          InpFreshMaxExtAtr   = 12.0;  // Extension counted as fully mature
input int             InpSwingStrength    = 3;     // Pivot bars required each side

input group "=== Dashboard telemetry (read only) ==="
//--- Writes this EA's reasoning to MQL5\Files\KrishMix\telemetry so the
//--- dashboard backend can read it. Purely an export: it never touches an
//--- order, and turning it off changes nothing about how the EA trades.
input bool            InpTelemetry        = true;  // Export state for the dashboard
input int             InpTelemetrySec     = 5;     // Seconds between snapshots

input group "=== Display ==="
input bool            InpShowPanel        = true;  // On-chart panel
input bool            InpShowNarrative    = true;  // Show the playbook's five-step reasoning

//+------------------------------------------------------------------+
CKMBus     Bus;
CKMSignals Sig;
CKMBook    Book;
CKMExec    Exec;

//--- add-on layers
CKMStructure StructEntry;   // on the chart timeframe: fresh-trend gate + fib pivots
CKMStructure StructSwing;   // on InpIbTimeframe: the inside-bar setup
CKMFib       Fib;
CKMPlaybook  Play;
CKMTelemetry Tel;           // dashboard export, read only

int        g_hAtrSwing     = INVALID_HANDLE;  // ATR on the inside-bar timeframe
bool       g_structOk      = false;
bool       g_swingOk       = false;
bool       g_playOk        = false;

datetime   g_lastEntryTime = 0;
datetime   g_lastEntryBar  = 0;
string     g_lastTrigger   = "-";
string     g_lastBlock     = "-";
int        g_entryCount    = 0;

//--- how many entries each trigger has produced, so it is obvious which
//--- layer is actually contributing and which is dead weight
#define KM1_T_PULLBACK  0
#define KM1_T_BREAKOUT  1
#define KM1_T_REVERSAL  2
#define KM1_T_INSIDEBAR 3
#define KM1_T_FIBREV    4
#define KM1_T_PLAYBOOK  5
#define KM1_T_COUNT     6

long   g_trigCount[KM1_T_COUNT];
long   g_trigFired[KM1_T_COUNT];   // qualified, before the shared gates

string TriggerName(const int i)
  {
   switch(i)
     {
      case KM1_T_PULLBACK:  return "PULLBACK";
      case KM1_T_BREAKOUT:  return "BREAKOUT";
      case KM1_T_REVERSAL:  return "REVERSAL";
      case KM1_T_INSIDEBAR: return "INSIDEBAR";
      case KM1_T_FIBREV:    return "FIBREV";
      case KM1_T_PLAYBOOK:  return "PLAYBOOK";
     }
   return "?";
  }

int TriggerIndex(const string name)
  {
   for(int i = 0; i < KM1_T_COUNT; i++)
      if(TriggerName(i) == name)
         return i;
   return -1;
  }

//+------------------------------------------------------------------+
//| One qualified entry idea.                                        |
//|                                                                  |
//| 'isCounter' marks a setup that is counter-trend by nature. Those   |
//| skip the MTF-agreement and ADX floors, which exist to keep         |
//| CONTINUATION entries honest and would otherwise make a             |
//| mean-reversion setup impossible to reach.                          |
//|                                                                  |
//| 'tpPrice' lets a layer carry its own target, which is how the      |
//| inside-bar 1:3 and the fib projection get their real levels        |
//| instead of the generic ATR distance.                               |
//+------------------------------------------------------------------+
struct EntryCandidate
  {
   bool             ok;
   ENUM_KM_DIR      dir;
   string           trigger;
   bool             isCounter;
   double           tpPrice;    // 0 = fall back to the normal TP mode
   string           note;
  };

void ResetCandidate(EntryCandidate &c)
  {
   c.ok        = false;
   c.dir       = KM_DIR_NONE;
   c.trigger   = "";
   c.isCounter = false;
   c.tpPrice   = 0.0;
   c.note      = "";
  }

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
#define KM1_B_MIDTREND   12
#define KM1_B_STRUCT     13
#define KM1_B_COUNT      14

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
      case KM1_B_MIDTREND:   return "mid-trend, not a corner";
      case KM1_B_STRUCT:     return "structure not ready";
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
   ArrayInitialize(g_trigCount, 0);
   ArrayInitialize(g_trigFired, 0);

//=== add-on layers ===============================================
//--- A failure to start any of these is NOT fatal: the EA keeps running
//--- on its original triggers and simply reports the layer as offline.

//--- structure on the chart timeframe: fresh-trend gate and fib pivots
   StructureConfig sc;
   KM_DefaultStructureConfig(sc);
   sc.swingStrength   = MathMax(1, InpSwingStrength);
   sc.freshMaturity   = InpFreshMaturityMax;
   sc.cornerAtr       = InpFreshCornerAtr;
   sc.flipRecentBars  = InpFreshFlipBars;
   sc.maxLegs         = MathMax(1, InpFreshMaxLegs);
   sc.maxExtensionAtr = MathMax(1.0, InpFreshMaxExtAtr);
   StructEntry.Config(sc);
   StructEntry.Init(_Symbol, PERIOD_CURRENT);
   g_structOk = true;

//--- structure on the inside-bar timeframe
   if(InpUseInsideBar)
     {
      StructureConfig ic = sc;
      ic.insideMotherMinAtr    = InpIbMotherMinAtr;
      ic.insideBabyMaxFrac     = InpIbBabyMaxFrac;
      ic.insideMaxAgeBars      = MathMax(1, InpIbMaxAgeBars);
      ic.insideExtremeLookback = MathMax(3, InpIbExtremeLookback);
      StructSwing.Config(ic);
      StructSwing.Init(_Symbol, InpIbTimeframe);

      g_hAtrSwing = iATR(_Symbol, InpIbTimeframe, MathMax(2, InpAtrPeriod));
      g_swingOk   = (g_hAtrSwing != INVALID_HANDLE);
      if(!g_swingOk)
         Print("KM1: inside-bar layer offline, ATR on ",
               EnumToString(InpIbTimeframe), " could not be created.");
     }

//--- trend-based fibonacci
   if(InpUseFibRev)
     {
      FibConfig fc;
      KM_DefaultFibConfig(fc);
      fc.r1            = InpFibR1;
      fc.r2            = InpFibR2;
      fc.r3            = InpFibR3;
      fc.minImpulseAtr = InpFibMinImpulseAtr;
      fc.minRetracePct = InpFibMinRetracePct;
      fc.maxRetracePct = InpFibMaxRetracePct;
      fc.levelTolerAtr = InpFibTolerAtr;
      Fib.Config(fc);
     }

//--- top-down playbook
   if(InpUsePlaybook)
     {
      PlaybookConfig pc;
      KM_DefaultPlaybookConfig(pc);
      pc.tfHigh          = InpPbHighTf;
      pc.tfMid           = InpPbMidTf;
      pc.tfLow           = InpPbLowTf;
      pc.atrPeriod       = MathMax(2, InpAtrPeriod);
      pc.maPeriod        = MathMax(2, InpPbMaPeriod);
      pc.minConfidence   = InpPbMinConfidence;
      pc.requireHtfAlign = InpPbRequireHtfAlign;
      pc.vwapMinSd       = InpPbVwapMinSd;
      Play.Config(pc);

      g_playOk = Play.Init(_Symbol);
      if(!g_playOk)
         Print("KM1: playbook layer offline -> ", Play.LastIssue());
     }

   PrintFormat("KM1 add-ons: insideBar=%s(%s) fibRev=%s playbook=%s(%s/%s/%s) freshTrendOnly=%s",
               (InpUseInsideBar ? "on" : "off"), EnumToString(InpIbTimeframe),
               (InpUseFibRev ? "on" : "off"),
               (InpUsePlaybook ? "on" : "off"),
               EnumToString(InpPbHighTf), EnumToString(InpPbMidTf), EnumToString(InpPbLowTf),
               (InpFreshTrendOnly ? "on" : "off"));

//--- dashboard export. Full fidelity is written here on purpose: the
//--- backend decides what a viewer is allowed to see, so anything held
//--- back at this layer would simply be missing from developer mode too.
   if(InpTelemetry)
     {
      if(Tel.Init("KM1", _Symbol, InpTelemetrySec))
         PrintFormat("KM1 telemetry -> MQL5\\Files\\%s (every %ds)",
                     Tel.FileName(), InpTelemetrySec);
      else
         Print("KM1 telemetry could not start: ", Tel.LastError());
     }

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
   Play.Release();
   if(g_hAtrSwing != INVALID_HANDLE)
      IndicatorRelease(g_hAtrSwing);
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

   RefreshAddOns(v);

   Book.Scan();

   EntryCandidate cand;
   if(Decide(v, cand) && cand.ok)
      TryEnter(cand, v);

   DiagLog(v);
   Panel(v);
  }

//+------------------------------------------------------------------+
//| Refresh the add-on layers. Each one is independent: if a layer is  |
//| not ready the others still work, and the original triggers are     |
//| never affected.                                                    |
//+------------------------------------------------------------------+
void RefreshAddOns(const MarketView &v)
  {
//--- structure on the chart timeframe, using the ATR the suite already
//--- computed so both modules read the same volatility
   if(g_structOk)
      StructEntry.Refresh(v.atr);

//--- structure + fib on the inside-bar timeframe
   if(InpUseInsideBar && g_swingOk)
     {
      double atrSwing = 0.0;
      double tmp[];
      if(CopyBuffer(g_hAtrSwing, 0, 1, 1, tmp) >= 1 && tmp[0] > 0.0)
        {
         atrSwing = tmp[0];
         StructSwing.Refresh(atrSwing);
        }
     }

//--- fib is built from the chart-timeframe pivots
   if(InpUseFibRev && g_structOk && StructEntry.Valid())
      Fib.Build(StructEntry, v.atr, KM_Bid(_Symbol));

//--- playbook, optionally following the style EA6 published
   if(InpUsePlaybook && g_playOk)
     {
      if(InpPbUseBusStyle && Bus.StyleFresh())
         Play.SetStyle(Bus.Style(), Bus.WorkingTf());
      Play.Refresh();
     }
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
//| The gate. Collects candidates from every enabled layer, applies    |
//| the shared filters, and records why it refused so the panel can    |
//| show which condition is actually binding.                          |
//+------------------------------------------------------------------+
bool Decide(const MarketView &v, EntryCandidate &out)
  {
   ResetCandidate(out);

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
      return false;
     }

   if(InpMaxSpreadPoints > 0.0 && KM_SpreadPoints(_Symbol) > InpMaxSpreadPoints)
     {
      Blocked(KM1_B_SPREAD, StringFormat("spread %.0f > %.0f",
                                         KM_SpreadPoints(_Symbol), InpMaxSpreadPoints));
      return false;
     }

//--- cooldown ------------------------------------------------------
   if(InpCooldownSeconds > 0 && g_lastEntryTime > 0 &&
      (TimeCurrent() - g_lastEntryTime) < InpCooldownSeconds)
     {
      Blocked(KM1_B_COOLDOWN, StringFormat("cooldown, %ds left",
                                           InpCooldownSeconds - (int)(TimeCurrent() - g_lastEntryTime)));
      return false;
     }

   datetime curBar = (datetime)SeriesInfoInteger(_Symbol, PERIOD_CURRENT, SERIES_LASTBAR_DATE);
   if(InpOneEntryPerBar && curBar == g_lastEntryBar)
     {
      Blocked(KM1_B_SAMEBAR, "already entered on this bar");
      return false;
     }

   EntryCandidate cand;
   ResetCandidate(cand);

//=== collect candidates, most specific setup first ================
//
//  Order matters only when two layers fire on the same bar. The
//  structural setups are checked first because they name an exact price
//  level, while a score-driven continuation is a statement about
//  conditions. Whenever the new layers are silent the original triggers
//  behave exactly as they always did.
//
   if(!cand.ok) TryInsideBar(v, cand);
   if(!cand.ok) TryFibReversal(v, cand);
   if(!cand.ok) TryPlaybook(v, cand);
   if(!cand.ok) TryScoreBased(v, cand);

   if(!cand.ok)
     {
      Blocked(KM1_B_SCORE, StringFormat("no layer qualified (score %+.0f, needs %+.0f)",
                                        v.score, InpMinScore));
      return false;
     }

   g_trigFired[MathMax(0, TriggerIndex(cand.trigger))]++;

//=== shared gates ================================================

//--- MTF agreement and the ADX floor exist to keep CONTINUATION
//--- entries honest. A counter-trend setup that had to satisfy them
//--- would be unreachable, which is exactly the trap the original
//--- REVERSAL trigger fell into.
   if(!cand.isCounter && InpRequireMtfAgree && !v.mtfAgree)
     {
      Blocked(KM1_B_MTF, "higher timeframes disagree (" + cand.trigger + ")");
      return false;
     }

   if(!cand.isCounter && v.trendStrength < InpMinAdx)
     {
      Blocked(KM1_B_ADX, StringFormat("adx %.1f < %.1f (%s)",
                                      v.trendStrength, InpMinAdx, cand.trigger));
      return false;
     }

//--- volatility applies to every layer
   if(InpSkipExtremeVol && v.volState == KM_VOL_EXTREME)
     {
      Blocked(KM1_B_VOL, StringFormat("volatility EXTREME (atr x%.2f)", v.atrRatio));
      return false;
     }

//--- never join a move that is already running -------------------
   if(InpFreshTrendOnly)
     {
      if(!g_structOk || !StructEntry.Valid())
        {
         Blocked(KM1_B_STRUCT, "fresh-trend gate needs structure -> " + StructEntry.LastIssue());
         return false;
        }

      string freshWhy;
      if(!StructEntry.EntryIsFresh(cand.dir, InpFreshMinRetrace, freshWhy))
        {
         Blocked(KM1_B_MIDTREND, cand.trigger + ": " + freshWhy);
         return false;
        }
      cand.note += " | fresh: " + freshWhy;
     }

//--- exposure ---------------------------------------------------
   bool isBuy = (cand.dir == KM_DIR_BUY);

   KMAgg mine;
   Book.AggSlot(KM_EA_ENTRY, isBuy, mine);
   if(InpMaxPerDirection > 0 && mine.count >= InpMaxPerDirection)
     {
      Blocked(KM1_B_EXPOSURE, StringFormat("EA1 already holds %d %s position(s)",
                                           mine.count, (isBuy ? "buy" : "sell")));
      return false;
     }

   if(!InpAllowBoth)
     {
      KMAgg other;
      Book.AggSlot(KM_EA_ENTRY, !isBuy, other);
      if(other.count > 0)
        {
         Blocked(KM1_B_EXPOSURE, "opposite EA1 position is open");
         return false;
        }
     }

   g_lastTrigger = cand.trigger;
   out = cand;
   return true;
  }

//+------------------------------------------------------------------+
//| ORIGINAL LAYER - score driven continuation and exhaustion         |
//|                                                                  |
//| Unchanged in behaviour: the composite score picks a direction, the |
//| exhaustion case takes precedence over continuation, and the        |
//| PULLBACK / BREAKOUT triggers confirm a continuation.               |
//+------------------------------------------------------------------+
void TryScoreBased(const MarketView &v, EntryCandidate &c)
  {
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
      return;

//--- exhaustion takes precedence: a score stretched far enough to raise
//--- the flag is always past the continuation floor too, so continuation
//--- would otherwise win every tie
   bool isReversal = (revBias != KM_DIR_NONE);
   ENUM_KM_DIR dir = (isReversal ? revBias : contBias);

   string trig = "";
   if(isReversal)
      trig = "REVERSAL";
   else if(!Trigger(v, dir, trig))
     {
      Blocked(KM1_B_TRIGGER, StringFormat("no trigger (regime %s, score %+.0f)",
                                          KM_RegimeName(v.regime), v.score));
      return;
     }

   c.ok        = true;
   c.dir       = dir;
   c.trigger   = trig;
   c.isCounter = isReversal;
   c.tpPrice   = 0.0;                  // use the configured TP mode
   c.note      = StringFormat("score %+.0f", v.score);
  }

//+------------------------------------------------------------------+
//| ADD-ON LAYER - inside bar at a swing extreme                      |
//|                                                                  |
//| A fresh swing high, a big candle that made it, a baby candle fully |
//| inside that candle, and the entry is the break of the baby's low.  |
//| Reward is a multiple of the implied risk; no stop is ever sent.    |
//+------------------------------------------------------------------+
void TryInsideBar(const MarketView &v, EntryCandidate &c)
  {
   if(!InpUseInsideBar || !g_swingOk || !StructSwing.Valid())
      return;

   KMInsideBar ib;
   StructSwing.InsideBar(ib);
   if(!ib.found)
      return;

   double bid = KM_Bid(_Symbol);
   double ask = KM_Ask(_Symbol);
   if(bid <= 0.0 || ask <= 0.0)
      return;

//--- SELL: fresh swing high, baby low broken, not already resolved
   if(InpIbSellAtHigh && ib.atSwingHigh && !ib.brokenDown && bid < ib.babyLow)
     {
      double invalidation = (InpIbRiskFromMother ? ib.motherHigh : ib.babyHigh);
      double risk         = invalidation - bid;
      if(risk <= 0.0)
         return;

      c.ok        = true;
      c.dir       = KM_DIR_SELL;
      c.trigger   = "INSIDEBAR";
      c.isCounter = true;   // selling into a high is not a continuation
      c.tpPrice   = bid - risk * MathMax(0.5, InpIbRewardRatio);
      c.note      = StringFormat("baby low %.*f broken, risk %.2f, 1:%.1f",
                                 _Digits, ib.babyLow, risk, InpIbRewardRatio);
      return;
     }

//--- BUY: the mirror at a fresh swing low
   if(InpIbBuyAtLow && ib.atSwingLow && !ib.brokenUp && ask > ib.babyHigh)
     {
      double invalidation = (InpIbRiskFromMother ? ib.motherLow : ib.babyLow);
      double risk         = ask - invalidation;
      if(risk <= 0.0)
         return;

      c.ok        = true;
      c.dir       = KM_DIR_BUY;
      c.trigger   = "INSIDEBAR";
      c.isCounter = true;
      c.tpPrice   = ask + risk * MathMax(0.5, InpIbRewardRatio);
      c.note      = StringFormat("baby high %.*f broken, risk %.2f, 1:%.1f",
                                 _Digits, ib.babyHigh, risk, InpIbRewardRatio);
      return;
     }
  }

//+------------------------------------------------------------------+
//| ADD-ON LAYER - trend-based Fibonacci reversal level               |
//+------------------------------------------------------------------+
void TryFibReversal(const MarketView &v, EntryCandidate &c)
  {
   if(!InpUseFibRev || !g_structOk)
      return;

   KMFibSetup fs;
   Fib.Setup(fs);
   if(!fs.valid || fs.reversalDir == KM_DIR_NONE)
      return;

   string why;
   if(!Fib.ReversalSignal(fs.reversalDir, why))
      return;

   double tp = Fib.TargetFor(fs.reversalDir, InpFibRewardRatio);

   c.ok        = true;
   c.dir       = fs.reversalDir;
   c.trigger   = "FIBREV";
   c.isCounter = true;      // the trade runs against the impulse
   c.tpPrice   = tp;
   c.note      = why;
  }

//+------------------------------------------------------------------+
//| ADD-ON LAYER - the top-down playbook edge                         |
//+------------------------------------------------------------------+
void TryPlaybook(const MarketView &v, EntryCandidate &c)
  {
   if(!InpUsePlaybook || !g_playOk)
      return;

   PlaybookView pv;
   Play.View(pv);
   if(!pv.valid || pv.dir == KM_DIR_NONE)
      return;

   string why;
   if(!Play.Backs(pv.dir, why))
      return;

//--- a reversal-flavoured edge is counter-trend by nature; a trendline
//--- or VWAP-side edge is a continuation
   bool counter = (pv.edge == KM_EDGE_SR_DIVERGENCE ||
                   pv.edge == KM_EDGE_PATTERN_LEVEL);

   c.ok        = true;
   c.dir       = pv.dir;
   c.trigger   = "PLAYBOOK";
   c.isCounter = counter;
   c.tpPrice   = 0.0;       // the configured TP mode handles it
   c.note      = why;
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
//| Send the entry.                                                   |
//|                                                                  |
//| A layer that named its own target keeps it - that is how the       |
//| inside-bar 1:3 and the fib projection reach the real level instead  |
//| of a generic ATR distance. Everything else falls back to the        |
//| configured TP mode. A stop loss is never sent, by design.           |
//+------------------------------------------------------------------+
void TryEnter(const EntryCandidate &cand, const MarketView &v)
  {
   bool   isBuy = (cand.dir == KM_DIR_BUY);
   double entry = isBuy ? KM_Ask(_Symbol) : KM_Bid(_Symbol);

   double tp   = 0.0;
   double dist = 0.0;
   string tpSrc;

   if(cand.tpPrice > 0.0)
     {
      //--- the layer's own target, but only if it sits the right side of
      //--- entry; a stale level would otherwise be sent as a wrong-way TP
      bool sane = (isBuy ? (cand.tpPrice > entry) : (cand.tpPrice < entry));
      if(sane)
        {
         tp    = cand.tpPrice;
         dist  = MathAbs(tp - entry);
         tpSrc = cand.trigger;
        }
     }

   if(tp <= 0.0)
     {
      dist = TpDistance(v);
      if(dist > 0.0)
         tp = isBuy ? (entry + dist) : (entry - dist);
      tpSrc = EnumToString(InpTpMode);
     }

   long   magic = KM_Magic(InpMagicBase, KM_EA_ENTRY, isBuy);
   string note  = StringFormat("%s|s%.0f|%s", cand.trigger, v.score, KM_RegimeName(v.regime));

   ulong ticket = 0;
   if(!Exec.Open(isBuy, InpLot, magic, tp, note, ticket))
     {
      Blocked(KM1_B_SENDFAIL, "order send failed -> " + Exec.LastError());
      return;
     }

   g_lastEntryTime = TimeCurrent();
   g_lastEntryBar  = (datetime)SeriesInfoInteger(_Symbol, PERIOD_CURRENT, SERIES_LASTBAR_DATE);
   g_entryCount++;

   int ti = TriggerIndex(cand.trigger);
   if(ti >= 0)
      g_trigCount[ti]++;

   PrintFormat("KM1 ENTRY %s %.2f @ %.*f | %s | tp %.*f (%.2f away, from %s) | no SL",
               (isBuy ? "BUY" : "SELL"), InpLot, _Digits, entry,
               cand.trigger, _Digits, tp, dist, tpSrc);
   PrintFormat("KM1   why: %s | score %+.0f adx %.1f %s %s",
               cand.note, v.score, v.trendStrength,
               KM_RegimeName(v.regime), KM_VolName(v.volState));

   if(InpShowNarrative && InpUsePlaybook && g_playOk)
     {
      PlaybookView pv;
      Play.View(pv);
      if(pv.valid)
         Print("KM1   playbook at entry:\n", pv.narrative);
     }
  }

//+------------------------------------------------------------------+
//| Dashboard export.                                                 |
//|                                                                  |
//| Writes everything this EA knows: the indicator reading, the gate    |
//| outcome and why, which layer qualified and which actually entered,  |
//| the structure and trend maturity, the inside-bar and fib setups,    |
//| and the playbook's five-step narrative verbatim.                    |
//|                                                                  |
//| Full fidelity is deliberate. The dashboard backend gates what a     |
//| viewer sees behind a PIN, so anything censored at this layer would   |
//| be missing from developer mode as well - the redaction belongs       |
//| where the authentication is, not here.                              |
//|                                                                  |
//| Called last in OnTick and reads only already-computed state, so it   |
//| cannot influence a single trading decision.                         |
//+------------------------------------------------------------------+
void WriteTelemetry(const MarketView &v)
  {
   if(!InpTelemetry || !Tel.Enabled() || !Tel.Due())
      return;

   Tel.Begin();

   Tel.SymbolBlock(_Symbol);
   Tel.AccountBlock();

//--- which suite members are alive on this symbol
   bool alive[KM_EA_LAST];
   for(int s = KM_EA_FIRST; s <= KM_EA_LAST; s++)
      alive[s - KM_EA_FIRST] = Bus.Alive(s);
   Tel.Roster("roster", alive, KM_EA_LAST - KM_EA_FIRST + 1);

//=== the indicator reading =========================================
   Tel.Obj("view");
   Tel.Bool("valid",     v.valid);
   Tel.Num("score",      v.score, 1);
   Tel.Str("regime",     KM_RegimeName(v.regime));
   Tel.Str("vol",        KM_VolName(v.volState));
   Tel.Num("atr",        v.atr, _Digits);
   Tel.Num("atrRatio",   v.atrRatio, 3);
   Tel.Num("adx",        v.trendStrength, 1);
   Tel.Num("plusDI",     v.plusDI, 1);
   Tel.Num("minusDI",    v.minusDI, 1);
   Tel.Num("rsi",        v.rsi, 1);
   Tel.Num("stoch",      v.stoch, 1);
   Tel.Num("macdHist",   v.macdHist, _Digits);
   Tel.Num("macdSlope",  v.macdSlope, _Digits);
   Tel.Num("bbPercent",  v.bbPercent, 3);
   Tel.Num("bbWidth",    v.bbWidth, 5);
   Tel.Bool("mtfAgree",  v.mtfAgree);
   Tel.Bool("bullExhaust", v.bullExhaust);
   Tel.Bool("bearExhaust", v.bearExhaust);
   Tel.Num("swingHigh",  v.swingHigh, _Digits);
   Tel.Num("swingLow",   v.swingLow, _Digits);
   Tel.Num("emaFast",    v.emaFast, _Digits);
   Tel.Num("emaSlow",    v.emaSlow, _Digits);
   Tel.Num("emaFilter",  v.emaFilter, _Digits);
   Tel.Num("bbUpper",    v.bbUpper, _Digits);
   Tel.Num("bbLower",    v.bbLower, _Digits);
   Tel.EndObj();

//=== the gate: what it decided and what held it back ================
   Tel.Obj("gate");
   Tel.Int("evaluated",   g_evaluated);
   Tel.Int("entries",     g_entryCount);
   Tel.Str("lastTrigger", g_lastTrigger);
   Tel.Str("lastBlock",   g_lastBlock);
   Tel.Num("scoreBest",   g_scoreBest, 1);
   Tel.Num("adxBest",     g_adxBest, 1);
   Tel.Int("lastEntryTs", (long)g_lastEntryTime);

   Tel.Obj("floors");
   Tel.Num("minScore",        InpMinScore, 1);
   Tel.Num("minAdx",          InpMinAdx, 1);
   Tel.Num("adxTrendLevel",   InpAdxTrendLevel, 1);
   Tel.Num("reversalStretch", InpReversalStretch, 1);
   Tel.Num("maxSpreadPoints", InpMaxSpreadPoints, 0);
   Tel.Int("cooldownSec",     InpCooldownSeconds);
   Tel.EndObj();

//--- the block histogram, which is the answer to "why no entry"
   string bNames[KM1_B_COUNT];
   long   bCounts[KM1_B_COUNT];
   for(int i = 0; i < KM1_B_COUNT; i++)
     {
      bNames[i]  = BlockName(i);
      bCounts[i] = g_block[i];
     }
   Tel.CounterArray("blocks", bNames, bCounts, KM1_B_COUNT, true);
   Tel.EndObj();

//=== per-layer attribution: qualified vs actually entered ===========
   Tel.Arr("layers");
   for(int i = 0; i < KM1_T_COUNT; i++)
     {
      Tel.ArrObj();
      Tel.Str("name",      TriggerName(i));
      Tel.Int("qualified", g_trigFired[i]);
      Tel.Int("entered",   g_trigCount[i]);

      bool on = true;
      if(i == KM1_T_PULLBACK)  on = InpUsePullback;
      if(i == KM1_T_BREAKOUT)  on = InpUseBreakout;
      if(i == KM1_T_REVERSAL)  on = InpUseReversal;
      if(i == KM1_T_INSIDEBAR) on = InpUseInsideBar;
      if(i == KM1_T_FIBREV)    on = InpUseFibRev;
      if(i == KM1_T_PLAYBOOK)  on = InpUsePlaybook;
      Tel.Bool("enabled", on);
      Tel.EndObj();
     }
   Tel.EndArr();

//=== structure and trend maturity ==================================
   Tel.Obj("structure");
   Tel.Bool("ready", g_structOk && StructEntry.Valid());
   Tel.Str("summary", StructEntry.Summary());

   if(g_structOk && StructEntry.Valid())
     {
      KMTrendState ts;
      StructEntry.Trend(ts);
      Tel.Obj("trend");
      Tel.Str("dir",          (ts.dir == KM_DIR_BUY ? "UP" :
                               (ts.dir == KM_DIR_SELL ? "DOWN" : "RANGE")));
      Tel.Num("maturity",     ts.maturity, 1);
      Tel.Int("legs",         ts.legsCompleted);
      Tel.Num("extensionAtr", ts.extensionAtr, 2);
      Tel.Num("retracePct",   ts.retracePct, 1);
      Tel.Num("originPrice",  ts.originPrice, _Digits);
      Tel.Int("originBar",    ts.originBar);
      Tel.Bool("isFresh",     ts.isFresh);
      Tel.Bool("nearCorner",  ts.nearCorner);
      Tel.Bool("justFlipped", ts.justFlipped);
      Tel.EndObj();
     }
   Tel.EndObj();

//=== inside bar setup ==============================================
   Tel.Obj("insideBar");
   Tel.Bool("enabled", InpUseInsideBar);
   Tel.Str("timeframe", EnumToString(InpIbTimeframe));

   if(InpUseInsideBar && g_swingOk && StructSwing.Valid())
     {
      KMInsideBar ib;
      StructSwing.InsideBar(ib);
      Tel.Bool("found", ib.found);
      if(ib.found)
        {
         Tel.Num("babyLow",     ib.babyLow, _Digits);
         Tel.Num("babyHigh",    ib.babyHigh, _Digits);
         Tel.Num("motherLow",   ib.motherLow, _Digits);
         Tel.Num("motherHigh",  ib.motherHigh, _Digits);
         Tel.Num("motherRange", ib.motherRange, _Digits);
         Tel.Num("babyRange",   ib.babyRange, _Digits);
         Tel.Bool("atSwingHigh", ib.atSwingHigh);
         Tel.Bool("atSwingLow",  ib.atSwingLow);
         Tel.Bool("brokenDown",  ib.brokenDown);
         Tel.Bool("brokenUp",    ib.brokenUp);
         Tel.Int("ageBars",      ib.ageBars);
        }
     }
   else
      Tel.Bool("found", false);
   Tel.EndObj();

//=== trend-based fib ===============================================
   Tel.Obj("fib");
   Tel.Bool("enabled", InpUseFibRev);
   Tel.Str("summary", Fib.Summary());

   if(InpUseFibRev)
     {
      KMFibSetup fs;
      Fib.Setup(fs);
      Tel.Bool("valid", fs.valid);
      Tel.Str("reason", fs.reason);
      if(fs.valid)
        {
         Tel.Bool("impulseUp",   fs.impulseUp);
         Tel.Str("reversalDir",  (fs.reversalDir == KM_DIR_BUY ? "BUY" : "SELL"));
         Tel.Num("priceA",       fs.priceA, _Digits);
         Tel.Num("priceB",       fs.priceB, _Digits);
         Tel.Num("priceC",       fs.priceC, _Digits);
         Tel.Num("impulseSize",  fs.impulseSize, _Digits);

         Tel.Arr("levels");
         for(int i = 0; i < KM_FIB_LEVELS; i++)
           {
            Tel.ArrObj();
            Tel.Num("ratio", fs.ratio[i], 3);
            Tel.Num("price", fs.level[i], _Digits);
            Tel.EndObj();
           }
         Tel.EndArr();

         Tel.Bool("atLevel",        fs.atLevel);
         Tel.Int("nearestIdx",      fs.nearestIdx);
         Tel.Num("nearestPrice",    fs.nearestPrice, _Digits);
         Tel.Num("nearestDist",     fs.nearestDist, _Digits);
         Tel.Bool("reachedDeepest", fs.reachedDeepest);
        }
     }
   Tel.EndObj();

//=== the five-step playbook ========================================
   Tel.Obj("playbook");
   Tel.Bool("enabled", InpUsePlaybook);
   Tel.Bool("ready",   g_playOk);

   if(InpUsePlaybook && g_playOk)
     {
      PlaybookView pv;
      Play.View(pv);
      Tel.Bool("valid", pv.valid);
      Tel.Str("summary", Play.Summary());

      if(pv.valid)
        {
         Tel.Str("htfBias",     KM_HtfName(pv.htfBias));
         Tel.Num("htfMaturity", pv.htfMaturity, 1);
         Tel.Bool("htfFresh",   pv.htfFresh);

         Tel.Str("edge",        KM_EdgeName(pv.edge));
         Tel.Str("dir",         (pv.dir == KM_DIR_BUY ? "LONG" :
                                 (pv.dir == KM_DIR_SELL ? "SHORT" : "-")));
         Tel.Num("confidence",  pv.confidence, 1);
         Tel.Int("confluences", pv.confluences);

         Tel.Bool("hasLevel", pv.hasLevel);
         if(pv.hasLevel)
           {
            Tel.Num("levelPrice",    pv.levelPrice, _Digits);
            Tel.Int("levelTouches",  pv.levelTouches);
            Tel.Bool("levelIsRes",   pv.levelIsResistance);
            Tel.Num("levelStrength", pv.levelStrength, 1);
            Tel.Num("levelDistAtr",  pv.levelDistAtr, 2);
           }

         Tel.Bool("hasLine", pv.hasLine);
         if(pv.hasLine)
           {
            Tel.Bool("lineIsSupport", pv.lineIsSupport);
            Tel.Num("linePrice",      pv.linePrice, _Digits);
            Tel.Num("lineDistAtr",    pv.lineDistAtr, 2);
           }

         Tel.Bool("vwapValid", pv.vwapValid);
         if(pv.vwapValid)
           {
            Tel.Num("vwapPrice",  pv.vwapPrice, _Digits);
            Tel.Num("vwapDistSd", pv.vwapDistSd, 2);
            Tel.Bool("aboveVwap", pv.aboveVwap);
           }

         Tel.Bool("aboveMa",    pv.aboveMa);
         Tel.Num("maValue",     pv.maValue, _Digits);
         Tel.Str("divergence",  pv.divergence);
         Tel.Bool("divBull",    pv.divBull);
         Tel.Bool("divBear",    pv.divBear);
         Tel.Str("patterns",    pv.patterns);
         Tel.Bool("patBull",    pv.patBull);
         Tel.Bool("patBear",    pv.patBear);

         Tel.Str("style",     KM_StyleName(pv.style));
         Tel.Str("workingTf", EnumToString(pv.workingTf));
         Tel.Str("narrative", pv.narrative);
        }
     }
   Tel.EndObj();

//=== what this EA is currently holding =============================
   KMAgg mb, ms;
   Book.AggSlot(KM_EA_ENTRY, true,  mb);
   Book.AggSlot(KM_EA_ENTRY, false, ms);

   Tel.Obj("holdings");
   Tel.Obj("buy");
   Tel.Int("count",  mb.count);
   Tel.Num("lots",   mb.lots, 2);
   Tel.Num("profit", mb.profit, 2);
   Tel.Num("avgPrice", mb.avgPrice, _Digits);
   Tel.EndObj();
   Tel.Obj("sell");
   Tel.Int("count",  ms.count);
   Tel.Num("lots",   ms.lots, 2);
   Tel.Num("profit", ms.profit, 2);
   Tel.Num("avgPrice", ms.avgPrice, _Digits);
   Tel.EndObj();
   Tel.EndObj();

   Tel.HealthBlock();
   Tel.End();
  }

//+------------------------------------------------------------------+
void Panel(const MarketView &v)
  {
//--- The dashboard snapshot is taken here rather than in OnTick because
//--- every exit path from OnTick passes through this function, including
//--- the early return while the market view is still warming up. That is
//--- precisely a state worth seeing on the dashboard, and it must be
//--- exported whether or not the on-chart panel itself is switched on.
   WriteTelemetry(v);

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

//--- which layer is actually contributing
   t += "-----------------------------------\n";
   t += "layer            qualified  entered\n";
   for(int i = 0; i < KM1_T_COUNT; i++)
      t += StringFormat("  %-14s %8I64d %8I64d\n", TriggerName(i), g_trigFired[i], g_trigCount[i]);

//--- add-on layer state
   t += "-----------------------------------\n";
   if(InpFreshTrendOnly && g_structOk)
      t += "struct: " + StructEntry.Summary() + "\n";

   if(InpUseInsideBar)
     {
      if(g_swingOk && StructSwing.Valid())
        {
         KMInsideBar ib;
         StructSwing.InsideBar(ib);
         if(ib.found)
            t += StringFormat("insideBar %s: baby %.*f / %.*f age %d%s%s\n",
                              EnumToString(InpIbTimeframe),
                              _Digits, ib.babyLow, _Digits, ib.babyHigh, ib.ageBars,
                              (ib.atSwingHigh ? " atHIGH" : (ib.atSwingLow ? " atLOW" : "")),
                              (ib.brokenDown ? " brokeDn" : (ib.brokenUp ? " brokeUp" : "")));
         else
            t += "insideBar: none right now\n";
        }
      else
         t += "insideBar: layer offline\n";
     }

   if(InpUseFibRev)
      t += Fib.Summary() + "\n";

   if(InpUsePlaybook)
     {
      if(g_playOk)
        {
         t += "playbook: " + Play.Summary() + "\n";
         if(InpShowNarrative)
           {
            PlaybookView pv;
            Play.View(pv);
            if(pv.valid)
               t += pv.narrative + "\n";
           }
        }
      else
         t += "playbook: layer offline\n";
     }

   t += "no stop loss is used - EA2/3/4 manage adverse moves\n";

   Comment(t);
  }
//+------------------------------------------------------------------+
