//+------------------------------------------------------------------+
//|                                                SymbolMapper.mqh |
//|  Master symbol -> Slave (broker) symbol resolution.               |
//|  Never assumes both brokers use identical symbol names.           |
//+------------------------------------------------------------------+
#ifndef __CT_SYMBOLMAPPER_MQH__
#define __CT_SYMBOLMAPPER_MQH__

class CSymbolMapper
  {
private:
   bool              m_auto_mapping;
   string            m_prefix;
   string            m_suffix;
   string            m_manual_from[];
   string            m_manual_to[];

   bool              IsSymbolTradable(const string sym)
     {
      if(sym == "")
         return false;
      if(!SymbolSelect(sym, true))
         return false;
      long trade_mode = SYMBOL_TRADE_MODE_DISABLED;
      if(!SymbolInfoInteger(sym, SYMBOL_TRADE_MODE, trade_mode))
         return false;
      return true; // caller checks whether trade_mode allows the specific action
     }

public:
   void              Init(const bool auto_mapping, const string prefix, const string suffix,
                           const string manual_mapping_list)
     {
      m_auto_mapping = auto_mapping;
      m_prefix       = prefix;
      m_suffix       = suffix;
      ParseManualMapping(manual_mapping_list);
     }

   void              ParseManualMapping(const string list)
     {
      ArrayResize(m_manual_from, 0);
      ArrayResize(m_manual_to, 0);
      if(list == "")
         return;

      string pairs[];
      int pn = StringSplit(list, ';', pairs);
      for(int i = 0; i < pn; i++)
        {
         string kv[];
         if(StringSplit(pairs[i], '=', kv) == 2)
           {
            int sz = ArraySize(m_manual_from);
            ArrayResize(m_manual_from, sz + 1);
            ArrayResize(m_manual_to, sz + 1);
            m_manual_from[sz] = kv[0];
            m_manual_to[sz]   = kv[1];
           }
        }
     }

   //--- resolve master_symbol -> tradable slave symbol -------------
   bool              MapSymbol(const string master_symbol, string &slave_symbol)
     {
      //--- 1. explicit manual mapping always wins ---------------------
      for(int i = 0; i < ArraySize(m_manual_from); i++)
        {
         if(m_manual_from[i] == master_symbol)
           {
            if(IsSymbolTradable(m_manual_to[i]))
              {
               slave_symbol = m_manual_to[i];
               return true;
              }
            return false; // explicit mapping given but target not tradable -> fail loudly, no fallback
           }
        }

      //--- 2. exact name match ----------------------------------------
      if(IsSymbolTradable(master_symbol))
        {
         slave_symbol = master_symbol;
         return true;
        }

      if(!m_auto_mapping)
         return false;

      //--- 3. prefix + base + suffix -----------------------------------
      string candidate = m_prefix + master_symbol + m_suffix;
      if(candidate != master_symbol && IsSymbolTradable(candidate))
        {
         slave_symbol = candidate;
         return true;
        }

      //--- 4. scan full symbol list for a name that contains the base --
      int total = SymbolsTotal(false);
      for(int i = 0; i < total; i++)
        {
         string sym = SymbolName(i, false);
         if(StringFind(sym, master_symbol) >= 0 && IsSymbolTradable(sym))
           {
            slave_symbol = sym;
            return true;
           }
        }

      return false;
     }
  };

#endif // __CT_SYMBOLMAPPER_MQH__
