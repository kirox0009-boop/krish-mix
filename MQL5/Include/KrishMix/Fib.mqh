//+------------------------------------------------------------------+
//|                                             KrishMix\Fib.mqh     |
//|                                                                  |
//|  TREND-BASED Fibonacci, not a plain retracement.                  |
//|                                                                  |
//|  A plain retracement needs two points and tells you where a       |
//|  pullback might end. A trend-based extension needs THREE and tells |
//|  you where the NEXT leg is likely to terminate - which is where a   |
//|  move runs out and reverses. Those terminations are the levels      |
//|  this module produces.                                             |
//|                                                                  |
//|      A   the swing that started the impulse                        |
//|      B   the swing that ended it        (A -> B is the impulse)     |
//|      C   the swing that ended the pullback                         |
//|                                                                  |
//|      level(r) = C + (B - A) * r     for r in {0.618, 1.0, 1.618}   |
//|                                                                  |
//|  Exactly three levels, and the trade taken at them runs AGAINST    |
//|  the impulse: a down impulse projects three levels below C, price   |
//|  falls into one of them and turns back up, so those are BUY        |
//|  reversal levels. An up impulse mirrors it.                        |
//|                                                                  |
//|  Pivots come from CKMStructure, so this module adds no indicator   |
//|  handles and stays consistent with the rest of the suite.          |
//+------------------------------------------------------------------+
#ifndef KRISHMIX_FIB_MQH
#define KRISHMIX_FIB_MQH

#include <KrishMix\Common.mqh>
#include <KrishMix\Structure.mqh>

#define KM_FIB_LEVELS 3

//+------------------------------------------------------------------+
//| One resolved setup                                                |
//+------------------------------------------------------------------+
struct KMFibSetup
  {
   bool             valid;
   string           reason;        // why it is or is not valid

   //--- anchors, A oldest through C newest
   double           priceA, priceB, priceC;
   int              barA, barB, barC;
   bool             impulseUp;     // true when A -> B travelled up

   //--- the three projected reversal levels, nearest to price first
   double           level[KM_FIB_LEVELS];
   double           ratio[KM_FIB_LEVELS];

   ENUM_KM_DIR      reversalDir;   // direction of a trade taken at a level
   double           impulseSize;   // |B - A| in price

   //--- live state
   int              nearestIdx;    // which level price is closest to
   double           nearestPrice;
   double           nearestDist;   // absolute distance in price
   bool             atLevel;       // inside the tolerance band of a level
   bool             reachedDeepest;// price is past the 1.618 projection
  };

void KM_ResetFibSetup(KMFibSetup &f)
  {
   f.valid          = false;
   f.reason         = "not built";
   f.priceA         = 0.0;
   f.priceB         = 0.0;
   f.priceC         = 0.0;
   f.barA           = 0;
   f.barB           = 0;
   f.barC           = 0;
   f.impulseUp      = false;
   f.reversalDir    = KM_DIR_NONE;
   f.impulseSize    = 0.0;
   f.nearestIdx     = -1;
   f.nearestPrice   = 0.0;
   f.nearestDist    = 0.0;
   f.atLevel        = false;
   f.reachedDeepest = false;

   for(int i = 0; i < KM_FIB_LEVELS; i++)
     {
      f.level[i] = 0.0;
      f.ratio[i] = 0.0;
     }
  }

//+------------------------------------------------------------------+
//| Tunables                                                         |
//+------------------------------------------------------------------+
struct FibConfig
  {
   double           r1, r2, r3;        // the three extension ratios
   double           minImpulseAtr;     // ignore noise-sized impulses
   double           maxRetracePct;     // C may not retrace more than this of A->B
   double           minRetracePct;     // ... nor less than this
   double           levelTolerAtr;     // how close counts as "at the level"
   int              maxSetupAgeBars;   // ignore a stale C
  };

void KM_DefaultFibConfig(FibConfig &c)
  {
   c.r1              = 0.618;
   c.r2              = 1.000;
   c.r3              = 1.618;
   c.minImpulseAtr   = 2.0;
   c.maxRetracePct   = 90.0;
   c.minRetracePct   = 20.0;
   c.levelTolerAtr   = 0.50;
   c.maxSetupAgeBars = 60;
  }

//+------------------------------------------------------------------+
//| Builder                                                          |
//+------------------------------------------------------------------+
class CKMFib
  {
private:
   FibConfig         m_cfg;
   KMFibSetup        m_setup;

public:
                     CKMFib(void)
     {
      KM_DefaultFibConfig(m_cfg);
      KM_ResetFibSetup(m_setup);
     }

   void              Config(const FibConfig &c) { m_cfg = c; }
   void              Setup(KMFibSetup &out) const { out = m_setup; }
   string            Reason(void) const { return m_setup.reason; }

   //+---------------------------------------------------------------+
   //| Resolve A, B, C from the three most recent alternating pivots  |
   //| and project the levels. 'price' is the live price used to work |
   //| out which level is in play.                                    |
   //+---------------------------------------------------------------+
   bool              Build(const CKMStructure &st, const double atr, const double price)
     {
      KM_ResetFibSetup(m_setup);

      if(atr <= 0.0)
        {
         m_setup.reason = "no ATR";
         return false;
        }
      if(!st.Valid())
        {
         m_setup.reason = "structure not ready";
         return false;
        }

      //--- C is the newest pivot; B is the next pivot of the opposite
      //--- kind; A is the next one of C's kind. That is one impulse plus
      //--- one pullback, which is exactly what the projection needs.
      KMSwing c, b, a;
      //--- zeroed up front. b and a are only filled inside the search loop
      //--- below, so without this the compiler cannot prove they are
      //--- initialised by the time the projection reads them.
      ZeroMemory(c);
      ZeroMemory(b);
      ZeroMemory(a);

      if(!st.Swing(0, c))
        {
         m_setup.reason = "no pivots";
         return false;
        }

      bool gotB = false, gotA = false;
      int  total = st.SwingCount();

      for(int i = 1; i < total; i++)
        {
         KMSwing s;
         if(!st.Swing(i, s))
            break;

         if(!gotB)
           {
            if(s.isHigh != c.isHigh)
              {
               b = s;
               gotB = true;
              }
           }
         else if(!gotA)
           {
            if(s.isHigh == c.isHigh)
              {
               a = s;
               gotA = true;
               break;
              }
           }
        }

      if(!gotB || !gotA)
        {
         m_setup.reason = "need three alternating pivots";
         return false;
        }

      if(c.bar > m_cfg.maxSetupAgeBars)
        {
         m_setup.reason = StringFormat("setup is stale, C is %d bars old", c.bar);
         return false;
        }

      //--- A -> B is the impulse. A and C are the same kind of pivot, so
      //--- B sits between them and the geometry is guaranteed.
      double impulse = b.price - a.price;
      m_setup.impulseSize = MathAbs(impulse);

      if(m_setup.impulseSize < atr * m_cfg.minImpulseAtr)
        {
         m_setup.reason = StringFormat("impulse %.2f is under %.1f ATR",
                                       m_setup.impulseSize, m_cfg.minImpulseAtr);
         return false;
        }

      m_setup.impulseUp = (impulse > 0.0);

      //--- C has to be a real pullback of A->B, not a fresh extreme
      double retrace = MathAbs(b.price - c.price) / m_setup.impulseSize * 100.0;
      if(retrace < m_cfg.minRetracePct || retrace > m_cfg.maxRetracePct)
        {
         m_setup.reason = StringFormat("C retraces %.0f%%, outside %.0f-%.0f%%",
                                       retrace, m_cfg.minRetracePct, m_cfg.maxRetracePct);
         return false;
        }

      //--- and it must sit on the correct side of B
      if(m_setup.impulseUp && c.price >= b.price)
        {
         m_setup.reason = "C is not below B on an up impulse";
         return false;
        }
      if(!m_setup.impulseUp && c.price <= b.price)
        {
         m_setup.reason = "C is not above B on a down impulse";
         return false;
        }

      m_setup.priceA = a.price;  m_setup.barA = a.bar;
      m_setup.priceB = b.price;  m_setup.barB = b.bar;
      m_setup.priceC = c.price;  m_setup.barC = c.bar;

      //--- project from C. An up impulse throws the levels above C, a
      //--- down impulse below it.
      m_setup.ratio[0] = m_cfg.r1;
      m_setup.ratio[1] = m_cfg.r2;
      m_setup.ratio[2] = m_cfg.r3;

      for(int i = 0; i < KM_FIB_LEVELS; i++)
         m_setup.level[i] = c.price + impulse * m_setup.ratio[i];

      //--- the trade at a termination level runs against the impulse
      m_setup.reversalDir = (m_setup.impulseUp ? KM_DIR_SELL : KM_DIR_BUY);

      //--- which level is price actually working on?
      double toler = atr * m_cfg.levelTolerAtr;
      double best  = -1.0;

      for(int i = 0; i < KM_FIB_LEVELS; i++)
        {
         double d = MathAbs(price - m_setup.level[i]);
         if(best < 0.0 || d < best)
           {
            best                 = d;
            m_setup.nearestIdx   = i;
            m_setup.nearestPrice = m_setup.level[i];
            m_setup.nearestDist  = d;
           }
        }

      m_setup.atLevel = (best >= 0.0 && best <= toler);

      //--- past the deepest projection the idea has failed rather than
      //--- triggered, so callers can stand aside
      double deepest = m_setup.level[KM_FIB_LEVELS - 1];
      m_setup.reachedDeepest = (m_setup.impulseUp ? (price > deepest) : (price < deepest));

      m_setup.valid  = true;
      m_setup.reason = StringFormat("%s impulse %.2f, C retraced %.0f%%, levels %.*f / %.*f / %.*f",
                                    (m_setup.impulseUp ? "up" : "down"),
                                    m_setup.impulseSize, retrace,
                                    _Digits, m_setup.level[0],
                                    _Digits, m_setup.level[1],
                                    _Digits, m_setup.level[2]);
      return true;
     }

   //+---------------------------------------------------------------+
   //| Is a reversal trade in 'dir' justified right now?              |
   //|                                                               |
   //| Price must be sitting on one of the three projections, the     |
   //| direction must match the counter-impulse side, and price must   |
   //| not already have blown through the deepest level.               |
   //+---------------------------------------------------------------+
   bool              ReversalSignal(const ENUM_KM_DIR dir, string &why) const
     {
      why = "";

      if(!m_setup.valid)
        {
         why = m_setup.reason;
         return false;
        }
      if(m_setup.reversalDir != dir)
        {
         why = StringFormat("levels point %s, not %s",
                            (m_setup.reversalDir == KM_DIR_BUY ? "long" : "short"),
                            (dir == KM_DIR_BUY ? "long" : "short"));
         return false;
        }
      if(m_setup.reachedDeepest)
        {
         why = "price is beyond the 1.618 projection, setup failed";
         return false;
        }
      if(!m_setup.atLevel)
        {
         why = StringFormat("%.*f away from the %.3f level",
                            _Digits, m_setup.nearestDist,
                            (m_setup.nearestIdx >= 0 ? m_setup.ratio[m_setup.nearestIdx] : 0.0));
         return false;
        }

      why = StringFormat("at the %.3f projection (%.*f)",
                         m_setup.ratio[m_setup.nearestIdx],
                         _Digits, m_setup.nearestPrice);
      return true;
     }

   //--- a 1:3 style target measured back toward C
   double           TargetFor(const ENUM_KM_DIR dir, const double rr) const
     {
      if(!m_setup.valid || m_setup.nearestIdx < 0)
         return 0.0;

      //--- risk proxy: the tolerance band around the level, scaled by RR
      double span = MathAbs(m_setup.nearestPrice - m_setup.priceC);
      if(span <= 0.0)
         return 0.0;

      double reach = span * MathMax(0.1, rr) / 3.0;
      return (dir == KM_DIR_BUY ? m_setup.nearestPrice + reach
              : m_setup.nearestPrice - reach);
     }

   string            Summary(void) const
     {
      if(!m_setup.valid)
         return "fib: " + m_setup.reason;

      return StringFormat("fib %s -> %s levels%s, nearest %.3f at %.*f (%.*f away)",
                          (m_setup.impulseUp ? "up" : "down"),
                          (m_setup.reversalDir == KM_DIR_BUY ? "BUY" : "SELL"),
                          (m_setup.atLevel ? " AT LEVEL" : ""),
                          (m_setup.nearestIdx >= 0 ? m_setup.ratio[m_setup.nearestIdx] : 0.0),
                          _Digits, m_setup.nearestPrice,
                          _Digits, m_setup.nearestDist);
     }
  };

#endif // KRISHMIX_FIB_MQH
//+------------------------------------------------------------------+
