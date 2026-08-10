//+------------------------------------------------------------------+
//|                                                  PivotFinder.mqh |
//|      Swing high / low detection for the pivot breakout strategy   |
//+------------------------------------------------------------------+
#property copyright "Gold Trade Pro EA"
#property strict

//+------------------------------------------------------------------+
//| Finds the most recent untraded swing point that price has not yet |
//| reached.                                                          |
//|                                                                   |
//| A bar at index i qualifies as a swing high when:                  |
//|   * no bar in the RightBars newer than i has a higher high        |
//|     (the swing has been confirmed, price turned away from it),    |
//|   * no bar in the LeftBars older than i has a higher high         |
//|     (it is a genuine local extreme, not a step inside a rally),   |
//|   * optionally, it is the highest high of everything newer than   |
//|     it, which makes it the first level an upward breakout meets,  |
//|   * it sits at least MinDistance above the current Ask, so the    |
//|     breakout order has room to be placed and is not filled by     |
//|     noise on the next tick.                                       |
//|                                                                   |
//| The search walks from the newest confirmed bar backwards and      |
//| returns the first match, i.e. the nearest level above price.      |
//+------------------------------------------------------------------+
class CPivotFinder
  {
private:
   string            m_symbol;
   ENUM_TIMEFRAMES   m_tf;
   int               m_left_bars;      // older bars that must not exceed the pivot
   int               m_right_bars;     // newer bars that confirm the pivot
   int               m_max_lookback;   // how far back to search
   double            m_min_distance;   // minimum gap from price, in price units
   bool              m_require_extreme; // pivot must be the extreme of everything newer

public:
                     CPivotFinder(void)
      : m_symbol(""), m_tf(PERIOD_D1), m_left_bars(4), m_right_bars(2),
        m_max_lookback(160), m_min_distance(0.0), m_require_extreme(true) {}

   void              Configure(const string symbol, const ENUM_TIMEFRAMES tf,
                               const int left_bars, const int right_bars,
                               const int max_lookback, const double min_distance,
                               const bool require_extreme)
     {
      m_symbol          = symbol;
      m_tf              = tf;
      m_left_bars       = (left_bars  > 0 ? left_bars  : 1);
      m_right_bars      = (right_bars > 0 ? right_bars : 1);
      m_max_lookback    = (max_lookback > 0 ? max_lookback : 100);
      m_min_distance    = min_distance;
      m_require_extreme = require_extreme;
     }

   void              SetMinDistance(const double distance) { m_min_distance = distance; }

   //--- Nearest confirmed swing high above the current Ask.
   bool              FindHigh(double &price, int &shift)
     {
      price = 0.0;
      shift = -1;

      double ask = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
      if(ask <= 0.0)
         return(false);

      int available = Bars(m_symbol, m_tf);
      int limit     = MathMin(m_max_lookback, available - m_left_bars - 2);
      if(limit <= m_right_bars)
         return(false);

      double newest_extreme = 0.0;   // highest high seen while walking backwards

      for(int i = m_right_bars + 1; i <= limit; i++)
        {
         double candidate = iHigh(m_symbol, m_tf, i);
         if(candidate <= 0.0)
            continue;

         //--- Bars newer than the candidate, up to the confirmation window.
         bool confirmed = true;
         for(int r = i - 1; r >= i - m_right_bars && r >= 0; r--)
            if(iHigh(m_symbol, m_tf, r) > candidate)
              { confirmed = false; break; }
         if(!confirmed)
           {
            newest_extreme = MathMax(newest_extreme, candidate);
            continue;
           }

         //--- Bars older than the candidate.
         bool is_local_max = true;
         for(int l = i + 1; l <= i + m_left_bars; l++)
            if(iHigh(m_symbol, m_tf, l) > candidate)
              { is_local_max = false; break; }
         if(!is_local_max)
           {
            newest_extreme = MathMax(newest_extreme, candidate);
            continue;
           }

         //--- Must still be untouched by everything that happened since.
         if(m_require_extreme && candidate < newest_extreme)
           {
            newest_extreme = MathMax(newest_extreme, candidate);
            continue;
           }

         newest_extreme = MathMax(newest_extreme, candidate);

         if(candidate < ask + m_min_distance)
            continue;   // too close to price, keep looking further back

         price = candidate;
         shift = i;
         return(true);
        }

      return(false);
     }

   //--- Nearest confirmed swing low below the current Bid.
   bool              FindLow(double &price, int &shift)
     {
      price = 0.0;
      shift = -1;

      double bid = SymbolInfoDouble(m_symbol, SYMBOL_BID);
      if(bid <= 0.0)
         return(false);

      int available = Bars(m_symbol, m_tf);
      int limit     = MathMin(m_max_lookback, available - m_left_bars - 2);
      if(limit <= m_right_bars)
         return(false);

      double newest_extreme = DBL_MAX;

      for(int i = m_right_bars + 1; i <= limit; i++)
        {
         double candidate = iLow(m_symbol, m_tf, i);
         if(candidate <= 0.0)
            continue;

         bool confirmed = true;
         for(int r = i - 1; r >= i - m_right_bars && r >= 0; r--)
            if(iLow(m_symbol, m_tf, r) < candidate)
              { confirmed = false; break; }
         if(!confirmed)
           {
            newest_extreme = MathMin(newest_extreme, candidate);
            continue;
           }

         bool is_local_min = true;
         for(int l = i + 1; l <= i + m_left_bars; l++)
            if(iLow(m_symbol, m_tf, l) < candidate)
              { is_local_min = false; break; }
         if(!is_local_min)
           {
            newest_extreme = MathMin(newest_extreme, candidate);
            continue;
           }

         if(m_require_extreme && candidate > newest_extreme)
           {
            newest_extreme = MathMin(newest_extreme, candidate);
            continue;
           }

         newest_extreme = MathMin(newest_extreme, candidate);

         if(candidate > bid - m_min_distance)
            continue;

         price = candidate;
         shift = i;
         return(true);
        }

      return(false);
     }
  };
//+------------------------------------------------------------------+
