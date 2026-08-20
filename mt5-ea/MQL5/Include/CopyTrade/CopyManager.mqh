//+------------------------------------------------------------------+
//|                                                 CopyManager.mqh |
//|  Core copy-trade logic: CMasterEngine publishes a full snapshot   |
//|  of the DEMO account on every trade event + every timer tick.     |
//|  CSlaveEngine reconciles the REAL account against that snapshot,  |
//|  identifying already-copied trades purely from live MT5 state     |
//|  (Magic Number + Comment tag) - never from a separate state file  |
//|  that could drift out of sync.                                    |
//+------------------------------------------------------------------+
#ifndef __CT_COPYMANAGER_MQH__
#define __CT_COPYMANAGER_MQH__

#include "Logger.mqh"
#include "FileProtocol.mqh"
#include "SymbolMapper.mqh"
#include "AccountValidator.mqh"
#include "RiskManager.mqh"
#include "TradeManager.mqh"

enum ENUM_COPY_MODE
  {
   MODE_MASTER = 0,
   MODE_SLAVE  = 1
  };

enum ENUM_LOT_MODE
  {
   LOT_FIXED         = 0,
   LOT_MULTIPLIER    = 1,
   LOT_BALANCE_RATIO = 2,
   LOT_EQUITY_RATIO  = 3
  };

enum ENUM_SLTP_MODE
  {
   SLTP_MODE_NONE     = 0,
   SLTP_MODE_COPY     = 1,
   SLTP_MODE_DISTANCE = 2
  };

//+------------------------------------------------------------------+
//| small string-array helper                                        |
//+------------------------------------------------------------------+
int CT_FindIndex(const string &arr[], const string value)
  {
   for(int i = 0; i < ArraySize(arr); i++)
      if(arr[i] == value)
         return i;
   return -1;
  }

bool CT_ParseCopyIdFromComment(const string comment, string &copy_id)
  {
   string parts[];
   if(StringSplit(comment, '|', parts) != 3)
      return false;
   if(parts[0] != "COPY")
      return false;
   copy_id = parts[1] + "_" + parts[2];
   return true;
  }

//+------------------------------------------------------------------+
//| MASTER ENGINE                                                    |
//+------------------------------------------------------------------+
class CMasterEngine
  {
private:
   string            m_password_hash;
   datetime          m_last_trade_time;
   bool              m_enabled;
   long              m_cache_position_id[];
   long              m_cache_order_id[];

   long              FindCachedOrder(const long position_id)
     {
      for(int i = 0; i < ArraySize(m_cache_position_id); i++)
         if(m_cache_position_id[i] == position_id)
            return m_cache_order_id[i];
      return -1;
     }

   void              StoreCachedOrder(const long position_id, const long order_id)
     {
      int sz = ArraySize(m_cache_position_id);
      ArrayResize(m_cache_position_id, sz + 1);
      ArrayResize(m_cache_order_id, sz + 1);
      m_cache_position_id[sz] = position_id;
      m_cache_order_id[sz]    = order_id;
     }

   //--- if this position was opened by a pending order triggering, return
   //--- that order's ticket so the SLAVE can map it back to its own
   //--- pending-order copy instead of opening a duplicate market position
   long              ResolveOriginatingOrder(const long position_id, const datetime time_open)
     {
      long cached = FindCachedOrder(position_id);
      if(cached >= 0)
         return cached;

      long result = 0;
      if(HistorySelect(time_open - 5, time_open + 5))
        {
         int total = HistoryDealsTotal();
         for(int i = 0; i < total; i++)
           {
            ulong deal_ticket = HistoryDealGetTicket(i);
            if(deal_ticket == 0)
               continue;
            if((long)HistoryDealGetInteger(deal_ticket, DEAL_POSITION_ID) != position_id)
               continue;
            if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal_ticket, DEAL_ENTRY) != DEAL_ENTRY_IN)
               continue;

            long order_ticket = (long)HistoryDealGetInteger(deal_ticket, DEAL_ORDER);
            if(order_ticket > 0 && HistoryOrderSelect(order_ticket))
              {
               ENUM_ORDER_TYPE otype = (ENUM_ORDER_TYPE)HistoryOrderGetInteger(order_ticket, ORDER_TYPE);
               if(otype != ORDER_TYPE_BUY && otype != ORDER_TYPE_SELL)
                  result = order_ticket; // only pending-type orders count as "origin"
              }
            break;
           }
        }
      StoreCachedOrder(position_id, result);
      return result;
     }

public:
   void              Init(const string copy_password, const bool require_demo)
     {
      m_password_hash   = CT_HashPassword(copy_password);
      m_last_trade_time = 0;
      m_enabled         = true;

      string err;
      if(!CAccountValidator::ValidateMaster(require_demo, err))
        {
         g_logger.Error(err);
         m_enabled = false;
         return;
        }

      g_logger.Info(StringFormat("MASTER initialized. login=%d server=%s type=%s",
                     (int)AccountInfoInteger(ACCOUNT_LOGIN), AccountInfoString(ACCOUNT_SERVER),
                     CAccountValidator::TradeModeToString((int)AccountInfoInteger(ACCOUNT_TRADE_MODE))));
     }

   bool              IsEnabled() { return m_enabled; }

   void              BuildSnapshot(MasterSnapshot &snap)
     {
      snap.version             = CT_PROTOCOL_VERSION;
      snap.master_login        = (long)AccountInfoInteger(ACCOUNT_LOGIN);
      snap.master_server       = AccountInfoString(ACCOUNT_SERVER);
      snap.account_trade_mode  = (int)AccountInfoInteger(ACCOUNT_TRADE_MODE);
      snap.account_margin_mode = (int)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
      snap.timestamp           = TimeCurrent();
      snap.balance             = AccountInfoDouble(ACCOUNT_BALANCE);
      snap.equity              = AccountInfoDouble(ACCOUNT_EQUITY);
      snap.margin              = AccountInfoDouble(ACCOUNT_MARGIN);
      snap.free_margin         = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      snap.currency            = AccountInfoString(ACCOUNT_CURRENCY);
      snap.leverage            = (int)AccountInfoInteger(ACCOUNT_LEVERAGE);
      snap.password_hash       = m_password_hash;

      ArrayResize(snap.positions, 0);
      int pn = 0;
      int total_pos = PositionsTotal();
      for(int i = 0; i < total_pos; i++)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0)
            continue;

         long     posid = (long)PositionGetInteger(POSITION_IDENTIFIER);
         datetime topen  = (datetime)PositionGetInteger(POSITION_TIME);

         ArrayResize(snap.positions, pn + 1);
         snap.positions[pn].copy_id         = CT_BuildPositionCopyId(snap.master_login, posid);
         snap.positions[pn].position_id     = posid;
         snap.positions[pn].symbol          = PositionGetString(POSITION_SYMBOL);
         snap.positions[pn].type            = (int)PositionGetInteger(POSITION_TYPE);
         snap.positions[pn].volume          = PositionGetDouble(POSITION_VOLUME);
         snap.positions[pn].price_open      = PositionGetDouble(POSITION_PRICE_OPEN);
         snap.positions[pn].sl              = PositionGetDouble(POSITION_SL);
         snap.positions[pn].tp              = PositionGetDouble(POSITION_TP);
         snap.positions[pn].magic           = (long)PositionGetInteger(POSITION_MAGIC);
         snap.positions[pn].comment         = PositionGetString(POSITION_COMMENT);
         snap.positions[pn].time_open       = topen;
         snap.positions[pn].source_order_id = ResolveOriginatingOrder(posid, topen);
         pn++;
        }

      ArrayResize(snap.orders, 0);
      int on = 0;
      int total_ord = OrdersTotal();
      for(int i = 0; i < total_ord; i++)
        {
         ulong ticket = OrderGetTicket(i);
         if(ticket == 0)
            continue;

         string ord_symbol = OrderGetString(ORDER_SYMBOL);
         ENUM_ORDER_TYPE otype = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
         bool is_buy_side = (otype == ORDER_TYPE_BUY_LIMIT || otype == ORDER_TYPE_BUY_STOP || otype == ORDER_TYPE_BUY_STOP_LIMIT);

         double market_ref = 0;
         MqlTick tick;
         if(SymbolInfoTick(ord_symbol, tick))
            market_ref = is_buy_side ? tick.ask : tick.bid;

         ArrayResize(snap.orders, on + 1);
         snap.orders[on].copy_id          = CT_BuildOrderCopyId(snap.master_login, (long)ticket);
         snap.orders[on].order_id         = (long)ticket;
         snap.orders[on].symbol           = ord_symbol;
         snap.orders[on].type             = (int)otype;
         snap.orders[on].volume           = OrderGetDouble(ORDER_VOLUME_CURRENT);
         snap.orders[on].price_open       = OrderGetDouble(ORDER_PRICE_OPEN);
         snap.orders[on].price_stoplimit  = OrderGetDouble(ORDER_PRICE_STOPLIMIT);
         snap.orders[on].sl               = OrderGetDouble(ORDER_SL);
         snap.orders[on].tp               = OrderGetDouble(ORDER_TP);
         snap.orders[on].magic            = (long)OrderGetInteger(ORDER_MAGIC);
         snap.orders[on].comment          = OrderGetString(ORDER_COMMENT);
         snap.orders[on].expiration       = (datetime)OrderGetInteger(ORDER_TIME_EXPIRATION);
         snap.orders[on].market_price_ref = market_ref;
         on++;
        }
     }

   void              PublishSnapshot()
     {
      if(!m_enabled)
         return;
      MasterSnapshot snap;
      BuildSnapshot(snap);
      string err;
      if(!CT_WriteMasterSnapshot(snap, err))
         g_logger.Error("Failed to write master snapshot: " + err);
      else
         g_logger.Debug(StringFormat("Snapshot published. positions=%d orders=%d", ArraySize(snap.positions), ArraySize(snap.orders)));
     }

   void              PublishHeartbeat()
     {
      if(!m_enabled)
         return;
      MasterHeartbeat hb;
      hb.version         = CT_PROTOCOL_VERSION;
      hb.login           = (long)AccountInfoInteger(ACCOUNT_LOGIN);
      hb.server          = AccountInfoString(ACCOUNT_SERVER);
      hb.timestamp       = TimeCurrent();
      hb.balance         = AccountInfoDouble(ACCOUNT_BALANCE);
      hb.equity          = AccountInfoDouble(ACCOUNT_EQUITY);
      hb.last_trade_time = m_last_trade_time;
      hb.password_hash   = m_password_hash;

      string err;
      if(!CT_WriteHeartbeat(hb, err))
         g_logger.Error("Failed to write heartbeat: " + err);
     }

   void              OnTradeTransactionEvent(const MqlTradeTransaction &trans)
     {
      if(!m_enabled)
         return;

      switch(trans.type)
        {
         case TRADE_TRANSACTION_DEAL_ADD:
            m_last_trade_time = TimeCurrent();
            g_logger.Info(StringFormat("Master deal added: deal=%d symbol=%s", (int)trans.deal, trans.symbol));
            break;
         case TRADE_TRANSACTION_ORDER_ADD:
            g_logger.Info(StringFormat("Master pending order added: order=%d symbol=%s", (int)trans.order, trans.symbol));
            break;
         case TRADE_TRANSACTION_ORDER_UPDATE:
            g_logger.Debug(StringFormat("Master pending order updated: order=%d", (int)trans.order));
            break;
         case TRADE_TRANSACTION_ORDER_DELETE:
            g_logger.Info(StringFormat("Master pending order removed: order=%d", (int)trans.order));
            break;
         case TRADE_TRANSACTION_POSITION:
            g_logger.Debug(StringFormat("Master position changed: symbol=%s", trans.symbol));
            break;
         default:
            break;
        }

      PublishSnapshot();
     }

   void              OnTimerTick()
     {
      if(!m_enabled)
         return;
      PublishSnapshot();
      PublishHeartbeat();
     }
  };

//+------------------------------------------------------------------+
//| SLAVE ENGINE configuration                                       |
//+------------------------------------------------------------------+
struct CT_SlaveConfig
  {
   long              magic;
   ENUM_LOT_MODE     lot_mode;
   double            fixed_lot;
   double            lot_multiplier;
   bool              auto_symbol_mapping;
   string            symbol_prefix;
   string            symbol_suffix;
   string            manual_symbol_mapping;
   int               max_deviation_points;
   ENUM_SLTP_MODE    sltp_mode;
   bool              copy_sl;
   bool              copy_tp;
   int               sl_distance_points;
   int               tp_distance_points;
   bool              enable_pending_orders;
   double            max_daily_loss_pct;
   double            max_equity_dd_pct;
   int               max_open_positions;
   double            max_total_lots;
   bool              enable_spread_filter;
   int               max_spread_points;
   int               master_timeout_seconds;
   bool              close_when_offline;
   bool              emergency_close_all;
   bool              require_real_account;
   string            copy_password;
   bool              copy_delayed_trades;
   int               max_retry_count;
   int               retry_delay_ms;
   bool              test_mode;
   bool              dry_run;
  };

//+------------------------------------------------------------------+
//| SLAVE ENGINE                                                      |
//+------------------------------------------------------------------+
class CSlaveEngine
  {
private:
   CT_SlaveConfig    m_cfg;
   CSymbolMapper     m_mapper;
   CTradeExecutor    m_trade;
   CRiskManager      m_risk;
   string            m_password_hash;
   bool              m_require_password;
   bool              m_enabled;
   bool              m_master_online;
   datetime          m_last_master_update;
   datetime          m_last_copy_time;
   long              m_copy_latency_ms;
   int               m_copy_success_count;
   int               m_copy_failed_count;
   MasterSnapshot    m_last_snapshot;
   bool              m_has_snapshot;
   bool              m_emergency_triggered;

   //--- persisted "never retry this copy_id" marker (spread filter, CopyDelayedTrades=false)
   bool              IsPermanentlySkipped(const string copy_id)
     {
      return GlobalVariableCheck("CT_SKIP_" + copy_id);
     }
   void              MarkPermanentlySkipped(const string copy_id)
     {
      GlobalVariableSet("CT_SKIP_" + copy_id, 1);
      g_logger.Warning("copy_id=" + copy_id + " permanently skipped (spread filter, CopyDelayedTrades=false)");
     }
   void              ClearSkipMarker(const string copy_id)
     {
      if(GlobalVariableCheck("CT_SKIP_" + copy_id))
         GlobalVariableDel("CT_SKIP_" + copy_id);
     }

   double            NormalizeLot(const string symbol, const double vol)
     {
      if(vol <= 0)
         return 0;
      double min_lot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
      double max_lot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
      double step    = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
      if(step <= 0)
         step = 0.01;

      double steps = MathFloor(vol / step + 0.0000001); // floor: never round the lot UP
      double norm  = steps * step;

      if(norm < min_lot)
         return 0; // below broker minimum - refuse rather than silently inflate the lot

      if(norm > max_lot)
        {
         g_logger.Warning(StringFormat("Lot capped to broker maximum %.2f (calculated %.4f) on %s", max_lot, vol, symbol));
         norm = max_lot;
        }

      int lot_digits = 2;
      if(step < 0.01)
         lot_digits = 3;
      if(step < 0.001)
         lot_digits = 4;
      return NormalizeDouble(norm, lot_digits);
     }

   double            CalculateLot(const double master_volume, const string slave_symbol, const MasterSnapshot &snap)
     {
      double raw;
      switch(m_cfg.lot_mode)
        {
         case LOT_FIXED:
            raw = m_cfg.fixed_lot;
            break;
         case LOT_MULTIPLIER:
            raw = master_volume * m_cfg.lot_multiplier;
            break;
         case LOT_BALANCE_RATIO:
            raw = (snap.balance > 0) ? master_volume * (AccountInfoDouble(ACCOUNT_BALANCE) / snap.balance) * m_cfg.lot_multiplier : 0;
            break;
         case LOT_EQUITY_RATIO:
            raw = (snap.equity > 0) ? master_volume * (AccountInfoDouble(ACCOUNT_EQUITY) / snap.equity) * m_cfg.lot_multiplier : 0;
            break;
         default:
            raw = master_volume;
        }
      return NormalizeLot(slave_symbol, raw);
     }

   //--- widen a stop just enough to satisfy the broker's minimum stop distance
   double            AdjustStopDistance(const string symbol, const double price, const double stop,
                                         const bool is_buy, const bool is_sl)
     {
      if(stop <= 0)
         return 0;
      double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
      long stops_level = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
      double min_dist = stops_level * point;
      if(min_dist <= 0)
         return stop;

      double dist = MathAbs(price - stop);
      if(dist >= min_dist)
         return stop;

      bool further_is_lower = (is_buy && is_sl) || (!is_buy && !is_sl);
      return further_is_lower ? (price - min_dist) : (price + min_dist);
     }

   void              ComputeSlaveSLTP(const CopyPositionRecord &mp, const string slave_symbol,
                                       const ENUM_ORDER_TYPE order_type, const double open_price,
                                       double &out_sl, double &out_tp)
     {
      out_sl = 0;
      out_tp = 0;
      if(m_cfg.sltp_mode == SLTP_MODE_NONE)
         return;

      int digits = (int)SymbolInfoInteger(slave_symbol, SYMBOL_DIGITS);
      double point = SymbolInfoDouble(slave_symbol, SYMBOL_POINT);
      bool is_buy = (order_type == ORDER_TYPE_BUY);

      if(m_cfg.sltp_mode == SLTP_MODE_COPY)
        {
         if(m_cfg.copy_sl && mp.sl > 0)
           {
            double dist = MathAbs(mp.price_open - mp.sl);
            out_sl = is_buy ? (open_price - dist) : (open_price + dist);
           }
         if(m_cfg.copy_tp && mp.tp > 0)
           {
            double dist = MathAbs(mp.tp - mp.price_open);
            out_tp = is_buy ? (open_price + dist) : (open_price - dist);
           }
        }
      else if(m_cfg.sltp_mode == SLTP_MODE_DISTANCE)
        {
         if(m_cfg.copy_sl && m_cfg.sl_distance_points > 0)
            out_sl = is_buy ? (open_price - m_cfg.sl_distance_points * point) : (open_price + m_cfg.sl_distance_points * point);
         if(m_cfg.copy_tp && m_cfg.tp_distance_points > 0)
            out_tp = is_buy ? (open_price + m_cfg.tp_distance_points * point) : (open_price - m_cfg.tp_distance_points * point);
        }

      out_sl = AdjustStopDistance(slave_symbol, open_price, out_sl, is_buy, true);
      out_tp = AdjustStopDistance(slave_symbol, open_price, out_tp, is_buy, false);

      if(out_sl > 0)
         out_sl = NormalizeDouble(out_sl, digits);
      if(out_tp > 0)
         out_tp = NormalizeDouble(out_tp, digits);
     }

   bool              MasterHasMatchingPosition(const MasterSnapshot &snap, const string managed_id)
     {
      for(int i = 0; i < ArraySize(snap.positions); i++)
        {
         if(snap.positions[i].copy_id == managed_id)
            return true;
         if(snap.positions[i].source_order_id != 0)
           {
            string derived = CT_BuildOrderCopyId(snap.master_login, snap.positions[i].source_order_id);
            if(derived == managed_id)
               return true;
           }
        }
      return false;
     }

   void              TryOpenCopy(const CopyPositionRecord &mp, const MasterSnapshot &snap)
     {
      string slave_symbol;
      if(!m_mapper.MapSymbol(mp.symbol, slave_symbol))
        {
         g_logger.Error(StringFormat("Symbol mapping failed for master symbol=%s - skipping copy_id=%s", mp.symbol, mp.copy_id));
         return;
        }

      long trade_mode = SYMBOL_TRADE_MODE_DISABLED;
      SymbolInfoInteger(slave_symbol, SYMBOL_TRADE_MODE, trade_mode);
      if(trade_mode == SYMBOL_TRADE_MODE_DISABLED)
        {
         g_logger.Warning(StringFormat("Trading disabled for %s - skipping copy_id=%s", slave_symbol, mp.copy_id));
         return;
        }
      if(trade_mode == SYMBOL_TRADE_MODE_CLOSEONLY)
        {
         g_logger.Warning(StringFormat("%s is close-only - skipping new open copy_id=%s", slave_symbol, mp.copy_id));
         return;
        }

      MqlTick tick;
      if(!SymbolInfoTick(slave_symbol, tick) || tick.bid <= 0 || tick.ask <= 0)
        {
         g_logger.Warning(StringFormat("No valid tick / market closed for %s - skipping copy_id=%s", slave_symbol, mp.copy_id));
         return;
        }

      if(m_cfg.enable_spread_filter && m_risk.IsSpreadTooHigh(slave_symbol))
        {
         g_logger.Warning(StringFormat("Spread too high on %s - copy_id=%s deferred", slave_symbol, mp.copy_id));
         if(!m_cfg.copy_delayed_trades)
            MarkPermanentlySkipped(mp.copy_id);
         return;
        }

      if(m_risk.IsNewTradeBlocked())
        {
         g_logger.Warning(StringFormat("Risk limit blocks new trades - copy_id=%s not opened", mp.copy_id));
         return;
        }
      if(m_risk.IsMaxPositionsExceeded())
        {
         g_logger.Warning(StringFormat("Max open positions reached - copy_id=%s not opened", mp.copy_id));
         return;
        }

      double lot = CalculateLot(mp.volume, slave_symbol, snap);
      if(lot <= 0)
        {
         g_logger.Warning(StringFormat("Calculated lot invalid/below broker minimum for %s - copy_id=%s not opened", slave_symbol, mp.copy_id));
         return;
        }
      if(m_risk.IsMaxTotalLotsExceeded(lot))
        {
         g_logger.Warning(StringFormat("Max total lots would be exceeded - copy_id=%s not opened", mp.copy_id));
         return;
        }

      ENUM_ORDER_TYPE order_type = (mp.type == POSITION_TYPE_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      double price = (order_type == ORDER_TYPE_BUY) ? tick.ask : tick.bid;

      double margin_required;
      if(OrderCalcMargin(order_type, slave_symbol, lot, price, margin_required))
        {
         double free_margin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
         if(margin_required > free_margin)
           {
            g_logger.Error(StringFormat("Insufficient margin for %s lot=%.2f required=%.2f free=%.2f - copy_id=%s",
                            slave_symbol, lot, margin_required, free_margin, mp.copy_id));
            return;
           }
        }

      double sl, tp;
      ComputeSlaveSLTP(mp, slave_symbol, order_type, price, sl, tp);

      string comment = StringFormat("COPY|%d|%d", snap.master_login, mp.position_id);
      ulong out_ticket;
      string err;

      g_logger.Info(StringFormat("Master detected %s %s %.2f | COPY_ID=%s", EnumToString(order_type), mp.symbol, mp.volume, mp.copy_id));
      g_logger.Info(StringFormat("Sending %s %s %.2f (mapped from %s)", EnumToString(order_type), slave_symbol, lot, mp.symbol));

      if(m_trade.OpenPosition(slave_symbol, order_type, lot, sl, tp, comment, out_ticket, err))
        {
         m_copy_success_count++;
         m_last_copy_time  = TimeCurrent();
         m_copy_latency_ms = (long)((TimeCurrent() - snap.timestamp) * 1000);
         g_logger.Trade(StringFormat("Ticket=%d Copy successful copy_id=%s", (int)out_ticket, mp.copy_id));
        }
      else
        {
         m_copy_failed_count++;
         g_logger.Error(StringFormat("Copy OPEN failed copy_id=%s symbol=%s: %s", mp.copy_id, slave_symbol, err));
        }
     }

   void              SyncExistingPosition(const ulong slave_ticket, const CopyPositionRecord &mp,
                                           const MasterSnapshot &snap, const double current_slave_volume)
     {
      if(!PositionSelectByTicket(slave_ticket))
         return;

      string slave_symbol = PositionGetString(POSITION_SYMBOL);
      double slave_open_price = PositionGetDouble(POSITION_PRICE_OPEN);
      ENUM_ORDER_TYPE order_type = (mp.type == POSITION_TYPE_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

      //--- proportional partial-close: recompute what the slave volume SHOULD
      //--- be right now for the master's CURRENT (already reduced) volume; if
      //--- that is less than what the slave still holds, close the difference.
      double target_volume = CalculateLot(mp.volume, slave_symbol, snap);
      if(target_volume < current_slave_volume - 0.0000001)
        {
         double close_volume = NormalizeLot(slave_symbol, current_slave_volume - target_volume);
         if(close_volume > 0 && close_volume < current_slave_volume)
           {
            string err;
            if(m_trade.ClosePosition(slave_ticket, close_volume, err))
              {
               g_logger.Info(StringFormat("Master partial close detected -> Slave partial close ticket=%d volume=%.2f copy_id=%s",
                              (int)slave_ticket, close_volume, mp.copy_id));
               m_copy_success_count++;
               m_last_copy_time = TimeCurrent();
              }
            else
              {
               m_copy_failed_count++;
               g_logger.Error(StringFormat("Partial close failed ticket=%d copy_id=%s: %s", (int)slave_ticket, mp.copy_id, err));
              }
           }
         else if(close_volume >= current_slave_volume)
           {
            // remaining target lot rounds to zero under broker step - close fully
            string err;
            if(m_trade.ClosePosition(slave_ticket, 0, err))
              {
               g_logger.Info(StringFormat("Master reduced below slave's minimum lot -> Slave full close ticket=%d copy_id=%s",
                              (int)slave_ticket, mp.copy_id));
               m_copy_success_count++;
               m_last_copy_time = TimeCurrent();
              }
           }
        }

      if(!PositionSelectByTicket(slave_ticket))
         return; // may have just been fully closed above

      double want_sl, want_tp;
      ComputeSlaveSLTP(mp, slave_symbol, order_type, slave_open_price, want_sl, want_tp);

      double cur_sl = PositionGetDouble(POSITION_SL);
      double cur_tp = PositionGetDouble(POSITION_TP);
      double point  = SymbolInfoDouble(slave_symbol, SYMBOL_POINT);

      bool sl_changed = MathAbs(want_sl - cur_sl) > point;
      bool tp_changed = MathAbs(want_tp - cur_tp) > point;

      if(sl_changed || tp_changed)
        {
         string err;
         if(m_trade.ModifyPosition(slave_ticket, want_sl, want_tp, err))
           {
            g_logger.Info(StringFormat("Master SL/TP change detected -> Slave modify ticket=%d sl=%.5f tp=%.5f copy_id=%s",
                           (int)slave_ticket, want_sl, want_tp, mp.copy_id));
            m_copy_success_count++;
            m_last_copy_time = TimeCurrent();
           }
         else
           {
            m_copy_failed_count++;
            g_logger.Error(StringFormat("SL/TP modify failed ticket=%d copy_id=%s: %s", (int)slave_ticket, mp.copy_id, err));
           }
        }
     }

   void              ReconcilePositions(const MasterSnapshot &snap)
     {
      string managed_ids[];
      ulong  managed_tickets[];
      double managed_volumes[];
      int mcount = 0;

      int total = PositionsTotal();
      for(int i = 0; i < total; i++)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0)
            continue;
         if((long)PositionGetInteger(POSITION_MAGIC) != m_cfg.magic)
            continue;
         string cid;
         if(!CT_ParseCopyIdFromComment(PositionGetString(POSITION_COMMENT), cid))
            continue; // never touch a position we did not tag ourselves

         ArrayResize(managed_ids, mcount + 1);
         ArrayResize(managed_tickets, mcount + 1);
         ArrayResize(managed_volumes, mcount + 1);
         managed_ids[mcount]     = cid;
         managed_tickets[mcount] = ticket;
         managed_volumes[mcount] = PositionGetDouble(POSITION_VOLUME);
         mcount++;
        }

      for(int i = 0; i < ArraySize(snap.positions); i++)
        {
         CopyPositionRecord mp = snap.positions[i];

         int idx = CT_FindIndex(managed_ids, mp.copy_id);
         if(idx < 0 && mp.source_order_id != 0)
            idx = CT_FindIndex(managed_ids, CT_BuildOrderCopyId(snap.master_login, mp.source_order_id));

         if(idx < 0)
           {
            if(!IsPermanentlySkipped(mp.copy_id))
               TryOpenCopy(mp, snap);
           }
         else
            SyncExistingPosition(managed_tickets[idx], mp, snap, managed_volumes[idx]);
        }

      for(int i = 0; i < mcount; i++)
        {
         if(!MasterHasMatchingPosition(snap, managed_ids[i]))
           {
            ClearSkipMarker(managed_ids[i]);
            string err;
            if(m_trade.ClosePosition(managed_tickets[i], 0, err))
              {
               g_logger.Info(StringFormat("Master position closed -> Slave CLOSE ticket=%d copy_id=%s", (int)managed_tickets[i], managed_ids[i]));
               m_copy_success_count++;
               m_last_copy_time = TimeCurrent();
              }
            else
              {
               m_copy_failed_count++;
               g_logger.Error(StringFormat("Failed to close slave position ticket=%d copy_id=%s: %s", (int)managed_tickets[i], managed_ids[i], err));
              }
           }
        }
     }

   void              TryPlaceOrderCopy(const CopyOrderRecord &mo, const MasterSnapshot &snap)
     {
      string slave_symbol;
      if(!m_mapper.MapSymbol(mo.symbol, slave_symbol))
        {
         g_logger.Error(StringFormat("Symbol mapping failed for master symbol=%s - skipping pending copy_id=%s", mo.symbol, mo.copy_id));
         return;
        }

      long trade_mode = SYMBOL_TRADE_MODE_DISABLED;
      SymbolInfoInteger(slave_symbol, SYMBOL_TRADE_MODE, trade_mode);
      if(trade_mode == SYMBOL_TRADE_MODE_DISABLED || trade_mode == SYMBOL_TRADE_MODE_CLOSEONLY)
        {
         g_logger.Warning(StringFormat("Trading unavailable for %s - skipping pending copy_id=%s", slave_symbol, mo.copy_id));
         return;
        }

      if(m_risk.IsNewTradeBlocked() || m_risk.IsMaxPositionsExceeded())
        {
         g_logger.Warning(StringFormat("Risk limit blocks new pending order - copy_id=%s not placed", mo.copy_id));
         return;
        }

      double lot = CalculateLot(mo.volume, slave_symbol, snap);
      if(lot <= 0)
        {
         g_logger.Warning(StringFormat("Calculated lot invalid/below broker minimum for %s - pending copy_id=%s not placed", slave_symbol, mo.copy_id));
         return;
        }
      if(m_risk.IsMaxTotalLotsExceeded(lot))
        {
         g_logger.Warning(StringFormat("Max total lots would be exceeded - pending copy_id=%s not placed", mo.copy_id));
         return;
        }

      MqlTick tick;
      if(!SymbolInfoTick(slave_symbol, tick) || tick.bid <= 0 || tick.ask <= 0)
        {
         g_logger.Warning(StringFormat("No valid tick for %s - skipping pending copy_id=%s", slave_symbol, mo.copy_id));
         return;
        }

      ENUM_ORDER_TYPE order_type = (ENUM_ORDER_TYPE)mo.type;
      bool is_buy_side = (order_type == ORDER_TYPE_BUY_LIMIT || order_type == ORDER_TYPE_BUY_STOP || order_type == ORDER_TYPE_BUY_STOP_LIMIT);
      double slave_ref = is_buy_side ? tick.ask : tick.bid;

      //--- translate the pending price by the same DISTANCE the master's price
      //--- currently has from its own pending price - never copy the raw price.
      double price, stoplimit;
      if(mo.market_price_ref > 0)
        {
         double distance = mo.market_price_ref - mo.price_open;
         price = slave_ref - distance;
         if(order_type == ORDER_TYPE_BUY_STOP_LIMIT || order_type == ORDER_TYPE_SELL_STOP_LIMIT)
           {
            double distance_sl = mo.market_price_ref - mo.price_stoplimit;
            stoplimit = slave_ref - distance_sl;
           }
         else
            stoplimit = 0;
        }
      else
        {
         g_logger.Warning(StringFormat("Master had no live tick for %s at snapshot time - falling back to literal price for pending copy_id=%s", mo.symbol, mo.copy_id));
         price = mo.price_open;
         stoplimit = mo.price_stoplimit;
        }

      long stops_level = SymbolInfoInteger(slave_symbol, SYMBOL_TRADE_STOPS_LEVEL);
      double point = SymbolInfoDouble(slave_symbol, SYMBOL_POINT);
      double min_dist = stops_level * point;
      if(min_dist > 0 && MathAbs(slave_ref - price) < min_dist)
        {
         g_logger.Warning(StringFormat("Pending price too close to market on %s (stops level) - skipping copy_id=%s this cycle", slave_symbol, mo.copy_id));
         return;
        }

      double sl = 0, tp = 0;
      if(m_cfg.copy_sl && mo.sl > 0)
        {
         double dist = MathAbs(mo.price_open - mo.sl);
         sl = is_buy_side ? price - dist : price + dist;
         sl = AdjustStopDistance(slave_symbol, price, sl, is_buy_side, true);
        }
      if(m_cfg.copy_tp && mo.tp > 0)
        {
         double dist = MathAbs(mo.tp - mo.price_open);
         tp = is_buy_side ? price + dist : price - dist;
         tp = AdjustStopDistance(slave_symbol, price, tp, is_buy_side, false);
        }

      int digits = (int)SymbolInfoInteger(slave_symbol, SYMBOL_DIGITS);
      price     = NormalizeDouble(price, digits);
      stoplimit = NormalizeDouble(stoplimit, digits);
      if(sl > 0)
         sl = NormalizeDouble(sl, digits);
      if(tp > 0)
         tp = NormalizeDouble(tp, digits);

      string comment = StringFormat("COPY|%d|O%d", snap.master_login, mo.order_id);
      ulong out_ticket;
      string err;

      g_logger.Info(StringFormat("Master pending %s %s %.2f | COPY_ID=%s", EnumToString(order_type), mo.symbol, mo.volume, mo.copy_id));

      if(m_trade.PlacePendingOrder(slave_symbol, order_type, lot, price, stoplimit, sl, tp, mo.expiration, comment, out_ticket, err))
        {
         m_copy_success_count++;
         m_last_copy_time = TimeCurrent();
         g_logger.Trade(StringFormat("Ticket=%d Pending copy successful copy_id=%s", (int)out_ticket, mo.copy_id));
        }
      else
        {
         m_copy_failed_count++;
         g_logger.Error(StringFormat("Copy pending order failed copy_id=%s symbol=%s: %s", mo.copy_id, slave_symbol, err));
        }
     }

   void              SyncExistingOrder(const ulong slave_ticket, const CopyOrderRecord &mo)
     {
      if(!OrderSelect(slave_ticket))
         return;

      string slave_symbol = OrderGetString(ORDER_SYMBOL);
      MqlTick tick;
      if(!SymbolInfoTick(slave_symbol, tick))
         return;

      ENUM_ORDER_TYPE order_type = (ENUM_ORDER_TYPE)mo.type;
      bool is_buy_side = (order_type == ORDER_TYPE_BUY_LIMIT || order_type == ORDER_TYPE_BUY_STOP || order_type == ORDER_TYPE_BUY_STOP_LIMIT);
      double slave_ref = is_buy_side ? tick.ask : tick.bid;

      double price, stoplimit = 0;
      if(mo.market_price_ref > 0)
        {
         double distance = mo.market_price_ref - mo.price_open;
         price = slave_ref - distance;
         if(order_type == ORDER_TYPE_BUY_STOP_LIMIT || order_type == ORDER_TYPE_SELL_STOP_LIMIT)
           {
            double distance_sl = mo.market_price_ref - mo.price_stoplimit;
            stoplimit = slave_ref - distance_sl;
           }
        }
      else
        {
         // master had no live tick this cycle - preserve the order's current
         // price/stoplimit rather than risk clearing a valid stop-limit trigger
         price     = OrderGetDouble(ORDER_PRICE_OPEN);
         stoplimit = OrderGetDouble(ORDER_PRICE_STOPLIMIT);
        }

      double sl = 0, tp = 0;
      if(m_cfg.copy_sl && mo.sl > 0)
        {
         double dist = MathAbs(mo.price_open - mo.sl);
         sl = is_buy_side ? price - dist : price + dist;
         sl = AdjustStopDistance(slave_symbol, price, sl, is_buy_side, true);
        }
      if(m_cfg.copy_tp && mo.tp > 0)
        {
         double dist = MathAbs(mo.tp - mo.price_open);
         tp = is_buy_side ? price + dist : price - dist;
         tp = AdjustStopDistance(slave_symbol, price, tp, is_buy_side, false);
        }

      int digits = (int)SymbolInfoInteger(slave_symbol, SYMBOL_DIGITS);
      price = NormalizeDouble(price, digits);
      if(sl > 0)
         sl = NormalizeDouble(sl, digits);
      if(tp > 0)
         tp = NormalizeDouble(tp, digits);

      double cur_price = OrderGetDouble(ORDER_PRICE_OPEN);
      double cur_sl     = OrderGetDouble(ORDER_SL);
      double cur_tp     = OrderGetDouble(ORDER_TP);
      double point      = SymbolInfoDouble(slave_symbol, SYMBOL_POINT);

      bool changed = (MathAbs(price - cur_price) > point) || (MathAbs(sl - cur_sl) > point) || (MathAbs(tp - cur_tp) > point);
      if(!changed)
         return;

      string err;
      if(m_trade.ModifyPendingOrder(slave_ticket, price, stoplimit, sl, tp, mo.expiration, err))
        {
         g_logger.Info(StringFormat("Master pending order change detected -> Slave modify ticket=%d copy_id=%s", (int)slave_ticket, mo.copy_id));
         m_copy_success_count++;
         m_last_copy_time = TimeCurrent();
        }
      else
        {
         m_copy_failed_count++;
         g_logger.Error(StringFormat("Pending order modify failed ticket=%d copy_id=%s: %s", (int)slave_ticket, mo.copy_id, err));
        }
     }

   void              ReconcileOrders(const MasterSnapshot &snap)
     {
      string managed_ids[];
      ulong  managed_tickets[];
      int mcount = 0;

      int total = OrdersTotal();
      for(int i = 0; i < total; i++)
        {
         ulong ticket = OrderGetTicket(i);
         if(ticket == 0)
            continue;
         if((long)OrderGetInteger(ORDER_MAGIC) != m_cfg.magic)
            continue;
         string cid;
         if(!CT_ParseCopyIdFromComment(OrderGetString(ORDER_COMMENT), cid))
            continue;

         ArrayResize(managed_ids, mcount + 1);
         ArrayResize(managed_tickets, mcount + 1);
         managed_ids[mcount]     = cid;
         managed_tickets[mcount] = ticket;
         mcount++;
        }

      for(int i = 0; i < ArraySize(snap.orders); i++)
        {
         CopyOrderRecord mo = snap.orders[i];
         int idx = CT_FindIndex(managed_ids, mo.copy_id);
         if(idx < 0)
           {
            if(!IsPermanentlySkipped(mo.copy_id))
               TryPlaceOrderCopy(mo, snap);
           }
         else
            SyncExistingOrder(managed_tickets[idx], mo);
        }

      for(int i = 0; i < mcount; i++)
        {
         int idx = -1;
         for(int j = 0; j < ArraySize(snap.orders); j++)
            if(snap.orders[j].copy_id == managed_ids[i])
              {
               idx = j;
               break;
              }
         if(idx < 0)
           {
            ClearSkipMarker(managed_ids[i]);
            string err;
            if(m_trade.DeletePendingOrder(managed_tickets[i], err))
              {
               g_logger.Info(StringFormat("Master pending order gone -> Slave DELETE ticket=%d copy_id=%s", (int)managed_tickets[i], managed_ids[i]));
               m_copy_success_count++;
              }
            else
              {
               m_copy_failed_count++;
               g_logger.Error(StringFormat("Failed to delete slave pending order ticket=%d: %s", (int)managed_tickets[i], err));
              }
           }
        }
     }

   void              CloseAllManagedPositions(const string reason)
     {
      g_logger.Warning("CloseAllManagedPositions triggered: " + reason);

      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0)
            continue;
         if((long)PositionGetInteger(POSITION_MAGIC) != m_cfg.magic)
            continue;
         string cid;
         if(!CT_ParseCopyIdFromComment(PositionGetString(POSITION_COMMENT), cid))
            continue;

         string err;
         if(m_trade.ClosePosition(ticket, 0, err))
            g_logger.Info(StringFormat("Close-all: OK ticket=%d", (int)ticket));
         else
            g_logger.Error(StringFormat("Close-all: FAILED ticket=%d: %s", (int)ticket, err));
        }

      for(int i = OrdersTotal() - 1; i >= 0; i--)
        {
         ulong ticket = OrderGetTicket(i);
         if(ticket == 0)
            continue;
         if((long)OrderGetInteger(ORDER_MAGIC) != m_cfg.magic)
            continue;
         string cid;
         if(!CT_ParseCopyIdFromComment(OrderGetString(ORDER_COMMENT), cid))
            continue;

         string err;
         m_trade.DeletePendingOrder(ticket, err);
        }
     }

public:
   void              Init(const CT_SlaveConfig &cfg)
     {
      m_cfg                 = cfg;
      m_password_hash        = CT_HashPassword(cfg.copy_password);
      m_require_password     = (m_password_hash != "");
      m_master_online        = false;
      m_last_master_update   = 0;
      m_last_copy_time       = 0;
      m_copy_latency_ms      = 0;
      m_copy_success_count   = 0;
      m_copy_failed_count    = 0;
      m_has_snapshot         = false;
      m_emergency_triggered  = false;

      m_mapper.Init(cfg.auto_symbol_mapping, cfg.symbol_prefix, cfg.symbol_suffix, cfg.manual_symbol_mapping);
      m_trade.Init(cfg.magic, cfg.max_deviation_points, cfg.max_retry_count, cfg.retry_delay_ms, cfg.test_mode, cfg.dry_run);
      m_risk.Init(cfg.max_daily_loss_pct, cfg.max_equity_dd_pct, cfg.max_open_positions, cfg.max_total_lots, cfg.max_spread_points, cfg.magic);

      m_enabled = true;
      string err;
      if(!CAccountValidator::ValidateSlave(cfg.require_real_account, err))
        {
         g_logger.Error(err);
         m_enabled = false;
         return;
        }

      if(CAccountValidator::IsNettingAccount())
        {
         g_logger.Error("Slave account is a NETTING account. This EA (v1) supports HEDGING accounts only, "
                         "because netting brokers merge multiple positions per symbol into a single net "
                         "position and cannot represent a 1:1 Master->Slave position mapping. Refusing to "
                         "trade rather than silently mis-mapping trades.");
         m_enabled = false;
         return;
        }

      if((ENUM_ACCOUNT_TRADE_MODE)AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_REAL)
         g_logger.Warning("WARNING: REAL ACCOUNT COPY TRADE ENABLED");

      g_logger.Info(StringFormat("SLAVE initialized. login=%d server=%s type=%s magic=%d",
                     (int)AccountInfoInteger(ACCOUNT_LOGIN), AccountInfoString(ACCOUNT_SERVER),
                     CAccountValidator::TradeModeToString((int)AccountInfoInteger(ACCOUNT_TRADE_MODE)), cfg.magic));
     }

   bool              IsEnabled()         { return m_enabled; }
   bool              IsMasterOnline()    { return m_master_online; }
   datetime          LastMasterUpdate()  { return m_last_master_update; }
   datetime          LastCopyTime()      { return m_last_copy_time; }
   long              CopyLatencyMs()     { return m_copy_latency_ms; }
   int               CopySuccessCount()  { return m_copy_success_count; }
   int               CopyFailedCount()   { return m_copy_failed_count; }
   int               OpenMasterCount()   { return m_has_snapshot ? ArraySize(m_last_snapshot.positions) : 0; }
   int               OpenSlaveCount()    { return m_risk.CountManagedPositions(); }

   string            RiskStatus()
     {
      if(!m_enabled)
         return "BLOCKED";
      if(m_emergency_triggered)
         return "EMERGENCY";
      if(m_risk.IsNewTradeBlocked())
         return "BLOCKED";
      return "NORMAL";
     }

   void              Run()
     {
      if(!m_enabled)
         return;

      m_risk.OnTimerUpdate();

      MasterHeartbeat hb;
      string err;
      bool hb_ok = CT_ReadHeartbeat(hb, err);
      bool online = false;

      if(hb_ok)
        {
         int age = (int)(TimeCurrent() - hb.timestamp);
         if(age <= m_cfg.master_timeout_seconds)
           {
            if(!m_require_password || hb.password_hash == m_password_hash)
              {
               online = true;
               m_last_master_update = TimeCurrent();
              }
            else
               g_logger.Error("Heartbeat password hash mismatch - refusing to trust this master");
           }
         else
            g_logger.Warning(StringFormat("Master heartbeat stale: age=%ds > timeout=%ds", age, m_cfg.master_timeout_seconds));
        }
      else
         g_logger.Warning("Cannot read master heartbeat: " + err);

      if(online != m_master_online)
        {
         if(online)
            g_logger.Info("Master ONLINE");
         else
           {
            g_logger.Warning("Master OFFLINE (heartbeat missing/stale/invalid)");
            if(m_cfg.close_when_offline)
               CloseAllManagedPositions("Master offline and CloseTradesWhenMasterOffline=true");
           }
        }
      m_master_online = online;

      if(!online)
         return; // never act on stale/untrusted data

      MasterSnapshot snap;
      if(!CT_ReadMasterSnapshot(snap, err))
        {
         g_logger.Error("Invalid/corrupted master snapshot, skipping this cycle: " + err);
         return;
        }
      if(m_require_password && snap.password_hash != m_password_hash)
        {
         g_logger.Error("Snapshot password hash mismatch - refusing to trust this snapshot");
         return;
        }

      m_last_snapshot = snap;
      m_has_snapshot  = true;

      if(m_risk.IsNewTradeBlocked())
        {
         if(m_cfg.emergency_close_all && !m_emergency_triggered)
           {
            CloseAllManagedPositions("EMERGENCY: daily-loss/drawdown limit breached and EmergencyCloseAll=true");
            m_emergency_triggered = true;
           }
        }
      else
         m_emergency_triggered = false;

      ReconcilePositions(snap);
      if(m_cfg.enable_pending_orders)
         ReconcileOrders(snap);
     }
  };

#endif // __CT_COPYMANAGER_MQH__
