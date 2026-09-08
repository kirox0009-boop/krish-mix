//+------------------------------------------------------------------+
//|                                            KrishMix\Vwap.mqh     |
//|                                                                  |
//|  Session VWAP with volume-weighted deviation bands, plus RSI       |
//|  divergence. These are the two ingredients the M5 step of the       |
//|  top-down playbook needs that the main indicator stack does not     |
//|  already provide.                                                   |
//|                                                                  |
//|  VWAP is anchored to the trading day and resets on the first bar   |
//|  of a new day, computed from typical price weighted by volume:      |
//|                                                                  |
//|      vwap = SUM(tp * vol) / SUM(vol),  tp = (H + L + C) / 3        |
//|      sd   = sqrt( SUM(vol * (tp - vwap)^2) / SUM(vol) )            |
//|                                                                  |
//|  Divergence compares two price pivots against RSI at those same    |
//|  bars. Pivot locations come from CKMStructure, which must be        |
//|  running on the SAME timeframe as this module.                      |
//+------------------------------------------------------------------+
#ifndef KRISHMIX_VWAP_MQH
#define KRISHMIX_VWAP_MQH

#include <KrishMix\Common.mqh>

//+------------------------------------------------------------------+
//| VWAP reading                                                     |
//+------------------------------------------------------------------+
struct KMVwapView
  {
   bool             valid;
   double           vwap;
   double           sd;            // volume weighted deviation
   double           upper1, lower1;
   double           upper2, lower2;
   double           price;         // last closed price
   double           distSd;        // (price - vwap) / sd
   bool             above;
   int              barsInSession;
   double           sessionVolume;
  };

//+------------------------------------------------------------------+
//| Divergence between price pivots and RSI at those pivots           |
//+------------------------------------------------------------------+
struct KMDivergence
  {
   bool             bearishRegular;  // price HH, RSI LH  -> reversal down
   bool             bullishRegular;  // price LL, RSI HL  -> reversal up
   bool             bearishHidden;   // price LH, RSI HH  -> continuation down
   bool             bullishHidden;   // price HL, RSI LL  -> continuation up
   double           priceNewer, priceOlder;
   double           rsiNewer,   rsiOlder;
   string           names;
  };

void KM_ResetDivergence(KMDivergence &d)
  {
   d.bearishRegular = false;
   d.bullishRegular = false;
   d.bearishHidden  = false;
   d.bullishHidden  = false;
   d.priceNewer     = 0.0;
   d.priceOlder     = 0.0;
   d.rsiNewer       = 0.0;
   d.rsiOlder       = 0.0;
   d.names          = "none";
  }

//+------------------------------------------------------------------+
//| Tunables                                                         |
//+------------------------------------------------------------------+
struct VwapConfig
  {
   int              maxSessionBars;   // hard cap on the session scan
   int              minSessionBars;   // below this the VWAP is meaningless
   int              rsiPeriod;
   double           minRsiGap;        // RSI difference that counts as real
   double           minPriceGapAtr;   // price difference that counts as real
   bool             useRealVolume;    // real volume when the feed has it
  };

void KM_DefaultVwapConfig(VwapConfig &c)
  {
   c.maxSessionBars = 600;
   c.minSessionBars = 5;
   c.rsiPeriod      = 14;
   c.minRsiGap      = 2.0;
   c.minPriceGapAtr = 0.25;
   c.useRealVolume  = false;
  }

//+------------------------------------------------------------------+
//| Engine                                                           |
//+------------------------------------------------------------------+
class CKMVwap
  {
private:
   string            m_symbol;
   ENUM_TIMEFRAMES   m_tf;
   VwapConfig        m_cfg;
   int               m_hRsi;

   KMVwapView        m_view;
   datetime          m_lastBar;
   string            m_lastIssue;

public:
                     CKMVwap(void)
     {
      m_symbol    = "";
      m_tf        = PERIOD_CURRENT;
      m_hRsi      = INVALID_HANDLE;
      m_lastBar   = 0;
      m_lastIssue = "not refreshed yet";
      KM_DefaultVwapConfig(m_cfg);
      m_view.valid = false;
     }

                    ~CKMVwap(void) { Release(); }

   void              Config(const VwapConfig &c) { m_cfg = c; }
   string            LastIssue(void) const { return m_lastIssue; }

   bool              Init(const string sym, const ENUM_TIMEFRAMES tf)
     {
      m_symbol = sym;
      m_tf     = tf;

      m_hRsi = iRSI(sym, tf, MathMax(2, m_cfg.rsiPeriod), PRICE_CLOSE);
      if(m_hRsi == INVALID_HANDLE)
        {
         m_lastIssue = "failed to create the RSI handle";
         return false;
        }
      return true;
     }

   void              Release(void)
     {
      if(m_hRsi != INVALID_HANDLE)
        {
         IndicatorRelease(m_hRsi);
         m_hRsi = INVALID_HANDLE;
        }
     }

   //+---------------------------------------------------------------+
   //| RSI at a given bar shift                                       |
   //+---------------------------------------------------------------+
   bool              RsiAt(const int shift, double &out)
     {
      out = 0.0;
      if(m_hRsi == INVALID_HANDLE)
         return false;

      double tmp[];
      ResetLastError();
      if(CopyBuffer(m_hRsi, 0, shift, 1, tmp) < 1)
        {
         m_lastIssue = StringFormat("RSI at shift %d unavailable (error %d)",
                                    shift, GetLastError());
         return false;
        }
      out = tmp[0];
      return true;
     }

   //+---------------------------------------------------------------+
   //| Session VWAP, recomputed once per closed bar                   |
   //+---------------------------------------------------------------+
   bool              Refresh(KMVwapView &out, const bool force = false)
     {
      datetime bt = (datetime)SeriesInfoInteger(m_symbol, m_tf, SERIES_LASTBAR_DATE);
      if(!force && bt == m_lastBar && m_view.valid)
        {
         out = m_view;
         return true;
        }

      m_view.valid = false;

      int want = MathMax(20, m_cfg.maxSessionBars);

      datetime tm[];
      double   h[], l[], c[];
      long     vol[];

      ArraySetAsSeries(tm, true);
      ArraySetAsSeries(h, true);
      ArraySetAsSeries(l, true);
      ArraySetAsSeries(c, true);
      ArraySetAsSeries(vol, true);

      if(CopyTime(m_symbol, m_tf, 0, want, tm) < want ||
         CopyHigh(m_symbol, m_tf, 0, want, h)  < want ||
         CopyLow(m_symbol, m_tf, 0, want, l)   < want ||
         CopyClose(m_symbol, m_tf, 0, want, c) < want)
        {
         m_lastIssue = StringFormat("need %d bars on %s, have %d",
                                    want, EnumToString(m_tf), Bars(m_symbol, m_tf));
         out = m_view;
         return false;
        }

      bool haveVol = false;
      if(m_cfg.useRealVolume)
         haveVol = (CopyRealVolume(m_symbol, m_tf, 0, want, vol) == want);
      if(!haveVol)
         haveVol = (CopyTickVolume(m_symbol, m_tf, 0, want, vol) == want);

      //--- how far back does the current trading day reach?
      MqlDateTime ref;
      TimeToStruct(tm[1], ref);          // anchor on the last CLOSED bar
      int lastIdx = 1;

      for(int i = 1; i < want; i++)
        {
         MqlDateTime d;
         TimeToStruct(tm[i], d);
         if(d.day != ref.day || d.mon != ref.mon || d.year != ref.year)
            break;
         lastIdx = i;
        }

      int nBars = lastIdx;             // bars 1..lastIdx belong to this day
      if(nBars < m_cfg.minSessionBars)
        {
         m_lastIssue = StringFormat("only %d closed bars in this session", nBars);
         out = m_view;
         return false;
        }

      double sumPV = 0.0, sumV = 0.0;

      for(int i = 1; i <= lastIdx; i++)
        {
         double tp = (h[i] + l[i] + c[i]) / 3.0;
         double v  = (haveVol ? (double)vol[i] : 1.0);
         if(v <= 0.0)
            v = 1.0;
         sumPV += tp * v;
         sumV  += v;
        }

      if(sumV <= 0.0)
        {
         m_lastIssue = "session volume is zero";
         out = m_view;
         return false;
        }

      double vwap = sumPV / sumV;

      //--- volume weighted deviation around the VWAP
      double sumW = 0.0;
      for(int i = 1; i <= lastIdx; i++)
        {
         double tp = (h[i] + l[i] + c[i]) / 3.0;
         double v  = (haveVol ? (double)vol[i] : 1.0);
         if(v <= 0.0)
            v = 1.0;
         sumW += v * (tp - vwap) * (tp - vwap);
        }
      double sd = MathSqrt(sumW / sumV);

      m_view.valid         = true;
      m_view.vwap          = vwap;
      m_view.sd            = sd;
      m_view.upper1        = vwap + sd;
      m_view.lower1        = vwap - sd;
      m_view.upper2        = vwap + 2.0 * sd;
      m_view.lower2        = vwap - 2.0 * sd;
      m_view.price         = c[1];
      m_view.above         = (c[1] > vwap);
      m_view.distSd        = (sd > 0.0 ? (c[1] - vwap) / sd : 0.0);
      m_view.barsInSession = nBars;
      m_view.sessionVolume = sumV;

      m_lastBar   = bt;
      m_lastIssue = "";
      out         = m_view;
      return true;
     }

   //+---------------------------------------------------------------+
   //| Divergence between two price pivots and RSI at those bars.     |
   //|                                                               |
   //| 'onHighs' selects which family of divergence to look for:       |
   //|   highs -> bearish regular (price HH, RSI LH)                   |
   //|            bearish hidden  (price LH, RSI HH)                   |
   //|   lows  -> bullish regular (price LL, RSI HL)                   |
   //|            bullish hidden  (price HL, RSI LL)                   |
   //+---------------------------------------------------------------+
   bool              Divergence(const int barNewer, const double priceNewer,
                                const int barOlder, const double priceOlder,
                                const bool onHighs, const double atr,
                                KMDivergence &out)
     {
      KM_ResetDivergence(out);

      if(barNewer >= barOlder)
        {
         m_lastIssue = "divergence needs the newer pivot first";
         return false;
        }

      double rNew, rOld;
      if(!RsiAt(barNewer, rNew) || !RsiAt(barOlder, rOld))
         return false;

      out.priceNewer = priceNewer;
      out.priceOlder = priceOlder;
      out.rsiNewer   = rNew;
      out.rsiOlder   = rOld;

      double priceGap = MathAbs(priceNewer - priceOlder);
      double rsiGap   = MathAbs(rNew - rOld);

      //--- both legs of the comparison have to be real, not noise
      if(atr > 0.0 && priceGap < atr * m_cfg.minPriceGapAtr)
        {
         out.names = "price gap too small";
         return true;
        }
      if(rsiGap < m_cfg.minRsiGap)
        {
         out.names = "rsi gap too small";
         return true;
        }

      out.names = "";

      if(onHighs)
        {
         if(priceNewer > priceOlder && rNew < rOld)
           {
            out.bearishRegular = true;
            out.names += "bearishRegular ";
           }
         else if(priceNewer < priceOlder && rNew > rOld)
           {
            out.bearishHidden = true;
            out.names += "bearishHidden ";
           }
        }
      else
        {
         if(priceNewer < priceOlder && rNew > rOld)
           {
            out.bullishRegular = true;
            out.names += "bullishRegular ";
           }
         else if(priceNewer > priceOlder && rNew < rOld)
           {
            out.bullishHidden = true;
            out.names += "bullishHidden ";
           }
        }

      if(out.names == "")
         out.names = "none";

      return true;
     }

   //--- does the reading support a trade in 'dir' from a VWAP band edge?
   bool              BandEdgeSignal(const KMVwapView &v, const ENUM_KM_DIR dir,
                                    const double minSd, string &why) const
     {
      why = "";
      if(!v.valid)
        {
         why = "vwap not ready";
         return false;
        }

      //--- stretched below the VWAP favours a long, stretched above a short
      if(dir == KM_DIR_BUY && v.distSd <= -minSd)
        {
         why = StringFormat("%.2f sd below vwap", -v.distSd);
         return true;
        }
      if(dir == KM_DIR_SELL && v.distSd >= minSd)
        {
         why = StringFormat("%.2f sd above vwap", v.distSd);
         return true;
        }

      why = StringFormat("only %.2f sd from vwap", v.distSd);
      return false;
     }

   string            Summary(const KMVwapView &v) const
     {
      if(!v.valid)
         return "vwap: " + m_lastIssue;
      return StringFormat("vwap %.*f (%.2f sd, %s) session %d bars",
                          _Digits, v.vwap, v.distSd,
                          (v.above ? "above" : "below"), v.barsInSession);
     }
  };

#endif // KRISHMIX_VWAP_MQH
//+------------------------------------------------------------------+
