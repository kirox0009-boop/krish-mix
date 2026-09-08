//+------------------------------------------------------------------+
//|                                       KrishMix\Positions.mqh     |
//|                                                                  |
//|  One scan of the book, then any aggregation the four EAs need:    |
//|                                                                  |
//|    per direction   every buy leg / every sell leg, whichever EA   |
//|                    opened it (this is the "basket")               |
//|    per EA slot     only EA1's legs, only EA2's legs, ...          |
//|    recovery group  a losing basket PLUS the EA3 recovery legs      |
//|                    that were opened to rescue it - the group that |
//|                    must be judged and closed together             |
//+------------------------------------------------------------------+
#ifndef KRISHMIX_POSITIONS_MQH
#define KRISHMIX_POSITIONS_MQH

#include <KrishMix\Common.mqh>
#include <Trade\PositionInfo.mqh>

//+------------------------------------------------------------------+
//| A single open position belonging to the suite                    |
//+------------------------------------------------------------------+
struct KMLeg
  {
   ulong            ticket;
   long             magic;
   int              slot;       // KM_EA_ENTRY / GRID / HEDGE
   bool             isBuy;
   double           lot;
   double           openPrice;
   double           tp;
   double           profit;     // floating money including swap
   datetime         openTime;
  };

//+------------------------------------------------------------------+
//| Aggregate of a set of legs                                       |
//+------------------------------------------------------------------+
struct KMAgg
  {
   int              count;
   double           lots;
   double           profit;
   double           minPrice;
   double           maxPrice;
   double           avgPrice;    // volume weighted
   datetime         firstOpen;
   datetime         lastOpen;
   int              buyCount;
   int              sellCount;
   double           buyLots;
   double           sellLots;
  };

void KM_ResetAgg(KMAgg &a)
  {
   a.count     = 0;
   a.lots      = 0.0;
   a.profit    = 0.0;
   a.minPrice  = 0.0;
   a.maxPrice  = 0.0;
   a.avgPrice  = 0.0;
   a.firstOpen = 0;
   a.lastOpen  = 0;
   a.buyCount  = 0;
   a.sellCount = 0;
   a.buyLots   = 0.0;
   a.sellLots  = 0.0;
  }

//+------------------------------------------------------------------+
//| Book                                                             |
//+------------------------------------------------------------------+
class CKMBook
  {
private:
   string            m_symbol;
   long              m_base;
   KMLeg             m_legs[];
   int               m_n;
   CPositionInfo     m_pos;
   double            m_commissionPerLot;

   void              Accumulate(const int i, KMAgg &a) const
     {
      a.count++;
      a.lots   += m_legs[i].lot;
      a.profit += m_legs[i].profit;

      if(m_legs[i].isBuy)
        {
         a.buyCount++;
         a.buyLots += m_legs[i].lot;
        }
      else
        {
         a.sellCount++;
         a.sellLots += m_legs[i].lot;
        }

      if(a.minPrice == 0.0 || m_legs[i].openPrice < a.minPrice)
         a.minPrice = m_legs[i].openPrice;
      if(m_legs[i].openPrice > a.maxPrice)
         a.maxPrice = m_legs[i].openPrice;

      if(a.firstOpen == 0 || m_legs[i].openTime < a.firstOpen)
         a.firstOpen = m_legs[i].openTime;
      if(m_legs[i].openTime > a.lastOpen)
         a.lastOpen = m_legs[i].openTime;

      a.avgPrice += m_legs[i].openPrice * m_legs[i].lot;   // finalised below
     }

   void              Finalise(KMAgg &a) const
     {
      if(a.lots > 0.0)
         a.avgPrice /= a.lots;
      else
         a.avgPrice = 0.0;

      //--- estimated round-turn commission makes every target honest
      if(m_commissionPerLot > 0.0)
         a.profit -= m_commissionPerLot * a.lots;
     }

public:
                     CKMBook(void)
     {
      m_symbol = "";
      m_base   = KM_MAGIC_BASE_DEFAULT;
      m_n      = 0;
      m_commissionPerLot = 0.0;
     }

   void              Init(const string sym, const long magicBase, const double commissionPerLotRT = 0.0)
     {
      m_symbol = sym;
      m_base   = magicBase;
      m_commissionPerLot = commissionPerLotRT;
     }

   int               Total(void) const { return m_n; }

   bool              Leg(const int i, KMLeg &out) const
     {
      if(i < 0 || i >= m_n)
         return false;
      out = m_legs[i];
      return true;
     }

   //+---------------------------------------------------------------+
   //| Refresh the whole snapshot. Call once per tick, then aggregate. |
   //+---------------------------------------------------------------+
   void              Scan(void)
     {
      m_n = 0;
      ArrayResize(m_legs, MathMax(8, PositionsTotal()));

      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         if(!m_pos.SelectByIndex(i))
            continue;
         if(m_pos.Symbol() != m_symbol)
            continue;

         long magic = m_pos.Magic();
         if(!KM_InFamily(m_base, magic))
            continue;

         if(m_n >= ArraySize(m_legs))
            ArrayResize(m_legs, m_n + 8);

         m_legs[m_n].ticket    = m_pos.Ticket();
         m_legs[m_n].magic     = magic;
         m_legs[m_n].slot      = KM_EaSlotOf(m_base, magic);
         m_legs[m_n].isBuy     = (m_pos.PositionType() == POSITION_TYPE_BUY);
         m_legs[m_n].lot       = m_pos.Volume();
         m_legs[m_n].openPrice = m_pos.PriceOpen();
         m_legs[m_n].tp        = m_pos.TakeProfit();
         m_legs[m_n].profit    = m_pos.Profit() + m_pos.Swap();
         m_legs[m_n].openTime  = m_pos.Time();
         m_n++;
        }
     }

   //+---------------------------------------------------------------+
   //| Direction basket: every leg of one side, any EA                |
   //+---------------------------------------------------------------+
   void              AggDirection(const bool isBuy, KMAgg &a) const
     {
      KM_ResetAgg(a);
      for(int i = 0; i < m_n; i++)
         if(m_legs[i].isBuy == isBuy)
            Accumulate(i, a);
      Finalise(a);
     }

   //+---------------------------------------------------------------+
   //| One EA's own legs on one side                                  |
   //+---------------------------------------------------------------+
   void              AggSlot(const int slot, const bool isBuy, KMAgg &a) const
     {
      KM_ResetAgg(a);
      for(int i = 0; i < m_n; i++)
         if(m_legs[i].slot == slot && m_legs[i].isBuy == isBuy)
            Accumulate(i, a);
      Finalise(a);
     }

   //+---------------------------------------------------------------+
   //| Everything the suite holds on this symbol                      |
   //+---------------------------------------------------------------+
   void              AggAll(KMAgg &a) const
     {
      KM_ResetAgg(a);
      for(int i = 0; i < m_n; i++)
         Accumulate(i, a);
      Finalise(a);
     }

   //+---------------------------------------------------------------+
   //| Recovery group.                                                |
   //|                                                                |
   //| 'losingDir' is the side that is under water. The group is that  |
   //| whole basket PLUS the EA3 recovery legs opened in the opposite  |
   //| direction to rescue it. Judging these together is the point of  |
   //| the hedge: the rescue leg's gain is what lifts the group to     |
   //| break-even and beyond.                                          |
   //+---------------------------------------------------------------+
   void              AggRecoveryGroup(const ENUM_KM_DIR losingDir, KMAgg &a) const
     {
      KM_ResetAgg(a);
      if(losingDir == KM_DIR_NONE)
        {
         Finalise(a);
         return;
        }

      bool losingIsBuy = (losingDir == KM_DIR_BUY);

      for(int i = 0; i < m_n; i++)
        {
         bool inGroup = false;

         if(m_legs[i].isBuy == losingIsBuy)
            inGroup = true;                     // the drowning basket, any EA
         else if(m_legs[i].slot == KM_EA_HEDGE)
            inGroup = true;                     // rescue legs, which run opposite

         if(inGroup)
            Accumulate(i, a);
        }

      Finalise(a);
     }

   //+---------------------------------------------------------------+
   //| Ticket collectors for the closing routines                     |
   //+---------------------------------------------------------------+
   int               TicketsDirection(const bool isBuy, ulong &out[]) const
     {
      ArrayResize(out, 0);
      int k = 0;
      for(int i = 0; i < m_n; i++)
         if(m_legs[i].isBuy == isBuy)
           {
            ArrayResize(out, k + 1);
            out[k++] = m_legs[i].ticket;
           }
      return k;
     }

   int               TicketsSlot(const int slot, const bool isBuy, ulong &out[]) const
     {
      ArrayResize(out, 0);
      int k = 0;
      for(int i = 0; i < m_n; i++)
         if(m_legs[i].slot == slot && m_legs[i].isBuy == isBuy)
           {
            ArrayResize(out, k + 1);
            out[k++] = m_legs[i].ticket;
           }
      return k;
     }

   int               TicketsRecoveryGroup(const ENUM_KM_DIR losingDir, ulong &out[]) const
     {
      ArrayResize(out, 0);
      if(losingDir == KM_DIR_NONE)
         return 0;

      bool losingIsBuy = (losingDir == KM_DIR_BUY);
      int k = 0;

      for(int i = 0; i < m_n; i++)
        {
         bool inGroup = (m_legs[i].isBuy == losingIsBuy) || (m_legs[i].slot == KM_EA_HEDGE);
         if(inGroup)
           {
            ArrayResize(out, k + 1);
            out[k++] = m_legs[i].ticket;
           }
        }
      return k;
     }

   int               TicketsAll(ulong &out[]) const
     {
      ArrayResize(out, m_n);
      for(int i = 0; i < m_n; i++)
         out[i] = m_legs[i].ticket;
      return m_n;
     }

   //+---------------------------------------------------------------+
   //| Helpers used by the decision logic                             |
   //+---------------------------------------------------------------+

   //--- does this direction hold EA3 rescue legs? when it does, the
   //--- direction must not be closed on its own: it belongs to a group
   bool              HasHedgeLegs(const bool isBuy) const
     {
      for(int i = 0; i < m_n; i++)
         if(m_legs[i].slot == KM_EA_HEDGE && m_legs[i].isBuy == isBuy)
            return true;
      return false;
     }

   //--- has EA2 started averaging this side yet? Until it has, the entry
   //--- is still a plain single trade riding its own take profit and the
   //--- basket manager has no business closing it.
   bool              GridOpen(const bool isBuy) const
     {
      for(int i = 0; i < m_n; i++)
         if(m_legs[i].slot == KM_EA_GRID && m_legs[i].isBuy == isBuy)
            return true;
      return false;
     }

   bool              AnyGridLegs(void) const
     {
      for(int i = 0; i < m_n; i++)
         if(m_legs[i].slot == KM_EA_GRID)
            return true;
      return false;
     }

   //--- legs on one side that still carry a broker-side take profit
   int               CountWithTP(const bool isBuy) const
     {
      int k = 0;
      for(int i = 0; i < m_n; i++)
         if(m_legs[i].isBuy == isBuy && m_legs[i].tp != 0.0)
            k++;
      return k;
     }

   int               CountWithTPAll(void) const
     {
      int k = 0;
      for(int i = 0; i < m_n; i++)
         if(m_legs[i].tp != 0.0)
            k++;
      return k;
     }

   int               CountSlot(const int slot, const bool isBuy) const
     {
      int k = 0;
      for(int i = 0; i < m_n; i++)
         if(m_legs[i].slot == slot && m_legs[i].isBuy == isBuy)
            k++;
      return k;
     }

   //--- how far price has run against a basket, in price units
   double            AdverseExcursion(const bool isBuy, const double bid, const double ask) const
     {
      KMAgg a;
      AggDirection(isBuy, a);
      if(a.count == 0)
         return 0.0;

      if(isBuy)
         return MathMax(0.0, a.avgPrice - bid);
      return MathMax(0.0, ask - a.avgPrice);
     }

   //--- the worst-priced leg, i.e. the edge the next grid step measures from
   double            GridAnchor(const bool isBuy) const
     {
      KMAgg a;
      AggDirection(isBuy, a);
      if(a.count == 0)
         return 0.0;
      return (isBuy ? a.minPrice : a.maxPrice);
     }

   //--- which side is currently the loser, by money
   ENUM_KM_DIR       LosingSide(void) const
     {
      KMAgg b, s;
      AggDirection(true, b);
      AggDirection(false, s);

      if(b.count == 0 && s.count == 0)
         return KM_DIR_NONE;
      if(b.count == 0)
         return (s.profit < 0.0 ? KM_DIR_SELL : KM_DIR_NONE);
      if(s.count == 0)
         return (b.profit < 0.0 ? KM_DIR_BUY : KM_DIR_NONE);

      if(b.profit >= 0.0 && s.profit >= 0.0)
         return KM_DIR_NONE;

      return (b.profit < s.profit ? KM_DIR_BUY : KM_DIR_SELL);
     }
  };

#endif // KRISHMIX_POSITIONS_MQH
//+------------------------------------------------------------------+
