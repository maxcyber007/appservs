//+------------------------------------------------------------------+
//|                                                        Utils.mqh |
//|                          Gold Trade Pro EA - shared helpers       |
//+------------------------------------------------------------------+
#property copyright "Gold Trade Pro EA"
#property strict

//+------------------------------------------------------------------+
//| Value of one point of price movement for one lot, in account cash |
//| Returns 0 when the symbol does not expose usable tick data.       |
//+------------------------------------------------------------------+
double GTP_PointValuePerLot(const string symbol)
  {
   double tick_value = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   double point      = SymbolInfoDouble(symbol, SYMBOL_POINT);

   if(tick_value <= 0.0 || tick_size <= 0.0 || point <= 0.0)
      return(0.0);

   return(tick_value * point / tick_size);
  }

//+------------------------------------------------------------------+
//| Clamp a lot size to the broker's min/max/step grid                |
//+------------------------------------------------------------------+
double GTP_NormalizeLots(const string symbol, double lots)
  {
   double min_lot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double max_lot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double lot_step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   if(lot_step <= 0.0)
      lot_step = 0.01;

   lots = MathFloor(lots / lot_step) * lot_step;

   if(lots < min_lot)
      lots = min_lot;
   if(max_lot > 0.0 && lots > max_lot)
      lots = max_lot;

   // Round away binary noise introduced by the division above.
   int step_digits = (int)MathMax(0, MathCeil(-MathLog10(lot_step) - 0.0000001));
   return(NormalizeDouble(lots, step_digits));
  }

//+------------------------------------------------------------------+
//| Minimum distance (in price) the broker allows between the market  |
//| price and a stop loss / take profit level.                        |
//+------------------------------------------------------------------+
double GTP_MinStopDistance(const string symbol)
  {
   double point  = SymbolInfoDouble(symbol, SYMBOL_POINT);
   long   stops  = (long)SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long   freeze = (long)SymbolInfoInteger(symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   long   levels = (stops > freeze ? stops : freeze);

   return((double)levels * point);
  }

//+------------------------------------------------------------------+
//| Current spread of the symbol expressed in points                  |
//+------------------------------------------------------------------+
double GTP_SpreadPoints(const string symbol)
  {
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double ask   = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(symbol, SYMBOL_BID);

   if(point <= 0.0)
      return(0.0);

   return((ask - bid) / point);
  }

//+------------------------------------------------------------------+
//| True the first time it is called on each new bar of the timeframe |
//+------------------------------------------------------------------+
bool GTP_IsNewBar(const string symbol, const ENUM_TIMEFRAMES tf, datetime &last_bar_time)
  {
   datetime current = (datetime)SeriesInfoInteger(symbol, tf, SERIES_LASTBAR_DATE);

   if(current == 0 || current == last_bar_time)
      return(false);

   last_bar_time = current;
   return(true);
  }

//+------------------------------------------------------------------+
//| Whether "hour" falls inside [start, end); wraps over midnight     |
//+------------------------------------------------------------------+
bool GTP_HourInSession(const int hour, const int start_hour, const int end_hour)
  {
   if(start_hour == end_hour)
      return(true);                       // 24h session

   if(start_hour < end_hour)
      return(hour >= start_hour && hour < end_hour);

   return(hour >= start_hour || hour < end_hour);
  }
//+------------------------------------------------------------------+
