//+------------------------------------------------------------------+
//|                                            AccountValidator.mqh |
//|  Real/Demo account safety checks + hedging/netting detection.     |
//+------------------------------------------------------------------+
#ifndef __CT_ACCOUNTVALIDATOR_MQH__
#define __CT_ACCOUNTVALIDATOR_MQH__

class CAccountValidator
  {
public:
   static bool       ValidateMaster(const bool require_demo, string &error)
     {
      ENUM_ACCOUNT_TRADE_MODE mode = (ENUM_ACCOUNT_TRADE_MODE)AccountInfoInteger(ACCOUNT_TRADE_MODE);
      if(require_demo && mode != ACCOUNT_TRADE_MODE_DEMO)
        {
         error = "Master account is NOT a DEMO account but RequireDemoMaster=true. Refusing to run as MASTER.";
         return false;
        }
      return true;
     }

   static bool       ValidateSlave(const bool require_real, string &error)
     {
      ENUM_ACCOUNT_TRADE_MODE mode = (ENUM_ACCOUNT_TRADE_MODE)AccountInfoInteger(ACCOUNT_TRADE_MODE);
      if(require_real && mode != ACCOUNT_TRADE_MODE_REAL)
        {
         error = "Slave account is NOT a REAL account but RequireRealAccount=true. Refusing to trade.";
         return false;
        }
      return true;
     }

   static bool       IsNettingAccount()
     {
      ENUM_ACCOUNT_MARGIN_MODE mode = (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
      return (mode == ACCOUNT_MARGIN_MODE_RETAIL_NETTING);
     }

   static string     TradeModeToString(const int mode)
     {
      switch((ENUM_ACCOUNT_TRADE_MODE)mode)
        {
         case ACCOUNT_TRADE_MODE_DEMO:    return "DEMO";
         case ACCOUNT_TRADE_MODE_CONTEST: return "CONTEST";
         case ACCOUNT_TRADE_MODE_REAL:    return "REAL";
        }
      return "UNKNOWN";
     }
  };

#endif // __CT_ACCOUNTVALIDATOR_MQH__
