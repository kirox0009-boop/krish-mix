//+------------------------------------------------------------------+
//|                                       KrishMix\Execution.mqh     |
//|                                                                  |
//|  Order placing and closing, with the broker-side realities        |
//|  handled once: filling mode, retries on transient rejects,        |
//|  volume clamping and stop-level validation.                       |
//+------------------------------------------------------------------+
#ifndef KRISHMIX_EXECUTION_MQH
#define KRISHMIX_EXECUTION_MQH

#include <KrishMix\Common.mqh>
#include <Trade\Trade.mqh>

class CKMExec
  {
private:
   string            m_symbol;
   CTrade            m_trade;
   int               m_slippage;
   string            m_tag;
   string            m_lastError;

   bool              Transient(const uint rc) const
     {
      return (rc == TRADE_RETCODE_REQUOTE       ||
              rc == TRADE_RETCODE_PRICE_CHANGED ||
              rc == TRADE_RETCODE_PRICE_OFF     ||
              rc == TRADE_RETCODE_TIMEOUT       ||
              rc == TRADE_RETCODE_CONNECTION    ||
              rc == TRADE_RETCODE_TOO_MANY_REQUESTS);
     }

   bool              Accepted(const uint rc) const
     {
      return (rc == TRADE_RETCODE_DONE    ||
              rc == TRADE_RETCODE_PLACED  ||
              rc == TRADE_RETCODE_DONE_PARTIAL);
     }

public:
                     CKMExec(void)
     {
      m_symbol    = "";
      m_slippage  = 30;
      m_tag       = "KM";
      m_lastError = "";
     }

   void              Init(const string sym, const int slippagePoints, const string tag)
     {
      m_symbol   = sym;
      m_slippage = MathMax(1, slippagePoints);
      m_tag      = tag;

      m_trade.SetDeviationInPoints((ulong)m_slippage);
      m_trade.SetTypeFillingBySymbol(sym);
      m_trade.SetMarginMode();
     }

   string            LastError(void) const { return m_lastError; }

   //+---------------------------------------------------------------+
   //| Snap a take-profit to a level the server will accept.          |
   //| Returns 0.0 when no TP should be sent.                          |
   //+---------------------------------------------------------------+
   double            SanitizeTP(const bool isBuy, const double tp) const
     {
      if(tp <= 0.0)
         return 0.0;

      int    digits   = (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS);
      double point    = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      long   stopsLvl = SymbolInfoInteger(m_symbol, SYMBOL_TRADE_STOPS_LEVEL);
      double minDist  = (double)stopsLvl * point;

      double ask = KM_Ask(m_symbol);
      double bid = KM_Bid(m_symbol);
      double out = NormalizeDouble(tp, digits);

      if(isBuy)
        {
         double floorPrice = ask + minDist + point;
         if(out < floorPrice)
            out = NormalizeDouble(floorPrice, digits);
        }
      else
        {
         double capPrice = bid - minDist - point;
         if(out > capPrice)
            out = NormalizeDouble(capPrice, digits);
         if(out <= 0.0)
            return 0.0;
        }

      return out;
     }

   //+---------------------------------------------------------------+
   //| Open a market position.                                        |
   //|                                                                |
   //| No stop loss is ever sent - that is the design of this suite.   |
   //| A take profit is optional and validated against the broker's    |
   //| stop level before it goes out.                                  |
   //|                                                                |
   //| Volume is trimmed to what free margin can actually support:     |
   //| that is not a strategy limit, an unaffordable order is simply   |
   //| rejected by the server.                                         |
   //+---------------------------------------------------------------+
   bool              Open(const bool isBuy, double lot, const long magic,
                          const double tp, const string note, ulong &ticketOut)
     {
      ticketOut   = 0;
      m_lastError = "";

      if(lot <= 0.0)
        {
         m_lastError = "volume is zero";
         return false;
        }

      lot = KM_NormalizeLot(m_symbol, lot);

      double affordable = KM_MaxAffordableLot(m_symbol, isBuy, lot);
      if(affordable <= 0.0)
        {
         m_lastError = StringFormat("no free margin for %.2f lots (free %.2f)",
                                    lot, AccountInfoDouble(ACCOUNT_MARGIN_FREE));
         return false;
        }
      if(affordable < lot)
        {
         m_lastError = StringFormat("volume trimmed %.2f -> %.2f by free margin", lot, affordable);
         Print("KMExec: ", m_lastError);
         lot = affordable;
        }

      double useTp = SanitizeTP(isBuy, tp);
      string cmt   = m_tag + "|" + note;

      m_trade.SetExpertMagicNumber((ulong)magic);
      m_trade.SetDeviationInPoints((ulong)m_slippage);

      MqlTick tick;

      for(int attempt = 0; attempt < 3; attempt++)
        {
         SymbolInfoTick(m_symbol, tick);   // refresh rates before each try

         bool sent = isBuy
                     ? m_trade.Buy(lot, m_symbol, 0.0, 0.0, useTp, cmt)
                     : m_trade.Sell(lot, m_symbol, 0.0, 0.0, useTp, cmt);

         uint rc = m_trade.ResultRetcode();

         if(sent && Accepted(rc))
           {
            ticketOut = m_trade.ResultOrder();
            return true;
           }

         m_lastError = StringFormat("%s %.2f rejected: %u %s",
                                    (isBuy ? "BUY" : "SELL"), lot, rc,
                                    m_trade.ResultRetcodeDescription());

         //--- an invalid TP should not cost us the entry: resend naked
         if(rc == TRADE_RETCODE_INVALID_STOPS && useTp != 0.0)
           {
            Print("KMExec: TP rejected, resending without TP. ", m_lastError);
            useTp = 0.0;
            continue;
           }

         if(!Transient(rc))
            break;

         Sleep(200);
        }

      Print("KMExec: ", m_lastError);
      return false;
     }

   //+---------------------------------------------------------------+
   //| Close an explicit list of tickets, retrying what is left over.  |
   //| Returns the number still open when it gives up.                 |
   //+---------------------------------------------------------------+
   int               CloseTickets(const ulong &tickets[], const int passes = 4)
     {
      int n = ArraySize(tickets);
      if(n <= 0)
         return 0;

      for(int p = 0; p < passes; p++)
        {
         int remaining = 0;

         for(int i = 0; i < n; i++)
           {
            if(tickets[i] == 0)
               continue;
            if(!PositionSelectByTicket(tickets[i]))
               continue;      // already gone

            remaining++;

            long magic = PositionGetInteger(POSITION_MAGIC);
            m_trade.SetExpertMagicNumber((ulong)magic);

            if(!m_trade.PositionClose(tickets[i], (ulong)m_slippage))
               m_lastError = StringFormat("close #%I64u failed: %u %s",
                                          tickets[i], m_trade.ResultRetcode(),
                                          m_trade.ResultRetcodeDescription());
           }

         if(remaining == 0)
            return 0;

         Sleep(150);
        }

      //--- count what survived every pass
      int stillOpen = 0;
      for(int i = 0; i < n; i++)
         if(tickets[i] != 0 && PositionSelectByTicket(tickets[i]))
            stillOpen++;

      if(stillOpen > 0)
         Print("KMExec: ", stillOpen, " position(s) would not close. ", m_lastError);

      return stillOpen;
     }

   //+---------------------------------------------------------------+
   //| Replace the take profit on one ticket                          |
   //+---------------------------------------------------------------+
   bool              SetTP(const ulong ticket, const double tp)
     {
      if(!PositionSelectByTicket(ticket))
         return false;

      bool   isBuy = ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double useTp = SanitizeTP(isBuy, tp);
      double curTp = PositionGetDouble(POSITION_TP);
      int    digits = (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS);

      if(NormalizeDouble(curTp, digits) == NormalizeDouble(useTp, digits))
         return true;

      long magic = PositionGetInteger(POSITION_MAGIC);
      m_trade.SetExpertMagicNumber((ulong)magic);

      return m_trade.PositionModify(ticket, PositionGetDouble(POSITION_SL), useTp);
     }
  };

#endif // KRISHMIX_EXECUTION_MQH
//+------------------------------------------------------------------+
