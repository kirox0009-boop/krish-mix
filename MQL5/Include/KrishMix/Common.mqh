//+------------------------------------------------------------------+
//|                                       KrishMix\Common.mqh        |
//|                                                                  |
//|  Shared types, magic-number layout and symbol maths for the       |
//|  four-EA KrishMix suite.                                          |
//+------------------------------------------------------------------+
#ifndef KRISHMIX_COMMON_MQH
#define KRISHMIX_COMMON_MQH

//--- suite version, printed by every EA on start
#define KM_VERSION "1.00"

//--- EA slot ids inside the magic-number family
#define KM_EA_ENTRY     1   // EA1 - pinpoint entry
#define KM_EA_GRID      2   // EA2 - grid / averaging brain
#define KM_EA_HEDGE     3   // EA3 - recovery hedge
#define KM_EA_BASKET    4   // EA4 - basket take profit manager
#define KM_EA_PORTFOLIO 5   // EA5 - multi-asset recovery and portfolio exit
#define KM_EA_TFSELECT  6   // EA6 - timeframe selector (places no orders)

#define KM_EA_FIRST     1
#define KM_EA_LAST      6

//+------------------------------------------------------------------+
//| Enumerations                                                     |
//+------------------------------------------------------------------+
enum ENUM_KM_REGIME
  {
   KM_REGIME_RANGE        = 0, // Ranging / no clear trend
   KM_REGIME_TREND_UP     = 1, // Established uptrend
   KM_REGIME_TREND_DOWN   = 2, // Established downtrend
   KM_REGIME_BREAKOUT_UP  = 3, // Expansion breaking up
   KM_REGIME_BREAKOUT_DN  = 4  // Expansion breaking down
  };

enum ENUM_KM_VOL
  {
   KM_VOL_LOW     = 0, // Compressed
   KM_VOL_NORMAL  = 1, // Normal
   KM_VOL_HIGH    = 2, // Elevated
   KM_VOL_EXTREME = 3  // Extreme - news / spike
  };

enum ENUM_KM_DIR
  {
   KM_DIR_SELL = -1, // Short
   KM_DIR_NONE =  0, // Flat / no bias
   KM_DIR_BUY  =  1  // Long
  };

//--- Trading style, which is what decides the working timeframe.
//--- Published by KM6 and read by the entry logic.
enum ENUM_KM_STYLE
  {
   KM_STYLE_SCALP    = 0, // Scalping    - M1 / M3 / M5
   KM_STYLE_INTRADAY = 1, // Intraday    - M5 / M15
   KM_STYLE_SWING    = 2  // Swing       - H1 / H4
  };

string KM_StyleName(const ENUM_KM_STYLE s)
  {
   switch(s)
     {
      case KM_STYLE_SCALP:    return "SCALP";
      case KM_STYLE_INTRADAY: return "INTRADAY";
      case KM_STYLE_SWING:    return "SWING";
     }
   return "?";
  }

//--- Higher timeframe verdict for the top-down playbook
enum ENUM_KM_HTFBIAS
  {
   KM_HTF_CONSOLIDATING = 0, // Ranging / no directional edge
   KM_HTF_UP            = 1, // Uptrend
   KM_HTF_DOWN          = 2  // Downtrend
  };

string KM_HtfName(const ENUM_KM_HTFBIAS b)
  {
   switch(b)
     {
      case KM_HTF_UP:   return "UPTREND";
      case KM_HTF_DOWN: return "DOWNTREND";
     }
   return "CONSOLIDATING";
  }

//+------------------------------------------------------------------+
//| Magic number layout                                              |
//|                                                                  |
//|  All four EAs share ONE base number. Every order the suite ever   |
//|  places lives in [base+1 .. base+99], which lets any EA recognise |
//|  the whole family while still knowing exactly which EA and which  |
//|  direction a position came from.                                  |
//|                                                                  |
//|    magic = base + eaSlot*10 + (buy ? 1 : 2)                       |
//|                                                                  |
//|  e.g. base 51000 ->  51011 EA1 buy   51012 EA1 sell               |
//|                      51021 EA2 buy   51022 EA2 sell               |
//|                      51031 EA3 buy   51032 EA3 sell               |
//|                                                                  |
//|  KEEP InpMagicBase IDENTICAL IN ALL FOUR EAs.                     |
//+------------------------------------------------------------------+
#define KM_MAGIC_BASE_DEFAULT 51000

long KM_Magic(const long base, const int eaSlot, const bool isBuy)
  {
   return base + eaSlot * 10 + (isBuy ? 1 : 2);
  }

bool KM_InFamily(const long base, const long magic)
  {
   return (magic > base && magic <= base + 99);
  }

int KM_EaSlotOf(const long base, const long magic)
  {
   if(!KM_InFamily(base, magic))
      return -1;
   return (int)((magic - base) / 10);
  }

bool KM_IsBuyMagic(const long base, const long magic)
  {
   if(!KM_InFamily(base, magic))
      return false;
   return (((magic - base) % 10) == 1);
  }

string KM_EaSlotName(const int slot)
  {
   switch(slot)
     {
      case KM_EA_ENTRY:     return "E1-Entry";
      case KM_EA_GRID:      return "E2-Grid";
      case KM_EA_HEDGE:     return "E3-Hedge";
      case KM_EA_BASKET:    return "E4-Basket";
      case KM_EA_PORTFOLIO: return "E5-Portfolio";
      case KM_EA_TFSELECT:  return "E6-TfSelect";
     }
   return "unknown";
  }

//+------------------------------------------------------------------+
//| Symbol maths                                                     |
//+------------------------------------------------------------------+

//--- money earned per 1.00 lot for every 1.0 of PRICE movement.
//--- For gold (100 oz contract, tick 0.01 worth $1) this returns 100.
double KM_MoneyPerPricePerLot(const string sym)
  {
   double tickValue = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);

   if(tickSize > 0.0 && tickValue > 0.0)
      return tickValue / tickSize;

//--- fallback: contract size (works for most CFD / metal feeds)
   double contract = SymbolInfoDouble(sym, SYMBOL_TRADE_CONTRACT_SIZE);
   return (contract > 0.0 ? contract : 1.0);
  }

//--- how many lots are needed to earn 'money' over a 'priceMove'
double KM_LotsForMoney(const string sym, const double money, const double priceMove)
  {
   if(priceMove <= 0.0)
      return 0.0;
   double perLot = KM_MoneyPerPricePerLot(sym) * priceMove;
   if(perLot <= 0.0)
      return 0.0;
   return money / perLot;
  }

int KM_VolumeDigits(const string sym)
  {
   double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   if(step <= 0.0)
      step = 0.01;

   int d = 0;
   double t = step;
   while(t < 1.0 - 1e-9 && d < 8)
     {
      t *= 10.0;
      d++;
     }
   return d;
  }

double KM_NormalizeLot(const string sym, double lot)
  {
   double minLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);

   if(step <= 0.0)
      step = 0.01;

   lot = MathFloor(lot / step + 0.5) * step;

   if(lot < minLot)
      lot = minLot;
   if(maxLot > 0.0 && lot > maxLot)
      lot = maxLot;

   return NormalizeDouble(lot, KM_VolumeDigits(sym));
  }

double KM_SpreadPoints(const string sym)
  {
   return (double)SymbolInfoInteger(sym, SYMBOL_SPREAD);
  }

double KM_Ask(const string sym)
  {
   return SymbolInfoDouble(sym, SYMBOL_ASK);
  }

double KM_Bid(const string sym)
  {
   return SymbolInfoDouble(sym, SYMBOL_BID);
  }

//+------------------------------------------------------------------+
//| Free margin the terminal reports for a hypothetical order.        |
//| This is a broker reality check, not a strategy limitation: an     |
//| order without margin is simply rejected by the server.            |
//+------------------------------------------------------------------+
bool KM_HasMarginFor(const string sym, const bool isBuy, const double lot, double &needed)
  {
   needed = 0.0;
   ENUM_ORDER_TYPE type = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double price = isBuy ? KM_Ask(sym) : KM_Bid(sym);

   if(price <= 0.0 || lot <= 0.0)
      return false;

   if(!OrderCalcMargin(type, sym, lot, price, needed))
      return true;   // cannot tell - let the server decide

   return (needed <= AccountInfoDouble(ACCOUNT_MARGIN_FREE));
  }

//--- largest lot the current free margin can still afford
double KM_MaxAffordableLot(const string sym, const bool isBuy, const double wanted)
  {
   double need = 0.0;
   if(KM_HasMarginFor(sym, isBuy, wanted, need))
      return wanted;

   double free = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(need <= 0.0 || free <= 0.0)
      return 0.0;

//--- margin is linear in volume, so scale down and keep a 5% cushion
   double scaled = wanted * (free / need) * 0.95;
   double lot    = KM_NormalizeLot(sym, scaled);

   if(!KM_HasMarginFor(sym, isBuy, lot, need))
      return 0.0;

   return lot;
  }

//+------------------------------------------------------------------+
//| Multi-symbol helpers                                             |
//|                                                                  |
//| Brokers name the same instrument a dozen different ways: XAUUSD,  |
//| XAUUSD.a, XAUUSDm, GOLD, US100 versus USTEC versus NAS100. A      |
//| configured list therefore has to be RESOLVED against what this    |
//| particular broker actually offers before it can be traded.        |
//+------------------------------------------------------------------+
#define KM_MAX_SYMBOLS 16

//--- split a comma separated list, trimmed, into out[]
int KM_ParseSymbolList(const string csv, string &out[])
  {
   ArrayResize(out, 0);

   string parts[];
   int n = StringSplit(csv, ',', parts);
   if(n <= 0)
      return 0;

   int k = 0;
   for(int i = 0; i < n && k < KM_MAX_SYMBOLS; i++)
     {
      string s = parts[i];
      StringTrimLeft(s);
      StringTrimRight(s);
      if(StringLen(s) == 0)
         continue;
      ArrayResize(out, k + 1);
      out[k++] = s;
     }
   return k;
  }

//--- Find the broker's actual name for a wanted instrument.
//--- Tries the exact name, then a prefix match, then a contains match.
bool KM_ResolveSymbol(const string want, string &resolved)
  {
   resolved = "";
   if(StringLen(want) == 0)
      return false;

//--- exact name first
   if(SymbolSelect(want, true))
     {
      if(SymbolInfoDouble(want, SYMBOL_BID) > 0.0 ||
         SymbolInfoInteger(want, SYMBOL_SELECT))
        {
         resolved = want;
         return true;
        }
     }

   string wantUp = want;
   StringToUpper(wantUp);

   int total = SymbolsTotal(false);   // every symbol the server offers

//--- prefix match: XAUUSD -> XAUUSD.a, XAUUSDm
   for(int i = 0; i < total; i++)
     {
      string nm = SymbolName(i, false);
      string up = nm;
      StringToUpper(up);
      if(StringFind(up, wantUp) == 0)
        {
         if(SymbolSelect(nm, true))
           {
            resolved = nm;
            return true;
           }
        }
     }

//--- contains match, as a last resort
   for(int i = 0; i < total; i++)
     {
      string nm = SymbolName(i, false);
      string up = nm;
      StringToUpper(up);
      if(StringFind(up, wantUp) >= 0)
        {
         if(SymbolSelect(nm, true))
           {
            resolved = nm;
            return true;
           }
        }
     }

   return false;
  }

//--- resolve a whole list, reporting what could not be found
int KM_ResolveSymbolList(const string csv, string &resolved[], string &missing)
  {
   missing = "";
   ArrayResize(resolved, 0);

   string wanted[];
   int n = KM_ParseSymbolList(csv, wanted);
   int k = 0;

   for(int i = 0; i < n; i++)
     {
      string got;
      if(KM_ResolveSymbol(wanted[i], got))
        {
         //--- skip duplicates, e.g. two aliases resolving to one symbol
         bool dup = false;
         for(int j = 0; j < k; j++)
            if(resolved[j] == got)
              {
               dup = true;
               break;
              }
         if(dup)
            continue;

         ArrayResize(resolved, k + 1);
         resolved[k++] = got;
        }
      else
         missing += wanted[i] + " ";
     }

   return k;
  }

//+------------------------------------------------------------------+
//| Misc helpers                                                     |
//+------------------------------------------------------------------+
string KM_RegimeName(const ENUM_KM_REGIME r)
  {
   switch(r)
     {
      case KM_REGIME_RANGE:       return "RANGE";
      case KM_REGIME_TREND_UP:    return "TREND-UP";
      case KM_REGIME_TREND_DOWN:  return "TREND-DOWN";
      case KM_REGIME_BREAKOUT_UP: return "BREAKOUT-UP";
      case KM_REGIME_BREAKOUT_DN: return "BREAKOUT-DN";
     }
   return "?";
  }

string KM_VolName(const ENUM_KM_VOL v)
  {
   switch(v)
     {
      case KM_VOL_LOW:     return "LOW";
      case KM_VOL_NORMAL:  return "NORMAL";
      case KM_VOL_HIGH:    return "HIGH";
      case KM_VOL_EXTREME: return "EXTREME";
     }
   return "?";
  }

//--- true when the regime trends in the given direction
bool KM_RegimeFavours(const ENUM_KM_REGIME r, const ENUM_KM_DIR dir)
  {
   if(dir == KM_DIR_BUY)
      return (r == KM_REGIME_TREND_UP || r == KM_REGIME_BREAKOUT_UP);
   if(dir == KM_DIR_SELL)
      return (r == KM_REGIME_TREND_DOWN || r == KM_REGIME_BREAKOUT_DN);
   return false;
  }

#endif // KRISHMIX_COMMON_MQH
//+------------------------------------------------------------------+
