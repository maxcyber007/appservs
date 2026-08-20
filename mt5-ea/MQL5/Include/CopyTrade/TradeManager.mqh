//+------------------------------------------------------------------+
//|                                                TradeManager.mqh |
//|  Thin wrapper around CTrade: every call verifies the real server  |
//|  retcode (never trusts a bare bool return), supports bounded      |
//|  retry for transient errors only, and honours TestMode/DryRun.    |
//+------------------------------------------------------------------+
#ifndef __CT_TRADEMANAGER_MQH__
#define __CT_TRADEMANAGER_MQH__

#include <Trade/Trade.mqh>
#include "Logger.mqh"

class CTradeExecutor
  {
private:
   CTrade            m_trade;
   long              m_magic;
   int               m_deviation_points;
   int               m_max_retry;
   int               m_retry_delay_ms;
   bool              m_test_mode;
   bool              m_dry_run;

   bool              IsRetryableRetcode(const uint retcode)
     {
      switch(retcode)
        {
         case TRADE_RETCODE_REQUOTE:
         case TRADE_RETCODE_PRICE_CHANGED:
         case TRADE_RETCODE_PRICE_OFF:
         case TRADE_RETCODE_CONNECTION:
         case TRADE_RETCODE_TIMEOUT:
         case TRADE_RETCODE_TOO_MANY_REQUESTS:
         case TRADE_RETCODE_REJECT:
            return true;
        }
      return false;
     }

   bool              Simulated() { return (m_test_mode || m_dry_run); }
   string            SimTag()    { return m_test_mode ? "[TEST]" : "[DRYRUN]"; }

public:
   void              Init(const long magic, const int deviation_points,
                           const int max_retry, const int retry_delay_ms,
                           const bool test_mode, const bool dry_run)
     {
      m_magic            = magic;
      m_deviation_points = deviation_points;
      m_max_retry        = MathMax(0, max_retry);
      m_retry_delay_ms   = MathMax(0, retry_delay_ms);
      m_test_mode        = test_mode;
      m_dry_run          = dry_run;

      m_trade.SetExpertMagicNumber(magic);
      m_trade.SetDeviationInPoints(deviation_points);
      m_trade.LogLevel(LOG_LEVEL_ERRORS);
     }

   //--- open a market position -----------------------------------------
   bool              OpenPosition(const string symbol, const ENUM_ORDER_TYPE type,
                                   const double volume, const double sl, const double tp,
                                   const string comment, ulong &out_ticket, string &error)
     {
      out_ticket = 0;

      if(Simulated())
        {
         g_logger.Info(StringFormat("%s Would %s %s volume=%.2f sl=%.5f tp=%.5f comment=%s",
                        SimTag(), (type == ORDER_TYPE_BUY ? "BUY" : "SELL"), symbol, volume, sl, tp, comment));
         return true;
        }

      m_trade.SetTypeFillingBySymbol(symbol);

      for(int attempt = 0; attempt <= m_max_retry; attempt++)
        {
         bool ok;
         double price = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(symbol, SYMBOL_ASK)
                                                   : SymbolInfoDouble(symbol, SYMBOL_BID);
         if(type == ORDER_TYPE_BUY)
            ok = m_trade.Buy(volume, symbol, price, sl, tp, comment);
         else
            ok = m_trade.Sell(volume, symbol, price, sl, tp, comment);

         uint retcode = m_trade.ResultRetcode();

         if(ok && (retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_DONE_PARTIAL || retcode == TRADE_RETCODE_PLACED))
           {
            out_ticket = m_trade.ResultOrder();
            if(out_ticket == 0)
               out_ticket = m_trade.ResultDeal();
            g_logger.Trade(StringFormat("OpenPosition OK symbol=%s type=%s vol=%.2f ticket=%d retcode=%d(%s)",
                            symbol, EnumToString(type), volume, (int)out_ticket, retcode, m_trade.ResultRetcodeDescription()));
            return true;
           }

         error = StringFormat("retcode=%d (%s)", retcode, m_trade.ResultRetcodeDescription());

         if(!IsRetryableRetcode(retcode) || attempt == m_max_retry)
           {
            g_logger.Error(StringFormat("OpenPosition FAILED symbol=%s type=%s vol=%.2f %s", symbol, EnumToString(type), volume, error));
            return false;
           }

         g_logger.Warning(StringFormat("OpenPosition retry %d/%d symbol=%s %s", attempt + 1, m_max_retry, symbol, error));
         Sleep(m_retry_delay_ms);
        }
      return false;
     }

   //--- close (full or partial) an existing position --------------------
   bool              ClosePosition(const ulong ticket, const double volume, string &error)
     {
      if(Simulated())
        {
         g_logger.Info(StringFormat("%s Would CLOSE ticket=%d volume=%.2f", SimTag(), (int)ticket, volume));
         return true;
        }

      if(!PositionSelectByTicket(ticket))
        {
         error = "Position not found (already closed?)";
         return true; // idempotent: nothing to do
        }

      string symbol = PositionGetString(POSITION_SYMBOL);
      m_trade.SetTypeFillingBySymbol(symbol);

      for(int attempt = 0; attempt <= m_max_retry; attempt++)
        {
         bool ok = (volume > 0) ? m_trade.PositionClosePartial(ticket, volume) : m_trade.PositionClose(ticket);
         uint retcode = m_trade.ResultRetcode();

         if(ok && (retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_DONE_PARTIAL))
           {
            g_logger.Trade(StringFormat("ClosePosition OK ticket=%d volume=%.2f retcode=%d(%s)",
                            (int)ticket, volume, retcode, m_trade.ResultRetcodeDescription()));
            return true;
           }

         error = StringFormat("retcode=%d (%s)", retcode, m_trade.ResultRetcodeDescription());

         if(!IsRetryableRetcode(retcode) || attempt == m_max_retry)
           {
            g_logger.Error(StringFormat("ClosePosition FAILED ticket=%d %s", (int)ticket, error));
            return false;
           }

         g_logger.Warning(StringFormat("ClosePosition retry %d/%d ticket=%d %s", attempt + 1, m_max_retry, (int)ticket, error));
         Sleep(m_retry_delay_ms);
        }
      return false;
     }

   //--- modify SL/TP of an existing position -----------------------------
   bool              ModifyPosition(const ulong ticket, const double sl, const double tp, string &error)
     {
      if(Simulated())
        {
         g_logger.Info(StringFormat("%s Would MODIFY ticket=%d sl=%.5f tp=%.5f", SimTag(), (int)ticket, sl, tp));
         return true;
        }

      if(!PositionSelectByTicket(ticket))
        {
         error = "Position not found";
         return false;
        }

      for(int attempt = 0; attempt <= m_max_retry; attempt++)
        {
         bool ok = m_trade.PositionModify(ticket, sl, tp);
         uint retcode = m_trade.ResultRetcode();

         if(ok && retcode == TRADE_RETCODE_DONE)
           {
            g_logger.Trade(StringFormat("ModifyPosition OK ticket=%d sl=%.5f tp=%.5f", (int)ticket, sl, tp));
            return true;
           }

         error = StringFormat("retcode=%d (%s)", retcode, m_trade.ResultRetcodeDescription());

         if(!IsRetryableRetcode(retcode) || attempt == m_max_retry)
           {
            g_logger.Error(StringFormat("ModifyPosition FAILED ticket=%d %s", (int)ticket, error));
            return false;
           }

         g_logger.Warning(StringFormat("ModifyPosition retry %d/%d ticket=%d %s", attempt + 1, m_max_retry, (int)ticket, error));
         Sleep(m_retry_delay_ms);
        }
      return false;
     }

   //--- place a pending order ---------------------------------------------
   bool              PlacePendingOrder(const string symbol, const ENUM_ORDER_TYPE type, const double volume,
                                        const double price, const double stoplimit, const double sl, const double tp,
                                        const datetime expiration, const string comment, ulong &out_ticket, string &error)
     {
      out_ticket = 0;

      if(Simulated())
        {
         g_logger.Info(StringFormat("%s Would PLACE %s %s vol=%.2f price=%.5f sl=%.5f tp=%.5f",
                        SimTag(), EnumToString(type), symbol, volume, price, sl, tp));
         return true;
        }

      m_trade.SetTypeFillingBySymbol(symbol);
      ENUM_ORDER_TYPE_TIME exp_type = (expiration > 0) ? ORDER_TIME_SPECIFIED : ORDER_TIME_GTC;

      for(int attempt = 0; attempt <= m_max_retry; attempt++)
        {
         bool ok = m_trade.OrderOpen(symbol, type, volume, stoplimit, price, sl, tp, exp_type, expiration, comment);
         uint retcode = m_trade.ResultRetcode();

         if(ok && (retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_PLACED))
           {
            out_ticket = m_trade.ResultOrder();
            g_logger.Trade(StringFormat("PlacePendingOrder OK symbol=%s type=%s vol=%.2f ticket=%d",
                            symbol, EnumToString(type), volume, (int)out_ticket));
            return true;
           }

         error = StringFormat("retcode=%d (%s)", retcode, m_trade.ResultRetcodeDescription());

         if(!IsRetryableRetcode(retcode) || attempt == m_max_retry)
           {
            g_logger.Error(StringFormat("PlacePendingOrder FAILED symbol=%s %s", symbol, error));
            return false;
           }

         g_logger.Warning(StringFormat("PlacePendingOrder retry %d/%d symbol=%s %s", attempt + 1, m_max_retry, symbol, error));
         Sleep(m_retry_delay_ms);
        }
      return false;
     }

   //--- modify a pending order -------------------------------------------
   bool              ModifyPendingOrder(const ulong ticket, const double price, const double stoplimit,
                                         const double sl, const double tp, const datetime expiration, string &error)
     {
      if(Simulated())
        {
         g_logger.Info(StringFormat("%s Would MODIFY ORDER ticket=%d price=%.5f sl=%.5f tp=%.5f", SimTag(), (int)ticket, price, sl, tp));
         return true;
        }

      if(!OrderSelect(ticket))
        {
         error = "Order not found";
         return false;
        }

      ENUM_ORDER_TYPE_TIME exp_type = (expiration > 0) ? ORDER_TIME_SPECIFIED : ORDER_TIME_GTC;

      for(int attempt = 0; attempt <= m_max_retry; attempt++)
        {
         bool ok = m_trade.OrderModify(ticket, price, sl, tp, exp_type, expiration, stoplimit);
         uint retcode = m_trade.ResultRetcode();

         if(ok && retcode == TRADE_RETCODE_DONE)
           {
            g_logger.Trade(StringFormat("ModifyPendingOrder OK ticket=%d", (int)ticket));
            return true;
           }

         error = StringFormat("retcode=%d (%s)", retcode, m_trade.ResultRetcodeDescription());

         if(!IsRetryableRetcode(retcode) || attempt == m_max_retry)
           {
            g_logger.Error(StringFormat("ModifyPendingOrder FAILED ticket=%d %s", (int)ticket, error));
            return false;
           }

         g_logger.Warning(StringFormat("ModifyPendingOrder retry %d/%d ticket=%d %s", attempt + 1, m_max_retry, (int)ticket, error));
         Sleep(m_retry_delay_ms);
        }
      return false;
     }

   //--- delete a pending order ----------------------------------------------
   bool              DeletePendingOrder(const ulong ticket, string &error)
     {
      if(Simulated())
        {
         g_logger.Info(StringFormat("%s Would DELETE ORDER ticket=%d", SimTag(), (int)ticket));
         return true;
        }

      if(!OrderSelect(ticket))
        {
         error = "Order not found (already gone?)";
         return true; // idempotent
        }

      for(int attempt = 0; attempt <= m_max_retry; attempt++)
        {
         bool ok = m_trade.OrderDelete(ticket);
         uint retcode = m_trade.ResultRetcode();

         if(ok && retcode == TRADE_RETCODE_DONE)
           {
            g_logger.Trade(StringFormat("DeletePendingOrder OK ticket=%d", (int)ticket));
            return true;
           }

         error = StringFormat("retcode=%d (%s)", retcode, m_trade.ResultRetcodeDescription());

         if(!IsRetryableRetcode(retcode) || attempt == m_max_retry)
           {
            g_logger.Error(StringFormat("DeletePendingOrder FAILED ticket=%d %s", (int)ticket, error));
            return false;
           }

         g_logger.Warning(StringFormat("DeletePendingOrder retry %d/%d ticket=%d %s", attempt + 1, m_max_retry, (int)ticket, error));
         Sleep(m_retry_delay_ms);
        }
      return false;
     }
  };

#endif // __CT_TRADEMANAGER_MQH__
