//+------------------------------------------------------------------+
//|                                        KrishMix\Playbook.mqh     |
//|                                                                  |
//|  The top-down read, run as five explicit steps so the reasoning    |
//|  can be printed and audited rather than hidden inside a score.      |
//|                                                                  |
//|    STEP 1  higher timeframe: uptrend, downtrend or consolidating   |
//|    STEP 2  mid timeframe: support, resistance and the major        |
//|            trendline, marked and measured against price            |
//|    STEP 3  low timeframe: VWAP, moving average, RSI divergence     |
//|            and chart patterns (H&S, rising wedge, falling wedge)   |
//|    STEP 4  resolve WHICH EDGE is present - a named combination     |
//|            such as VWAP plus price action, or support/resistance   |
//|            plus RSI divergence                                     |
//|    STEP 5  the working timeframe, taken from the style the         |
//|            timeframe selector published                            |
//|                                                                  |
//|  Nothing here replaces Signals.mqh. The composite score, the       |
//|  regime read and every existing trigger keep working exactly as    |
//|  before; this is a second, independent opinion that a caller can   |
//|  demand in addition.                                               |
//|                                                                  |
//|  Works on any symbol, so the same engine serves gold, bitcoin,     |
//|  silver, oil, the indices - whatever it is pointed at.             |
//+------------------------------------------------------------------+
#ifndef KRISHMIX_PLAYBOOK_MQH
#define KRISHMIX_PLAYBOOK_MQH

#include <KrishMix\Common.mqh>
#include <KrishMix\Structure.mqh>
#include <KrishMix\Vwap.mqh>

//+------------------------------------------------------------------+
//| The named edges. An entry is only taken when one of these is       |
//| actually present - "the indicators look good" is not an edge.       |
//+------------------------------------------------------------------+
enum ENUM_KM_EDGE
  {
   KM_EDGE_NONE           = 0, // no edge
   KM_EDGE_VWAP_PA        = 1, // VWAP band edge + price action
   KM_EDGE_SR_DIVERGENCE  = 2, // support/resistance + RSI divergence
   KM_EDGE_PATTERN_LEVEL  = 3, // chart pattern resolving at a level
   KM_EDGE_TRENDLINE_VWAP = 4  // trendline touch confirmed by VWAP side
  };

string KM_EdgeName(const ENUM_KM_EDGE e)
  {
   switch(e)
     {
      case KM_EDGE_VWAP_PA:        return "VWAP+PriceAction";
      case KM_EDGE_SR_DIVERGENCE:  return "S/R+RSIdivergence";
      case KM_EDGE_PATTERN_LEVEL:  return "Pattern@Level";
      case KM_EDGE_TRENDLINE_VWAP: return "Trendline+VWAP";
     }
   return "none";
  }

//+------------------------------------------------------------------+
//| One complete top-down reading                                    |
//+------------------------------------------------------------------+
struct PlaybookView
  {
   bool             valid;

   //--- step 1
   ENUM_KM_HTFBIAS  htfBias;
   double           htfMaturity;      // how far the HTF move has run
   bool             htfFresh;

   //--- step 2
   bool             hasLevel;
   double           levelPrice;
   int              levelTouches;
   bool             levelIsResistance;
   double           levelStrength;
   double           levelDistAtr;
   bool             hasLine;
   bool             lineIsSupport;
   double           linePrice;        // projected at the current bar
   double           lineDistAtr;

   //--- step 3
   bool             vwapValid;
   double           vwapPrice;
   double           vwapDistSd;
   bool             aboveVwap;
   bool             aboveMa;
   double           maValue;
   string           divergence;
   bool             divBull, divBear;
   string           patterns;
   bool             patBull, patBear;

   //--- step 4
   ENUM_KM_EDGE     edge;
   ENUM_KM_DIR      dir;
   double           confidence;       // 0..100
   int              confluences;      // how many independent legs agreed

   //--- step 5
   ENUM_KM_STYLE    style;
   ENUM_TIMEFRAMES  workingTf;

   string           narrative;        // the five steps, in words
  };

void KM_ResetPlaybook(PlaybookView &p)
  {
   p.valid             = false;
   p.htfBias           = KM_HTF_CONSOLIDATING;
   p.htfMaturity       = 100.0;
   p.htfFresh          = false;
   p.hasLevel          = false;
   p.levelPrice        = 0.0;
   p.levelTouches      = 0;
   p.levelIsResistance = false;
   p.levelStrength     = 0.0;
   p.levelDistAtr      = 999.0;
   p.hasLine           = false;
   p.lineIsSupport     = false;
   p.linePrice         = 0.0;
   p.lineDistAtr       = 999.0;
   p.vwapValid         = false;
   p.vwapPrice         = 0.0;
   p.vwapDistSd        = 0.0;
   p.aboveVwap         = false;
   p.aboveMa           = false;
   p.maValue           = 0.0;
   p.divergence        = "none";
   p.divBull           = false;
   p.divBear           = false;
   p.patterns          = "none";
   p.patBull           = false;
   p.patBear           = false;
   p.edge              = KM_EDGE_NONE;
   p.dir               = KM_DIR_NONE;
   p.confidence        = 0.0;
   p.confluences       = 0;
   p.style             = KM_STYLE_INTRADAY;
   p.workingTf         = PERIOD_M5;
   p.narrative         = "";
  }

//+------------------------------------------------------------------+
//| Tunables                                                         |
//+------------------------------------------------------------------+
struct PlaybookConfig
  {
   ENUM_TIMEFRAMES  tfHigh;              // step 1
   ENUM_TIMEFRAMES  tfMid;               // step 2
   ENUM_TIMEFRAMES  tfLow;               // step 3
   int              atrPeriod;
   int              maPeriod;
   ENUM_MA_METHOD   maMethod;
   double           levelProximityAtr;   // "at" a level
   double           lineProximityAtr;    // "at" the trendline
   double           vwapMinSd;           // band-edge stretch that counts
   double           minConfidence;
   bool             requireHtfAlign;     // hard gate instead of a penalty
   double           htfPenalty;          // confidence lost when counter-HTF
   int              minLevelTouches;
};

void KM_DefaultPlaybookConfig(PlaybookConfig &c)
  {
   c.tfHigh            = PERIOD_H4;
   c.tfMid             = PERIOD_M15;
   c.tfLow             = PERIOD_M5;
   c.atrPeriod         = 14;
   c.maPeriod          = 50;
   c.maMethod          = MODE_EMA;
   c.levelProximityAtr = 0.80;
   c.lineProximityAtr  = 0.80;
   c.vwapMinSd         = 1.20;
   c.minConfidence     = 55.0;
   c.requireHtfAlign   = false;
   c.htfPenalty        = 20.0;
   c.minLevelTouches   = 2;
  }

//+------------------------------------------------------------------+
//| Engine                                                           |
//+------------------------------------------------------------------+
class CKMPlaybook
  {
private:
   string            m_symbol;
   PlaybookConfig    m_cfg;

   CKMStructure      m_stHigh, m_stMid, m_stLow;
   CKMVwap           m_vwap;

   int               m_hAtrHigh, m_hAtrMid, m_hAtrLow;
   int               m_hMa;

   PlaybookView      m_view;
   datetime          m_lastBar;
   string            m_lastIssue;

   ENUM_KM_STYLE     m_style;
   ENUM_TIMEFRAMES   m_workingTf;

   //--- read one value of buffer 0 at the last closed bar
   bool              ReadOne(const int handle, double &out)
     {
      out = 0.0;
      if(handle == INVALID_HANDLE)
         return false;
      double tmp[];
      if(CopyBuffer(handle, 0, 1, 1, tmp) < 1)
         return false;
      out = tmp[0];
      return true;
     }

   bool              ReadAtr(const int handle, double &out)
     {
      return (ReadOne(handle, out) && out > 0.0);
     }

public:
                     CKMPlaybook(void)
     {
      m_symbol    = "";
      m_hAtrHigh  = INVALID_HANDLE;
      m_hAtrMid   = INVALID_HANDLE;
      m_hAtrLow   = INVALID_HANDLE;
      m_hMa       = INVALID_HANDLE;
      m_lastBar   = 0;
      m_lastIssue = "not refreshed yet";
      m_style     = KM_STYLE_INTRADAY;
      m_workingTf = PERIOD_M5;
      KM_DefaultPlaybookConfig(m_cfg);
      KM_ResetPlaybook(m_view);
     }

                    ~CKMPlaybook(void) { Release(); }

   void              Config(const PlaybookConfig &c) { m_cfg = c; }
   string            LastIssue(void) const { return m_lastIssue; }

   //--- step 5 comes from outside: the timeframe selector publishes it
   void              SetStyle(const ENUM_KM_STYLE s, const ENUM_TIMEFRAMES tf)
     {
      m_style     = s;
      m_workingTf = tf;
     }

   bool              Init(const string sym)
     {
      m_symbol = sym;

      m_stHigh.Init(sym, m_cfg.tfHigh);
      m_stMid.Init(sym,  m_cfg.tfMid);
      m_stLow.Init(sym,  m_cfg.tfLow);

      //--- the higher timeframes only need the trend read, so a shorter
      //--- pivot scan there keeps the cost down
      StructureConfig hc;
      KM_DefaultStructureConfig(hc);
      hc.swingLookback = 150;
      m_stHigh.Config(hc);

      if(!m_vwap.Init(sym, m_cfg.tfLow))
        {
         m_lastIssue = "vwap init failed: " + m_vwap.LastIssue();
         return false;
        }

      m_hAtrHigh = iATR(sym, m_cfg.tfHigh, MathMax(2, m_cfg.atrPeriod));
      m_hAtrMid  = iATR(sym, m_cfg.tfMid,  MathMax(2, m_cfg.atrPeriod));
      m_hAtrLow  = iATR(sym, m_cfg.tfLow,  MathMax(2, m_cfg.atrPeriod));
      m_hMa      = iMA(sym, m_cfg.tfLow, MathMax(2, m_cfg.maPeriod), 0,
                       m_cfg.maMethod, PRICE_CLOSE);

      if(m_hAtrHigh == INVALID_HANDLE || m_hAtrMid == INVALID_HANDLE ||
         m_hAtrLow == INVALID_HANDLE  || m_hMa == INVALID_HANDLE)
        {
         m_lastIssue = "failed to create a playbook indicator handle";
         return false;
        }

      return true;
     }

   void              Release(void)
     {
      if(m_hAtrHigh != INVALID_HANDLE) IndicatorRelease(m_hAtrHigh);
      if(m_hAtrMid  != INVALID_HANDLE) IndicatorRelease(m_hAtrMid);
      if(m_hAtrLow  != INVALID_HANDLE) IndicatorRelease(m_hAtrLow);
      if(m_hMa      != INVALID_HANDLE) IndicatorRelease(m_hMa);
      m_hAtrHigh = m_hAtrMid = m_hAtrLow = m_hMa = INVALID_HANDLE;
      m_vwap.Release();
     }

   void              View(PlaybookView &out) const { out = m_view; }

   //--- Delegating accessors for the low-timeframe structure.
   //--- CKMStructure owns dynamic arrays, so it is never copied out by
   //--- value; callers reach through to exactly what they need instead.
   void              LowInsideBar(KMInsideBar &out)  const { m_stLow.InsideBar(out); }
   void              LowTrend(KMTrendState &out)     const { m_stLow.Trend(out); }
   void              LowPatterns(KMPatterns &out)    const { m_stLow.Patterns(out); }
   int               LowSwingCount(void)             const { return m_stLow.SwingCount(); }

   bool              LowPivot(const bool wantHigh, const int nth, KMSwing &out) const
     {
      return m_stLow.RecentPivot(wantHigh, nth, out);
     }

   bool              LowEntryIsFresh(const ENUM_KM_DIR dir, const double minRetrace,
                                     string &why) const
     {
      return m_stLow.EntryIsFresh(dir, minRetrace, why);
     }

   bool              MidLevel(const double price, const bool wantResistance,
                              const double maxAtr, KMLevel &out) const
     {
      return m_stMid.NearestLevel(price, wantResistance, maxAtr, out);
     }

   //+---------------------------------------------------------------+
   //| Run all five steps. Recomputed once per bar of the low          |
   //| timeframe.                                                      |
   //+---------------------------------------------------------------+
   bool              Refresh(const bool force = false)
     {
      datetime bt = (datetime)SeriesInfoInteger(m_symbol, m_cfg.tfLow, SERIES_LASTBAR_DATE);
      if(!force && bt == m_lastBar && m_view.valid)
         return true;

      KM_ResetPlaybook(m_view);
      m_view.style     = m_style;
      m_view.workingTf = m_workingTf;

      double atrHigh, atrMid, atrLow;
      if(!ReadAtr(m_hAtrHigh, atrHigh) || !ReadAtr(m_hAtrMid, atrMid) ||
         !ReadAtr(m_hAtrLow, atrLow))
        {
         m_lastIssue = "ATR not ready on one of the three timeframes";
         return false;
        }

      //=== STEP 1 - higher timeframe direction =====================
      if(!m_stHigh.Refresh(atrHigh))
        {
         m_lastIssue = "step 1: " + m_stHigh.LastIssue();
         return false;
        }

      KMTrendState htf;
      m_stHigh.Trend(htf);

      if(htf.dir == KM_DIR_BUY)
         m_view.htfBias = KM_HTF_UP;
      else if(htf.dir == KM_DIR_SELL)
         m_view.htfBias = KM_HTF_DOWN;
      else
         m_view.htfBias = KM_HTF_CONSOLIDATING;

      m_view.htfMaturity = htf.maturity;
      m_view.htfFresh    = htf.isFresh;

      //=== STEP 2 - mid timeframe levels and trendline =============
      if(!m_stMid.Refresh(atrMid))
        {
         m_lastIssue = "step 2: " + m_stMid.LastIssue();
         return false;
        }

      double price = SymbolInfoDouble(m_symbol, SYMBOL_BID);
      if(price <= 0.0)
        {
         m_lastIssue = "no bid price";
         return false;
        }

      KMLevel lv;
      if(m_stMid.AtLevel(price, 4.0, lv))     // widen the search, measure after
        {
         m_view.hasLevel          = true;
         m_view.levelPrice        = lv.price;
         m_view.levelTouches      = lv.touches;
         m_view.levelIsResistance = lv.isResistance;
         m_view.levelStrength     = lv.strength;
         m_view.levelDistAtr      = (atrMid > 0.0 ? MathAbs(price - lv.price) / atrMid : 999.0);
        }

      KMTrendline sup, res;
      m_stMid.SupportLine(sup);
      m_stMid.ResistanceLine(res);

      //--- keep whichever line price is currently closer to
      double dSup = 999.0, dRes = 999.0;
      double pSup = 0.0,   pRes = 0.0;
      if(sup.valid)
        {
         pSup = KM_TrendlinePrice(sup, 1);
         if(atrMid > 0.0) dSup = MathAbs(price - pSup) / atrMid;
        }
      if(res.valid)
        {
         pRes = KM_TrendlinePrice(res, 1);
         if(atrMid > 0.0) dRes = MathAbs(price - pRes) / atrMid;
        }

      if(sup.valid || res.valid)
        {
         bool useSup = (dSup <= dRes);
         m_view.hasLine       = true;
         m_view.lineIsSupport = useSup;
         m_view.linePrice     = (useSup ? pSup : pRes);
         m_view.lineDistAtr   = (useSup ? dSup : dRes);
        }

      //=== STEP 3 - low timeframe execution picture ================
      if(!m_stLow.Refresh(atrLow))
        {
         m_lastIssue = "step 3: " + m_stLow.LastIssue();
         return false;
        }

      KMVwapView vw;
      if(m_vwap.Refresh(vw) && vw.valid)
        {
         m_view.vwapValid  = true;
         m_view.vwapPrice  = vw.vwap;
         m_view.vwapDistSd = vw.distSd;
         m_view.aboveVwap  = vw.above;
        }

      double ma;
      if(ReadOne(m_hMa, ma) && ma > 0.0)
        {
         m_view.maValue = ma;
         m_view.aboveMa = (price > ma);
        }

      //--- divergence between the two most recent pivots of each kind
      KMSwing hNew, hOld, lNew, lOld;
      KMDivergence dv;

      if(m_stLow.RecentPivot(true, 0, hNew) && m_stLow.RecentPivot(true, 1, hOld))
        {
         if(m_vwap.Divergence(hNew.bar, hNew.price, hOld.bar, hOld.price,
                              true, atrLow, dv))
            if(dv.bearishRegular || dv.bearishHidden)
              {
               m_view.divBear    = true;
               m_view.divergence = dv.names;
              }
        }

      if(m_stLow.RecentPivot(false, 0, lNew) && m_stLow.RecentPivot(false, 1, lOld))
        {
         if(m_vwap.Divergence(lNew.bar, lNew.price, lOld.bar, lOld.price,
                              false, atrLow, dv))
            if(dv.bullishRegular || dv.bullishHidden)
              {
               m_view.divBull    = true;
               m_view.divergence = dv.names;
              }
        }

      KMPatterns pat;
      m_stLow.Patterns(pat);
      m_view.patterns = pat.names;
      m_view.patBear  = (pat.headShoulders    || pat.risingWedge);
      m_view.patBull  = (pat.invHeadShoulders || pat.fallingWedge);

      //=== STEP 4 - which edge is actually present? ================
      ResolveEdge(price, atrLow);

      //=== STEP 5 - working timeframe (already set) ================
      BuildNarrative(price);

      m_view.valid = true;
      m_lastBar    = bt;
      m_lastIssue  = "";
      return true;
     }

private:
   //+---------------------------------------------------------------+
   //| Score one direction and keep the better of the two.            |
   //+---------------------------------------------------------------+
   void              ResolveEdge(const double price, const double atrLow)
     {
      double bestConf = 0.0;
      ENUM_KM_EDGE bestEdge = KM_EDGE_NONE;
      ENUM_KM_DIR  bestDir  = KM_DIR_NONE;
      int          bestConfl = 0;

      for(int pass = 0; pass < 2; pass++)
        {
         ENUM_KM_DIR dir = (pass == 0 ? KM_DIR_BUY : KM_DIR_SELL);
         bool isBuy = (dir == KM_DIR_BUY);

         //--- shared ingredients for this direction
         bool levelRight = (m_view.hasLevel &&
                            m_view.levelTouches >= m_cfg.minLevelTouches &&
                            m_view.levelDistAtr <= m_cfg.levelProximityAtr &&
                            m_view.levelIsResistance == !isBuy);

         bool vwapStretched = (m_view.vwapValid &&
                               ((isBuy  && m_view.vwapDistSd <= -m_cfg.vwapMinSd) ||
                                (!isBuy && m_view.vwapDistSd >=  m_cfg.vwapMinSd)));

         bool vwapSide = (m_view.vwapValid &&
                          ((isBuy && m_view.aboveVwap) || (!isBuy && !m_view.aboveVwap)));

         bool divRight = (isBuy ? m_view.divBull : m_view.divBear);
         bool patRight = (isBuy ? m_view.patBull : m_view.patBear);

         bool lineRight = (m_view.hasLine &&
                           m_view.lineDistAtr <= m_cfg.lineProximityAtr &&
                           m_view.lineIsSupport == isBuy);

         KMInsideBar ib;
         m_stLow.InsideBar(ib);
         bool ibRight = (ib.found &&
                         ((isBuy && ib.atSwingLow && !ib.brokenUp) ||
                          (!isBuy && ib.atSwingHigh && !ib.brokenDown)));

         KMTrendState lowTrend;
         m_stLow.Trend(lowTrend);
         bool priceAction = (levelRight || ibRight || lowTrend.nearCorner);

         //--- candidate edges, each with its own base confidence
         ENUM_KM_EDGE edge = KM_EDGE_NONE;
         double conf = 0.0;
         int    confl = 0;

         if(vwapStretched && priceAction)
           {
            edge = KM_EDGE_VWAP_PA;
            conf = 62.0;
            confl = 2;
           }

         if(levelRight && divRight)
           {
            double c = 70.0;
            if(c > conf)
              {
               edge = KM_EDGE_SR_DIVERGENCE;
               conf = c;
               confl = 2;
              }
           }

         if(patRight && (levelRight || lineRight))
           {
            double c = 66.0;
            if(c > conf)
              {
               edge = KM_EDGE_PATTERN_LEVEL;
               conf = c;
               confl = 2;
              }
           }

         if(lineRight && vwapSide)
           {
            double c = 58.0;
            if(c > conf)
              {
               edge = KM_EDGE_TRENDLINE_VWAP;
               conf = c;
               confl = 2;
              }
           }

         if(edge == KM_EDGE_NONE)
            continue;

         //--- extra independent agreement raises confidence
         if(divRight   && edge != KM_EDGE_SR_DIVERGENCE) { conf += 8.0;  confl++; }
         if(patRight   && edge != KM_EDGE_PATTERN_LEVEL) { conf += 6.0;  confl++; }
         if(levelRight && edge != KM_EDGE_SR_DIVERGENCE &&
                          edge != KM_EDGE_PATTERN_LEVEL) { conf += 6.0;  confl++; }
         if(ibRight)                                     { conf += 5.0;  confl++; }

         //--- higher timeframe agreement
         bool htfAgrees = ((isBuy  && m_view.htfBias == KM_HTF_UP) ||
                           (!isBuy && m_view.htfBias == KM_HTF_DOWN));
         bool htfAgainst = ((isBuy  && m_view.htfBias == KM_HTF_DOWN) ||
                            (!isBuy && m_view.htfBias == KM_HTF_UP));

         if(htfAgrees)
           {
            conf += 10.0;
            confl++;
           }
         else if(htfAgainst)
           {
            if(m_cfg.requireHtfAlign)
               continue;                       // hard gate
            conf -= m_cfg.htfPenalty;          // otherwise just costlier
           }

         conf = MathMax(0.0, MathMin(100.0, conf));

         if(conf > bestConf)
           {
            bestConf  = conf;
            bestEdge  = edge;
            bestDir   = dir;
            bestConfl = confl;
           }
        }

      if(bestEdge != KM_EDGE_NONE && bestConf >= m_cfg.minConfidence)
        {
         m_view.edge        = bestEdge;
         m_view.dir         = bestDir;
         m_view.confidence  = bestConf;
         m_view.confluences = bestConfl;
        }
      else
        {
         m_view.edge        = KM_EDGE_NONE;
         m_view.dir         = KM_DIR_NONE;
         m_view.confidence  = bestConf;   // keep it for the panel
         m_view.confluences = bestConfl;
        }
     }

   //+---------------------------------------------------------------+
   void              BuildNarrative(const double price)
     {
      string n = "";

      n += StringFormat("1) %s on %s (maturity %.0f%s)\n",
                        KM_HtfName(m_view.htfBias), EnumToString(m_cfg.tfHigh),
                        m_view.htfMaturity, (m_view.htfFresh ? ", fresh" : ""));

      n += StringFormat("2) %s: ", EnumToString(m_cfg.tfMid));
      if(m_view.hasLevel)
         n += StringFormat("%s %.*f x%d (%.1f atr away)",
                           (m_view.levelIsResistance ? "res" : "sup"),
                           _Digits, m_view.levelPrice, m_view.levelTouches,
                           m_view.levelDistAtr);
      else
         n += "no clear level";
      if(m_view.hasLine)
         n += StringFormat(" | %s line %.*f (%.1f atr)",
                           (m_view.lineIsSupport ? "rising" : "falling"),
                           _Digits, m_view.linePrice, m_view.lineDistAtr);
      n += "\n";

      n += StringFormat("3) %s: ", EnumToString(m_cfg.tfLow));
      if(m_view.vwapValid)
         n += StringFormat("vwap %.*f (%.2f sd %s)", _Digits, m_view.vwapPrice,
                           m_view.vwapDistSd, (m_view.aboveVwap ? "above" : "below"));
      else
         n += "vwap n/a";
      n += StringFormat(" | ma %s | div %s | pat %s\n",
                        (m_view.aboveMa ? "above" : "below"),
                        m_view.divergence, m_view.patterns);

      if(m_view.edge != KM_EDGE_NONE)
         n += StringFormat("4) EDGE %s %s, confidence %.0f from %d legs\n",
                           KM_EdgeName(m_view.edge),
                           (m_view.dir == KM_DIR_BUY ? "LONG" : "SHORT"),
                           m_view.confidence, m_view.confluences);
      else
         n += StringFormat("4) no edge (best confidence %.0f, need %.0f)\n",
                           m_view.confidence, m_cfg.minConfidence);

      n += StringFormat("5) style %s -> working %s",
                        KM_StyleName(m_view.style), EnumToString(m_view.workingTf));

      m_view.narrative = n;
     }

public:
   //+---------------------------------------------------------------+
   //| Does the playbook back a trade in 'dir' right now?             |
   //+---------------------------------------------------------------+
   bool              Backs(const ENUM_KM_DIR dir, string &why) const
     {
      why = "";
      if(!m_view.valid)
        {
         why = "playbook not ready";
         return false;
        }
      if(m_view.edge == KM_EDGE_NONE)
        {
         why = StringFormat("no edge (best %.0f)", m_view.confidence);
         return false;
        }
      if(m_view.dir != dir)
        {
         why = StringFormat("edge %s points %s",
                            KM_EdgeName(m_view.edge),
                            (m_view.dir == KM_DIR_BUY ? "long" : "short"));
         return false;
        }

      why = StringFormat("%s, confidence %.0f, %d legs",
                         KM_EdgeName(m_view.edge), m_view.confidence, m_view.confluences);
      return true;
     }

   string            Summary(void) const
     {
      if(!m_view.valid)
         return "playbook: " + m_lastIssue;
      return StringFormat("%s | edge %s %s conf %.0f | %s",
                          KM_HtfName(m_view.htfBias),
                          KM_EdgeName(m_view.edge),
                          (m_view.dir == KM_DIR_BUY ? "LONG" :
                           (m_view.dir == KM_DIR_SELL ? "SHORT" : "-")),
                          m_view.confidence, KM_StyleName(m_view.style));
     }
  };

#endif // KRISHMIX_PLAYBOOK_MQH
//+------------------------------------------------------------------+
