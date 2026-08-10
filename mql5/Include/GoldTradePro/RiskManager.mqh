//+------------------------------------------------------------------+
//|                                                  RiskManager.mqh |
//|        Gold Trade Pro EA - position sizing and account guards     |
//+------------------------------------------------------------------+
#property copyright "Gold Trade Pro EA"
#property strict

#include <GoldTradePro/Utils.mqh>

//+------------------------------------------------------------------+
//| Sizes positions from a risk percentage and enforces the daily     |
//| loss / drawdown limits that stop the EA from trading on bad days. |
//+------------------------------------------------------------------+
class CGoldRiskManager
  {
private:
   string            m_symbol;
   double            m_risk_percent;       // risk per trade, % of balance
   double            m_fixed_lots;         // used when m_risk_percent <= 0
   double            m_max_daily_loss_pct; // 0 disables the guard
   double            m_max_drawdown_pct;   // 0 disables the guard

   datetime          m_day_start;          // midnight of the tracked day
   double            m_day_start_equity;
   double            m_peak_equity;
   bool              m_halted_today;

   datetime          DayStart(const datetime t) const
     {
      MqlDateTime dt;
      TimeToStruct(t, dt);
      dt.hour = 0;
      dt.min  = 0;
      dt.sec  = 0;
      return(StructToTime(dt));
     }

public:
                     CGoldRiskManager(void)
      : m_symbol(""), m_risk_percent(1.0), m_fixed_lots(0.01),
        m_max_daily_loss_pct(0.0), m_max_drawdown_pct(0.0),
        m_day_start(0), m_day_start_equity(0.0), m_peak_equity(0.0),
        m_halted_today(false) {}

   void              Configure(const string symbol, const double risk_percent, const double fixed_lots,
                               const double max_daily_loss_pct, const double max_drawdown_pct)
     {
      m_symbol             = symbol;
      m_risk_percent       = risk_percent;
      m_fixed_lots         = fixed_lots;
      m_max_daily_loss_pct = max_daily_loss_pct;
      m_max_drawdown_pct   = max_drawdown_pct;

      double equity        = AccountInfoDouble(ACCOUNT_EQUITY);
      m_day_start          = DayStart(TimeCurrent());
      m_day_start_equity   = equity;
      m_peak_equity        = equity;
      m_halted_today       = false;
     }

   //--- Call once per tick before looking for signals.
   void              Refresh(void)
     {
      datetime today = DayStart(TimeCurrent());
      if(today != m_day_start)
        {
         m_day_start        = today;
         m_day_start_equity = AccountInfoDouble(ACCOUNT_EQUITY);
         m_halted_today     = false;
        }

      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(equity > m_peak_equity)
         m_peak_equity = equity;
     }

   double            DayLossPercent(void) const
     {
      if(m_day_start_equity <= 0.0)
         return(0.0);
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      return((m_day_start_equity - equity) / m_day_start_equity * 100.0);
     }

   double            DrawdownPercent(void) const
     {
      if(m_peak_equity <= 0.0)
         return(0.0);
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      return((m_peak_equity - equity) / m_peak_equity * 100.0);
     }

   //--- False when a guard has tripped and no new trade may be opened.
   bool              TradingAllowed(string &reason)
     {
      if(m_max_daily_loss_pct > 0.0 && DayLossPercent() >= m_max_daily_loss_pct)
        {
         m_halted_today = true;
         reason = StringFormat("daily loss limit reached (%.2f%% >= %.2f%%)",
                               DayLossPercent(), m_max_daily_loss_pct);
         return(false);
        }

      if(m_halted_today)
        {
         reason = "trading halted for the rest of the day";
         return(false);
        }

      if(m_max_drawdown_pct > 0.0 && DrawdownPercent() >= m_max_drawdown_pct)
        {
         reason = StringFormat("max drawdown reached (%.2f%% >= %.2f%%)",
                               DrawdownPercent(), m_max_drawdown_pct);
         return(false);
        }

      reason = "";
      return(true);
     }

   //--- Lot size that risks m_risk_percent of balance over stop_distance
   //--- (a positive price distance). Returns 0 when it cannot be sized.
   double            LotsForStop(const double stop_distance)
     {
      if(m_risk_percent <= 0.0)
         return(GTP_NormalizeLots(m_symbol, m_fixed_lots));

      if(stop_distance <= 0.0)
         return(0.0);

      double point = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      double pv    = GTP_PointValuePerLot(m_symbol);
      if(point <= 0.0 || pv <= 0.0)
         return(0.0);

      double risk_money    = AccountInfoDouble(ACCOUNT_BALANCE) * m_risk_percent / 100.0;
      double loss_per_lot  = (stop_distance / point) * pv;
      if(risk_money <= 0.0 || loss_per_lot <= 0.0)
         return(0.0);

      double lots = GTP_NormalizeLots(m_symbol, risk_money / loss_per_lot);

      //--- Never let the rounding-up to min lot blow past the risk budget.
      double min_lot = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MIN);
      if(lots <= min_lot && loss_per_lot * min_lot > risk_money * 1.5)
         return(0.0);

      //--- Respect free margin for the intended trade.
      double margin = 0.0;
      double ask    = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
      if(OrderCalcMargin(ORDER_TYPE_BUY, m_symbol, lots, ask, margin))
        {
         double free_margin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
         if(margin > free_margin * 0.9 && margin > 0.0)
           {
            double affordable = lots * (free_margin * 0.9 / margin);
            lots = GTP_NormalizeLots(m_symbol, affordable);
            if(OrderCalcMargin(ORDER_TYPE_BUY, m_symbol, lots, ask, margin) &&
               margin > free_margin)
               return(0.0);
           }
        }

      return(lots);
     }
  };
//+------------------------------------------------------------------+
