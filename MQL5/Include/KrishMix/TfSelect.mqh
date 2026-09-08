//+------------------------------------------------------------------+
//|                                        KrishMix\TfSelect.mqh     |
//|                                                                  |
//|  Chooses the trading style, and therefore the working timeframe.   |
//|                                                                  |
//|      SCALP     M1 / M3 / M5                                        |
//|      INTRADAY  M5 / M15                                            |
//|      SWING     H1 / H4                                             |
//|                                                                  |
//|  The decision is not a preference, it is arithmetic. Four inputs:   |
//|                                                                  |
//|  1. SPREAD ECONOMICS - the one that actually matters.               |
//|     Scalping only works if the spread is small next to the range   |
//|     a bar actually delivers. spread / ATR(M5) above roughly a       |
//|     quarter means a scalp pays the broker more than the move is     |
//|     worth, so the decision is pushed up the timeframes. On gold or |
//|     an index this single test rules scalping out most of the day.   |
//|                                                                  |
//|  2. VOLATILITY - ATR against its own long average. An expanding    |
//|     market gives a short timeframe something to work with; a dead  |
//|     one does not.                                                  |
//|                                                                  |
//|  3. TREND PERSISTENCE - ADX on the higher timeframe. A durable     |
//|     trend is worth holding, which favours swing; chop favours       |
//|     shorter, faster work.                                           |
//|                                                                  |
//|  4. SESSION LIQUIDITY - the London / New York overlap supports     |
//|     fast trading, the dead hours do not.                            |
//+------------------------------------------------------------------+
#ifndef KRISHMIX_TFSELECT_MQH
#define KRISHMIX_TFSELECT_MQH

#include <KrishMix\Common.mqh>

//+------------------------------------------------------------------+
struct KMTfDecision
  {
   bool             valid;
   ENUM_KM_STYLE    style;
   ENUM_TIMEFRAMES  tf;

   double           scalpScore;
   double           intradayScore;
   double           swingScore;

   double           spreadCost;      // spread / ATR(reference tf)
   double           atrRatio;        // ATR vs its own long average
   double           adxHigh;         // trend persistence on the higher tf
   bool             liquidSession;
   int              serverHour;

   string           reason;
  };

void KM_ResetTfDecision(KMTfDecision &d)
  {
   d.valid         = false;
   d.style         = KM_STYLE_INTRADAY;
   d.tf            = PERIOD_M5;
   d.scalpScore    = 0.0;
   d.intradayScore = 0.0;
   d.swingScore    = 0.0;
   d.spreadCost    = 0.0;
   d.atrRatio      = 1.0;
   d.adxHigh       = 0.0;
   d.liquidSession = false;
   d.serverHour    = 0;
   d.reason        = "not decided";
  }

//+------------------------------------------------------------------+
struct TfSelectConfig
  {
   ENUM_TIMEFRAMES  refTf;             // timeframe the spread is judged against
   ENUM_TIMEFRAMES  trendTf;           // timeframe persistence is judged on
   int              atrPeriod;
   int              atrAvgPeriod;
   int              adxPeriod;

   double           spreadScalpMax;    // above this, scalping is uneconomic
   double           spreadIntradayMax; // above this, even intraday suffers
   double           volLow;            // atrRatio at or below = dead
   double           volHigh;           // atrRatio at or above = expanding
   double           adxTrending;       // ADX at or above = durable trend

   int              liquidFromHour;    // server time
   int              liquidToHour;
   bool             allowScalp;
   bool             allowIntraday;
   bool             allowSwing;
  };

void KM_DefaultTfSelectConfig(TfSelectConfig &c)
  {
   c.refTf             = PERIOD_M5;
   c.trendTf           = PERIOD_H1;
   c.atrPeriod         = 14;
   c.atrAvgPeriod      = 100;
   c.adxPeriod         = 14;
   c.spreadScalpMax    = 0.25;
   c.spreadIntradayMax = 0.60;
   c.volLow            = 0.75;
   c.volHigh           = 1.30;
   c.adxTrending       = 25.0;
   c.liquidFromHour    = 8;
   c.liquidToHour      = 20;
   c.allowScalp        = true;
   c.allowIntraday     = true;
   c.allowSwing        = true;
  }

//+------------------------------------------------------------------+
class CKMTfSelect
  {
private:
   string            m_symbol;
   TfSelectConfig    m_cfg;

   int               m_hAtrRef;
   int               m_hAdx;

   KMTfDecision      m_dec;
   datetime          m_lastBar;
   string            m_lastIssue;

   bool              ReadOne(const int handle, const int shift, double &out)
     {
      out = 0.0;
      if(handle == INVALID_HANDLE)
         return false;
      double tmp[];
      if(CopyBuffer(handle, 0, shift, 1, tmp) < 1)
         return false;
      out = tmp[0];
      return true;
     }

public:
                     CKMTfSelect(void)
     {
      m_symbol    = "";
      m_hAtrRef   = INVALID_HANDLE;
      m_hAdx      = INVALID_HANDLE;
      m_lastBar   = 0;
      m_lastIssue = "not refreshed yet";
      KM_DefaultTfSelectConfig(m_cfg);
      KM_ResetTfDecision(m_dec);
     }

                    ~CKMTfSelect(void) { Release(); }

   void              Config(const TfSelectConfig &c) { m_cfg = c; }
   string            LastIssue(void) const { return m_lastIssue; }
   string            Symbol(void)    const { return m_symbol; }
   void              Decision(KMTfDecision &out) const { out = m_dec; }

   bool              Init(const string sym)
     {
      m_symbol = sym;

      m_hAtrRef = iATR(sym, m_cfg.refTf, MathMax(2, m_cfg.atrPeriod));
      m_hAdx    = iADX(sym, m_cfg.trendTf, MathMax(2, m_cfg.adxPeriod));

      if(m_hAtrRef == INVALID_HANDLE || m_hAdx == INVALID_HANDLE)
        {
         m_lastIssue = "failed to create a timeframe-selector handle";
         return false;
        }
      return true;
     }

   void              Release(void)
     {
      if(m_hAtrRef != INVALID_HANDLE) IndicatorRelease(m_hAtrRef);
      if(m_hAdx    != INVALID_HANDLE) IndicatorRelease(m_hAdx);
      m_hAtrRef = m_hAdx = INVALID_HANDLE;
     }

   //+---------------------------------------------------------------+
   bool              Refresh(KMTfDecision &out, const bool force = false)
     {
      datetime bt = (datetime)SeriesInfoInteger(m_symbol, m_cfg.refTf, SERIES_LASTBAR_DATE);
      if(!force && bt == m_lastBar && m_dec.valid)
        {
         out = m_dec;
         return true;
        }

      KM_ResetTfDecision(m_dec);

      double atr;
      if(!ReadOne(m_hAtrRef, 1, atr) || atr <= 0.0)
        {
         m_lastIssue = StringFormat("ATR on %s not ready", EnumToString(m_cfg.refTf));
         out = m_dec;
         return false;
        }

      //--- ATR against its own long average
      double arr[];
      double atrAvg = atr;
      if(CopyBuffer(m_hAtrRef, 0, 1, m_cfg.atrAvgPeriod, arr) == m_cfg.atrAvgPeriod)
        {
         double sum = 0.0;
         for(int i = 0; i < m_cfg.atrAvgPeriod; i++)
            sum += arr[i];
         if(m_cfg.atrAvgPeriod > 0)
            atrAvg = sum / m_cfg.atrAvgPeriod;
        }

      double adx;
      if(!ReadOne(m_hAdx, 1, adx))
        {
         m_lastIssue = StringFormat("ADX on %s not ready", EnumToString(m_cfg.trendTf));
         out = m_dec;
         return false;
        }

      //--- spread expressed in the same units as the ATR
      double point  = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      double spread = (double)SymbolInfoInteger(m_symbol, SYMBOL_SPREAD) * point;

      m_dec.spreadCost = (atr > 0.0 ? spread / atr : 999.0);
      m_dec.atrRatio   = (atrAvg > 0.0 ? atr / atrAvg : 1.0);
      m_dec.adxHigh    = adx;

      MqlDateTime st;
      TimeToStruct(TimeCurrent(), st);
      m_dec.serverHour    = st.hour;
      m_dec.liquidSession = (st.hour >= m_cfg.liquidFromHour && st.hour < m_cfg.liquidToHour);

      //=== score the three styles ==================================
      double sc = 50.0, in = 50.0, sw = 50.0;
      string notes = "";

      //--- 1. spread economics, the heaviest term
      if(m_dec.spreadCost <= m_cfg.spreadScalpMax * 0.5)
        {
         sc += 30.0;
         notes += "spread cheap; ";
        }
      else if(m_dec.spreadCost <= m_cfg.spreadScalpMax)
        {
         sc += 10.0;
         notes += "spread ok for scalp; ";
        }
      else if(m_dec.spreadCost <= m_cfg.spreadIntradayMax)
        {
         sc -= 30.0;
         in += 10.0;
         notes += StringFormat("spread %.2f atr blocks scalping; ", m_dec.spreadCost);
        }
      else
        {
         sc -= 60.0;
         in -= 20.0;
         sw += 25.0;
         notes += StringFormat("spread %.2f atr is heavy, go slower; ", m_dec.spreadCost);
        }

      //--- 2. volatility
      if(m_dec.atrRatio >= m_cfg.volHigh)
        {
         sc += 15.0;
         in += 10.0;
         notes += "volatility expanding; ";
        }
      else if(m_dec.atrRatio <= m_cfg.volLow)
        {
         sc -= 20.0;
         sw += 15.0;
         notes += "volatility dead; ";
        }

      //--- 3. trend persistence
      if(adx >= m_cfg.adxTrending)
        {
         sw += 20.0;
         in += 10.0;
         sc -= 5.0;
         notes += StringFormat("adx %.0f trend worth holding; ", adx);
        }
      else
        {
         sc += 10.0;
         notes += StringFormat("adx %.0f chop; ", adx);
        }

      //--- 4. session
      if(m_dec.liquidSession)
        {
         sc += 10.0;
         in += 5.0;
         notes += "liquid session; ";
        }
      else
        {
         sc -= 20.0;
         sw += 10.0;
         notes += "thin session; ";
        }

      if(!m_cfg.allowScalp)    sc = -1000.0;
      if(!m_cfg.allowIntraday) in = -1000.0;
      if(!m_cfg.allowSwing)    sw = -1000.0;

      m_dec.scalpScore    = sc;
      m_dec.intradayScore = in;
      m_dec.swingScore    = sw;

      //=== pick the winner and the concrete timeframe ==============
      if(sc >= in && sc >= sw)
        {
         m_dec.style = KM_STYLE_SCALP;
         //--- inside scalping, a worse spread still means a slower chart
         if(m_dec.spreadCost <= m_cfg.spreadScalpMax * 0.35)
            m_dec.tf = PERIOD_M1;
         else if(m_dec.spreadCost <= m_cfg.spreadScalpMax * 0.7)
            m_dec.tf = PERIOD_M3;
         else
            m_dec.tf = PERIOD_M5;
        }
      else if(in >= sw)
        {
         m_dec.style = KM_STYLE_INTRADAY;
         m_dec.tf    = (m_dec.atrRatio >= m_cfg.volHigh ? PERIOD_M5 : PERIOD_M15);
        }
      else
        {
         m_dec.style = KM_STYLE_SWING;
         m_dec.tf    = (adx >= m_cfg.adxTrending + 10.0 ? PERIOD_H4 : PERIOD_H1);
        }

      m_dec.reason = StringFormat("%s -> %s | scalp %.0f intraday %.0f swing %.0f | %s",
                                  KM_StyleName(m_dec.style), EnumToString(m_dec.tf),
                                  sc, in, sw, notes);

      m_dec.valid = true;
      m_lastBar   = bt;
      m_lastIssue = "";
      out         = m_dec;
      return true;
     }

   string            Summary(void) const
     {
      if(!m_dec.valid)
         return m_symbol + " tf: " + m_lastIssue;

      return StringFormat("%-10s %-8s %-9s spread %.2fatr vol x%.2f adx %.0f%s",
                          m_symbol, KM_StyleName(m_dec.style),
                          EnumToString(m_dec.tf), m_dec.spreadCost,
                          m_dec.atrRatio, m_dec.adxHigh,
                          (m_dec.liquidSession ? "" : " thin"));
     }
  };

#endif // KRISHMIX_TFSELECT_MQH
//+------------------------------------------------------------------+
