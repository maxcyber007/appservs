//+------------------------------------------------------------------+
//|                                                 SignalEngine.mqh |
//|      Gold Trade Pro EA - trend-following entry signal generator   |
//+------------------------------------------------------------------+
#property copyright "Gold Trade Pro EA"
#property strict

//--- Direction returned by CGoldSignalEngine::Evaluate()
enum ENUM_GTP_SIGNAL
  {
   GTP_SIGNAL_NONE = 0,
   GTP_SIGNAL_BUY  = 1,
   GTP_SIGNAL_SELL = -1
  };

//+------------------------------------------------------------------+
//| Signal model                                                     |
//|                                                                  |
//|  * Higher timeframe EMA sets the directional bias - gold trends   |
//|    hard but whipsaws inside the trend, so counter-bias entries    |
//|    are simply not taken.                                          |
//|  * On the entry timeframe a fast/slow EMA cross arms the trade.   |
//|  * RSI must confirm momentum without being already exhausted.     |
//|  * ATR must exceed a floor, which keeps the EA out of the dead    |
//|    low-volatility hours where gold spreads eat the edge.          |
//+------------------------------------------------------------------+
class CGoldSignalEngine
  {
private:
   string            m_symbol;
   ENUM_TIMEFRAMES   m_tf_entry;
   ENUM_TIMEFRAMES   m_tf_trend;

   int               m_handle_ema_fast;
   int               m_handle_ema_slow;
   int               m_handle_ema_trend;
   int               m_handle_rsi;
   int               m_handle_atr;

   double            m_rsi_buy_min;
   double            m_rsi_buy_max;
   double            m_rsi_sell_min;
   double            m_rsi_sell_max;
   double            m_min_atr_points;

   bool              m_use_trend_filter;

   //--- Copy "count" values of a handle's buffer starting at bar 1 (closed bars).
   bool              Read(const int handle, const int buffer, const int count, double &out[]) const
     {
      ArraySetAsSeries(out, true);
      if(handle == INVALID_HANDLE)
         return(false);
      return(CopyBuffer(handle, buffer, 1, count, out) == count);
     }

public:
                     CGoldSignalEngine(void)
      : m_symbol(""), m_tf_entry(PERIOD_M15), m_tf_trend(PERIOD_H1),
        m_handle_ema_fast(INVALID_HANDLE), m_handle_ema_slow(INVALID_HANDLE),
        m_handle_ema_trend(INVALID_HANDLE), m_handle_rsi(INVALID_HANDLE),
        m_handle_atr(INVALID_HANDLE),
        m_rsi_buy_min(50.0), m_rsi_buy_max(75.0),
        m_rsi_sell_min(25.0), m_rsi_sell_max(50.0),
        m_min_atr_points(0.0), m_use_trend_filter(true) {}

                    ~CGoldSignalEngine(void) { Release(); }

   bool              Init(const string symbol,
                          const ENUM_TIMEFRAMES tf_entry,
                          const ENUM_TIMEFRAMES tf_trend,
                          const int ema_fast_period,
                          const int ema_slow_period,
                          const int ema_trend_period,
                          const int rsi_period,
                          const int atr_period)
     {
      Release();

      m_symbol   = symbol;
      m_tf_entry = tf_entry;
      m_tf_trend = tf_trend;

      m_handle_ema_fast  = iMA(symbol, tf_entry, ema_fast_period, 0, MODE_EMA, PRICE_CLOSE);
      m_handle_ema_slow  = iMA(symbol, tf_entry, ema_slow_period, 0, MODE_EMA, PRICE_CLOSE);
      m_handle_ema_trend = iMA(symbol, tf_trend, ema_trend_period, 0, MODE_EMA, PRICE_CLOSE);
      m_handle_rsi       = iRSI(symbol, tf_entry, rsi_period, PRICE_CLOSE);
      m_handle_atr       = iATR(symbol, tf_entry, atr_period);

      return(m_handle_ema_fast  != INVALID_HANDLE &&
             m_handle_ema_slow  != INVALID_HANDLE &&
             m_handle_ema_trend != INVALID_HANDLE &&
             m_handle_rsi       != INVALID_HANDLE &&
             m_handle_atr       != INVALID_HANDLE);
     }

   void              Release(void)
     {
      if(m_handle_ema_fast  != INVALID_HANDLE) { IndicatorRelease(m_handle_ema_fast);  m_handle_ema_fast  = INVALID_HANDLE; }
      if(m_handle_ema_slow  != INVALID_HANDLE) { IndicatorRelease(m_handle_ema_slow);  m_handle_ema_slow  = INVALID_HANDLE; }
      if(m_handle_ema_trend != INVALID_HANDLE) { IndicatorRelease(m_handle_ema_trend); m_handle_ema_trend = INVALID_HANDLE; }
      if(m_handle_rsi       != INVALID_HANDLE) { IndicatorRelease(m_handle_rsi);       m_handle_rsi       = INVALID_HANDLE; }
      if(m_handle_atr       != INVALID_HANDLE) { IndicatorRelease(m_handle_atr);       m_handle_atr       = INVALID_HANDLE; }
     }

   void              SetFilters(const double rsi_buy_min, const double rsi_buy_max,
                                const double rsi_sell_min, const double rsi_sell_max,
                                const double min_atr_points, const bool use_trend_filter)
     {
      m_rsi_buy_min      = rsi_buy_min;
      m_rsi_buy_max      = rsi_buy_max;
      m_rsi_sell_min     = rsi_sell_min;
      m_rsi_sell_max     = rsi_sell_max;
      m_min_atr_points   = min_atr_points;
      m_use_trend_filter = use_trend_filter;
     }

   //--- Latest ATR value on the last closed bar, in price units. 0 on failure.
   double            ATR(void) const
     {
      double atr[];
      if(!Read(m_handle_atr, 0, 1, atr))
         return(0.0);
      return(atr[0]);
     }

   //--- Evaluate the last two closed bars. "reason" describes the outcome.
   ENUM_GTP_SIGNAL   Evaluate(string &reason)
     {
      double fast[], slow[], trend[], rsi[];

      if(!Read(m_handle_ema_fast, 0, 2, fast) ||
         !Read(m_handle_ema_slow, 0, 2, slow) ||
         !Read(m_handle_rsi,      0, 1, rsi)  ||
         !Read(m_handle_ema_trend, 0, 1, trend))
        {
         reason = "indicator data not ready";
         return(GTP_SIGNAL_NONE);
        }

      double atr = ATR();
      if(atr <= 0.0)
        {
         reason = "ATR not ready";
         return(GTP_SIGNAL_NONE);
        }

      double point = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      if(m_min_atr_points > 0.0 && point > 0.0 && atr / point < m_min_atr_points)
        {
         reason = StringFormat("volatility too low (ATR %.0f pts < %.0f pts)",
                               atr / point, m_min_atr_points);
         return(GTP_SIGNAL_NONE);
        }

      double close_trend = iClose(m_symbol, m_tf_trend, 1);
      if(close_trend <= 0.0)
        {
         reason = "trend timeframe data not ready";
         return(GTP_SIGNAL_NONE);
        }

      bool bias_up   = (!m_use_trend_filter) || (close_trend > trend[0]);
      bool bias_down = (!m_use_trend_filter) || (close_trend < trend[0]);

      // fast[0]/slow[0] = last closed bar, fast[1]/slow[1] = the bar before it.
      bool cross_up   = (fast[1] <= slow[1] && fast[0] > slow[0]);
      bool cross_down = (fast[1] >= slow[1] && fast[0] < slow[0]);

      if(cross_up && bias_up)
        {
         if(rsi[0] < m_rsi_buy_min || rsi[0] > m_rsi_buy_max)
           {
            reason = StringFormat("buy cross rejected by RSI %.1f", rsi[0]);
            return(GTP_SIGNAL_NONE);
           }
         reason = StringFormat("buy: EMA cross up, RSI %.1f, ATR %.0f pts",
                               rsi[0], (point > 0.0 ? atr / point : 0.0));
         return(GTP_SIGNAL_BUY);
        }

      if(cross_down && bias_down)
        {
         if(rsi[0] < m_rsi_sell_min || rsi[0] > m_rsi_sell_max)
           {
            reason = StringFormat("sell cross rejected by RSI %.1f", rsi[0]);
            return(GTP_SIGNAL_NONE);
           }
         reason = StringFormat("sell: EMA cross down, RSI %.1f, ATR %.0f pts",
                               rsi[0], (point > 0.0 ? atr / point : 0.0));
         return(GTP_SIGNAL_SELL);
        }

      if(cross_up || cross_down)
         reason = "cross against higher timeframe bias";
      else
         reason = "no cross";

      return(GTP_SIGNAL_NONE);
     }
  };
//+------------------------------------------------------------------+
