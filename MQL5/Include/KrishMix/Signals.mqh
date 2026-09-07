//+------------------------------------------------------------------+
//|                                       KrishMix\Signals.mqh       |
//|                                                                  |
//|  The shared analysis engine used by all four EAs.                 |
//|                                                                  |
//|  It folds a multi-timeframe indicator stack into one MarketView:  |
//|                                                                  |
//|    score          -100..+100 composite directional conviction     |
//|    regime         range / trend / breakout                        |
//|    volState       compressed .. extreme                           |
//|    atr            volatility in price units (drives distances)    |
//|    exhaustion     stretched-and-stalling flags for reversals      |
//|                                                                  |
//|  Indicator stack                                                  |
//|    trend      EMA fast / slow / filter on the trading TF          |
//|               plus EMA on two higher timeframes (MTF agreement)   |
//|    strength   ADX with +DI / -DI                                  |
//|    momentum   MACD histogram (value and slope), RSI, Stochastic   |
//|    volatility ATR versus its own long average, Bollinger width    |
//|    structure  Donchian channel breakout, swing high / low         |
//+------------------------------------------------------------------+
#ifndef KRISHMIX_SIGNALS_MQH
#define KRISHMIX_SIGNALS_MQH

#include <KrishMix\Common.mqh>

//+------------------------------------------------------------------+
//| One complete reading of the market                               |
//+------------------------------------------------------------------+
struct MarketView
  {
   bool             valid;         // false when indicators are not ready
   double           score;         // -100..+100 composite bias
   double           trendStrength; // ADX main, 0..100
   ENUM_KM_REGIME   regime;
   ENUM_KM_VOL      volState;

   double           atr;           // price units
   double           atrRatio;      // atr / long-run atr average
   double           bbWidth;       // (upper-lower) / base

   double           rsi;
   double           stoch;
   double           macdHist;
   double           macdSlope;     // hist[0] - hist[1]
   double           bbPercent;     // 0..1 position inside the bands
   double           plusDI;
   double           minusDI;

   double           swingHigh;     // Donchian high
   double           swingLow;      // Donchian low
   double           closePrice;

   double           emaFast;       // exposed so EAs can time pullbacks
   double           emaSlow;
   double           emaFilter;
   double           bbUpper;
   double           bbLower;

   bool             bullExhaust;   // stretched up and losing steam
   bool             bearExhaust;   // stretched down and losing steam
   bool             mtfAgree;      // both higher timeframes agree with score
  };

void KM_ResetView(MarketView &v)
  {
   v.valid         = false;
   v.score         = 0.0;
   v.trendStrength = 0.0;
   v.regime        = KM_REGIME_RANGE;
   v.volState      = KM_VOL_NORMAL;
   v.atr           = 0.0;
   v.atrRatio      = 1.0;
   v.bbWidth       = 0.0;
   v.rsi           = 50.0;
   v.stoch         = 50.0;
   v.macdHist      = 0.0;
   v.macdSlope     = 0.0;
   v.bbPercent     = 0.5;
   v.plusDI        = 0.0;
   v.minusDI       = 0.0;
   v.swingHigh     = 0.0;
   v.swingLow      = 0.0;
   v.closePrice    = 0.0;
   v.emaFast       = 0.0;
   v.emaSlow       = 0.0;
   v.emaFilter     = 0.0;
   v.bbUpper       = 0.0;
   v.bbLower       = 0.0;
   v.bullExhaust   = false;
   v.bearExhaust   = false;
   v.mtfAgree      = false;
  }

//+------------------------------------------------------------------+
//| Tunables, exposed as one struct so every EA can surface them      |
//| as inputs without repeating twenty parameters.                    |
//+------------------------------------------------------------------+
struct SignalConfig
  {
   int              emaFast;
   int              emaSlow;
   int              emaFilter;
   ENUM_TIMEFRAMES  mtf1;
   ENUM_TIMEFRAMES  mtf2;
   int              emaMtf;
   int              adxPeriod;
   int              rsiPeriod;
   int              stochK;
   int              stochD;
   int              stochSlow;
   int              macdFast;
   int              macdSlow;
   int              macdSignal;
   int              atrPeriod;
   int              atrAvgPeriod;
   int              bbPeriod;
   double           bbDeviation;
   int              donchianPeriod;
   int              donchianShift;   // MUST be >= 2, see KM_DefaultSignalConfig
   double           adxTrendLevel;   // above this = trending
   double           adxRangeLevel;   // below this = ranging
   double           volHighRatio;    // atrRatio above this = HIGH
   double           volExtremeRatio; // atrRatio above this = EXTREME
   double           volLowRatio;     // atrRatio below this = LOW
  };

void KM_DefaultSignalConfig(SignalConfig &c)
  {
   c.emaFast         = 8;
   c.emaSlow         = 21;
   c.emaFilter       = 50;
   c.mtf1            = PERIOD_M15;
   c.mtf2            = PERIOD_H1;
   c.emaMtf          = 50;
   c.adxPeriod       = 14;
   c.rsiPeriod       = 14;
   c.stochK          = 14;
   c.stochD          = 3;
   c.stochSlow       = 3;
   c.macdFast        = 12;
   c.macdSlow        = 26;
   c.macdSignal      = 9;
   c.atrPeriod       = 14;
   c.atrAvgPeriod    = 100;
   c.bbPeriod        = 20;
   c.bbDeviation     = 2.0;
   c.donchianPeriod  = 40;
//--- The channel must EXCLUDE the bar whose close is tested against it.
//--- With shift 1 the tested bar's own high IS the channel high, so
//--- "close above the channel" would require a bar closing exactly at
//--- its own high while that high is also the 40-bar extreme. That made
//--- breakout detection almost impossible. Shift 2 starts the channel
//--- one bar earlier, which is what makes a breakout meaningful.
   c.donchianShift   = 2;
   c.adxTrendLevel   = 25.0;
   c.adxRangeLevel   = 18.0;
   c.volHighRatio    = 1.40;
   c.volExtremeRatio = 2.20;
   c.volLowRatio     = 0.70;
  }

//+------------------------------------------------------------------+
//| Engine                                                           |
//+------------------------------------------------------------------+
class CKMSignals
  {
private:
   string            m_symbol;
   ENUM_TIMEFRAMES   m_tf;
   SignalConfig      m_cfg;

   int               m_hEmaFast, m_hEmaSlow, m_hEmaFilt;
   int               m_hEmaMtf1, m_hEmaMtf2;
   int               m_hAdx, m_hRsi, m_hStoch, m_hMacd, m_hAtr, m_hBands;

   //--- cache so many EAs on one terminal do not recompute per tick
   MarketView        m_view;
   datetime          m_viewBar;

   //--- why the last Refresh failed. Without this a not-ready buffer is
   //--- silent and the EA looks broken rather than warming up.
   string            m_lastIssue;

   bool              One(const int handle, const int buffer, const int shift,
                         double &out, const string name)
     {
      double tmp[];

      if(handle == INVALID_HANDLE)
        {
         m_lastIssue = name + ": indicator handle is invalid";
         return false;
        }

      ResetLastError();
      int got = CopyBuffer(handle, buffer, shift, 1, tmp);
      if(got < 1)
        {
         m_lastIssue = StringFormat("%s: CopyBuffer returned %d (error %d), %d bars on %s",
                                    name, got, GetLastError(),
                                    Bars(m_symbol, m_tf), EnumToString(m_tf));
         return false;
        }

      out = tmp[0];
      return true;
     }

   bool              Many(const int handle, const int buffer, const int shift,
                          const int count, double &out[], const string name)
     {
      if(handle == INVALID_HANDLE)
        {
         m_lastIssue = name + ": indicator handle is invalid";
         return false;
        }

      ResetLastError();
      int got = CopyBuffer(handle, buffer, shift, count, out);
      if(got != count)
        {
         m_lastIssue = StringFormat("%s: wanted %d values, got %d (error %d)",
                                    name, count, got, GetLastError());
         return false;
        }

      return true;
     }

public:
                     CKMSignals(void)
     {
      m_symbol    = "";
      m_tf        = PERIOD_CURRENT;
      m_viewBar   = 0;
      m_lastIssue = "not refreshed yet";
      m_hEmaFast = m_hEmaSlow = m_hEmaFilt = INVALID_HANDLE;
      m_hEmaMtf1 = m_hEmaMtf2 = INVALID_HANDLE;
      m_hAdx = m_hRsi = m_hStoch = m_hMacd = m_hAtr = m_hBands = INVALID_HANDLE;
      KM_ResetView(m_view);
      KM_DefaultSignalConfig(m_cfg);
     }

                    ~CKMSignals(void) { Release(); }

   void              Config(const SignalConfig &c) { m_cfg = c; }

   //--- exact reason the last Refresh could not produce a reading
   string            LastIssue(void) const { return m_lastIssue; }

   //--- how many bars each side of the stack still needs
   string            WarmupReport(void)
     {
      return StringFormat("%s bars=%d | %s bars=%d | %s bars=%d",
                          EnumToString(m_tf),          Bars(m_symbol, m_tf),
                          EnumToString(m_cfg.mtf1),    Bars(m_symbol, m_cfg.mtf1),
                          EnumToString(m_cfg.mtf2),    Bars(m_symbol, m_cfg.mtf2));
     }

   //+---------------------------------------------------------------+
   bool              Init(const string sym, const ENUM_TIMEFRAMES tf)
     {
      m_symbol = sym;
      m_tf     = tf;

      m_hEmaFast = iMA(sym, tf, m_cfg.emaFast,   0, MODE_EMA, PRICE_CLOSE);
      m_hEmaSlow = iMA(sym, tf, m_cfg.emaSlow,   0, MODE_EMA, PRICE_CLOSE);
      m_hEmaFilt = iMA(sym, tf, m_cfg.emaFilter, 0, MODE_EMA, PRICE_CLOSE);

      m_hEmaMtf1 = iMA(sym, m_cfg.mtf1, m_cfg.emaMtf, 0, MODE_EMA, PRICE_CLOSE);
      m_hEmaMtf2 = iMA(sym, m_cfg.mtf2, m_cfg.emaMtf, 0, MODE_EMA, PRICE_CLOSE);

      m_hAdx   = iADX(sym, tf, m_cfg.adxPeriod);
      m_hRsi   = iRSI(sym, tf, m_cfg.rsiPeriod, PRICE_CLOSE);
      m_hStoch = iStochastic(sym, tf, m_cfg.stochK, m_cfg.stochD, m_cfg.stochSlow,
                             MODE_SMA, STO_LOWHIGH);
      m_hMacd  = iMACD(sym, tf, m_cfg.macdFast, m_cfg.macdSlow, m_cfg.macdSignal, PRICE_CLOSE);
      m_hAtr   = iATR(sym, tf, m_cfg.atrPeriod);
      m_hBands = iBands(sym, tf, m_cfg.bbPeriod, 0, m_cfg.bbDeviation, PRICE_CLOSE);

      if(m_hEmaFast == INVALID_HANDLE || m_hEmaSlow == INVALID_HANDLE ||
         m_hEmaFilt == INVALID_HANDLE || m_hEmaMtf1 == INVALID_HANDLE ||
         m_hEmaMtf2 == INVALID_HANDLE || m_hAdx == INVALID_HANDLE ||
         m_hRsi == INVALID_HANDLE || m_hStoch == INVALID_HANDLE ||
         m_hMacd == INVALID_HANDLE || m_hAtr == INVALID_HANDLE ||
         m_hBands == INVALID_HANDLE)
        {
         Print("CKMSignals: failed to create one or more indicator handles.");
         return false;
        }

      return true;
     }

   void              Release(void)
     {
      if(m_hEmaFast != INVALID_HANDLE) IndicatorRelease(m_hEmaFast);
      if(m_hEmaSlow != INVALID_HANDLE) IndicatorRelease(m_hEmaSlow);
      if(m_hEmaFilt != INVALID_HANDLE) IndicatorRelease(m_hEmaFilt);
      if(m_hEmaMtf1 != INVALID_HANDLE) IndicatorRelease(m_hEmaMtf1);
      if(m_hEmaMtf2 != INVALID_HANDLE) IndicatorRelease(m_hEmaMtf2);
      if(m_hAdx   != INVALID_HANDLE)   IndicatorRelease(m_hAdx);
      if(m_hRsi   != INVALID_HANDLE)   IndicatorRelease(m_hRsi);
      if(m_hStoch != INVALID_HANDLE)   IndicatorRelease(m_hStoch);
      if(m_hMacd  != INVALID_HANDLE)   IndicatorRelease(m_hMacd);
      if(m_hAtr   != INVALID_HANDLE)   IndicatorRelease(m_hAtr);
      if(m_hBands != INVALID_HANDLE)   IndicatorRelease(m_hBands);

      m_hEmaFast = m_hEmaSlow = m_hEmaFilt = INVALID_HANDLE;
      m_hEmaMtf1 = m_hEmaMtf2 = INVALID_HANDLE;
      m_hAdx = m_hRsi = m_hStoch = m_hMacd = m_hAtr = m_hBands = INVALID_HANDLE;
     }

   //+---------------------------------------------------------------+
   //| Build a MarketView. Recomputed once per closed bar; every      |
   //| other call inside the same bar returns the cached reading.      |
   //+---------------------------------------------------------------+
   bool              Refresh(MarketView &v, const bool force = false)
     {
      datetime barTime = (datetime)SeriesInfoInteger(m_symbol, m_tf, SERIES_LASTBAR_DATE);

      if(!force && barTime == m_viewBar && m_view.valid)
        {
         v = m_view;
         return true;
        }

      MarketView t;
      KM_ResetView(t);

      //--- raw values, all read from shift 1 (last CLOSED bar) --------
      double emaF, emaS, emaFl, mtf1, mtf2, adx, pDI, mDI, rsi, stoK;
      double bbUp, bbLo, bbBase, atr;

      if(!One(m_hEmaFast, 0, 1, emaF,  "EMA fast"))       { v = t; return false; }
      if(!One(m_hEmaSlow, 0, 1, emaS,  "EMA slow"))       { v = t; return false; }
      if(!One(m_hEmaFilt, 0, 1, emaFl, "EMA filter"))     { v = t; return false; }
      if(!One(m_hEmaMtf1, 0, 1, mtf1,  "EMA on " + EnumToString(m_cfg.mtf1))) { v = t; return false; }
      if(!One(m_hEmaMtf2, 0, 1, mtf2,  "EMA on " + EnumToString(m_cfg.mtf2))) { v = t; return false; }
      if(!One(m_hAdx, 0, 1, adx,       "ADX main"))       { v = t; return false; }
      if(!One(m_hAdx, 1, 1, pDI,       "ADX +DI"))        { v = t; return false; }
      if(!One(m_hAdx, 2, 1, mDI,       "ADX -DI"))        { v = t; return false; }
      if(!One(m_hRsi, 0, 1, rsi,       "RSI"))            { v = t; return false; }
      if(!One(m_hStoch, 0, 1, stoK,    "Stochastic"))     { v = t; return false; }
      if(!One(m_hBands, 1, 1, bbUp,    "Bollinger upper")){ v = t; return false; }
      if(!One(m_hBands, 2, 1, bbLo,    "Bollinger lower")){ v = t; return false; }
      if(!One(m_hBands, 0, 1, bbBase,  "Bollinger base")) { v = t; return false; }
      if(!One(m_hAtr, 0, 1, atr,       "ATR"))            { v = t; return false; }

      //--- MACD histogram needs two bars for its slope
      double macdMain[], macdSig[];
      if(!Many(m_hMacd, 0, 1, 2, macdMain, "MACD main"))   { v = t; return false; }
      if(!Many(m_hMacd, 1, 1, 2, macdSig,  "MACD signal")) { v = t; return false; }
      double hist0 = macdMain[0] - macdSig[0];
      double hist1 = macdMain[1] - macdSig[1];

      //--- long-run ATR average for the volatility ratio
      double atrArr[];
      double atrAvg = atr;
      if(Many(m_hAtr, 0, 1, m_cfg.atrAvgPeriod, atrArr, "ATR average"))
        {
         double sum = 0.0;
         for(int i = 0; i < m_cfg.atrAvgPeriod; i++)
            sum += atrArr[i];
         if(m_cfg.atrAvgPeriod > 0)
            atrAvg = sum / m_cfg.atrAvgPeriod;
        }

      //--- Donchian structure
//--- The channel starts at donchianShift (2), so it does NOT contain the
//--- bar whose close is compared against it. With shift 1 that bar's own
//--- high was part of the channel, which made a breakout close all but
//--- unreachable.
      double hi[], lo[];
      double swingHigh = 0.0, swingLow = 0.0;
      int    dShift = MathMax(2, m_cfg.donchianShift);

      if(CopyHigh(m_symbol, m_tf, dShift, m_cfg.donchianPeriod, hi) == m_cfg.donchianPeriod &&
         CopyLow(m_symbol, m_tf, dShift, m_cfg.donchianPeriod, lo) == m_cfg.donchianPeriod)
        {
         swingHigh = hi[ArrayMaximum(hi)];
         swingLow  = lo[ArrayMinimum(lo)];
        }
      else
         m_lastIssue = StringFormat("Donchian: need %d bars from shift %d, have %d",
                                    m_cfg.donchianPeriod, dShift, Bars(m_symbol, m_tf));

      double closeArr[];
      double close1 = 0.0;
      if(CopyClose(m_symbol, m_tf, 1, 1, closeArr) == 1)
         close1 = closeArr[0];
      else
        {
         m_lastIssue = StringFormat("close of bar 1 unavailable (error %d, %d bars)",
                                    GetLastError(), Bars(m_symbol, m_tf));
         v = t;
         return false;
        }

      //--- fill measured fields -------------------------------------
      t.atr           = atr;
      t.atrRatio      = (atrAvg > 0.0 ? atr / atrAvg : 1.0);
      t.bbWidth       = (bbBase > 0.0 ? (bbUp - bbLo) / bbBase : 0.0);
      t.rsi           = rsi;
      t.stoch         = stoK;
      t.macdHist      = hist0;
      t.macdSlope     = hist0 - hist1;
      t.plusDI        = pDI;
      t.minusDI       = mDI;
      t.trendStrength = adx;
      t.swingHigh     = swingHigh;
      t.swingLow      = swingLow;
      t.closePrice    = close1;
      t.emaFast       = emaF;
      t.emaSlow       = emaS;
      t.emaFilter     = emaFl;
      t.bbUpper       = bbUp;
      t.bbLower       = bbLo;
      t.bbPercent     = (bbUp - bbLo > 0.0
                         ? MathMax(0.0, MathMin(1.0, (close1 - bbLo) / (bbUp - bbLo)))
                         : 0.5);

      //--- composite score, weights sum to 100 ----------------------
      double sc = 0.0;

      // 1. fast vs slow EMA, normalised by ATR so it scales with volatility
      if(atr > 0.0)
         sc += 15.0 * MathMax(-1.0, MathMin(1.0, (emaF - emaS) / atr));

      // 2. slow EMA vs the slower filter
      if(atr > 0.0)
         sc += 10.0 * MathMax(-1.0, MathMin(1.0, (emaS - emaFl) / atr));

      // 3+4. higher timeframe agreement
      double mtf1Bias = (close1 > mtf1 ? 1.0 : -1.0);
      double mtf2Bias = (close1 > mtf2 ? 1.0 : -1.0);
      sc += 10.0 * mtf1Bias;
      sc += 10.0 * mtf2Bias;

      // 5. MACD histogram sign, normalised
      if(atr > 0.0)
         sc += 10.0 * MathMax(-1.0, MathMin(1.0, hist0 / (atr * 0.5)));

      // 6. MACD histogram slope - momentum acceleration
      if(atr > 0.0)
         sc += 5.0 * MathMax(-1.0, MathMin(1.0, (hist0 - hist1) / (atr * 0.2)));

      // 7. RSI distance from the midline
      sc += 15.0 * MathMax(-1.0, MathMin(1.0, (rsi - 50.0) / 25.0));

      // 8. Stochastic distance from the midline
      sc += 10.0 * MathMax(-1.0, MathMin(1.0, (stoK - 50.0) / 30.0));

      // 9. Donchian breakout
      if(swingHigh > swingLow)
        {
         if(close1 >= swingHigh)
            sc += 15.0;
         else if(close1 <= swingLow)
            sc -= 15.0;
         else
           {
            double mid  = 0.5 * (swingHigh + swingLow);
            double half = 0.5 * (swingHigh - swingLow);
            if(half > 0.0)
               sc += 15.0 * MathMax(-1.0, MathMin(1.0, (close1 - mid) / half)) * 0.5;
           }
        }

      t.score    = MathMax(-100.0, MathMin(100.0, sc));
      t.mtfAgree = ((t.score > 0.0 && mtf1Bias > 0.0 && mtf2Bias > 0.0) ||
                    (t.score < 0.0 && mtf1Bias < 0.0 && mtf2Bias < 0.0));

      //--- volatility state -----------------------------------------
      if(t.atrRatio >= m_cfg.volExtremeRatio)
         t.volState = KM_VOL_EXTREME;
      else if(t.atrRatio >= m_cfg.volHighRatio)
         t.volState = KM_VOL_HIGH;
      else if(t.atrRatio <= m_cfg.volLowRatio)
         t.volState = KM_VOL_LOW;
      else
         t.volState = KM_VOL_NORMAL;

      //--- regime ---------------------------------------------------
      bool expanding = (t.atrRatio >= m_cfg.volHighRatio);
      bool brokeUp   = (swingHigh > 0.0 && close1 >= swingHigh);
      bool brokeDown = (swingLow  > 0.0 && close1 <= swingLow);

      if(expanding && brokeUp)
         t.regime = KM_REGIME_BREAKOUT_UP;
      else if(expanding && brokeDown)
         t.regime = KM_REGIME_BREAKOUT_DN;
      else if(adx >= m_cfg.adxTrendLevel && pDI > mDI)
         t.regime = KM_REGIME_TREND_UP;
      else if(adx >= m_cfg.adxTrendLevel && mDI > pDI)
         t.regime = KM_REGIME_TREND_DOWN;
      else
         t.regime = KM_REGIME_RANGE;

      //--- exhaustion: stretched AND momentum rolling over ----------
      t.bullExhaust = (rsi >= 68.0 && t.bbPercent >= 0.90 && t.macdSlope < 0.0);
      t.bearExhaust = (rsi <= 32.0 && t.bbPercent <= 0.10 && t.macdSlope > 0.0);

      t.valid     = true;
      m_view      = t;
      m_viewBar   = barTime;
      m_lastIssue = "";

      v = t;
      return true;
     }

   //+---------------------------------------------------------------+
   //| Convenience readers                                            |
   //+---------------------------------------------------------------+

   //--- directional bias once a conviction floor is cleared
   ENUM_KM_DIR       Bias(const MarketView &v, const double minScore) const
     {
      if(!v.valid)
         return KM_DIR_NONE;
      if(v.score >= minScore)
         return KM_DIR_BUY;
      if(v.score <= -minScore)
         return KM_DIR_SELL;
      return KM_DIR_NONE;
     }

   //--- does the reading argue for a reversal against 'dir'?
   bool              ExhaustedAgainst(const MarketView &v, const ENUM_KM_DIR dir) const
     {
      if(!v.valid)
         return false;
      if(dir == KM_DIR_BUY)
         return v.bearExhaust;    // sellers exhausted -> good for a buy add
      if(dir == KM_DIR_SELL)
         return v.bullExhaust;
      return false;
     }

   //--- how hard the market currently pushes against 'dir', 0..100
   double            PressureAgainst(const MarketView &v, const ENUM_KM_DIR dir) const
     {
      if(!v.valid || dir == KM_DIR_NONE)
         return 0.0;

      double against = (dir == KM_DIR_BUY ? -v.score : v.score);
      if(against <= 0.0)
         return 0.0;

      //--- weight raw bias by how trending the market is
      double trendW = MathMax(0.3, MathMin(1.5, v.trendStrength / 25.0));
      return MathMin(100.0, against * trendW);
     }
  };

#endif // KRISHMIX_SIGNALS_MQH
//+------------------------------------------------------------------+
