//+------------------------------------------------------------------+
//|                                          KM5_Portfolio.mq5       |
//|                                                                  |
//|  KRISHMIX EA 5  -  MULTI-ASSET RECOVERY AND PORTFOLIO EXIT         |
//|                                                                  |
//|  One chart covers the whole watchlist: gold, bitcoin, silver, oil,  |
//|  the tech index and the Dow. Three jobs.                            |
//|                                                                  |
//|  1. ENTRIES on every asset, independently. There is no             |
//|     one-asset-at-a-time rule: whenever a symbol meets the          |
//|     requirements an order goes in, whether or not something is     |
//|     already running elsewhere.                                     |
//|                                                                  |
//|  2. CROSS-ASSET ASSIST. When one symbol is stuck, the others help  |
//|     pull it out. KM5 finds the deepest drawdown, works out how     |
//|     much money has to be earned back, and opens sized positions on |
//|     OTHER symbols where it has real directional conviction. The    |
//|     load is split across every eligible helper, so recovery comes  |
//|     from several markets at once instead of doubling down on the   |
//|     one that is already hurting.                                   |
//|                                                                  |
//|     Sizing is per symbol, because contract values differ by four   |
//|     orders of magnitude. A dollar of gold movement is $100 a lot;  |
//|     an index point is $1 a lot. The recovery horizon is therefore  |
//|     expressed in ATR multiples and converted per symbol.           |
//|                                                                  |
//|     There is also an overshoot guard. The minimum volume on an     |
//|     index is 0.10 lots, which over an 8 ATR move on the Dow is     |
//|     worth about $120 - so a $50 drawdown cannot be assisted there  |
//|     without the help becoming a bigger bet than the problem. Such  |
//|     a helper is skipped rather than sized up.                       |
//|                                                                  |
//|  3. PORTFOLIO EXIT. Once everything together is far enough ahead,  |
//|     the whole book closes. Per-symbol baskets still belong to EA4; |
//|     this is the level above it.                                    |
//|                                                                  |
//|  Where the full per-symbol suite is already running, KM5 sees the  |
//|  heartbeat and does not open entries there - it only contributes    |
//|  assist volume and portfolio accounting.                            |
//|                                                                  |
//|  No stop loss, no equity rule, no halt state - same as the rest.    |
//+------------------------------------------------------------------+
#property copyright "krish-mix"
#property link      "https://github.com/kirox0009-boop/krish-mix"
#property version   "1.00"
#property description "KrishMix 5 - multi-asset entries, cross-asset recovery assist and portfolio exit."
#property description "One chart covers the whole watchlist. Assist volume is sized per symbol."

#include <KrishMix\Common.mqh>
#include <KrishMix\StateBus.mqh>
#include <KrishMix\Signals.mqh>
#include <KrishMix\Structure.mqh>
#include <KrishMix\Execution.mqh>
#include <KrishMix\Portfolio.mqh>

//+------------------------------------------------------------------+
input group "=== Suite wiring (keep the magic base identical everywhere) ==="
input long            InpMagicBase        = KM_MAGIC_BASE_DEFAULT; // Magic base
input double          InpCommissionPerLot = 0.0;   // Round-turn commission per 1.00 lot
input int             InpSlippagePoints   = 40;    // Max deviation, points

input group "=== Watchlist ==="
input string          InpSymbols          = "XAUUSD,BTCUSD,XAGUSD,XTIUSD,USTEC,US30"; // Assets, comma separated
input bool            InpDeferToSuite     = true;  // Do not open entries where EA1 is already live

input group "=== Entries (one asset never blocks another) ==="
input bool            InpAllowEntries     = true;  // Let KM5 open initial entries
input double          InpLot              = 0.01;  // Entry lot (scaled per symbol below)
input bool            InpScaleLotByAsset  = true;  // Scale so each asset risks a similar amount
input double          InpRiskPerEntry     = 20.0;  // Money one ATR of adverse move should cost
input int             InpMaxEntriesPerSym = 1;     // Max KM5 entries per symbol per direction
input double          InpMinScore         = 40.0;  // Conviction floor
input double          InpMinAdx           = 20.0;  // ADX floor
input bool            InpRequireMtfAgree  = true;  // Higher timeframes must agree
input bool            InpFreshTrendOnly   = true;  // Never join a move already running
input double          InpFreshMinRetrace  = 50.0;  // Pullback depth that re-opens a corner
input double          InpEntryTpAtrMult   = 2.00;  // Entry TP as an ATR multiple (0 = no TP)
input int             InpEntryCooldownSec = 600;   // Min seconds between KM5 entries per symbol
input double          InpMaxSpreadAtr     = 0.30;  // Skip when spread exceeds this fraction of ATR

input group "=== Cross-asset recovery assist ==="
input bool            InpAllowAssist      = true;  // Enable cross-asset assist
input double          InpAssistTriggerDd   = 60.0;  // Symbol drawdown that calls for help
input double          InpAssistCoverage    = 1.00;  // Fraction of the drawdown to target
input double          InpAssistHorizonAtr  = 8.00;  // Expect recovery over this many ATR
input double          InpAssistMinScore    = 55.0;  // Conviction floor for a helper
input double          InpAssistMinAdx      = 24.0;  // ADX floor for a helper
input bool             InpAssistRequireTrend = true; // Regime must back the helper direction
input bool             InpAssistBlockExhaust = true; // Never assist into an exhausted move
input double          InpAssistMaxOvershoot = 2.00; // Skip a helper whose min lot overshoots this much
input double          InpAssistMaxLotPerSym = 1.00; // Ceiling per assist order
input int             InpAssistMaxLegsPerSym= 2;    // Max assist legs per symbol
input int             InpAssistCooldownSec  = 300;  // Min seconds between assist orders

input group "=== Portfolio exit ==="
input bool            InpClosePortfolio   = true;  // Close the whole book at the target
input double          InpPfTargetPerLot    = 25.0;  // Money per 1.00 lot of total volume
input double          InpPfMinTarget       = 2.00;  // Absolute floor, always > 0
input int             InpPfManageFromLegs  = 2;     // Portfolio exit needs at least this many legs
input int             InpPfDepthReliefFrom = 4;     // Relief starts past this many legs
input double          InpPfDepthReliefStep = 0.94;  // Multiplier per extra leg
input double          InpPfMinReliefFloor  = 0.20;  // Relief never below this

input group "=== Signal engine (per symbol) ==="
input int             InpEmaFast          = 8;     // Fast EMA
input int             InpEmaSlow          = 21;    // Slow EMA
input int             InpEmaFilter        = 50;    // Filter EMA
input ENUM_TIMEFRAMES InpWorkTf           = PERIOD_M15; // Working timeframe for all symbols
input ENUM_TIMEFRAMES InpMtf1             = PERIOD_H1;  // Higher timeframe 1
input ENUM_TIMEFRAMES InpMtf2             = PERIOD_H4;  // Higher timeframe 2
input int             InpAdxPeriod        = 14;    // ADX period
input int             InpAtrPeriod        = 14;    // ATR period
input int             InpDonchianPeriod   = 40;    // Donchian lookback

input group "=== Display ==="
input bool            InpShowPanel        = true;  // On-chart panel
input int             InpLogSeconds       = 300;   // Log a portfolio summary every N seconds

//+------------------------------------------------------------------+
CKMPortfolio Pf;
CKMSignals   Sig[KM_MAX_SYMBOLS];
CKMStructure Struct[KM_MAX_SYMBOLS];
CKMExec      Exec[KM_MAX_SYMBOLS];
CKMBus       Bus[KM_MAX_SYMBOLS];

string     g_symbols[];
int        g_n = 0;
bool       g_ready[KM_MAX_SYMBOLS];
MarketView g_view[KM_MAX_SYMBOLS];
bool       g_viewOk[KM_MAX_SYMBOLS];
datetime   g_lastEntry[KM_MAX_SYMBOLS];

datetime   g_lastAssist   = 0;
int        g_assistCount  = 0;
int        g_entryCount   = 0;
int        g_closeCount   = 0;
string     g_lastAction   = "-";
string     g_assistWhy    = "-";
double     g_pfTarget     = 0.0;

//+------------------------------------------------------------------+
int OnInit()
  {
   if((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
     {
      Alert("KrishMix needs a HEDGING account. This one is netting.");
      return(INIT_FAILED);
     }

   if(InpPfMinTarget <= 0.0)
     {
      Alert("KM5: InpPfMinTarget must be above zero - the portfolio only ever closes in profit.");
      return(INIT_FAILED);
     }

   string missing = "";
   g_n = KM_ResolveSymbolList(InpSymbols, g_symbols, missing);

   if(g_n <= 0)
     {
      Alert("KM5: none of the configured symbols could be resolved on this broker.");
      return(INIT_FAILED);
     }
   if(StringLen(missing) > 0)
      Print("KM5 WARNING: could not resolve -> ", missing,
            "(check the exact names in Market Watch)");

   Pf.Init(InpMagicBase, InpCommissionPerLot);
   Pf.SetSymbols(g_symbols, g_n);

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
   cfg.adxTrendLevel  = InpMinAdx;      // keep the regime aligned with the gate
   cfg.donchianShift  = 2;

   StructureConfig sc;
   KM_DefaultStructureConfig(sc);

   for(int i = 0; i < g_n; i++)
     {
      Sig[i].Config(cfg);
      g_ready[i] = Sig[i].Init(g_symbols[i], InpWorkTf);
      if(!g_ready[i])
         Print("KM5: ", g_symbols[i], " signal engine not ready");

      Struct[i].Config(sc);
      Struct[i].Init(g_symbols[i], InpWorkTf);

      Exec[i].Init(g_symbols[i], InpSlippagePoints, "KM5");
      Bus[i].Init(g_symbols[i]);

      g_viewOk[i]    = false;
      g_lastEntry[i] = 0;
     }

   string names = "";
   for(int i = 0; i < g_n; i++)
      names += g_symbols[i] + " ";

   PrintFormat("KM5 Portfolio v%s | %d asset(s) on %s: %s",
               KM_VERSION, g_n, EnumToString(InpWorkTf), names);
   PrintFormat("KM5 magic slot %d -> buy %I64d / sell %I64d",
               KM_EA_PORTFOLIO,
               KM_Magic(InpMagicBase, KM_EA_PORTFOLIO, true),
               KM_Magic(InpMagicBase, KM_EA_PORTFOLIO, false));
   PrintFormat("KM5 assist: trigger %.2f drawdown, cover %.0f%% over %.1f ATR, overshoot guard %.1fx",
               InpAssistTriggerDd, InpAssistCoverage * 100.0,
               InpAssistHorizonAtr, InpAssistMaxOvershoot);
   PrintFormat("KM5 portfolio exit: %.2f per 1.00 lot, floor %.2f, from %d legs",
               InpPfTargetPerLot, InpPfMinTarget, InpPfManageFromLegs);
   Print("KM5: entries on one asset never block another. No SL, no equity rule, no halt.");

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   for(int i = 0; i < g_n; i++)
      Sig[i].Release();
   Comment("");
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   for(int i = 0; i < g_n; i++)
      Bus[i].Beat(KM_EA_PORTFOLIO);

//--- refresh every symbol's reading
   for(int i = 0; i < g_n; i++)
     {
      if(!g_ready[i])
        {
         g_ready[i] = Sig[i].Init(g_symbols[i], InpWorkTf);
         if(!g_ready[i])
            continue;
        }

      g_viewOk[i] = (Sig[i].Refresh(g_view[i]) && g_view[i].valid);
      if(g_viewOk[i])
         Struct[i].Refresh(g_view[i].atr);
     }

   Pf.Scan();
   Publish();

//--- take profit before adding risk
   if(InpClosePortfolio && TryPortfolioExit())
     {
      Panel();
      return;
     }

   if(InpAllowAssist)
      TryAssist();

   if(InpAllowEntries)
      TryEntries();

   LogSummary();
   Panel();
  }

//+------------------------------------------------------------------+
//| Publish each symbol's slice so the per-symbol EAs can see it      |
//+------------------------------------------------------------------+
void Publish(void)
  {
   for(int i = 0; i < g_n; i++)
     {
      KMSymbolState s;
      if(!Pf.State(i, s))
         continue;
      Bus[i].Set(KM_KEY_PF_DD,     s.drawdown);
      Bus[i].Set(KM_KEY_PF_LOTS,   s.lots);
      Bus[i].Set(KM_KEY_PF_ASSIST, (double)s.assistLegs);
     }
  }

//+------------------------------------------------------------------+
//| Lot for an entry, normalised so each asset risks a similar amount |
//|                                                                  |
//| Without this the same 0.01 lot means $6 of exposure per ATR on     |
//| gold and $500 on bitcoin. Scaling by the asset's own ATR value     |
//| makes one input mean the same thing everywhere.                    |
//+------------------------------------------------------------------+
double EntryLotFor(const int i)
  {
   if(!InpScaleLotByAsset)
      return KM_NormalizeLot(g_symbols[i], InpLot);

   double atr = g_view[i].atr;
   if(atr <= 0.0)
      return KM_NormalizeLot(g_symbols[i], InpLot);

   double perLot = KM_MoneyPerPricePerLot(g_symbols[i]);
   if(perLot <= 0.0)
      return KM_NormalizeLot(g_symbols[i], InpLot);

   double lot = InpRiskPerEntry / (atr * perLot);
   return KM_NormalizeLot(g_symbols[i], lot);
  }

//+------------------------------------------------------------------+
//| Entries, per symbol, independently                                |
//+------------------------------------------------------------------+
void TryEntries(void)
  {
   if(!TerminalInfoInteger(TERMINAL_CONNECTED) ||
      !MQLInfoInteger(MQL_TRADE_ALLOWED)       ||
      !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
      return;

   for(int i = 0; i < g_n; i++)
     {
      KMSymbolState st;
      if(!Pf.State(i, st) || !st.tradable)
         continue;
      if(!g_viewOk[i])
         continue;

      //--- the full suite owns this symbol's entries
      if(InpDeferToSuite && Bus[i].Alive(KM_EA_ENTRY))
         continue;

      if(InpEntryCooldownSec > 0 && g_lastEntry[i] > 0 &&
         (TimeCurrent() - g_lastEntry[i]) < InpEntryCooldownSec)
         continue;

      double atr = g_view[i].atr;
      if(atr <= 0.0)
         continue;

      //--- spread judged against this asset's own volatility
      double point  = SymbolInfoDouble(g_symbols[i], SYMBOL_POINT);
      double spread = (double)SymbolInfoInteger(g_symbols[i], SYMBOL_SPREAD) * point;
      if(InpMaxSpreadAtr > 0.0 && spread > atr * InpMaxSpreadAtr)
         continue;

      if(g_view[i].volState == KM_VOL_EXTREME)
         continue;

      ENUM_KM_DIR dir = Sig[i].Bias(g_view[i], InpMinScore);
      if(dir == KM_DIR_NONE)
         continue;

      if(InpRequireMtfAgree && !g_view[i].mtfAgree)
         continue;
      if(g_view[i].trendStrength < InpMinAdx)
         continue;

      if(InpFreshTrendOnly)
        {
         if(!Struct[i].Valid())
            continue;
         string why;
         if(!Struct[i].EntryIsFresh(dir, InpFreshMinRetrace, why))
            continue;
        }

      bool isBuy = (dir == KM_DIR_BUY);

      //--- KM5's own legs only. Entries and assists share magic slot 5, so
      //--- heavy assisting does count toward this cap - deliberately, since
      //--- it keeps total exposure per symbol bounded.
      int mine = (isBuy ? st.km5BuyLegs : st.km5SellLegs);
      if(InpMaxEntriesPerSym > 0 && mine >= InpMaxEntriesPerSym)
         continue;

      double lot = EntryLotFor(i);
      if(lot <= 0.0)
         continue;

      double entry = (isBuy ? KM_Ask(g_symbols[i]) : KM_Bid(g_symbols[i]));
      double tp    = 0.0;
      if(InpEntryTpAtrMult > 0.0)
        {
         double d = atr * InpEntryTpAtrMult;
         tp = (isBuy ? entry + d : entry - d);
        }

      long   magic = KM_Magic(InpMagicBase, KM_EA_PORTFOLIO, isBuy);
      string note  = StringFormat("ENTRY|s%.0f", g_view[i].score);

      ulong ticket = 0;
      if(!Exec[i].Open(isBuy, lot, magic, tp, note, ticket))
         continue;

      g_lastEntry[i] = TimeCurrent();
      g_entryCount++;
      g_lastAction = StringFormat("entry %s %s %.2f",
                                  g_symbols[i], (isBuy ? "BUY" : "SELL"), lot);

      PrintFormat("KM5 ENTRY %s %s %.2f lots @ %.*f | score %+.0f adx %.1f %s | tp %.*f | no SL",
                  g_symbols[i], (isBuy ? "BUY" : "SELL"), lot,
                  (int)SymbolInfoInteger(g_symbols[i], SYMBOL_DIGITS), entry,
                  g_view[i].score, g_view[i].trendStrength,
                  KM_RegimeName(g_view[i].regime),
                  (int)SymbolInfoInteger(g_symbols[i], SYMBOL_DIGITS), tp);
     }
  }

//+------------------------------------------------------------------+
//| Cross-asset assist: the other markets pull the stuck one out      |
//+------------------------------------------------------------------+
void TryAssist(void)
  {
   g_assistWhy = "-";

   KMPortfolioTotals tot;
   Pf.Totals(tot);

   if(tot.worstIdx < 0 || tot.worstDrawdown < InpAssistTriggerDd)
     {
      g_assistWhy = StringFormat("worst drawdown %.2f below trigger %.2f",
                                 tot.worstDrawdown, InpAssistTriggerDd);
      return;
     }

   if(InpAssistCooldownSec > 0 && g_lastAssist > 0 &&
      (TimeCurrent() - g_lastAssist) < InpAssistCooldownSec)
     {
      g_assistWhy = StringFormat("pacing, %ds since the last assist",
                                 (int)(TimeCurrent() - g_lastAssist));
      return;
     }

   KMSymbolState stuck;
   if(!Pf.State(tot.worstIdx, stuck))
      return;

//--- how much still has to be earned back, after crediting the assist
//--- volume already working
   double needed = stuck.drawdown * MathMax(0.1, InpAssistCoverage);

   for(int i = 0; i < g_n; i++)
     {
      if(i == tot.worstIdx)
         continue;
      KMSymbolState s;
      if(!Pf.State(i, s) || s.assistLots <= 0.0 || !g_viewOk[i])
         continue;
      needed -= CKMPortfolio::AssistDelivers(g_symbols[i], s.assistLots,
                                             g_view[i].atr, InpAssistHorizonAtr);
     }

   if(needed <= 0.0)
     {
      g_assistWhy = "existing assist volume already covers it";
      return;
     }

//--- who can actually help right now?
   int    eligible[KM_MAX_SYMBOLS];
   int    nElig = 0;
   bool   wantBuy[KM_MAX_SYMBOLS];

   for(int i = 0; i < g_n; i++)
     {
      if(i == tot.worstIdx)
         continue;

      KMSymbolState s;
      if(!Pf.State(i, s) || !s.tradable || !g_viewOk[i])
         continue;

      if(InpAssistMaxLegsPerSym > 0 && s.assistLegs >= InpAssistMaxLegsPerSym)
         continue;

      double atr = g_view[i].atr;
      if(atr <= 0.0)
         continue;

      //--- conviction: this is a directional bet, it needs a real read
      ENUM_KM_DIR dir = Sig[i].Bias(g_view[i], InpAssistMinScore);
      if(dir == KM_DIR_NONE)
         continue;
      if(g_view[i].trendStrength < InpAssistMinAdx)
         continue;
      if(InpAssistRequireTrend && !KM_RegimeFavours(g_view[i].regime, dir))
         continue;

      //--- never join the last gasp of a move
      if(InpAssistBlockExhaust)
        {
         bool exhausted = (dir == KM_DIR_BUY ? g_view[i].bullExhaust
                           : g_view[i].bearExhaust);
         if(exhausted)
            continue;
        }

      eligible[nElig] = i;
      wantBuy[nElig]  = (dir == KM_DIR_BUY);
      nElig++;
     }

   if(nElig <= 0)
     {
      g_assistWhy = StringFormat("%s is -%.2f but no other asset has conviction",
                                 stuck.symbol, stuck.drawdown);
      return;
     }

//--- split the load across every helper
   double share = needed / (double)nElig;
   int    opened = 0;

   for(int k = 0; k < nElig; k++)
     {
      int  i     = eligible[k];
      bool isBuy = wantBuy[k];
      double atr = g_view[i].atr;

      double want = CKMPortfolio::AssistLotsFor(g_symbols[i], share, atr,
                                                InpAssistHorizonAtr);
      if(want <= 0.0)
         continue;

      if(InpAssistMaxLotPerSym > 0.0)
         want = MathMin(want, InpAssistMaxLotPerSym);

      double lot = KM_NormalizeLot(g_symbols[i], want);

      //--- OVERSHOOT GUARD. Normalising can only round UP to the broker's
      //--- minimum, and on an index that minimum is large: 0.10 lots of
      //--- the Dow over 8 ATR is worth roughly $120, so a $40 share would
      //--- be answered with a $120 bet. Skip rather than oversize.
      double delivers = CKMPortfolio::AssistDelivers(g_symbols[i], lot, atr,
                                                     InpAssistHorizonAtr);
      if(share > 0.0 && delivers > share * MathMax(1.0, InpAssistMaxOvershoot))
        {
         PrintFormat("KM5 assist skips %s: minimum %.2f lots would recover %.2f "
                     "for a %.2f share (%.1fx overshoot)",
                     g_symbols[i], lot, delivers, share, delivers / share);
         continue;
        }

      long   magic = KM_Magic(InpMagicBase, KM_EA_PORTFOLIO, isBuy);
      string note  = StringFormat("ASSIST|%s|s%.0f", stuck.symbol, g_view[i].score);

      ulong ticket = 0;
      if(!Exec[i].Open(isBuy, lot, magic, 0.0, note, ticket))
         continue;

      opened++;
      g_assistCount++;

      PrintFormat("KM5 ASSIST %s %s %.2f lots to recover %.2f of %s's %.2f drawdown "
                  "| score %+.0f adx %.1f %s | delivers ~%.2f over %.1f ATR",
                  g_symbols[i], (isBuy ? "BUY" : "SELL"), lot, share,
                  stuck.symbol, stuck.drawdown,
                  g_view[i].score, g_view[i].trendStrength,
                  KM_RegimeName(g_view[i].regime), delivers, InpAssistHorizonAtr);
     }

   if(opened > 0)
     {
      g_lastAssist = TimeCurrent();
      g_lastAction = StringFormat("assist x%d for %s", opened, stuck.symbol);
      g_assistWhy  = StringFormat("opened %d helper(s) for %s (-%.2f)",
                                  opened, stuck.symbol, stuck.drawdown);
     }
   else
      g_assistWhy = StringFormat("%d helper(s) eligible but all were skipped", nElig);
  }

//+------------------------------------------------------------------+
//| Portfolio exit                                                    |
//+------------------------------------------------------------------+
bool TryPortfolioExit(void)
  {
   KMPortfolioTotals tot;
   Pf.Totals(tot);

   g_pfTarget = 0.0;

   if(tot.legs < MathMax(1, InpPfManageFromLegs))
      return false;

//--- nothing has gone wrong yet: every leg is an entry riding its own
//--- take profit, so sweeping the book would just cut those targets short
   if(Pf.StillEntryTpPhase())
      return false;

   double target = InpPfTargetPerLot * tot.lots;

//--- a deeper book gets an easier exit, so it can escape rather than
//--- hold out for a full win
   double relief = 1.0;
   if(InpPfDepthReliefFrom > 0 && tot.legs > InpPfDepthReliefFrom)
      relief = MathPow(MathMax(0.5, MathMin(1.0, InpPfDepthReliefStep)),
                       tot.legs - InpPfDepthReliefFrom);
   relief = MathMax(MathMax(0.01, InpPfMinReliefFloor), relief);

   target *= relief;
   target  = MathMax(target, InpPfMinTarget);   // always positive
   g_pfTarget = target;

   if(tot.profit < target)
      return false;

   ulong tickets[];
   int n = Pf.TicketsAll(tickets);
   if(n <= 0)
      return false;

   PrintFormat("KM5 CLOSE PORTFOLIO: %d legs across %d symbol(s), %.2f lots, "
               "%.2f %s vs target %.2f (relief %.2f)",
               tot.legs, tot.symbolsHolding, tot.lots, tot.profit,
               AccountInfoString(ACCOUNT_CURRENCY), target, relief);

//--- close through whichever executor owns each symbol
   int left = 0;
   for(int i = 0; i < g_n; i++)
     {
      ulong t2[];
      int m = Pf.TicketsSymbol(g_symbols[i], t2);
      if(m > 0)
         left += Exec[i].CloseTickets(t2);
     }

//--- anything on a discovered symbol is closed by the first executor,
//--- which can still address any ticket
   ulong rest[];
   if(Pf.TicketsAll(rest) > 0)
      left += Exec[0].CloseTickets(rest);

   g_closeCount++;
   g_lastAction = StringFormat("portfolio close %.2f", tot.profit);
   if(left > 0)
      g_lastAction += StringFormat(" (%d stuck)", left);

   return true;
  }

//+------------------------------------------------------------------+
void LogSummary(void)
  {
   if(InpLogSeconds <= 0)
      return;

   static datetime last = 0;
   if(TimeCurrent() - last < InpLogSeconds)
      return;
   last = TimeCurrent();

   Print("KM5 ", Pf.Summary());
   if(g_assistWhy != "-")
      Print("KM5 assist: ", g_assistWhy);
  }

//+------------------------------------------------------------------+
void Panel(void)
  {
   if(!InpShowPanel)
      return;

   static datetime last = 0;
   if(TimeCurrent() == last)
      return;
   last = TimeCurrent();

   KMPortfolioTotals tot;
   Pf.Totals(tot);
   string cur = AccountInfoString(ACCOUNT_CURRENCY);

   string t = "==== KM5  MULTI-ASSET PORTFOLIO ====\n";
   t += StringFormat("%d asset(s) on %s | %d legs %.2f lots\n",
                     g_n, EnumToString(InpWorkTf), tot.legs, tot.lots);
   t += "------------------------------------\n";
   t += "symbol      legs  lots     P/L    score  state\n";

   for(int i = 0; i < Pf.Count(); i++)
     {
      KMSymbolState s;
      if(!Pf.State(i, s))
         continue;

      string flags = "";
      if(!s.tradable)     flags += "ext ";
      if(s.gridOpen)      flags += "grid ";
      if(s.hedgeOpen)     flags += "hedge ";
      if(s.assistLegs > 0) flags += StringFormat("assist%d ", s.assistLegs);
      if(i < g_n && Bus[i].Alive(KM_EA_ENTRY)) flags += "EA1 ";
      if(i == tot.worstIdx && tot.worstDrawdown > 0.0) flags += "<==STUCK";

      string sc = "  -  ";
      if(i < g_n && g_viewOk[i])
         sc = StringFormat("%+5.0f", g_view[i].score);

      t += StringFormat("%-11s %4d %6.2f %8.2f  %s  %s\n",
                        s.symbol, s.legs, s.lots, s.profit, sc, flags);
     }

   t += "------------------------------------\n";
   t += StringFormat("portfolio P/L %.2f %s", tot.profit, cur);
   if(g_pfTarget > 0.0)
      t += StringFormat("  target %.2f", g_pfTarget);
   t += "\n";

   if(tot.worstIdx >= 0)
     {
      KMSymbolState w;
      if(Pf.State(tot.worstIdx, w))
         t += StringFormat("stuck: %s -%.2f %s\n", w.symbol, tot.worstDrawdown, cur);
     }

   t += "assist: " + g_assistWhy + "\n";
   t += StringFormat("entries %d | assists %d | portfolio closes %d\n",
                     g_entryCount, g_assistCount, g_closeCount);
   t += "last: " + g_lastAction + "\n";
   t += StringFormat("free margin %.2f %s\n", AccountInfoDouble(ACCOUNT_MARGIN_FREE), cur);
   t += "closes in profit only - no equity rule, no halt\n";

   Comment(t);
  }
//+------------------------------------------------------------------+
