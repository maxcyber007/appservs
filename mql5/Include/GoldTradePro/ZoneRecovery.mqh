//+------------------------------------------------------------------+
//|                                                 ZoneRecovery.mqh |
//|            Hedged zone recovery for a losing base position        |
//+------------------------------------------------------------------+
//| WHAT THIS DOES, AND WHAT IT COSTS                                 |
//|                                                                   |
//| When a base position moves against the EA, instead of taking the  |
//| loss the module opens a larger position in the opposite direction |
//| at the far edge of a price "zone", then flips again each time     |
//| price crosses the zone, each leg larger than the last. Whichever  |
//| way price finally breaks out, the newest and largest leg carries  |
//| the basket into profit and everything closes together.            |
//|                                                                   |
//| This converts a small certain loss into a large uncertain one.    |
//| Exposure grows geometrically while price stays inside the zone,   |
//| and the strategy only fails once - when price runs far enough in  |
//| one direction that the account cannot fund the next leg.          |
//|                                                                   |
//| Engaging a basket REMOVES THE STOP LOSS from the base position:   |
//| a stop firing mid-recovery would close the hedged leg and leave   |
//| the rest of the basket naked. From that moment the basket's only  |
//| risk control is the maximum-loss setting, so set it deliberately. |
//|                                                                   |
//| Requires a HEDGING account. On netting, opposite legs cancel out  |
//| and the basket cannot exist.                                      |
//+------------------------------------------------------------------+
#property copyright "Gold Trade Pro EA"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>
#include <GoldTradePro/Utils.mqh>

//--- How each recovery leg is sized relative to the base position.
enum ENUM_GTP_ZONE_VOLUME
  {
   GTP_ZONE_VOL_MULTIPLY = 0, // Geometric: base x factor^level
   GTP_ZONE_VOL_ADD = 1,      // Linear: base x (level + 1)
   GTP_ZONE_VOL_FIXED = 2     // Every leg the same: base x factor
  };

//--- What happens when the level cap is reached.
enum ENUM_GTP_ZONE_MAXACTION
  {
   GTP_ZONE_MAX_FREEZE = 0, // Add no more legs, let the basket run
   GTP_ZONE_MAX_CLOSE = 1   // Close the whole basket at its current loss
  };

//--- Snapshot of one basket, rebuilt from live positions on each pass.
struct SZoneBasket
  {
   ulong             base_ticket;
   bool              base_is_buy;
   double            base_open;
   double            base_volume;
   int               levels;        // recovery legs currently open
   double            total_volume;
   double            profit;        // basket profit incl. swap, account currency
   bool              last_is_buy;   // direction of the newest leg
  };

//+------------------------------------------------------------------+
class CZoneRecovery
  {
private:
   string            m_symbol;
   long              m_base_magic;
   long              m_recovery_magic;
   CTrade           *m_trade;
   string            m_prefix;
   int               m_digits;

   double            m_zone_size;      // price distance from entry to the far edge
   double            m_zone_shrink;    // the zone narrows by this much per level
   double            m_zone_min;       // never narrower than this

   ENUM_GTP_ZONE_VOLUME m_vol_mode;
   double            m_vol_factor;
   double            m_max_lot;
   double            m_max_total_lots;

   int               m_max_levels;
   ENUM_GTP_ZONE_MAXACTION m_max_action;
   double            m_target_money;
   bool              m_use_max_loss;
   double            m_max_loss_money;
   double            m_min_free_margin_pct;

   bool              m_frozen_logged;

   string            Tag(const ulong base_ticket) const
     {
      return(m_prefix + IntegerToString((long)base_ticket));
     }

   bool              IsBasePosition(void) const
     {
      return(PositionGetString(POSITION_SYMBOL) == m_symbol &&
             (long)PositionGetInteger(POSITION_MAGIC) == m_base_magic);
     }

   bool              IsRecoveryPosition(void) const
     {
      return(PositionGetString(POSITION_SYMBOL) == m_symbol &&
             (long)PositionGetInteger(POSITION_MAGIC) == m_recovery_magic);
     }

   //--- Money value of a position, the way the basket target counts it.
   double            PositionValue(void) const
     {
      return(PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP));
     }

public:
                     CZoneRecovery(void)
      : m_symbol(""), m_base_magic(0), m_recovery_magic(0), m_trade(NULL),
        m_prefix("ZR"), m_digits(0),
        m_zone_size(0.0), m_zone_shrink(0.0), m_zone_min(0.0),
        m_vol_mode(GTP_ZONE_VOL_MULTIPLY), m_vol_factor(1.5),
        m_max_lot(1.0), m_max_total_lots(5.0),
        m_max_levels(6), m_max_action(GTP_ZONE_MAX_FREEZE),
        m_target_money(0.0), m_use_max_loss(true), m_max_loss_money(0.0),
        m_min_free_margin_pct(30.0), m_frozen_logged(false) {}

   void              Configure(const string symbol, const long base_magic,
                               const long recovery_magic, CTrade *trade,
                               const string prefix)
     {
      m_symbol         = symbol;
      m_base_magic     = base_magic;
      m_recovery_magic = recovery_magic;
      m_trade          = trade;
      m_prefix         = prefix;
      m_digits         = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
     }

   void              SetZone(const double size, const double shrink, const double minimum)
     {
      m_zone_size   = size;
      m_zone_shrink = (shrink >= 0.0 ? shrink : 0.0);
      m_zone_min    = (minimum > 0.0 ? minimum : size);
     }

   void              SetVolume(const ENUM_GTP_ZONE_VOLUME mode, const double factor,
                               const double max_lot, const double max_total_lots)
     {
      m_vol_mode       = mode;
      m_vol_factor     = (factor > 0.0 ? factor : 1.0);
      m_max_lot        = max_lot;
      m_max_total_lots = max_total_lots;
     }

   void              SetLimits(const int max_levels, const ENUM_GTP_ZONE_MAXACTION action,
                               const double target_money, const bool use_max_loss,
                               const double max_loss_money, const double min_free_margin_pct)
     {
      m_max_levels          = (max_levels > 0 ? max_levels : 1);
      m_max_action          = action;
      m_target_money        = target_money;
      m_use_max_loss        = use_max_loss;
      m_max_loss_money      = MathAbs(max_loss_money);
      m_min_free_margin_pct = min_free_margin_pct;
     }

   //--- Zone width at the current level; it narrows as exposure grows, so
   //--- a smaller move is needed to bring the basket back to the target.
   double            ZoneAt(const int levels) const
     {
      double zone = m_zone_size - levels * m_zone_shrink;
      return(MathMax(zone, m_zone_min));
     }

   //--- Rebuild one basket from the live positions.
   bool              Collect(const ulong base_ticket, SZoneBasket &basket)
     {
      if(!PositionSelectByTicket(base_ticket))
         return(false);

      basket.base_ticket  = base_ticket;
      basket.base_is_buy  = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      basket.base_open    = PositionGetDouble(POSITION_PRICE_OPEN);
      basket.base_volume  = PositionGetDouble(POSITION_VOLUME);
      basket.total_volume = basket.base_volume;
      basket.profit       = PositionValue();
      basket.levels       = 0;
      basket.last_is_buy  = basket.base_is_buy;

      string   tag       = Tag(base_ticket);
      datetime newest    = 0;

      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0)
            continue;
         if(!IsRecoveryPosition())
            continue;
         if(PositionGetString(POSITION_COMMENT) != tag)
            continue;

         basket.levels++;
         basket.total_volume += PositionGetDouble(POSITION_VOLUME);
         basket.profit       += PositionValue();

         datetime opened = (datetime)PositionGetInteger(POSITION_TIME);
         if(opened >= newest)
           {
            newest = opened;
            basket.last_is_buy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
           }
        }

      return(true);
     }

   //--- Base tickets whose basket has engaged. These positions belong to
   //--- this module now and must be excluded from ordinary stop handling.
   void              ActiveBaseTickets(ulong &out[])
     {
      ArrayResize(out, 0);

      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !IsBasePosition())
            continue;

         SZoneBasket basket;
         if(!Collect(ticket, basket) || basket.levels == 0)
            continue;

         int size = ArraySize(out);
         ArrayResize(out, size + 1);
         out[size] = ticket;
        }
     }

   int               ActiveBasketCount(void)
     {
      ulong tickets[];
      ActiveBaseTickets(tickets);
      return(ArraySize(tickets));
     }

   //--- Deepest basket and its money value, for the status panel.
   void              Summary(int &deepest_levels, double &worst_profit, double &total_lots)
     {
      deepest_levels = 0;
      worst_profit   = 0.0;
      total_lots     = 0.0;

      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !IsBasePosition())
            continue;

         SZoneBasket basket;
         if(!Collect(ticket, basket) || basket.levels == 0)
            continue;

         if(basket.levels > deepest_levels)
            deepest_levels = basket.levels;
         if(basket.profit < worst_profit)
            worst_profit = basket.profit;
         total_lots += basket.total_volume;
        }
     }

   //--- Volume of the next leg, 0 when a cap forbids it.
   double            NextVolume(const SZoneBasket &basket)
     {
      int    level  = basket.levels + 1;
      double volume = 0.0;

      switch(m_vol_mode)
        {
         case GTP_ZONE_VOL_MULTIPLY:
            volume = basket.base_volume * MathPow(m_vol_factor, level);
            break;
         case GTP_ZONE_VOL_ADD:
            volume = basket.base_volume * (level + 1);
            break;
         case GTP_ZONE_VOL_FIXED:
         default:
            volume = basket.base_volume * m_vol_factor;
            break;
        }

      volume = GTP_NormalizeLots(m_symbol, volume);

      if(m_max_lot > 0.0 && volume > m_max_lot)
         volume = GTP_NormalizeLots(m_symbol, m_max_lot);

      if(m_max_total_lots > 0.0 && basket.total_volume + volume > m_max_total_lots)
         return(0.0);

      double min_lot = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MIN);
      if(volume < min_lot)
         return(0.0);

      return(volume);
     }

   //--- Close every leg of a basket, recovery legs first.
   void              CloseBasket(const ulong base_ticket, const string why)
     {
      string tag = Tag(base_ticket);

      for(int pass = 0; pass < 3; pass++)   // retries: closing changes the index set
        {
         bool any = false;

         for(int i = PositionsTotal() - 1; i >= 0; i--)
           {
            ulong ticket = PositionGetTicket(i);
            if(ticket == 0)
               continue;
            if(!IsRecoveryPosition())
               continue;
            if(PositionGetString(POSITION_COMMENT) != tag)
               continue;

            any = true;
            if(!m_trade.PositionClose(ticket))
               PrintFormat("Zone: could not close recovery leg #%I64u - retcode %d (%s)",
                           ticket, m_trade.ResultRetcode(), m_trade.ResultRetcodeDescription());
           }

         if(!any)
            break;
        }

      if(PositionSelectByTicket(base_ticket))
         if(!m_trade.PositionClose(base_ticket))
            PrintFormat("Zone: could not close base #%I64u - retcode %d (%s)",
                        base_ticket, m_trade.ResultRetcode(), m_trade.ResultRetcodeDescription());

      PrintFormat("Zone: basket %I64u closed - %s", base_ticket, why);
     }

   //--- Recovery legs whose base position no longer exists.
   void              CloseOrphans(void)
     {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !IsRecoveryPosition())
            continue;

         string comment = PositionGetString(POSITION_COMMENT);
         if(StringFind(comment, m_prefix) != 0)
            continue;

         string  parent_text = StringSubstr(comment, StringLen(m_prefix));
         ulong   parent      = (ulong)StringToInteger(parent_text);

         if(parent != 0 && PositionSelectByTicket(parent))
            continue;

         PrintFormat("Zone: closing orphaned recovery leg #%I64u (base %I64u is gone)",
                     ticket, parent);
         m_trade.PositionClose(ticket);
        }
     }

   //--- Open the next leg of a basket.
   bool              OpenLeg(const SZoneBasket &basket, const bool buy, const double volume)
     {
      if(volume <= 0.0)
         return(false);

      //--- Refuse to add exposure the account cannot carry.
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double free_margin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      if(equity > 0.0 && m_min_free_margin_pct > 0.0 &&
         free_margin / equity * 100.0 < m_min_free_margin_pct)
        {
         if(!m_frozen_logged)
           {
            PrintFormat("Zone: free margin %.1f%% of equity is below the %.1f%% floor, no new legs",
                        free_margin / equity * 100.0, m_min_free_margin_pct);
            m_frozen_logged = true;
           }
         return(false);
        }

      m_trade.SetExpertMagicNumber(m_recovery_magic);

      bool ok = buy
                ? m_trade.Buy(volume, m_symbol, 0.0, 0.0, 0.0, Tag(basket.base_ticket))
                : m_trade.Sell(volume, m_symbol, 0.0, 0.0, 0.0, Tag(basket.base_ticket));

      m_trade.SetExpertMagicNumber(m_base_magic);

      if(!ok)
        {
         PrintFormat("Zone: leg %d rejected - retcode %d (%s)",
                     basket.levels + 1, m_trade.ResultRetcode(),
                     m_trade.ResultRetcodeDescription());
         return(false);
        }

      m_frozen_logged = false;

      PrintFormat("Zone: basket %I64u leg %d - %s %.2f lots (total %.2f, P/L %.2f)",
                  basket.base_ticket, basket.levels + 1, (buy ? "BUY" : "SELL"),
                  volume, basket.total_volume + volume, basket.profit);
      return(true);
     }

   //--- Strip the stop and target from the base position when the basket
   //--- engages: a stop firing mid-recovery would break the hedge.
   void              ReleaseBaseStops(const ulong base_ticket)
     {
      if(!PositionSelectByTicket(base_ticket))
         return;

      if(PositionGetDouble(POSITION_SL) == 0.0 && PositionGetDouble(POSITION_TP) == 0.0)
         return;

      if(m_trade.PositionModify(base_ticket, 0.0, 0.0))
         PrintFormat("Zone: removed the stop and target of base #%I64u, the basket target governs it now",
                     base_ticket);
     }

   //--- Called on every tick.
   void              Manage(void)
     {
      if(m_zone_size <= 0.0)
         return;

      CloseOrphans();

      double ask = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(m_symbol, SYMBOL_BID);
      if(ask <= 0.0 || bid <= 0.0)
         return;

      //--- Snapshot the base tickets first: opening or closing legs inside
      //--- the loop would invalidate the position indices being walked.
      ulong bases[];
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !IsBasePosition())
            continue;
         int size = ArraySize(bases);
         ArrayResize(bases, size + 1);
         bases[size] = ticket;
        }

      for(int b = 0; b < ArraySize(bases); b++)
        {
         SZoneBasket basket;
         if(!Collect(bases[b], basket))
            continue;

         //--- Exits are evaluated before any new leg is considered.
         if(basket.levels > 0)
           {
            if(m_target_money > 0.0 && basket.profit >= m_target_money)
              {
               CloseBasket(basket.base_ticket,
                           StringFormat("target reached at %.2f", basket.profit));
               continue;
              }

            if(m_use_max_loss && m_max_loss_money > 0.0 && basket.profit <= -m_max_loss_money)
              {
               CloseBasket(basket.base_ticket,
                           StringFormat("maximum basket loss hit at %.2f", basket.profit));
               continue;
              }

            if(basket.levels >= m_max_levels && m_max_action == GTP_ZONE_MAX_CLOSE)
              {
               CloseBasket(basket.base_ticket,
                           StringFormat("level cap %d reached, P/L %.2f",
                                        m_max_levels, basket.profit));
               continue;
              }
           }

         if(basket.levels >= m_max_levels)
            continue;   // frozen: no more legs, the exits above still apply

         //--- Zone boundaries. The entry price is always one edge; the far
         //--- edge sits a zone width away on the losing side and closes in
         //--- as levels accumulate.
         double zone  = ZoneAt(basket.levels);
         double upper = basket.base_is_buy ? basket.base_open : basket.base_open + zone;
         double lower = basket.base_is_buy ? basket.base_open - zone : basket.base_open;

         bool   want_buy = !basket.last_is_buy;   // always flip the direction
         double trigger  = want_buy ? upper : lower;
         bool   reached  = want_buy ? (ask >= trigger) : (bid <= trigger);

         if(!reached)
            continue;

         double volume = NextVolume(basket);
         if(volume <= 0.0)
           {
            if(!m_frozen_logged)
              {
               PrintFormat("Zone: basket %I64u frozen at %.2f lots, a cap forbids the next leg",
                           basket.base_ticket, basket.total_volume);
               m_frozen_logged = true;
              }
            continue;
           }

         //--- First leg: hand the base position over to the basket.
         if(basket.levels == 0)
            ReleaseBaseStops(basket.base_ticket);

         OpenLeg(basket, want_buy, volume);
        }
     }
  };
//+------------------------------------------------------------------+
