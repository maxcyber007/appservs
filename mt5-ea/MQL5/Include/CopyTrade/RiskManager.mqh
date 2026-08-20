//+------------------------------------------------------------------+
//|                                                 RiskManager.mqh |
//|  Daily-loss / drawdown / position-count / lot-cap / spread guard  |
//|  for the SLAVE account. Blocks NEW opens only - never force-      |
//|  closes unless EmergencyCloseAll is explicitly enabled.           |
//+------------------------------------------------------------------+
#ifndef __CT_RISKMANAGER_MQH__
#define __CT_RISKMANAGER_MQH__

class CRiskManager
  {
private:
   double            m_day_start_equity;
   double            m_peak_equity;
   double            m_max_daily_loss_pct;
   double            m_max_dd_pct;
   int               m_max_positions;
   double            m_max_total_lots;
   int               m_max_spread_points;
   long              m_magic;

   string            GVDay()  { return "CT_RM_DAY_"  + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)); }
   string            GVBase() { return "CT_RM_DAYEQ_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)); }
   string            GVPeak() { return "CT_RM_PEAK_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)); }

   datetime          TodayMidnight()
     {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      dt.hour = 0; dt.min = 0; dt.sec = 0;
      return StructToTime(dt);
     }

public:
   void              Init(const double max_daily_loss_pct, const double max_dd_pct,
                           const int max_positions, const double max_total_lots,
                           const int max_spread_points, const long magic)
     {
      m_max_daily_loss_pct = max_daily_loss_pct;
      m_max_dd_pct          = max_dd_pct;
      m_max_positions       = max_positions;
      m_max_total_lots      = max_total_lots;
      m_max_spread_points   = max_spread_points;
      m_magic               = magic;

      datetime today  = TodayMidnight();
      double   equity = AccountInfoDouble(ACCOUNT_EQUITY);

      if(GlobalVariableCheck(GVDay()) && (datetime)GlobalVariableGet(GVDay()) == today)
         m_day_start_equity = GlobalVariableGet(GVBase());
      else
        {
         m_day_start_equity = equity;
         GlobalVariableSet(GVDay(), (double)today);
         GlobalVariableSet(GVBase(), equity);
        }

      m_peak_equity = GlobalVariableCheck(GVPeak()) ? GlobalVariableGet(GVPeak()) : equity;
      if(equity > m_peak_equity)
        {
         m_peak_equity = equity;
         GlobalVariableSet(GVPeak(), m_peak_equity);
        }
     }

   void              OnTimerUpdate()
     {
      datetime today  = TodayMidnight();
      double   equity = AccountInfoDouble(ACCOUNT_EQUITY);

      if(!GlobalVariableCheck(GVDay()) || (datetime)GlobalVariableGet(GVDay()) != today)
        {
         m_day_start_equity = equity;
         GlobalVariableSet(GVDay(), (double)today);
         GlobalVariableSet(GVBase(), equity);
        }
      if(equity > m_peak_equity)
        {
         m_peak_equity = equity;
         GlobalVariableSet(GVPeak(), m_peak_equity);
        }
     }

   bool              IsDailyLossExceeded()
     {
      if(m_max_daily_loss_pct <= 0 || m_day_start_equity <= 0)
         return false;
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double loss_pct = (m_day_start_equity - equity) / m_day_start_equity * 100.0;
      return loss_pct >= m_max_daily_loss_pct;
     }

   bool              IsDrawdownExceeded()
     {
      if(m_max_dd_pct <= 0 || m_peak_equity <= 0)
         return false;
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double dd_pct = (m_peak_equity - equity) / m_peak_equity * 100.0;
      return dd_pct >= m_max_dd_pct;
     }

   int               CountManagedPositions()
     {
      int cnt = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0)
            continue;
         if(PositionGetInteger(POSITION_MAGIC) == m_magic)
            cnt++;
        }
      return cnt;
     }

   double            TotalManagedLots()
     {
      double total = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0)
            continue;
         if(PositionGetInteger(POSITION_MAGIC) == m_magic)
            total += PositionGetDouble(POSITION_VOLUME);
        }
      return total;
     }

   bool              IsMaxPositionsExceeded()
     {
      if(m_max_positions <= 0)
         return false;
      return CountManagedPositions() >= m_max_positions;
     }

   bool              IsMaxTotalLotsExceeded(const double additional_volume = 0.0)
     {
      if(m_max_total_lots <= 0)
         return false;
      return (TotalManagedLots() + additional_volume) > m_max_total_lots;
     }

   bool              IsSpreadTooHigh(const string symbol)
     {
      if(m_max_spread_points <= 0)
         return false;
      long spread = SymbolInfoInteger(symbol, SYMBOL_SPREAD);
      return spread > m_max_spread_points;
     }

   //--- true if any account-level limit blocks NEW position opens ----
   bool              IsNewTradeBlocked()
     {
      return IsDailyLossExceeded() || IsDrawdownExceeded();
     }

   double            DayStartEquity() { return m_day_start_equity; }
   double            PeakEquity()     { return m_peak_equity; }
  };

#endif // __CT_RISKMANAGER_MQH__
