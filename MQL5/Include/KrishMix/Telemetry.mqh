//+------------------------------------------------------------------+
//|                                       KrishMix\Telemetry.mqh     |
//|                                                                  |
//|  Writes each EA's internal state to a JSON file so the dashboard   |
//|  backend can read it.                                             |
//|                                                                  |
//|  The EAs already compute everything worth showing - the composite  |
//|  score, the regime, which trigger fired, why the grid decided to   |
//|  wait, how the hedge was sized, what the basket target works out   |
//|  to. None of that leaves MT5 today. This module is the one-way     |
//|  door that lets it out, and it is READ ONLY with respect to        |
//|  trading: nothing here can place, modify or close an order.        |
//|                                                                  |
//|  Files land in                                                     |
//|      <terminal data folder>\MQL5\Files\KrishMix\telemetry\          |
//|  and the backend finds that folder by asking MT5 for it, so there   |
//|  is nothing to configure on either side.                            |
//|                                                                  |
//|  Two details that matter:                                          |
//|                                                                  |
//|  ATOMIC WRITES. The document is written to a .tmp file and then     |
//|  moved into place. A reader polling the folder therefore never      |
//|  catches a half-written file, which would otherwise show up as      |
//|  random JSON parse errors every few seconds.                        |
//|                                                                  |
//|  REAL ESCAPING. The playbook narrative contains newlines and        |
//|  quotes, and reason strings contain both. Naive string joining      |
//|  would produce invalid JSON the moment a narrative was included.    |
//+------------------------------------------------------------------+
#ifndef KRISHMIX_TELEMETRY_MQH
#define KRISHMIX_TELEMETRY_MQH

#include <KrishMix\Common.mqh>

#define KM_TELEMETRY_DIR "KrishMix\\telemetry"

//+------------------------------------------------------------------+
//| JSON document builder plus atomic file writer                     |
//|                                                                  |
//| Comma placement is handled by a single flag rather than a stack:    |
//| entering a container clears it, leaving one sets it, and adding a   |
//| value sets it. That is exactly the state needed to know whether     |
//| the next thing written is a sibling that must be preceded by a      |
//| comma, at any nesting depth.                                       |
//+------------------------------------------------------------------+
class CKMTelemetry
  {
private:
   string            m_buf;
   string            m_file;        // final name, relative to MQL5\Files
   string            m_tmp;         // scratch name
   string            m_ea;
   string            m_symbol;
   int               m_throttleSec;
   datetime          m_lastWrite;
   bool              m_needComma;
   bool              m_open;        // Begin() called, End() not yet
   bool              m_enabled;
   long              m_writes;
   long              m_failures;
   string            m_lastError;

   void              Put(const string s) { m_buf += s; }

   void              Comma(void)
     {
      if(m_needComma)
         m_buf += ",";
     }

   //--- a finite number, or null. JSON has no NaN or Infinity, and
   //--- emitting one silently breaks the whole document for the reader.
   string            NumText(const double v, const int digits) const
     {
      if(!MathIsValidNumber(v))
         return "null";
      return DoubleToString(v, digits);
     }

public:
                     CKMTelemetry(void)
     {
      m_buf         = "";
      m_file        = "";
      m_tmp         = "";
      m_ea          = "";
      m_symbol      = "";
      m_throttleSec = 5;
      m_lastWrite   = 0;
      m_needComma   = false;
      m_open        = false;
      m_enabled     = false;
      m_writes      = 0;
      m_failures    = 0;
      m_lastError   = "";
     }

   //+---------------------------------------------------------------+
   //| Escape a string for JSON. Output is pure ASCII, so the ANSI     |
   //| file write below is lossless whatever the broker calls things.  |
   //+---------------------------------------------------------------+
   static string     Esc(const string s)
     {
      string out = "";
      int n = StringLen(s);

      for(int i = 0; i < n; i++)
        {
         ushort c = StringGetCharacter(s, i);

         switch(c)
           {
            case '"':  out += "\\\"";  continue;
            case '\\': out += "\\\\";  continue;
            case '\n': out += "\\n";   continue;
            case '\r': out += "\\r";   continue;
            case '\t': out += "\\t";   continue;
            case '\b': out += "\\b";   continue;
            case '\f': out += "\\f";   continue;
           }

         //--- control characters and anything non-ASCII go out as \uXXXX
         if(c < 0x20 || c > 0x7E)
           {
            out += StringFormat("\\u%04x", c);
            continue;
           }

         out += ShortToString(c);
        }

      return out;
     }

   //+---------------------------------------------------------------+
   bool              Init(const string eaTag, const string symbol,
                          const int throttleSeconds = 5)
     {
      m_ea          = eaTag;
      m_symbol      = symbol;
      m_throttleSec = MathMax(1, throttleSeconds);

      //--- MQL5 does not create intermediate folders on FileOpen, so make
      //--- the directory up front. An existing folder is the normal case
      //--- and is not an error worth reacting to, so the result is only
      //--- recorded: the real test is whether FileOpen succeeds in End(),
      //--- which reports properly and is counted as a failure.
      ResetLastError();
      if(!FolderCreate(KM_TELEMETRY_DIR, 0))
        {
         int err = GetLastError();
         if(err != 0)
            m_lastError = StringFormat("FolderCreate note: error %d", err);
        }
      ResetLastError();

      string safeSym = symbol;
      StringReplace(safeSym, "\\", "_");
      StringReplace(safeSym, "/",  "_");
      StringReplace(safeSym, ":",  "_");
      StringReplace(safeSym, "*",  "_");
      StringReplace(safeSym, "?",  "_");

      m_file = StringFormat("%s\\%s_%s.json", KM_TELEMETRY_DIR, eaTag, safeSym);
      m_tmp  = m_file + ".tmp";

      m_enabled = true;
      return true;
     }

   void              Disable(void) { m_enabled = false; }
   bool              Enabled(void)   const { return m_enabled; }
   string            FileName(void)  const { return m_file; }
   string            LastError(void) const { return m_lastError; }
   long              Writes(void)    const { return m_writes; }
   long              Failures(void)  const { return m_failures; }

   //--- has the throttle interval elapsed?
   bool              Due(void) const
     {
      if(!m_enabled)
         return false;
      return ((TimeCurrent() - m_lastWrite) >= m_throttleSec);
     }

   //+---------------------------------------------------------------+
   //| Document lifecycle                                             |
   //+---------------------------------------------------------------+
   void              Begin(void)
     {
      m_buf       = "{";
      m_needComma = false;
      m_open      = true;

      //--- standard header on every document
      Str("ea",       m_ea);
      Str("symbol",   m_symbol);
      Int("ts",       (long)TimeCurrent());
      Str("time",     TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS));
      Str("suiteVer", KM_VERSION);
     }

   //--- close the document and move it into place
   bool              End(void)
     {
      if(!m_open)
         return false;

      m_buf += "}";
      m_open = false;

      if(!m_enabled)
         return false;

      ResetLastError();
      int h = FileOpen(m_tmp, FILE_WRITE | FILE_TXT | FILE_ANSI);
      if(h == INVALID_HANDLE)
        {
         m_failures++;
         m_lastError = StringFormat("FileOpen(%s) failed, error %d", m_tmp, GetLastError());
         return false;
        }

      FileWriteString(h, m_buf);
      FileClose(h);

      //--- atomic swap so a polling reader never sees a partial document
      ResetLastError();
      if(!FileMove(m_tmp, 0, m_file, FILE_REWRITE))
        {
         m_failures++;
         m_lastError = StringFormat("FileMove to %s failed, error %d", m_file, GetLastError());
         return false;
        }

      m_writes++;
      m_lastWrite = TimeCurrent();
      m_lastError = "";
      return true;
     }

   //+---------------------------------------------------------------+
   //| Scalars                                                        |
   //+---------------------------------------------------------------+
   void              Str(const string key, const string val)
     {
      Comma();
      Put("\"" + Esc(key) + "\":\"" + Esc(val) + "\"");
      m_needComma = true;
     }

   void              Num(const string key, const double val, const int digits = 2)
     {
      Comma();
      Put("\"" + Esc(key) + "\":" + NumText(val, digits));
      m_needComma = true;
     }

   void              Int(const string key, const long val)
     {
      Comma();
      Put("\"" + Esc(key) + "\":" + IntegerToString(val));
      m_needComma = true;
     }

   void              Bool(const string key, const bool val)
     {
      Comma();
      Put("\"" + Esc(key) + "\":" + (val ? "true" : "false"));
      m_needComma = true;
     }

   void              Null(const string key)
     {
      Comma();
      Put("\"" + Esc(key) + "\":null");
      m_needComma = true;
     }

   //+---------------------------------------------------------------+
   //| Containers                                                     |
   //+---------------------------------------------------------------+
   void              Obj(const string key)
     {
      Comma();
      Put("\"" + Esc(key) + "\":{");
      m_needComma = false;
     }

   void              EndObj(void)
     {
      Put("}");
      m_needComma = true;
     }

   void              Arr(const string key)
     {
      Comma();
      Put("\"" + Esc(key) + "\":[");
      m_needComma = false;
     }

   void              EndArr(void)
     {
      Put("]");
      m_needComma = true;
     }

   //--- an anonymous object as an array element
   void              ArrObj(void)
     {
      Comma();
      Put("{");
      m_needComma = false;
     }

   //--- bare values as array elements
   void              ArrStr(const string val)
     {
      Comma();
      Put("\"" + Esc(val) + "\"");
      m_needComma = true;
     }

   void              ArrNum(const double val, const int digits = 2)
     {
      Comma();
      Put(NumText(val, digits));
      m_needComma = true;
     }

   void              ArrInt(const long val)
     {
      Comma();
      Put(IntegerToString(val));
      m_needComma = true;
     }

   //+---------------------------------------------------------------+
   //| Convenience: a whole array of numbers in one call               |
   //+---------------------------------------------------------------+
   void              NumArray(const string key, const double &vals[], const int count,
                              const int digits = 2)
     {
      Arr(key);
      int n = MathMin(count, ArraySize(vals));
      for(int i = 0; i < n; i++)
         ArrNum(vals[i], digits);
      EndArr();
     }

   void              IntArray(const string key, const long &vals[], const int count)
     {
      Arr(key);
      int n = MathMin(count, ArraySize(vals));
      for(int i = 0; i < n; i++)
         ArrInt(vals[i]);
      EndArr();
     }

   //--- a labelled counter list, e.g. the block histogram or the
   //--- per-trigger tallies: [{"name":"...","count":N}, ...]
   void              CounterArray(const string key, const string &names[],
                                  const long &counts[], const int count,
                                  const bool skipZero = true)
     {
      Arr(key);
      int n = MathMin(count, MathMin(ArraySize(names), ArraySize(counts)));
      for(int i = 0; i < n; i++)
        {
         if(skipZero && counts[i] <= 0)
            continue;
         ArrObj();
         Str("name",  names[i]);
         Int("count", counts[i]);
         EndObj();
        }
      EndArr();
     }

   //+---------------------------------------------------------------+
   //| Shared blocks the EAs all want to publish                      |
   //+---------------------------------------------------------------+

   //--- which suite members are alive, straight from the heartbeat
   void              Roster(const string key, const bool &alive[], const int count)
     {
      Arr(key);
      int n = MathMin(count, ArraySize(alive));
      for(int i = 0; i < n; i++)
        {
         ArrObj();
         Int("slot",  i + KM_EA_FIRST);
         Str("name",  KM_EaSlotName(i + KM_EA_FIRST));
         Bool("alive", alive[i]);
         EndObj();
        }
      EndArr();
     }

   //--- symbol context every document benefits from
   void              SymbolBlock(const string sym)
     {
      Obj("market");
      int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      Num("bid",         SymbolInfoDouble(sym, SYMBOL_BID), digits);
      Num("ask",         SymbolInfoDouble(sym, SYMBOL_ASK), digits);
      Int("spreadPts",   SymbolInfoInteger(sym, SYMBOL_SPREAD));
      Int("digits",      digits);
      Num("moneyPerLot", KM_MoneyPerPricePerLot(sym), 4);
      EndObj();
     }

   //--- account context. The backend redacts this if configured to.
   void              AccountBlock(void)
     {
      Obj("account");
      Str("currency", AccountInfoString(ACCOUNT_CURRENCY));
      Num("balance",  AccountInfoDouble(ACCOUNT_BALANCE));
      Num("equity",   AccountInfoDouble(ACCOUNT_EQUITY));
      Num("margin",   AccountInfoDouble(ACCOUNT_MARGIN));
      Num("freeMargin", AccountInfoDouble(ACCOUNT_MARGIN_FREE));
      Num("marginLevel", AccountInfoDouble(ACCOUNT_MARGIN_LEVEL));
      Int("leverage", AccountInfoInteger(ACCOUNT_LEVERAGE));
      EndObj();
     }

   //--- health of this writer, so the dashboard can flag a stalled feed
   void              HealthBlock(void)
     {
      Obj("telemetry");
      Int("writes",   m_writes);
      Int("failures", m_failures);
      Str("file",     m_file);
      Str("lastError", m_lastError);
      EndObj();
     }
  };

#endif // KRISHMIX_TELEMETRY_MQH
//+------------------------------------------------------------------+
