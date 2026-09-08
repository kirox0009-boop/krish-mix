//+------------------------------------------------------------------+
//|                                       KrishMix\Portfolio.mqh     |
//|                                                                  |
//|  Multi-asset accounting for the whole suite.                      |
//|                                                                  |
//|  Every other module looks at one symbol. This one scans the entire |
//|  book in a single pass and buckets it per symbol, which is what     |
//|  makes cross-asset recovery possible: to know that gold is stuck    |
//|  and that bitcoin and silver could pull it out, something has to    |
//|  hold both facts at once.                                          |
//|                                                                  |
//|  Two kinds of symbol are tracked:                                  |
//|    TRADABLE   configured in the watchlist - KM5 may open here      |
//|    DISCOVERED found holding suite positions but not configured -    |
//|               counted for accounting only, never traded            |
//|                                                                  |
//|  Without the discovered bucket a drawdown on a symbol missing from  |
//|  the list would be invisible to the very EA meant to rescue it.     |
//+------------------------------------------------------------------+
#ifndef KRISHMIX_PORTFOLIO_MQH
#define KRISHMIX_PORTFOLIO_MQH

#include <KrishMix\Common.mqh>
#include <Trade\PositionInfo.mqh>

//+------------------------------------------------------------------+
//| One symbol's slice of the book                                   |
//+------------------------------------------------------------------+
struct KMSymbolState
  {
   string           symbol;
   bool             tradable;      // configured, so KM5 may open here

   int              legs;
   int              buyLegs, sellLegs;
   double           lots;
   double           buyLots, sellLots;
   double           profit;        // floating incl swap, minus commission est
   double           drawdown;      // max(0, -profit)

   double           avgBuy, avgSell;
   datetime         firstOpen, lastOpen;

   bool             gridOpen;      // EA2 has started averaging here
   bool             hedgeOpen;     // EA3 rescue legs present

   //--- EA5's own legs. Entries and assists share magic slot 5, so these
   //--- count both; the per-direction split is what an entry cap needs.
   int              assistLegs;
   double           assistLots;
   int              km5BuyLegs, km5SellLegs;

   int              legsWithTp;    // legs still carrying their own TP

   ENUM_KM_DIR      losingSide;
  };

//+------------------------------------------------------------------+
//| The whole book                                                   |
//+------------------------------------------------------------------+
struct KMPortfolioTotals
  {
   int              symbolsHolding;   // symbols with at least one leg
   int              legs;
   double           lots;
   double           profit;
   double           drawdown;

   int              worstIdx;         // deepest drawdown, -1 when none
   double           worstDrawdown;

   int              assistLegs;
   double           assistLots;
   bool             anyGrid;
   bool             anyHedge;
   int              legsWithTp;
  };

void KM_ResetSymbolState(KMSymbolState &s)
  {
   s.legs       = 0;
   s.buyLegs    = 0;
   s.sellLegs   = 0;
   s.lots       = 0.0;
   s.buyLots    = 0.0;
   s.sellLots   = 0.0;
   s.profit     = 0.0;
   s.drawdown   = 0.0;
   s.avgBuy     = 0.0;
   s.avgSell    = 0.0;
   s.firstOpen  = 0;
   s.lastOpen   = 0;
   s.gridOpen   = false;
   s.hedgeOpen  = false;
   s.assistLegs  = 0;
   s.assistLots  = 0.0;
   s.km5BuyLegs  = 0;
   s.km5SellLegs = 0;
   s.legsWithTp  = 0;
   s.losingSide  = KM_DIR_NONE;
  }

void KM_ResetTotals(KMPortfolioTotals &t)
  {
   t.symbolsHolding = 0;
   t.legs           = 0;
   t.lots           = 0.0;
   t.profit         = 0.0;
   t.drawdown       = 0.0;
   t.worstIdx       = -1;
   t.worstDrawdown  = 0.0;
   t.assistLegs     = 0;
   t.assistLots     = 0.0;
   t.anyGrid        = false;
   t.anyHedge       = false;
   t.legsWithTp     = 0;
  }

//+------------------------------------------------------------------+
class CKMPortfolio
  {
private:
   long              m_base;
   double            m_commissionPerLot;

   KMSymbolState     m_state[KM_MAX_SYMBOLS];
   int               m_n;                       // symbols tracked
   KMPortfolioTotals m_tot;

   //--- running weighted sums, finalised after the scan
   double            m_wBuy[KM_MAX_SYMBOLS];
   double            m_wSell[KM_MAX_SYMBOLS];

   CPositionInfo     m_pos;

public:
                     CKMPortfolio(void)
     {
      m_base             = KM_MAGIC_BASE_DEFAULT;
      m_commissionPerLot = 0.0;
      m_n                = 0;
      KM_ResetTotals(m_tot);
     }

   void              Init(const long magicBase, const double commissionPerLotRT)
     {
      m_base             = magicBase;
      m_commissionPerLot = commissionPerLotRT;
     }

   //--- declare the tradable universe. Order is preserved, so callers can
   //--- keep their per-symbol engines in the same slots.
   void              SetSymbols(const string &syms[], const int n)
     {
      m_n = 0;
      for(int i = 0; i < n && i < KM_MAX_SYMBOLS; i++)
        {
         KM_ResetSymbolState(m_state[m_n]);
         m_state[m_n].symbol   = syms[i];
         m_state[m_n].tradable = true;
         m_n++;
        }
     }

   int               Count(void) const { return m_n; }

   bool              State(const int i, KMSymbolState &out) const
     {
      if(i < 0 || i >= m_n)
         return false;
      out = m_state[i];
      return true;
     }

   void              Totals(KMPortfolioTotals &out) const { out = m_tot; }

   int               IndexOf(const string sym) const
     {
      for(int i = 0; i < m_n; i++)
         if(m_state[i].symbol == sym)
            return i;
      return -1;
     }

   //--- add a symbol that is holding suite positions but is not in the
   //--- watchlist. Accounting only: tradable stays false.
   int               Discover(const string sym)
     {
      if(m_n >= KM_MAX_SYMBOLS)
         return -1;
      KM_ResetSymbolState(m_state[m_n]);
      m_state[m_n].symbol   = sym;
      m_state[m_n].tradable = false;
      m_n++;
      return m_n - 1;
     }

   //+---------------------------------------------------------------+
   //| One pass over every open position in the terminal.              |
   //+---------------------------------------------------------------+
   void              Scan(void)
     {
      for(int i = 0; i < m_n; i++)
        {
         bool tradable = m_state[i].tradable;
         string sym    = m_state[i].symbol;
         KM_ResetSymbolState(m_state[i]);
         m_state[i].symbol   = sym;
         m_state[i].tradable = tradable;
         m_wBuy[i]  = 0.0;
         m_wSell[i] = 0.0;
        }

      KM_ResetTotals(m_tot);

      for(int p = PositionsTotal() - 1; p >= 0; p--)
        {
         if(!m_pos.SelectByIndex(p))
            continue;

         long magic = m_pos.Magic();
         if(!KM_InFamily(m_base, magic))
            continue;

         string sym = m_pos.Symbol();
         int    idx = IndexOf(sym);
         if(idx < 0)
           {
            idx = Discover(sym);
            if(idx < 0)
               continue;                 // universe full, cannot track it
            m_wBuy[idx]  = 0.0;
            m_wSell[idx] = 0.0;
           }

         int    slot  = KM_EaSlotOf(m_base, magic);
         bool   isBuy = (m_pos.PositionType() == POSITION_TYPE_BUY);
         double lot   = m_pos.Volume();
         double price = m_pos.PriceOpen();
         double prof  = m_pos.Profit() + m_pos.Swap();

         m_state[idx].legs++;
         m_state[idx].lots   += lot;
         m_state[idx].profit += prof;

         if(isBuy)
           {
            m_state[idx].buyLegs++;
            m_state[idx].buyLots += lot;
            m_wBuy[idx] += price * lot;
           }
         else
           {
            m_state[idx].sellLegs++;
            m_state[idx].sellLots += lot;
            m_wSell[idx] += price * lot;
           }

         if(m_pos.TakeProfit() != 0.0)
            m_state[idx].legsWithTp++;

         if(slot == KM_EA_GRID)
            m_state[idx].gridOpen = true;
         else if(slot == KM_EA_HEDGE)
            m_state[idx].hedgeOpen = true;
         else if(slot == KM_EA_PORTFOLIO)
           {
            m_state[idx].assistLegs++;
            m_state[idx].assistLots += lot;
            if(isBuy)
               m_state[idx].km5BuyLegs++;
            else
               m_state[idx].km5SellLegs++;
           }

         datetime t = m_pos.Time();
         if(m_state[idx].firstOpen == 0 || t < m_state[idx].firstOpen)
            m_state[idx].firstOpen = t;
         if(t > m_state[idx].lastOpen)
            m_state[idx].lastOpen = t;
        }

      //--- finalise per symbol
      for(int i = 0; i < m_n; i++)
        {
         if(m_state[i].buyLots  > 0.0) m_state[i].avgBuy  = m_wBuy[i]  / m_state[i].buyLots;
         if(m_state[i].sellLots > 0.0) m_state[i].avgSell = m_wSell[i] / m_state[i].sellLots;

         if(m_commissionPerLot > 0.0)
            m_state[i].profit -= m_commissionPerLot * m_state[i].lots;

         m_state[i].drawdown = MathMax(0.0, -m_state[i].profit);

         //--- which side of THIS symbol is under water
         if(m_state[i].buyLegs > 0 && m_state[i].sellLegs == 0)
            m_state[i].losingSide = (m_state[i].profit < 0.0 ? KM_DIR_BUY : KM_DIR_NONE);
         else if(m_state[i].sellLegs > 0 && m_state[i].buyLegs == 0)
            m_state[i].losingSide = (m_state[i].profit < 0.0 ? KM_DIR_SELL : KM_DIR_NONE);
         else if(m_state[i].buyLegs > 0 && m_state[i].sellLegs > 0)
           {
            //--- both sides open: the bigger exposure is what hurts
            m_state[i].losingSide = (m_state[i].buyLots >= m_state[i].sellLots
                                     ? KM_DIR_BUY : KM_DIR_SELL);
           }

         if(m_state[i].legs == 0)
            continue;

         m_tot.symbolsHolding++;
         m_tot.legs       += m_state[i].legs;
         m_tot.lots       += m_state[i].lots;
         m_tot.profit     += m_state[i].profit;
         m_tot.assistLegs += m_state[i].assistLegs;
         m_tot.assistLots += m_state[i].assistLots;
         m_tot.legsWithTp += m_state[i].legsWithTp;

         if(m_state[i].gridOpen)  m_tot.anyGrid  = true;
         if(m_state[i].hedgeOpen) m_tot.anyHedge = true;

         if(m_state[i].drawdown > m_tot.worstDrawdown)
           {
            m_tot.worstDrawdown = m_state[i].drawdown;
            m_tot.worstIdx      = i;
           }
        }

      m_tot.drawdown = MathMax(0.0, -m_tot.profit);
     }

   //+---------------------------------------------------------------+
   //| Ticket collectors                                              |
   //+---------------------------------------------------------------+
   int               TicketsAll(ulong &out[])
     {
      ArrayResize(out, 0);
      int k = 0;

      for(int p = PositionsTotal() - 1; p >= 0; p--)
        {
         if(!m_pos.SelectByIndex(p))
            continue;
         if(!KM_InFamily(m_base, m_pos.Magic()))
            continue;
         ArrayResize(out, k + 1);
         out[k++] = m_pos.Ticket();
        }
      return k;
     }

   int               TicketsSymbol(const string sym, ulong &out[])
     {
      ArrayResize(out, 0);
      int k = 0;

      for(int p = PositionsTotal() - 1; p >= 0; p--)
        {
         if(!m_pos.SelectByIndex(p))
            continue;
         if(m_pos.Symbol() != sym)
            continue;
         if(!KM_InFamily(m_base, m_pos.Magic()))
            continue;
         ArrayResize(out, k + 1);
         out[k++] = m_pos.Ticket();
        }
      return k;
     }

   //--- only the cross-asset assist legs, on every symbol
   int               TicketsAssist(ulong &out[])
     {
      ArrayResize(out, 0);
      int k = 0;

      for(int p = PositionsTotal() - 1; p >= 0; p--)
        {
         if(!m_pos.SelectByIndex(p))
            continue;
         long magic = m_pos.Magic();
         if(!KM_InFamily(m_base, magic))
            continue;
         if(KM_EaSlotOf(m_base, magic) != KM_EA_PORTFOLIO)
            continue;
         ArrayResize(out, k + 1);
         out[k++] = m_pos.Ticket();
        }
      return k;
     }

   //+---------------------------------------------------------------+
   //| Same hand-off rule EA4 uses, applied to the whole book.        |
   //|                                                               |
   //| While nothing has gone wrong - no grid, no hedge, no assist,    |
   //| and every leg still carrying its own take profit - those        |
   //| entries are riding real targets and must not be swept up by a   |
   //| portfolio-level exit.                                           |
   //+---------------------------------------------------------------+
   bool              StillEntryTpPhase(void) const
     {
      if(m_tot.legs == 0)
         return false;
      if(m_tot.anyGrid || m_tot.anyHedge || m_tot.assistLegs > 0)
         return false;
      return (m_tot.legsWithTp == m_tot.legs);
     }

   //+---------------------------------------------------------------+
   //| Money an assist position would recover over 'horizonAtr' ATR.   |
   //|                                                               |
   //| Contract values differ by four orders of magnitude across the   |
   //| watchlist - gold moves $100 per lot per dollar, an index moves  |
   //| $1 per point - so the horizon has to be expressed in ATR and    |
   //| the conversion done per symbol.                                 |
   //+---------------------------------------------------------------+
   static double     AssistDelivers(const string sym, const double lots,
                                    const double atr, const double horizonAtr)
     {
      double travel = atr * horizonAtr;
      if(travel <= 0.0 || lots <= 0.0)
         return 0.0;
      return lots * travel * KM_MoneyPerPricePerLot(sym);
     }

   //--- volume needed on 'sym' to recover 'money' over the horizon
   static double     AssistLotsFor(const string sym, const double money,
                                   const double atr, const double horizonAtr)
     {
      double travel = atr * horizonAtr;
      double perLot = KM_MoneyPerPricePerLot(sym);
      if(travel <= 0.0 || perLot <= 0.0 || money <= 0.0)
         return 0.0;
      return money / (travel * perLot);
     }

   string            Summary(void) const
     {
      string cur = AccountInfoString(ACCOUNT_CURRENCY);
      string s = StringFormat("%d symbol(s) holding, %d legs, %.2f lots, %.2f %s",
                              m_tot.symbolsHolding, m_tot.legs, m_tot.lots,
                              m_tot.profit, cur);
      if(m_tot.worstIdx >= 0)
         s += StringFormat(" | worst %s -%.2f",
                           m_state[m_tot.worstIdx].symbol, m_tot.worstDrawdown);
      if(m_tot.assistLegs > 0)
         s += StringFormat(" | assist %d legs %.2f lots",
                           m_tot.assistLegs, m_tot.assistLots);
      return s;
     }
  };

#endif // KRISHMIX_PORTFOLIO_MQH
//+------------------------------------------------------------------+
