//+------------------------------------------------------------------+
//|                                       KrishMix\StateBus.mqh      |
//|                                                                  |
//|  Cross-EA communication.                                          |
//|                                                                  |
//|  MT5 allows only ONE Expert Advisor per chart, so the four EAs of |
//|  this suite run on four charts of the same symbol. They talk to    |
//|  each other through TERMINAL GLOBAL VARIABLES, which are shared    |
//|  by every EA inside one terminal and survive a restart.            |
//|                                                                  |
//|  Every key is namespaced:   KM.<symbol>.<key>                      |
//+------------------------------------------------------------------+
#ifndef KRISHMIX_STATEBUS_MQH
#define KRISHMIX_STATEBUS_MQH

#include <KrishMix\Common.mqh>

//--- published by the EA that owns the reading
#define KM_KEY_SCORE          "score"        // -100..+100 composite bias
#define KM_KEY_REGIME         "regime"       // ENUM_KM_REGIME
#define KM_KEY_VOL            "vol"          // ENUM_KM_VOL
#define KM_KEY_ATR            "atr"          // ATR in price units
#define KM_KEY_TREND          "trend"        // 0..100 trend strength
#define KM_KEY_SIGTIME        "sigtime"      // when the reading was published

#define KM_KEY_GRID_LVL_BUY   "gridlvlbuy"   // EA2: current buy grid depth
#define KM_KEY_GRID_LVL_SELL  "gridlvlsell"  // EA2: current sell grid depth
#define KM_KEY_GRID_WAIT      "gridwait"     // EA2: 1 = deliberately waiting
#define KM_KEY_GRID_NEXT_BUY  "gridnextbuy"  // EA2: next buy add price
#define KM_KEY_GRID_NEXT_SELL "gridnextsell" // EA2: next sell add price

#define KM_KEY_HEDGE_DIR      "hedgedir"     // EA3: active recovery direction
#define KM_KEY_HEDGE_TIME     "hedgetime"    // EA3: when it fired
#define KM_KEY_HEDGE_LOTS     "hedgelots"    // EA3: recovery volume in play

#define KM_KEY_TGT_BUY        "tgtbuy"       // EA4: live buy basket target
#define KM_KEY_TGT_SELL       "tgtsell"      // EA4: live sell basket target
#define KM_KEY_TGT_GROUP      "tgtgroup"     // EA4: live recovery group target
#define KM_KEY_LASTCLOSE      "lastclose"    // EA4: last basket close time
#define KM_KEY_CYCLE          "cycle"        // EA4: increments on every close

#define KM_KEY_HB_PREFIX      "hb"           // heartbeat per EA slot

//+------------------------------------------------------------------+
//| Bus                                                              |
//+------------------------------------------------------------------+
class CKMBus
  {
private:
   string            m_symbol;
   string            m_prefix;

public:
                     CKMBus(void) { m_symbol = ""; m_prefix = ""; }

   void              Init(const string sym)
     {
      m_symbol = sym;
      //--- global variable names are capped at 63 chars, keep it tight
      m_prefix = "KM." + sym + ".";
     }

   string            Key(const string k) const { return m_prefix + k; }

   //--- write
   void              Set(const string k, const double v) const
     {
      GlobalVariableSet(Key(k), v);
     }

   //--- read with a fallback when nobody has published yet
   double            Get(const string k, const double def = 0.0) const
     {
      string name = Key(k);
      if(!GlobalVariableCheck(name))
         return def;
      return GlobalVariableGet(name);
     }

   bool              Has(const string k) const
     {
      return GlobalVariableCheck(Key(k));
     }

   void              Del(const string k) const
     {
      GlobalVariableDel(Key(k));
     }

   //--- typed convenience accessors -------------------------------
   void              PublishView(const double score, const ENUM_KM_REGIME regime,
                                 const ENUM_KM_VOL vol, const double atr,
                                 const double trendStrength) const
     {
      Set(KM_KEY_SCORE,  score);
      Set(KM_KEY_REGIME, (double)regime);
      Set(KM_KEY_VOL,    (double)vol);
      Set(KM_KEY_ATR,    atr);
      Set(KM_KEY_TREND,  trendStrength);
      Set(KM_KEY_SIGTIME, (double)TimeCurrent());
     }

   double            Score(void)  const { return Get(KM_KEY_SCORE, 0.0); }
   double            Atr(void)    const { return Get(KM_KEY_ATR, 0.0); }
   double            Trend(void)  const { return Get(KM_KEY_TREND, 0.0); }

   ENUM_KM_REGIME    Regime(void) const
     {
      return (ENUM_KM_REGIME)(int)Get(KM_KEY_REGIME, (double)KM_REGIME_RANGE);
     }

   ENUM_KM_VOL       Vol(void) const
     {
      return (ENUM_KM_VOL)(int)Get(KM_KEY_VOL, (double)KM_VOL_NORMAL);
     }

   //--- is the published market view still fresh enough to trust?
   bool              ViewFresh(const int maxAgeSeconds = 120) const
     {
      double t = Get(KM_KEY_SIGTIME, 0.0);
      if(t <= 0.0)
         return false;
      return ((TimeCurrent() - (datetime)t) <= maxAgeSeconds);
     }

   //--- heartbeat: each EA stamps its slot so the others know it runs
   void              Beat(const int eaSlot) const
     {
      Set(KM_KEY_HB_PREFIX + IntegerToString(eaSlot), (double)TimeCurrent());
     }

   bool              Alive(const int eaSlot, const int maxAgeSeconds = 90) const
     {
      double t = Get(KM_KEY_HB_PREFIX + IntegerToString(eaSlot), 0.0);
      if(t <= 0.0)
         return false;
      return ((TimeCurrent() - (datetime)t) <= maxAgeSeconds);
     }

   //--- human readable roster of which suite members are online
   string            Roster(const int maxAgeSeconds = 90) const
     {
      string s = "";
      for(int slot = KM_EA_ENTRY; slot <= KM_EA_BASKET; slot++)
        {
         s += KM_EaSlotName(slot);
         s += Alive(slot, maxAgeSeconds) ? ":on  " : ":OFF ";
        }
      return s;
     }

   //--- wipe every key of this symbol (used by a full suite reset)
   void              PurgeAll(void) const
     {
      int total = GlobalVariablesTotal();
      for(int i = total - 1; i >= 0; i--)
        {
         string name = GlobalVariableName(i);
         if(StringFind(name, m_prefix) == 0)
            GlobalVariableDel(name);
        }
     }
  };

#endif // KRISHMIX_STATEBUS_MQH
//+------------------------------------------------------------------+
