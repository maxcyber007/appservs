//+------------------------------------------------------------------+
//|                                               PendingManager.mqh |
//|        Placement and housekeeping of breakout stop orders         |
//+------------------------------------------------------------------+
#property copyright "Gold Trade Pro EA"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/OrderInfo.mqh>
#include <GoldTradePro/Utils.mqh>

//--- A pending order parked while the spread was too wide.
struct SParkedOrder
  {
   ENUM_ORDER_TYPE   type;
   double            price;
   double            volume;
   double            sl;
   double            tp;
  };

//+------------------------------------------------------------------+
//| Owns every pending order carrying the EA's magic number.          |
//|                                                                   |
//| Three behaviours here exist because of how gold actually trades:  |
//|  * Spread parking - during rollover and news the spread blows out |
//|    and a resting stop order gets filled at a price nobody would   |
//|    accept. The orders are pulled and restored afterwards instead. |
//|  * Virtual expiration - the EA times orders out itself rather     |
//|    than using ORDER_TIME_SPECIFIED, because a fair number of      |
//|    brokers reject or silently ignore broker-side expiry.          |
//|  * Volume refresh - when the balance moves far enough that the    |
//|    risk-based lot has drifted, resting orders are re-issued at    |
//|    the new size, so an old order does not fire at a stale volume. |
//+------------------------------------------------------------------+
class CPendingManager
  {
private:
   string            m_symbol;
   long              m_magic;
   CTrade           *m_trade;
   string            m_comment;

   int               m_max_per_side;
   double            m_min_spacing;    // price distance between two orders of a side
   int               m_expiry_seconds; // 0 = no expiry
   SParkedOrder      m_parked[];

   bool              IsOurs(void) const
     {
      return(OrderGetString(ORDER_SYMBOL) == m_symbol &&
             (long)OrderGetInteger(ORDER_MAGIC) == m_magic);
     }

public:
                     CPendingManager(void)
      : m_symbol(""), m_magic(0), m_trade(NULL), m_comment(""),
        m_max_per_side(1), m_min_spacing(0.0), m_expiry_seconds(0) {}

   void              Configure(const string symbol, const long magic, CTrade *trade,
                               const string comment, const int max_per_side,
                               const double min_spacing, const int expiry_seconds)
     {
      m_symbol         = symbol;
      m_magic          = magic;
      m_trade          = trade;
      m_comment        = comment;
      m_max_per_side   = (max_per_side > 0 ? max_per_side : 1);
      m_min_spacing    = min_spacing;
      m_expiry_seconds = expiry_seconds;
     }

   void              SetMinSpacing(const double spacing) { m_min_spacing = spacing; }

   //--- Count of our resting orders of one type.
   int               Count(const ENUM_ORDER_TYPE type) const
     {
      int count = 0;
      for(int i = OrdersTotal() - 1; i >= 0; i--)
        {
         ulong ticket = OrderGetTicket(i);
         if(ticket == 0 || !OrderSelect(ticket))
            continue;
         if(!IsOurs())
            continue;
         if((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) == type)
            count++;
        }
      return(count);
     }

   //--- True when an order of this type already rests near "price".
   bool              HasNear(const ENUM_ORDER_TYPE type, const double price) const
     {
      if(m_min_spacing <= 0.0)
         return(false);

      for(int i = OrdersTotal() - 1; i >= 0; i--)
        {
         ulong ticket = OrderGetTicket(i);
         if(ticket == 0 || !OrderSelect(ticket))
            continue;
         if(!IsOurs())
            continue;
         if((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) != type)
            continue;
         if(MathAbs(OrderGetDouble(ORDER_PRICE_OPEN) - price) < m_min_spacing)
            return(true);
        }
      return(false);
     }

   //--- Cheapest order to give up when the per-side cap is exceeded:
   //--- the buy stop furthest above price, or the sell stop furthest below.
   void              TrimToCap(const ENUM_ORDER_TYPE type)
     {
      while(Count(type) > m_max_per_side)
        {
         ulong  worst_ticket = 0;
         double worst_price  = (type == ORDER_TYPE_BUY_STOP ? 0.0 : DBL_MAX);

         for(int i = OrdersTotal() - 1; i >= 0; i--)
           {
            ulong ticket = OrderGetTicket(i);
            if(ticket == 0 || !OrderSelect(ticket))
               continue;
            if(!IsOurs())
               continue;
            if((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) != type)
               continue;

            double price = OrderGetDouble(ORDER_PRICE_OPEN);
            if(type == ORDER_TYPE_BUY_STOP ? (price > worst_price) : (price < worst_price))
              {
               worst_price  = price;
               worst_ticket = ticket;
              }
           }

         if(worst_ticket == 0)
            break;

         if(!m_trade.OrderDelete(worst_ticket))
            break;

         PrintFormat("Pending cap reached, removed #%I64u at %.*f",
                     worst_ticket, (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS), worst_price);
        }
     }

   //--- Place a stop order. Returns the ticket, or 0 when nothing was sent.
   ulong             PlaceStop(const ENUM_ORDER_TYPE type, const double price,
                               const double volume, const double sl, const double tp)
     {
      if(volume <= 0.0 || price <= 0.0)
         return(0);

      if(HasNear(type, price))
         return(0);

      if(Count(type) >= m_max_per_side)
         return(0);

      double min_distance = GTP_MinStopDistance(m_symbol);
      double ask = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(m_symbol, SYMBOL_BID);

      if(type == ORDER_TYPE_BUY_STOP && price <= ask + min_distance)
         return(0);
      if(type == ORDER_TYPE_SELL_STOP && price >= bid - min_distance)
         return(0);

      bool ok = (type == ORDER_TYPE_BUY_STOP)
                ? m_trade.BuyStop(volume, price, m_symbol, sl, tp, ORDER_TIME_GTC, 0, m_comment)
                : m_trade.SellStop(volume, price, m_symbol, sl, tp, ORDER_TIME_GTC, 0, m_comment);

      if(!ok)
        {
         PrintFormat("Stop order rejected - retcode %d (%s)",
                     m_trade.ResultRetcode(), m_trade.ResultRetcodeDescription());
         return(0);
        }

      return(m_trade.ResultOrder());
     }

   //--- Delete orders that have rested longer than the virtual expiry.
   void              ExpireOld(void)
     {
      if(m_expiry_seconds <= 0)
         return;

      datetime now = TimeCurrent();
      for(int i = OrdersTotal() - 1; i >= 0; i--)
        {
         ulong ticket = OrderGetTicket(i);
         if(ticket == 0 || !OrderSelect(ticket))
            continue;
         if(!IsOurs())
            continue;

         ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
         if(type != ORDER_TYPE_BUY_STOP && type != ORDER_TYPE_SELL_STOP)
            continue;

         datetime setup = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
         if(now - setup < m_expiry_seconds)
            continue;

         if(m_trade.OrderDelete(ticket))
            PrintFormat("Pending #%I64u expired after %d hours", ticket, m_expiry_seconds / 3600);
        }
     }

   //--- Pull every resting order off the book, remembering it for later.
   int               ParkAll(void)
     {
      int parked = 0;
      for(int i = OrdersTotal() - 1; i >= 0; i--)
        {
         ulong ticket = OrderGetTicket(i);
         if(ticket == 0 || !OrderSelect(ticket))
            continue;
         if(!IsOurs())
            continue;

         ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
         if(type != ORDER_TYPE_BUY_STOP && type != ORDER_TYPE_SELL_STOP)
            continue;

         SParkedOrder rec;
         rec.type   = type;
         rec.price  = OrderGetDouble(ORDER_PRICE_OPEN);
         rec.volume = OrderGetDouble(ORDER_VOLUME_CURRENT);
         rec.sl     = OrderGetDouble(ORDER_SL);
         rec.tp     = OrderGetDouble(ORDER_TP);

         if(!m_trade.OrderDelete(ticket))
            continue;

         int size = ArraySize(m_parked);
         ArrayResize(m_parked, size + 1);
         m_parked[size] = rec;
         parked++;
        }

      if(parked > 0)
         PrintFormat("Parked %d pending order(s) while conditions are unusable", parked);

      return(parked);
     }

   bool              HasParked(void) const { return(ArraySize(m_parked) > 0); }

   //--- Put the parked orders back, skipping any the market has since passed.
   void              RestoreParked(void)
     {
      if(ArraySize(m_parked) == 0)
         return;

      for(int i = ArraySize(m_parked) - 1; i >= 0; i--)
        {
         ulong ticket = PlaceStop(m_parked[i].type, m_parked[i].price,
                                  m_parked[i].volume, m_parked[i].sl, m_parked[i].tp);
         if(ticket != 0)
            PrintFormat("Restored parked %s at %.*f",
                        (m_parked[i].type == ORDER_TYPE_BUY_STOP ? "buy stop" : "sell stop"),
                        (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS), m_parked[i].price);
        }

      ArrayResize(m_parked, 0);
     }

   void              DropParked(void) { ArrayResize(m_parked, 0); }

   //--- Re-issue resting orders whose volume no longer matches the target.
   void              RefreshVolume(const double target_volume)
     {
      if(target_volume <= 0.0)
         return;

      double step = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_STEP);
      if(step <= 0.0)
         step = 0.01;

      for(int i = OrdersTotal() - 1; i >= 0; i--)
        {
         ulong ticket = OrderGetTicket(i);
         if(ticket == 0 || !OrderSelect(ticket))
            continue;
         if(!IsOurs())
            continue;

         ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
         if(type != ORDER_TYPE_BUY_STOP && type != ORDER_TYPE_SELL_STOP)
            continue;

         double volume = OrderGetDouble(ORDER_VOLUME_CURRENT);
         if(MathAbs(volume - target_volume) < step / 2.0)
            continue;

         double price = OrderGetDouble(ORDER_PRICE_OPEN);
         double sl    = OrderGetDouble(ORDER_SL);
         double tp    = OrderGetDouble(ORDER_TP);

         if(!m_trade.OrderDelete(ticket))
            continue;

         if(PlaceStop(type, price, target_volume, sl, tp) != 0)
            PrintFormat("Resized pending at %.*f from %.2f to %.2f lots",
                        (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS), price, volume, target_volume);
        }
     }

   //--- Remove every resting order (session close, weekend, shutdown).
   void              DeleteAll(void)
     {
      for(int i = OrdersTotal() - 1; i >= 0; i--)
        {
         ulong ticket = OrderGetTicket(i);
         if(ticket == 0 || !OrderSelect(ticket))
            continue;
         if(!IsOurs())
            continue;

         ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
         if(type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_SELL_STOP)
            m_trade.OrderDelete(ticket);
        }
     }
  };
//+------------------------------------------------------------------+
