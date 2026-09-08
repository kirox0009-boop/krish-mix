//+------------------------------------------------------------------+
//|                                       KrishMix\Structure.mqh     |
//|                                                                  |
//|  Price-structure reading. Everything here is ADDITIVE: it does not |
//|  touch or replace the indicator stack in Signals.mqh, it sits      |
//|  beside it and answers questions that indicators cannot.           |
//|                                                                  |
//|  What it provides                                                  |
//|    swings        pivot highs and lows (fractal confirmation)       |
//|    inside bar    a big candle followed by a baby candle contained   |
//|                  inside it, with the baby's low / high exposed as   |
//|                  the break trigger                                  |
//|    levels        support and resistance, clustered from swings      |
//|    trendlines    major rising / falling line through real swings    |
//|    trend state   direction, legs completed, how far it has run and  |
//|                  therefore whether it is FRESH or already mid-move  |
//|    patterns      head and shoulders, rising wedge, falling wedge    |
//|                                                                  |
//|  ATR is passed in by the caller so this module never creates its    |
//|  own indicator handle - the reading stays consistent with the one   |
//|  the rest of the suite is already using.                            |
//+------------------------------------------------------------------+
#ifndef KRISHMIX_STRUCTURE_MQH
#define KRISHMIX_STRUCTURE_MQH

#include <KrishMix\Common.mqh>

#define KM_MAX_SWINGS 64
#define KM_MAX_LEVELS 24

//+------------------------------------------------------------------+
//| A confirmed pivot                                                |
//+------------------------------------------------------------------+
struct KMSwing
  {
   int              bar;      // shift index, 1 = last closed bar
   datetime         time;
   double           price;
   bool             isHigh;
  };

//+------------------------------------------------------------------+
//| A clustered support / resistance level                           |
//+------------------------------------------------------------------+
struct KMLevel
  {
   double           price;
   int              touches;
   bool             isResistance;
   int              newestBar;   // most recent bar that touched it
   double           strength;    // 0..100, touches weighted by recency
  };

//+------------------------------------------------------------------+
//| Inside bar: mother candle + baby candle fully inside it           |
//+------------------------------------------------------------------+
struct KMInsideBar
  {
   bool             found;
   int              motherBar;
   int              babyBar;
   double           motherHigh, motherLow, motherRange;
   double           babyHigh,   babyLow,   babyRange;
   bool             atSwingHigh;   // the mother printed a fresh local high
   bool             atSwingLow;    // the mother printed a fresh local low
   bool             brokenDown;    // a later bar already closed below babyLow
   bool             brokenUp;      // a later bar already closed above babyHigh
   int              ageBars;       // bars since the baby closed
  };

//+------------------------------------------------------------------+
//| A fitted trendline. x axis is the bar shift, so a rising line has |
//| a positive slope when read forward in time.                       |
//+------------------------------------------------------------------+
struct KMTrendline
  {
   bool             valid;
   bool             isSupport;   // built from lows and sits under price
   double           slope;       // price change per bar, forward in time
   int              anchorBar;   // shift of the newer anchor
   double           anchorPrice; // price at that anchor
   int              touches;
   int              olderBar;
   double           olderPrice;
  };

//--- projected line price at a given bar shift
double KM_TrendlinePrice(const KMTrendline &t, const int shift)
  {
   if(!t.valid)
      return 0.0;
   return t.anchorPrice + t.slope * (double)(t.anchorBar - shift);
  }

//+------------------------------------------------------------------+
//| Where we are inside the current move.                            |
//|                                                                  |
//| This is what makes "never enter a trend that is already running"  |
//| enforceable: maturity rises as the move extends in ATR and as it  |
//| completes more legs, and isFresh / nearCorner mark the entries    |
//| that are still taken from the start of a move rather than its     |
//| middle.                                                           |
//+------------------------------------------------------------------+
struct KMTrendState
  {
   bool             valid;
   ENUM_KM_DIR      dir;
   int              legsCompleted;
   int              barsSinceStart;
   int              originBar;
   double           originPrice;      // where this move began
   double           extensionAtr;     // how far it has run, in ATR
   double           retracePct;       // current pullback vs the last leg, 0..100
   double           maturity;         // 0 = brand new, 100 = fully extended
   bool             isFresh;          // maturity within the fresh threshold
   bool             nearCorner;       // price still close to the origin
   bool             justFlipped;      // structure broke direction recently
  };

//+------------------------------------------------------------------+
//| Classic patterns                                                 |
//+------------------------------------------------------------------+
struct KMPatterns
  {
   bool             headShoulders;      // bearish
   bool             invHeadShoulders;   // bullish
   bool             risingWedge;        // bearish
   bool             fallingWedge;       // bullish
   double           neckline;           // H&S trigger level
   string           names;              // human readable list
  };

//+------------------------------------------------------------------+
//| Tunables                                                         |
//+------------------------------------------------------------------+
struct StructureConfig
  {
   int              swingStrength;       // pivot bars required each side
   int              swingLookback;       // bars scanned for pivots
   double           srToleranceAtr;      // clustering width, in ATR
   int              srMinTouches;
   double           insideMotherMinAtr;  // mother must be at least this big
   double           insideBabyMaxFrac;   // baby range / mother range ceiling
   int              insideMaxAgeBars;    // ignore stale inside bars
   int              insideExtremeLookback; // mother must be the extreme of this
   double           maxExtensionAtr;     // extension counted as fully mature
   int              maxLegs;             // legs counted as fully mature
   double           freshMaturity;       // maturity at or below this is fresh
   double           cornerAtr;           // distance from origin still a corner
   int              flipRecentBars;      // structure flip counts as recent
   double           patternToleranceAtr; // shoulder / symmetry tolerance
  };

void KM_DefaultStructureConfig(StructureConfig &c)
  {
   c.swingStrength         = 3;
   c.swingLookback         = 300;
   c.srToleranceAtr        = 0.60;
   c.srMinTouches          = 2;
   c.insideMotherMinAtr    = 0.80;
   c.insideBabyMaxFrac     = 0.55;
   c.insideMaxAgeBars      = 6;
   c.insideExtremeLookback = 12;
   c.maxExtensionAtr       = 12.0;
   c.maxLegs               = 5;
   c.freshMaturity         = 40.0;
   c.cornerAtr             = 3.0;
   c.flipRecentBars        = 25;
   c.patternToleranceAtr   = 0.80;
  }

//+------------------------------------------------------------------+
//| Structure reader                                                 |
//+------------------------------------------------------------------+
class CKMStructure
  {
private:
   string            m_symbol;
   ENUM_TIMEFRAMES   m_tf;
   StructureConfig   m_cfg;

   //--- copied series, index == bar shift
   double            m_h[], m_l[], m_o[], m_c[];
   datetime          m_t[];
   int               m_bars;

   KMSwing           m_swings[];   // newest first
   int               m_nSwings;
   KMLevel           m_levels[];
   int               m_nLevels;

   KMInsideBar       m_inside;
   KMTrendline       m_lineSup, m_lineRes;
   KMTrendState      m_trend;
   KMPatterns        m_pat;

   double            m_atr;
   datetime          m_lastBar;
   bool              m_valid;
   string            m_lastIssue;

   //---------------------------------------------------------------
   bool              LoadSeries(void)
     {
      int need = m_cfg.swingLookback + 2 * m_cfg.swingStrength + 8;

      ArraySetAsSeries(m_h, true);
      ArraySetAsSeries(m_l, true);
      ArraySetAsSeries(m_o, true);
      ArraySetAsSeries(m_c, true);
      ArraySetAsSeries(m_t, true);

      if(CopyHigh(m_symbol, m_tf, 0, need, m_h)  < need ||
         CopyLow(m_symbol, m_tf, 0, need, m_l)   < need ||
         CopyOpen(m_symbol, m_tf, 0, need, m_o)  < need ||
         CopyClose(m_symbol, m_tf, 0, need, m_c) < need ||
         CopyTime(m_symbol, m_tf, 0, need, m_t)  < need)
        {
         m_lastIssue = StringFormat("need %d bars on %s, have %d",
                                    need, EnumToString(m_tf), Bars(m_symbol, m_tf));
         return false;
        }

      m_bars = need;
      return true;
     }

   //--- fractal pivots, newest first ------------------------------
   void              FindSwings(void)
     {
      m_nSwings = 0;
      int s = MathMax(1, m_cfg.swingStrength);
      int last = MathMin(m_bars - s - 1, m_cfg.swingLookback);

      for(int i = s; i <= last && m_nSwings < KM_MAX_SWINGS; i++)
        {
         bool isHigh = true, isLow = true;

         for(int k = 1; k <= s; k++)
           {
            if(m_h[i] <= m_h[i - k] || m_h[i] <= m_h[i + k])
               isHigh = false;
            if(m_l[i] >= m_l[i - k] || m_l[i] >= m_l[i + k])
               isLow = false;
            if(!isHigh && !isLow)
               break;
           }

         if(!isHigh && !isLow)
            continue;

         m_swings[m_nSwings].bar    = i;
         m_swings[m_nSwings].time   = m_t[i];
         m_swings[m_nSwings].isHigh = isHigh;
         m_swings[m_nSwings].price  = (isHigh ? m_h[i] : m_l[i]);
         m_nSwings++;
        }
     }

   //--- cluster swings into levels -------------------------------
   void              BuildLevels(void)
     {
      m_nLevels = 0;
      double toler = MathMax(m_atr * m_cfg.srToleranceAtr, _Point * 10.0);

      for(int i = 0; i < m_nSwings; i++)
        {
         int found = -1;
         for(int j = 0; j < m_nLevels; j++)
            if(MathAbs(m_levels[j].price - m_swings[i].price) <= toler &&
               m_levels[j].isResistance == m_swings[i].isHigh)
              {
               found = j;
               break;
              }

         if(found >= 0)
           {
            //--- volume weighted toward the newer touch
            double n = (double)m_levels[found].touches;
            m_levels[found].price = (m_levels[found].price * n + m_swings[i].price) / (n + 1.0);
            m_levels[found].touches++;
            if(m_swings[i].bar < m_levels[found].newestBar)
               m_levels[found].newestBar = m_swings[i].bar;
           }
         else if(m_nLevels < KM_MAX_LEVELS)
           {
            m_levels[m_nLevels].price        = m_swings[i].price;
            m_levels[m_nLevels].touches      = 1;
            m_levels[m_nLevels].isResistance = m_swings[i].isHigh;
            m_levels[m_nLevels].newestBar    = m_swings[i].bar;
            m_levels[m_nLevels].strength     = 0.0;
            m_nLevels++;
           }
        }

      //--- strength: touches carry most of it, recency the rest
      for(int j = 0; j < m_nLevels; j++)
        {
         double tScore = MathMin(1.0, (double)m_levels[j].touches / 4.0);
         double rScore = 1.0 - MathMin(1.0, (double)m_levels[j].newestBar /
                                       (double)MathMax(1, m_cfg.swingLookback));
         m_levels[j].strength = 100.0 * (0.7 * tScore + 0.3 * rScore);
        }
     }

   //--- most recent usable inside bar ----------------------------
   void              FindInsideBar(void)
     {
      m_inside.found = false;

      int maxAge = MathMax(1, m_cfg.insideMaxAgeBars);

      //--- baby at shift b, mother at shift b+1
      for(int b = 1; b <= maxAge; b++)
        {
         int mo = b + 1;
         if(mo + m_cfg.insideExtremeLookback + 2 >= m_bars)
            break;

         double moRange = m_h[mo] - m_l[mo];
         double bbRange = m_h[b]  - m_l[b];

         if(moRange <= 0.0)
            continue;

         //--- containment
         if(m_h[b] > m_h[mo] || m_l[b] < m_l[mo])
            continue;

         //--- the mother has to be a genuinely big candle
         if(m_atr > 0.0 && moRange < m_atr * m_cfg.insideMotherMinAtr)
            continue;

         //--- and the baby genuinely small next to it
         if(bbRange > moRange * m_cfg.insideBabyMaxFrac)
            continue;

         //--- did the mother print a fresh local extreme?
         bool freshHigh = true, freshLow = true;
         for(int k = 1; k <= m_cfg.insideExtremeLookback; k++)
           {
            if(m_h[mo + k] >= m_h[mo])
               freshHigh = false;
            if(m_l[mo + k] <= m_l[mo])
               freshLow = false;
            if(!freshHigh && !freshLow)
               break;
           }

         //--- has a later closed bar already resolved the pattern?
         bool brokeDn = false, brokeUp = false;
         for(int k = b - 1; k >= 1; k--)
           {
            if(m_c[k] < m_l[b])
               brokeDn = true;
            if(m_c[k] > m_h[b])
               brokeUp = true;
           }

         m_inside.found       = true;
         m_inside.motherBar   = mo;
         m_inside.babyBar     = b;
         m_inside.motherHigh  = m_h[mo];
         m_inside.motherLow   = m_l[mo];
         m_inside.motherRange = moRange;
         m_inside.babyHigh    = m_h[b];
         m_inside.babyLow     = m_l[b];
         m_inside.babyRange   = bbRange;
         m_inside.atSwingHigh = freshHigh;
         m_inside.atSwingLow  = freshLow;
         m_inside.brokenDown  = brokeDn;
         m_inside.brokenUp    = brokeUp;
         m_inside.ageBars     = b;
         return;
        }
     }

   //--- fit a line through the two most recent same-type swings ----
   void              BuildTrendline(const bool fromLows, KMTrendline &out)
     {
      out.valid = false;

      int i1 = -1, i2 = -1;   // i1 newer, i2 older
      for(int i = 0; i < m_nSwings; i++)
        {
         if(m_swings[i].isHigh == fromLows)
            continue;         // want lows when fromLows, highs otherwise
         if(i1 < 0)
            i1 = i;
         else
           {
            i2 = i;
            break;
           }
        }

      if(i1 < 0 || i2 < 0)
         return;

      int    b1 = m_swings[i1].bar,   b2 = m_swings[i2].bar;
      double p1 = m_swings[i1].price, p2 = m_swings[i2].price;

      if(b2 <= b1)
         return;

      out.valid       = true;
      out.isSupport   = fromLows;
      out.anchorBar   = b1;
      out.anchorPrice = p1;
      out.olderBar    = b2;
      out.olderPrice  = p2;
      out.slope       = (p1 - p2) / (double)(b2 - b1);

      //--- count how many later swings sit close to the projection
      out.touches = 2;
      double toler = MathMax(m_atr * m_cfg.srToleranceAtr, _Point * 10.0);
      for(int i = 0; i < m_nSwings; i++)
        {
         if(i == i1 || i == i2)
            continue;
         if(m_swings[i].isHigh == fromLows)
            continue;
         double proj = KM_TrendlinePrice(out, m_swings[i].bar);
         if(MathAbs(m_swings[i].price - proj) <= toler)
            out.touches++;
        }
     }

   //--- direction, legs, extension, maturity ---------------------
   void              BuildTrendState(void)
     {
      //--- full reset: several paths below return early, and a stale flag
      //--- carried over from the previous bar would silently pass the
      //--- fresh-entry gate
      m_trend.valid          = false;
      m_trend.dir            = KM_DIR_NONE;
      m_trend.legsCompleted  = 0;
      m_trend.barsSinceStart = 0;
      m_trend.originBar      = 0;
      m_trend.originPrice    = 0.0;
      m_trend.extensionAtr   = 0.0;
      m_trend.retracePct     = 0.0;
      m_trend.maturity       = 100.0;
      m_trend.isFresh        = false;
      m_trend.nearCorner     = false;
      m_trend.justFlipped    = false;

      //--- collect the recent highs and lows separately, newest first
      double hi[8], lo[8];
      int    hiBar[8], loBar[8];
      int nh = 0, nl = 0;

      for(int i = 0; i < m_nSwings && (nh < 8 || nl < 8); i++)
        {
         if(m_swings[i].isHigh && nh < 8)
           {
            hi[nh]    = m_swings[i].price;
            hiBar[nh] = m_swings[i].bar;
            nh++;
           }
         else if(!m_swings[i].isHigh && nl < 8)
           {
            lo[nl]    = m_swings[i].price;
            loBar[nl] = m_swings[i].bar;
            nl++;
           }
        }

      if(nh < 2 || nl < 2)
        {
         m_lastIssue = "not enough swings for a trend read";
         return;
        }

      //--- higher highs and higher lows, or the mirror
      bool hh = (hi[0] > hi[1]);
      bool hl = (lo[0] > lo[1]);
      bool lh = (hi[0] < hi[1]);
      bool ll = (lo[0] < lo[1]);

      if(hh && hl)
         m_trend.dir = KM_DIR_BUY;
      else if(lh && ll)
         m_trend.dir = KM_DIR_SELL;
      else
         m_trend.dir = KM_DIR_NONE;

      m_trend.valid = true;

      if(m_trend.dir == KM_DIR_NONE)
        {
         //--- range: treat it as maximally "unclear" rather than fresh
         m_trend.maturity   = 50.0;
         m_trend.isFresh    = false;
         m_trend.nearCorner = false;
         return;
        }

      bool up = (m_trend.dir == KM_DIR_BUY);

      //--- walk back to where the move began: the last swing that broke
      //--- the sequence in the opposite direction
      int    originBar   = 0;
      double originPrice = 0.0;
      int    legs        = 0;

      if(up)
        {
         originBar   = loBar[nl - 1];
         originPrice = lo[nl - 1];
         for(int i = nl - 1; i >= 1; i--)
           {
            if(lo[i - 1] > lo[i])
               legs++;
            else
              {
               originBar   = loBar[i];
               originPrice = lo[i];
               legs        = 0;
              }
           }
        }
      else
        {
         originBar   = hiBar[nh - 1];
         originPrice = hi[nh - 1];
         for(int i = nh - 1; i >= 1; i--)
           {
            if(hi[i - 1] < hi[i])
               legs++;
            else
              {
               originBar   = hiBar[i];
               originPrice = hi[i];
               legs        = 0;
              }
           }
        }

      m_trend.originBar      = originBar;
      m_trend.originPrice    = originPrice;
      m_trend.legsCompleted  = MathMax(1, legs);
      m_trend.barsSinceStart = originBar;

      double now = m_c[1];
      m_trend.extensionAtr = (m_atr > 0.0 ? MathAbs(now - originPrice) / m_atr : 0.0);

      //--- how deep is the current pullback against the last leg
      double legHigh = (up ? hi[0] : lo[0]);
      double legSize = MathAbs(legHigh - originPrice);
      double pull    = (up ? (legHigh - now) : (now - legHigh));
      m_trend.retracePct = (legSize > 0.0 ? MathMax(0.0, MathMin(100.0, 100.0 * pull / legSize)) : 0.0);

      //--- maturity: extension and leg count, blended
      double extScore = 100.0 * MathMin(1.0, m_trend.extensionAtr /
                                        MathMax(0.1, m_cfg.maxExtensionAtr));
      double legScore = 100.0 * MathMin(1.0, (double)m_trend.legsCompleted /
                                        (double)MathMax(1, m_cfg.maxLegs));
      m_trend.maturity = 0.6 * extScore + 0.4 * legScore;

      m_trend.isFresh    = (m_trend.maturity <= m_cfg.freshMaturity);
      m_trend.nearCorner = (m_atr > 0.0 &&
                            MathAbs(now - originPrice) <= m_atr * m_cfg.cornerAtr);
      m_trend.justFlipped = (originBar <= m_cfg.flipRecentBars);
     }

   //--- head and shoulders, wedges ------------------------------
   void              BuildPatterns(void)
     {
      m_pat.headShoulders    = false;
      m_pat.invHeadShoulders = false;
      m_pat.risingWedge      = false;
      m_pat.fallingWedge     = false;
      m_pat.neckline         = 0.0;
      m_pat.names            = "";

      double hi[6], lo[6];
      int    hiBar[6], loBar[6];
      int nh = 0, nl = 0;
      for(int i = 0; i < m_nSwings && (nh < 6 || nl < 6); i++)
        {
         if(m_swings[i].isHigh && nh < 6)
           {
            hi[nh] = m_swings[i].price; hiBar[nh] = m_swings[i].bar; nh++;
           }
         else if(!m_swings[i].isHigh && nl < 6)
           {
            lo[nl] = m_swings[i].price; loBar[nl] = m_swings[i].bar; nl++;
           }
        }

      double toler = MathMax(m_atr * m_cfg.patternToleranceAtr, _Point * 10.0);

      //--- H&S: hi[2] left shoulder, hi[1] head, hi[0] right shoulder
      if(nh >= 3 && nl >= 2)
        {
         bool headHighest = (hi[1] > hi[0] && hi[1] > hi[2]);
         bool shoulders   = (MathAbs(hi[0] - hi[2]) <= toler);
         if(headHighest && shoulders)
           {
            m_pat.headShoulders = true;
            m_pat.neckline      = MathMin(lo[0], lo[1]);
            m_pat.names        += "H&S ";
           }
        }

      //--- inverse H&S on the lows
      if(nl >= 3 && nh >= 2)
        {
         bool headLowest = (lo[1] < lo[0] && lo[1] < lo[2]);
         bool shoulders  = (MathAbs(lo[0] - lo[2]) <= toler);
         if(headLowest && shoulders)
           {
            m_pat.invHeadShoulders = true;
            m_pat.neckline         = MathMax(hi[0], hi[1]);
            m_pat.names           += "invH&S ";
           }
        }

      //--- wedges need two slopes to compare
      if(nh >= 2 && nl >= 2 && hiBar[1] > hiBar[0] && loBar[1] > loBar[0])
        {
         double slopeHi = (hi[0] - hi[1]) / (double)(hiBar[1] - hiBar[0]);
         double slopeLo = (lo[0] - lo[1]) / (double)(loBar[1] - loBar[0]);

         double widthNow  = hi[0] - lo[0];
         double widthPrev = hi[1] - lo[1];
         bool   narrowing = (widthNow < widthPrev && widthNow > 0.0);

         //--- rising wedge: both rising, lows rising faster, range closing
         if(slopeHi > 0.0 && slopeLo > 0.0 && slopeLo > slopeHi && narrowing)
           {
            m_pat.risingWedge = true;
            m_pat.names      += "risingWedge ";
           }

         //--- falling wedge: both falling, highs falling faster
         if(slopeHi < 0.0 && slopeLo < 0.0 && slopeHi < slopeLo && narrowing)
           {
            m_pat.fallingWedge = true;
            m_pat.names       += "fallingWedge ";
           }
        }

      if(m_pat.names == "")
         m_pat.names = "none";
     }

public:
                     CKMStructure(void)
     {
      m_symbol    = "";
      m_tf        = PERIOD_CURRENT;
      m_bars      = 0;
      m_nSwings   = 0;
      m_nLevels   = 0;
      m_atr       = 0.0;
      m_lastBar   = 0;
      m_valid     = false;
      m_lastIssue = "not refreshed yet";
      KM_DefaultStructureConfig(m_cfg);
      ArrayResize(m_swings, KM_MAX_SWINGS);
      ArrayResize(m_levels, KM_MAX_LEVELS);

      m_inside.found     = false;
      m_lineSup.valid    = false;
      m_lineRes.valid    = false;
      m_trend.valid      = false;
      m_trend.dir        = KM_DIR_NONE;
      m_trend.isFresh    = false;
      m_trend.nearCorner = false;
      m_trend.justFlipped = false;
      m_pat.names        = "none";
     }

   void              Init(const string sym, const ENUM_TIMEFRAMES tf)
     {
      m_symbol = sym;
      m_tf     = tf;
     }

   void              Config(const StructureConfig &c) { m_cfg = c; }

   string            LastIssue(void) const { return m_lastIssue; }
   bool              Valid(void)     const { return m_valid; }
   ENUM_TIMEFRAMES   Timeframe(void) const { return m_tf; }

   //+---------------------------------------------------------------+
   //| Recompute once per closed bar of m_tf                          |
   //+---------------------------------------------------------------+
   bool              Refresh(const double atr, const bool force = false)
     {
      datetime bt = (datetime)SeriesInfoInteger(m_symbol, m_tf, SERIES_LASTBAR_DATE);
      if(!force && bt == m_lastBar && m_valid)
         return true;

      m_valid = false;
      m_atr   = atr;

      if(!LoadSeries())
         return false;

      FindSwings();
      if(m_nSwings < 2)
        {
         m_lastIssue = StringFormat("only %d pivots found on %s",
                                    m_nSwings, EnumToString(m_tf));
         return false;
        }

      BuildLevels();
      FindInsideBar();
      BuildTrendline(true,  m_lineSup);
      BuildTrendline(false, m_lineRes);
      BuildTrendState();
      BuildPatterns();

      m_valid     = true;
      m_lastBar   = bt;
      m_lastIssue = "";
      return true;
     }

   //+---------------------------------------------------------------+
   //| Accessors                                                     |
   //+---------------------------------------------------------------+
   int               SwingCount(void) const { return m_nSwings; }

   bool              Swing(const int i, KMSwing &out) const
     {
      if(i < 0 || i >= m_nSwings)
         return false;
      out = m_swings[i];
      return true;
     }

   //--- the n-th most recent high / low pivot (0 = newest)
   bool              RecentPivot(const bool wantHigh, const int nth, KMSwing &out) const
     {
      int seen = 0;
      for(int i = 0; i < m_nSwings; i++)
        {
         if(m_swings[i].isHigh != wantHigh)
            continue;
         if(seen == nth)
           {
            out = m_swings[i];
            return true;
           }
         seen++;
        }
      return false;
     }

   void              InsideBar(KMInsideBar &out) const { out = m_inside; }
   void              Trend(KMTrendState &out)    const { out = m_trend; }
   void              Patterns(KMPatterns &out)   const { out = m_pat; }
   void              SupportLine(KMTrendline &out)    const { out = m_lineSup; }
   void              ResistanceLine(KMTrendline &out) const { out = m_lineRes; }

   int               LevelCount(void) const { return m_nLevels; }

   bool              Level(const int i, KMLevel &out) const
     {
      if(i < 0 || i >= m_nLevels)
         return false;
      out = m_levels[i];
      return true;
     }

   //--- strongest level within 'maxAtr' ATR of price, above or below
   bool              NearestLevel(const double price, const bool wantResistance,
                                  const double maxAtr, KMLevel &out) const
     {
      bool   got  = false;
      double best = -1.0;

      for(int i = 0; i < m_nLevels; i++)
        {
         if(m_levels[i].isResistance != wantResistance)
            continue;
         if(m_levels[i].touches < m_cfg.srMinTouches)
            continue;
         if(m_atr > 0.0 && MathAbs(m_levels[i].price - price) > m_atr * maxAtr)
            continue;
         if(m_levels[i].strength > best)
           {
            best = m_levels[i].strength;
            out  = m_levels[i];
            got  = true;
           }
        }
      return got;
     }

   //--- is price sitting on a level of either kind?
   bool              AtLevel(const double price, const double maxAtr, KMLevel &out) const
     {
      KMLevel r, s;
      bool hr = NearestLevel(price, true,  maxAtr, r);
      bool hs = NearestLevel(price, false, maxAtr, s);

      if(hr && hs)
        {
         out = (r.strength >= s.strength ? r : s);
         return true;
        }
      if(hr) { out = r; return true; }
      if(hs) { out = s; return true; }
      return false;
     }

   //+---------------------------------------------------------------+
   //| The gate behind "never join a trend that is already running".  |
   //|                                                               |
   //| An entry in 'dir' is allowed when the move that direction is    |
   //| joining is still young: either the structure flipped recently,  |
   //| price is still near the origin of the move, or maturity is      |
   //| under the fresh threshold. A deep pullback inside a young trend |
   //| also counts, since that is a corner rather than a middle.       |
   //+---------------------------------------------------------------+
   bool              EntryIsFresh(const ENUM_KM_DIR dir, const double minRetraceForPullback,
                                  string &why) const
     {
      why = "";

      if(!m_valid || !m_trend.valid)
        {
         why = "structure not ready";
         return false;
        }

      //--- no established trend at all: nothing to be late to
      if(m_trend.dir == KM_DIR_NONE)
        {
         why = "no established trend, entry is not late";
         return true;
        }

      //--- trading against the established trend is by definition not
      //--- joining it late; the reversal logic upstream governs that
      if(m_trend.dir != dir)
        {
         why = StringFormat("counter to the %s trend, not a late join",
                            (m_trend.dir == KM_DIR_BUY ? "up" : "down"));
         return true;
        }

      if(m_trend.justFlipped)
        {
         why = StringFormat("structure flipped %d bars ago", m_trend.originBar);
         return true;
        }

      if(m_trend.nearCorner)
        {
         why = StringFormat("still %.1f ATR from the origin", m_trend.extensionAtr);
         return true;
        }

      if(m_trend.isFresh)
        {
         why = StringFormat("maturity %.0f within fresh limit %.0f",
                            m_trend.maturity, m_cfg.freshMaturity);
         return true;
        }

      //--- a deep pullback re-creates a corner even in an older move
      if(m_trend.retracePct >= minRetraceForPullback)
        {
         why = StringFormat("deep %.0f%% pullback is a corner", m_trend.retracePct);
         return true;
        }

      why = StringFormat("mid-trend: maturity %.0f, %d legs, %.1f ATR extended, only %.0f%% pulled back",
                         m_trend.maturity, m_trend.legsCompleted,
                         m_trend.extensionAtr, m_trend.retracePct);
      return false;
     }

   //--- one line summary for panels
   string            Summary(void) const
     {
      if(!m_valid)
         return "structure: " + m_lastIssue;

      string s = StringFormat("trend %s mat %.0f legs %d ext %.1fatr ret %.0f%%%s%s",
                              (m_trend.dir == KM_DIR_BUY ? "UP" :
                               (m_trend.dir == KM_DIR_SELL ? "DOWN" : "RANGE")),
                              m_trend.maturity, m_trend.legsCompleted,
                              m_trend.extensionAtr, m_trend.retracePct,
                              (m_trend.isFresh ? " FRESH" : ""),
                              (m_trend.nearCorner ? " CORNER" : ""));
      if(m_inside.found)
         s += StringFormat(" | insideBar age %d%s", m_inside.ageBars,
                           (m_inside.atSwingHigh ? " atHigh" :
                            (m_inside.atSwingLow ? " atLow" : "")));
      if(m_pat.names != "none")
         s += " | " + m_pat.names;
      return s;
     }
  };

#endif // KRISHMIX_STRUCTURE_MQH
//+------------------------------------------------------------------+
