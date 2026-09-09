//+------------------------------------------------------------------+
//|                                           KM6_TfSelect.mq5       |
//|                                                                  |
//|  KRISHMIX EA 6  -  THE TIMEFRAME BOT                               |
//|                                                                  |
//|  Places no trades. Its only job is step 5 of the playbook: decide  |
//|  what kind of trading the current conditions actually support, and  |
//|  publish that decision so the entry logic can read it.             |
//|                                                                  |
//|      SCALP     M1 / M3 / M5                                        |
//|      INTRADAY  M5 / M15                                            |
//|      SWING     H1 / H4                                             |
//|                                                                  |
//|  One instance covers the whole watchlist, so it needs a single      |
//|  chart no matter how many assets the suite trades. Each symbol      |
//|  gets its own decision, published under KM.<symbol>.style and       |
//|  KM.<symbol>.worktf.                                               |
//|                                                                  |
//|  The dominant term is spread economics: scalping is only viable     |
//|  while the spread is small next to the range a bar delivers. On     |
//|  gold and the indices that test alone rules scalping out for most   |
//|  of the session, which is the honest answer rather than a           |
//|  flattering one.                                                    |
//+------------------------------------------------------------------+
#property copyright "krish-mix"
#property link      "https://github.com/kirox0009-boop/krish-mix"
#property version   "1.00"
#property description "KrishMix 6 - decides scalp / intraday / swing per symbol and publishes the working timeframe."
#property description "Trades nothing. One chart covers the whole watchlist."

#include <KrishMix\Common.mqh>
#include <KrishMix\StateBus.mqh>
#include <KrishMix\TfSelect.mqh>
//--- read-only state export for the dashboard
#include <KrishMix\Telemetry.mqh>

//+------------------------------------------------------------------+
input group "=== Symbols ==="
input string          InpSymbols        = "";     // Watchlist, comma separated (empty = this chart only)

input group "=== Spread economics (the decisive test) ==="
input double          InpSpreadScalpMax = 0.25;   // spread/ATR above this: scalping is uneconomic
input double          InpSpreadIntraMax = 0.60;   // spread/ATR above this: even intraday suffers

input group "=== Reference timeframes ==="
input ENUM_TIMEFRAMES InpRefTf          = PERIOD_M5;  // Timeframe the spread is judged against
input ENUM_TIMEFRAMES InpTrendTf        = PERIOD_H1;  // Timeframe persistence is judged on
input int             InpAtrPeriod      = 14;     // ATR period
input int             InpAtrAvgPeriod   = 100;    // ATR average period
input int             InpAdxPeriod      = 14;     // ADX period

input group "=== Thresholds ==="
input double          InpVolLow         = 0.75;   // atrRatio at or below = dead market
input double          InpVolHigh        = 1.30;   // atrRatio at or above = expanding
input double          InpAdxTrending    = 25.0;   // ADX at or above = durable trend
input int             InpLiquidFrom     = 8;      // Liquid session start hour (server)
input int             InpLiquidTo       = 20;     // Liquid session end hour (server)

input group "=== Allowed styles ==="
input bool            InpAllowScalp     = true;   // Allow SCALP
input bool            InpAllowIntraday  = true;   // Allow INTRADAY
input bool            InpAllowSwing     = true;   // Allow SWING

input group "=== Dashboard telemetry (read only) ==="
input bool            InpTelemetry      = true;   // Export state for the dashboard
input int             InpTelemetrySec   = 15;     // Seconds between snapshots

input group "=== Operation ==="
input int             InpRecheckSeconds = 60;     // Re-decide no more often than this
input bool            InpLogChanges     = true;   // Log every style change
input bool            InpShowPanel      = true;   // On-chart panel

//+------------------------------------------------------------------+
CKMTelemetry  Tel;          // dashboard export, read only
string        g_symbols[];
int           g_nSymbols = 0;
CKMTfSelect   g_sel[KM_MAX_SYMBOLS];
CKMBus        g_bus[KM_MAX_SYMBOLS];
ENUM_KM_STYLE g_lastStyle[KM_MAX_SYMBOLS];
bool          g_styleLogged[KM_MAX_SYMBOLS];
bool          g_ready[KM_MAX_SYMBOLS];
datetime      g_lastRun = 0;

//+------------------------------------------------------------------+
int OnInit()
  {
   string list = InpSymbols;
   StringTrimLeft(list);
   StringTrimRight(list);
   if(StringLen(list) == 0)
      list = _Symbol;

   string missing = "";
   g_nSymbols = KM_ResolveSymbolList(list, g_symbols, missing);

   if(g_nSymbols <= 0)
     {
      Alert("KM6: none of the configured symbols could be resolved on this broker.");
      return(INIT_FAILED);
     }

   if(StringLen(missing) > 0)
      Print("KM6 WARNING: could not resolve -> ", missing,
            "(check the exact names in Market Watch)");

   TfSelectConfig cfg;
   KM_DefaultTfSelectConfig(cfg);
   cfg.refTf             = InpRefTf;
   cfg.trendTf           = InpTrendTf;
   cfg.atrPeriod         = InpAtrPeriod;
   cfg.atrAvgPeriod      = InpAtrAvgPeriod;
   cfg.adxPeriod         = InpAdxPeriod;
   cfg.spreadScalpMax    = InpSpreadScalpMax;
   cfg.spreadIntradayMax = InpSpreadIntraMax;
   cfg.volLow            = InpVolLow;
   cfg.volHigh           = InpVolHigh;
   cfg.adxTrending       = InpAdxTrending;
   cfg.liquidFromHour    = InpLiquidFrom;
   cfg.liquidToHour      = InpLiquidTo;
   cfg.allowScalp        = InpAllowScalp;
   cfg.allowIntraday     = InpAllowIntraday;
   cfg.allowSwing        = InpAllowSwing;

   if(!InpAllowScalp && !InpAllowIntraday && !InpAllowSwing)
     {
      Alert("KM6: every style is disabled, there is nothing to choose from.");
      return(INIT_FAILED);
     }

   for(int i = 0; i < g_nSymbols; i++)
     {
      g_sel[i].Config(cfg);
      g_ready[i] = g_sel[i].Init(g_symbols[i]);
      if(!g_ready[i])
         Print("KM6: ", g_symbols[i], " not ready -> ", g_sel[i].LastIssue());

      g_bus[i].Init(g_symbols[i]);
      g_lastStyle[i]    = KM_STYLE_INTRADAY;
      g_styleLogged[i]  = false;   // so the first decision always logs
     }

   string names = "";
   for(int i = 0; i < g_nSymbols; i++)
      names += g_symbols[i] + " ";

   PrintFormat("KM6 TfSelect v%s | %d symbol(s): %s", KM_VERSION, g_nSymbols, names);
   PrintFormat("KM6 spread gates: scalp <= %.2f ATR, intraday <= %.2f ATR (measured on %s)",
               InpSpreadScalpMax, InpSpreadIntraMax, EnumToString(InpRefTf));
   Print("KM6 places no orders. It publishes KM.<symbol>.style and KM.<symbol>.worktf.");

   if(InpTelemetry)
     {
      if(Tel.Init("KM6", "PORTFOLIO", InpTelemetrySec))
         PrintFormat("KM6 telemetry -> MQL5\\Files\\%s", Tel.FileName());
      else
         Print("KM6 telemetry could not start: ", Tel.LastError());
     }

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   for(int i = 0; i < g_nSymbols; i++)
      g_sel[i].Release();
   Comment("");
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   //--- every symbol shares one heartbeat slot for this EA
   for(int i = 0; i < g_nSymbols; i++)
      g_bus[i].Beat(KM_EA_TFSELECT);

   if(InpRecheckSeconds > 0 && (TimeCurrent() - g_lastRun) < InpRecheckSeconds)
     {
      Panel();
      return;
     }
   g_lastRun = TimeCurrent();

   for(int i = 0; i < g_nSymbols; i++)
     {
      if(!g_ready[i])
        {
         //--- a symbol can become tradable later, so keep retrying
         g_ready[i] = g_sel[i].Init(g_symbols[i]);
         if(!g_ready[i])
            continue;
        }

      KMTfDecision d;
      if(!g_sel[i].Refresh(d) || !d.valid)
         continue;

      g_bus[i].PublishStyle(d.style, d.tf);

      if(InpLogChanges && (!g_styleLogged[i] || d.style != g_lastStyle[i]))
        {
         PrintFormat("KM6 %s -> %s on %s | %s",
                     g_symbols[i], KM_StyleName(d.style), EnumToString(d.tf), d.reason);
         g_lastStyle[i]   = d.style;
         g_styleLogged[i] = true;
        }
     }

   Panel();
  }

//+------------------------------------------------------------------+
//| Dashboard export. Read only.                                      |
//|                                                                  |
//| Exports the style decision per symbol together with the three       |
//| competing scores and the reason text, so the dashboard can show     |
//| WHY a symbol is on swing rather than scalp - which is nearly always |
//| the spread-economics term.                                          |
//+------------------------------------------------------------------+
void WriteTelemetry(void)
  {
   if(!InpTelemetry || !Tel.Enabled() || !Tel.Due())
      return;

   Tel.Begin();

   Tel.Arr("symbols");
   for(int i = 0; i < g_nSymbols; i++)
     {
      Tel.ArrObj();
      Tel.Str("symbol", g_symbols[i]);
      Tel.Bool("ready", g_ready[i]);

      if(g_ready[i])
        {
         KMTfDecision d;
         g_sel[i].Decision(d);
         Tel.Bool("valid", d.valid);
         if(d.valid)
           {
            Tel.Str("style",         KM_StyleName(d.style));
            Tel.Str("timeframe",     EnumToString(d.tf));
            Tel.Num("scalpScore",    d.scalpScore, 0);
            Tel.Num("intradayScore", d.intradayScore, 0);
            Tel.Num("swingScore",    d.swingScore, 0);
            Tel.Num("spreadCost",    d.spreadCost, 3);
            Tel.Num("atrRatio",      d.atrRatio, 3);
            Tel.Num("adx",           d.adxHigh, 1);
            Tel.Bool("liquidSession", d.liquidSession);
            Tel.Int("serverHour",    d.serverHour);
            Tel.Str("reason",        d.reason);
           }
        }
      else
         Tel.Str("issue", g_sel[i].LastIssue());

      Tel.EndObj();
     }
   Tel.EndArr();

   Tel.Obj("config");
   Tel.Num("spreadScalpMax", InpSpreadScalpMax, 3);
   Tel.Num("spreadIntraMax", InpSpreadIntraMax, 3);
   Tel.Str("refTf",          EnumToString(InpRefTf));
   Tel.Str("trendTf",        EnumToString(InpTrendTf));
   Tel.Num("volLow",         InpVolLow, 2);
   Tel.Num("volHigh",        InpVolHigh, 2);
   Tel.Num("adxTrending",    InpAdxTrending, 1);
   Tel.Bool("allowScalp",    InpAllowScalp);
   Tel.Bool("allowIntraday", InpAllowIntraday);
   Tel.Bool("allowSwing",    InpAllowSwing);
   Tel.EndObj();

   Tel.HealthBlock();
   Tel.End();
  }

//+------------------------------------------------------------------+
void Panel()
  {
//--- exported here because every OnTick exit path reaches Panel()
   WriteTelemetry();

   if(!InpShowPanel)
      return;

   static datetime last = 0;
   if(TimeCurrent() == last)
      return;
   last = TimeCurrent();

   string t = "==== KM6  TIMEFRAME SELECTOR ====\n";
   t += StringFormat("%d symbol(s), re-decided every %ds\n", g_nSymbols, InpRecheckSeconds);
   t += "spread gate: scalp <= " + DoubleToString(InpSpreadScalpMax, 2) + " ATR\n";
   t += "---------------------------------\n";
   t += "symbol     style    timeframe  spread  vol   adx\n";

   for(int i = 0; i < g_nSymbols; i++)
     {
      if(!g_ready[i])
        {
         t += StringFormat("%-10s not ready\n", g_symbols[i]);
         continue;
        }

      KMTfDecision d;
      g_sel[i].Decision(d);

      if(!d.valid)
        {
         t += StringFormat("%-10s warming up\n", g_symbols[i]);
         continue;
        }

      t += StringFormat("%-10s %-8s %-10s %5.2f  x%.2f  %3.0f%s\n",
                        g_symbols[i], KM_StyleName(d.style),
                        EnumToString(d.tf), d.spreadCost, d.atrRatio, d.adxHigh,
                        (d.liquidSession ? "" : "  thin"));
     }

   t += "---------------------------------\n";
   t += "published to the state bus for EA1 / EA5\n";

   Comment(t);
  }
//+------------------------------------------------------------------+
